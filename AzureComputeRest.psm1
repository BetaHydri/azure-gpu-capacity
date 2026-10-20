#Requires -Version 5.1

function Get-AzureComputeHttpClient {
    <#
    .SYNOPSIS
        Erstellt den internen REST-Client ohne automatische Weiterleitungen.
    #>
    [CmdletBinding()]
    [OutputType([System.Net.Http.HttpClient])]
    param (
        [Parameter(Mandatory)]
        [ValidateRange(1, 16)]
        [int]$ThrottleLimit
    )

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.MaxConnectionsPerServer = $ThrottleLimit
    $handler.AutomaticDecompression =
        [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    [System.Net.Http.HttpClient]::new($handler)
}


function Get-AzureComputeRestData {
    <#
    .SYNOPSIS
        Liest Compute-REST-Listen parallel je Region mit Pagination und begrenzten Wiederholungen.
    .DESCRIPTION
        Interner Transport fuer die beiden Abfrageskripte. Liefert ein Objekt
        mit Location und Items je vollstaendig gelesener Region.
        AllLocations ist nur fuer den SKU-Katalog erlaubt.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Context,

        [Parameter(Mandatory)]
        [ValidateSet('Skus', 'Usage')]
        [string]$Resource,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Location,

        [Parameter()]
        [ValidateRange(1, 16)]
        [int]$ThrottleLimit = 4
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop

    $endpoint = [uri]$Context.Environment.ResourceManagerUrl
    if (-not $endpoint.IsAbsoluteUri -or $endpoint.Scheme -ne 'https' -or $endpoint.UserInfo) {
        throw 'Der Azure-Kontext muss einen absoluten HTTPS-Resource-Manager-Endpunkt enthalten.'
    }
    $baseUrl = $endpoint.AbsoluteUri.TrimEnd('/')
    $subscriptionPath = "/subscriptions/$($Context.Subscription.Id)/providers/Microsoft.Compute"
    $pending = [System.Collections.Generic.Queue[object]]::new()
    foreach ($region in ($Location | Select-Object -Unique)) {
        if ($region -notmatch '^[a-zA-Z0-9]+$' -or
            ($Resource -eq 'Usage' -and $region -eq 'AllLocations')) {
            throw "Ungueltige Region fuer $Resource : '$region'."
        }
        if ($Resource -eq 'Skus') {
            $url = "$baseUrl$subscriptionPath/skus?api-version=2021-07-01"
            if ($region -ne 'AllLocations') {
                $filter = [uri]::EscapeDataString("location eq '$region'")
                $url += '&$filter=' + $filter
            }
        } else {
            $url = "$baseUrl$subscriptionPath/locations/$region/usages?api-version=2025-04-01"
        }
        $seen = [System.Collections.Generic.HashSet[string]]::new()
        [void]$seen.Add($url)
        $pending.Enqueue([PSCustomObject]@{
            Location = $region
            Uri      = [uri]$url
            Path     = ([uri]$url).AbsolutePath
            Seen     = $seen
            Items    = [System.Collections.Generic.List[object]]::new()
            Attempt  = 0
            ReadyAt  = [DateTimeOffset]::UtcNow
            Task     = $null
        })
    }

    $accessToken = Get-AzAccessToken -ResourceUrl $endpoint.AbsoluteUri -DefaultProfile $Context -ErrorAction Stop
    $bearer = if ($accessToken.Token -is [securestring]) {
        [System.Net.NetworkCredential]::new('', $accessToken.Token).Password
    } else {
        [string]$accessToken.Token
    }
    if ([string]::IsNullOrWhiteSpace($bearer)) {
        throw 'Azure hat kein verwendbares ARM-Zugriffstoken geliefert.'
    }

    $client = Get-AzureComputeHttpClient -ThrottleLimit $ThrottleLimit
    $active = [System.Collections.Generic.List[object]]::new()
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(120)
        $client.DefaultRequestHeaders.Authorization =
            [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $bearer)
        $bearer = $null
        $accessToken = $null

        while ($pending.Count -gt 0 -or $active.Count -gt 0) {
            while ($pending.Count -gt 0 -and $active.Count -lt $ThrottleLimit) {
                $active.Add($pending.Dequeue())
            }
            foreach ($state in $active.ToArray()) {
                if ($null -eq $state.Task -and $state.ReadyAt -le [DateTimeOffset]::UtcNow) {
                    Write-Verbose "REST $Resource : $($state.Location)"
                    $state.Task = $client.GetAsync($state.Uri)
                }
                if ($null -eq $state.Task -or -not $state.Task.IsCompleted) {
                    continue
                }

                try {
                    $response = $state.Task.GetAwaiter().GetResult()
                } catch [System.Net.Http.HttpRequestException], [System.OperationCanceledException] {
                    $transportError = $_
                    if ($state.Attempt -ge 3) {
                        throw (
                            "REST $Resource / $($state.Location): Transportfehler nach drei Wiederholungen. " +
                            $transportError.Exception.Message
                        )
                    }
                    $state.Attempt++
                    $delay = [Math]::Pow(2, $state.Attempt)
                    Write-Warning (
                        "REST $Resource / $($state.Location): Transportfehler; " +
                        "Wiederholung $($state.Attempt)/3 nach $delay Sekunden."
                    )
                    $state.ReadyAt = [DateTimeOffset]::UtcNow.AddSeconds($delay)
                    $state.Task = $null
                    continue
                }
                try {
                    $status = [int]$response.StatusCode
                    if ($status -in @(408, 429, 500, 502, 503, 504) -and $state.Attempt -lt 3) {
                        $state.Attempt++
                        $delay = [Math]::Pow(2, $state.Attempt)
                        $retryAfter = $response.Headers.RetryAfter
                        if ($null -ne $retryAfter) {
                            if ($null -ne $retryAfter.Delta) {
                                $delay = [Math]::Max(0, $retryAfter.Delta.TotalSeconds)
                            } elseif ($null -ne $retryAfter.Date) {
                                $delay = [Math]::Max(
                                    0, ($retryAfter.Date - [DateTimeOffset]::UtcNow).TotalSeconds
                                )
                            }
                        }

                        Export-ModuleMember -Function Get-AzureComputeRestData
                        Write-Warning (
                            "REST $Resource / $($state.Location): HTTP $status; " +
                            "Wiederholung $($state.Attempt)/3 nach $delay Sekunden."
                        )
                        $state.ReadyAt = [DateTimeOffset]::UtcNow.AddSeconds($delay)
                        $state.Task = $null
                        continue
                    }

                    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    if (-not $response.IsSuccessStatusCode) {
                        $detail = $body.Substring(0, [Math]::Min(500, $body.Length))
                        throw "REST $Resource / $($state.Location): HTTP $status. $detail"
                    }
                    $page = ConvertFrom-Json -InputObject $body -ErrorAction Stop
                    if ($null -eq $page -or -not $page.PSObject.Properties['value'] -or
                        $page.value -isnot [array]) {
                        throw "REST $Resource / $($state.Location): Antwort ohne gueltiges value-Array."
                    }
                    foreach ($item in $page.value) {
                        if ($null -eq $item) {
                            throw "REST $Resource / $($state.Location): Null-Eintrag im value-Array."
                        }
                        $state.Items.Add($item)
                    }
                    $state.Attempt = 0
                    $state.Task = $null

                    if ($page.PSObject.Properties['nextLink'] -and
                        -not [string]::IsNullOrWhiteSpace($page.nextLink)) {
                        $nextUri = [uri]::new($state.Uri, [string]$page.nextLink)
                        # Pagination darf das Bearer-Token nicht an einen anderen Dienst weiterreichen.
                        if ($nextUri.Scheme -ne 'https' -or $nextUri.Authority -ne $endpoint.Authority -or
                            $nextUri.AbsolutePath -ne $state.Path -or $nextUri.UserInfo -or $nextUri.Fragment) {
                            throw "REST $Resource / $($state.Location): Unsicherer nextLink abgelehnt."
                        }
                        if (-not $state.Seen.Add($nextUri.AbsoluteUri)) {
                            throw "REST $Resource / $($state.Location): Wiederholter nextLink; Abbruch."
                        }
                        $state.Uri = $nextUri
                    } else {
                        [PSCustomObject]@{
                            Location = $state.Location
                            Items    = $state.Items.ToArray()
                        }
                        [void]$active.Remove($state)
                    }
                } finally {
                    $response.Dispose()
                }
            }
            if ($active.Count -gt 0) {
                Start-Sleep -Milliseconds 25
            }
        }
    } finally {
        $client.CancelPendingRequests()
        foreach ($state in $active) {
            if ($null -ne $state.Task -and $state.Task.Status -eq 'RanToCompletion') {
                $state.Task.GetAwaiter().GetResult().Dispose()
            }
        }
        $client.Dispose()
        $bearer = $null
        $accessToken = $null
    }
}
