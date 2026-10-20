#Requires -Version 5.1
#Requires -Modules Az.Accounts

<#
.SYNOPSIS
    Fragt GPU-VM-SKUs, Regionen, Zonen und gemeldete Einschraenkungen ab.
.DESCRIPTION
    Rein lesende Abfrage im bereits angemeldeten Azure-Kontext.
    Gibt eine Zeile je SKU und Region aus. Keine Aussage ueber freie Hardware.
    GPU-Hersteller werden nicht aus dem Namen oder der CPU abgeleitet.
.PARAMETER SubscriptionId
    Erwartete Subscription-ID. Muss zum aktuellen Az-Kontext passen.
.PARAMETER Location
    Eine oder mehrere Azure-Regionen, beispielsweise westeurope und northeurope.
.PARAMETER AllLocations
    Fragt alle vom SKU-Katalog gemeldeten Regionen ab. Kann laenger dauern.
.PARAMETER SkuName
    Optional: exakte SKU-Namen. Keine Wildcards oder Herstellererkennung.
.PARAMETER SkuPattern
    Optional: PowerShell-Wildcards fuer GPU-SKU-Namen. Nicht mit SkuName kombinieren.
.PARAMETER UseRest
    Nutzt parallele HttpClient-REST-Abfragen statt der bisherigen Az.Compute-Cmdlets.
.PARAMETER ThrottleLimit
    Maximale Zahl gleichzeitig abgefragter Regionen im REST-Modus. Standard: 4.
.EXAMPLE
    .\Get-AzureGpuSku.ps1 -SubscriptionId $subscriptionId -Location westeurope
.EXAMPLE
    .\Get-AzureGpuSku.ps1 -SubscriptionId $subscriptionId -AllLocations -SkuName Standard_NV6ads_A10_v5
.EXAMPLE
    .\Get-AzureGpuSku.ps1 -SubscriptionId $subscriptionId -Location westeurope,northeurope -UseRest
.OUTPUTS
    System.Management.Automation.PSCustomObject
#>
[CmdletBinding(DefaultParameterSetName = 'ByLocation')]
[OutputType([PSCustomObject])]
param (
    [Parameter(Mandatory)]
    [guid]$SubscriptionId,

    [Parameter(Mandatory, ParameterSetName = 'ByLocation')]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[a-zA-Z0-9]+$')]
    [string[]]$Location,

    [Parameter(Mandatory, ParameterSetName = 'AllLocations')]
    [switch]$AllLocations,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$SkuName,

    [Parameter()]
    [SupportsWildcards()]
    [ValidateNotNullOrEmpty()]
    [string[]]$SkuPattern,

    [Parameter()]
    [switch]$UseRest,

    [Parameter()]
    [ValidateRange(1, 16)]
    [int]$ThrottleLimit = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$context = Get-AzContext -ErrorAction Stop
if (-not $context -or -not $context.Subscription) {
    throw 'Kein Azure-Kontext. Zuerst Connect-AzAccount und Set-AzContext ausfuehren.'
}
if ($context.Subscription.Id -ne $SubscriptionId.ToString()) {
    throw "Falsche Subscription im Az-Kontext. Set-AzContext -SubscriptionId '$SubscriptionId' ausfuehren."
}
if ($PSCmdlet.ParameterSetName -eq 'AllLocations' -and -not $AllLocations) {
    throw 'AllLocations darf nicht explizit auf false gesetzt werden. Alternativ Location angeben.'
}
if ($SkuName -and $SkuPattern) {
    throw 'SkuName und SkuPattern nicht kombinieren. Exakte Namen oder Wildcards waehlen.'
}

$queryLocations = if ($AllLocations) { @('AllLocations') } else { @($Location | Select-Object -Unique) }
$queriedAt = [DateTime]::UtcNow.ToString('o')

$processRegion = {
    $queryLocation = $_.Location
    $matchedNames = @{}
    $matchedPatterns = @{}

    foreach ($sku in $_.Items) {
        $matchingPatterns = @($SkuPattern | Where-Object { $sku.Name -like $_ })
        if ($sku.ResourceType -eq 'virtualMachines' -and
            (-not $SkuName -or $sku.Name -in $SkuName) -and
            (-not $SkuPattern -or $matchingPatterns.Count -gt 0)) {
            $capabilities = @{}
            foreach ($capability in $sku.Capabilities) {
                $capabilities[$capability.Name] = $capability.Value
            }
            if ($capabilities.ContainsKey('GPUs') -and [double]$capabilities['GPUs'] -gt 0) {
                $matchedNames[$sku.Name] = $true
                foreach ($pattern in $matchingPatterns) {
                    $matchedPatterns[$pattern] = $true
                }
                $restrictions = @()
                if ($sku.PSObject.Properties['Restrictions']) {
                    $restrictions = @($sku.Restrictions | Where-Object { $null -ne $_ })
                }
                $restrictionsJson = ConvertTo-Json -InputObject $restrictions -Depth 20 -Compress
                foreach ($skuLocation in $sku.Locations) {
                    if ($AllLocations -or $skuLocation -eq $queryLocation) {
                        $zones = @()
                        if ($sku.PSObject.Properties['LocationInfo']) {
                            $zones = @(
                                $sku.LocationInfo |
                                    Where-Object { $_.Location -eq $skuLocation } |
                                    ForEach-Object {
                                        if ($_.PSObject.Properties['Zones']) { $_.Zones }
                                    } |
                                    Sort-Object -Unique
                            )
                        }
                        [PSCustomObject]@{
                            QueriedAtUtc            = $queriedAt
                            SubscriptionId          = $context.Subscription.Id
                            Location                = $skuLocation
                            SkuName                 = $sku.Name
                            Family                  = if ($sku.PSObject.Properties['Family']) {
                                $sku.Family
                            } else { $null }
                            VCpus                   = $capabilities['vCPUs']
                            MemoryGB                = $capabilities['MemoryGB']
                            GpuCapability           = $capabilities['GPUs']
                            Zones                   = $zones -join ','
                            HasReportedRestrictions = $restrictions.Count -gt 0
                            RestrictionsJson        = $restrictionsJson
                            PhysicalCapacity        = 'NotQueried'
                        }
                    }
                }
            }
        }
    }

    if ($matchedNames.Count -eq 0) {
        Write-Warning "Keine passenden GPU-SKUs gemeldet: $queryLocation. Keine Kapazitaetsaussage."
    }
    foreach ($requestedName in $SkuName) {
        if (-not $matchedNames.ContainsKey($requestedName)) {
            Write-Warning "GPU-SKU '$requestedName' nicht gemeldet: $queryLocation."
        }
    }
    foreach ($pattern in $SkuPattern) {
        if (-not $matchedPatterns.ContainsKey($pattern)) {
            Write-Warning "Keine GPU-SKU fuer Muster '$pattern' gemeldet: $queryLocation."
        }
    }
}

if ($UseRest) {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'AzureComputeRest.psm1') -ErrorAction Stop
    $restParameters = @{
        Context       = $context
        Resource      = 'Skus'
        Location      = $queryLocations
        ThrottleLimit = $ThrottleLimit
    }
    Get-AzureComputeRestData @restParameters | ForEach-Object -Process $processRegion
} else {
    Import-Module -Name Az.Compute -ErrorAction Stop
    foreach ($queryLocation in $queryLocations) {
        $parameters = @{
            DefaultProfile = $context
            ErrorAction    = 'Stop'
        }
        if (-not $AllLocations) {
            $parameters.Location = $queryLocation
        }
        Write-Verbose "Lese GPU-SKU-Katalog: $queryLocation"
        [PSCustomObject]@{
            Location = $queryLocation
            Items    = @(Get-AzComputeResourceSku @parameters)
        } | ForEach-Object -Process $processRegion
    }
}
