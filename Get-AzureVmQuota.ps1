#Requires -Version 5.1
#Requires -Modules Az.Accounts

<#
.SYNOPSIS
    Fragt regionale VM-Quotas und deren aktuelle Auslastung ab.
.DESCRIPTION
    Rein lesende Abfrage. Optional werden eine VM-Familie und die gesamte
    regionale vCPU-Quota (cores) fuer einen zusaetzlichen vCPU-Bedarf verglichen.
    Quota-Headroom ist keine Zusage freier physischer Kapazitaet.
.PARAMETER SubscriptionId
    Erwartete Subscription-ID. Muss zum aktuellen Az-Kontext passen.
.PARAMETER Location
    Eine oder mehrere Azure-Regionen.
.PARAMETER Family
    Exakter Quota-Familienname aus Get-AzureGpuSku.ps1. cores wird zusaetzlich ausgegeben.
.PARAMETER RequiredVCpu
    Zusaetzlich benoetigte vCPUs, beispielsweise VM-Anzahl mal vCPUs je VM.
    Nur zusammen mit Family; kein Gesamturteil ueber die Deploybarkeit.
.PARAMETER UseRest
    Nutzt parallele HttpClient-REST-Abfragen statt der bisherigen Az.Compute-Cmdlets.
.PARAMETER ThrottleLimit
    Maximale Zahl gleichzeitig abgefragter Regionen im REST-Modus. Standard: 4.
.EXAMPLE
    .\Get-AzureVmQuota.ps1 -SubscriptionId $subscriptionId -Location westeurope
.EXAMPLE
    .\Get-AzureVmQuota.ps1 -SubscriptionId $subscriptionId -Location westeurope -Family $family -RequiredVCpu 60
.OUTPUTS
    System.Management.Automation.PSCustomObject
#>
[CmdletBinding(DefaultParameterSetName = 'List')]
[OutputType([PSCustomObject])]
param (
    [Parameter(Mandatory)]
    [guid]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[a-zA-Z0-9]+$')]
    [string[]]$Location,

    [Parameter(ParameterSetName = 'List')]
    [Parameter(Mandatory, ParameterSetName = 'Check')]
    [ValidateNotNullOrEmpty()]
    [string]$Family,

    [Parameter(Mandatory, ParameterSetName = 'Check')]
    [ValidateRange(1, 2147483647)]
    [int]$RequiredVCpu,

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

$queriedAt = [DateTime]::UtcNow.ToString('o')
$checkRequired = $PSBoundParameters.ContainsKey('RequiredVCpu')
$processRegion = {
    $region = $_.Location
    $usage = @($_.Items)
    if ($usage.Count -eq 0) {
        throw (
            "Azure hat keine VM-Quota-Daten fuer '$region' geliefert. " +
            'Microsoft.Compute-Registrierung und Subscription-Zugriff pruefen. Abfrage unvollstaendig.'
        )
    }
    if ($Family) {
        foreach ($requiredName in (@('cores', $Family) | Select-Object -Unique)) {
            if (-not ($usage | Where-Object { $_.Name.Value -eq $requiredName })) {
                throw "Quota '$requiredName' in '$region' nicht gemeldet. Kein gueltiger Quota-Vergleich."
            }
        }
        $usage = @($usage | Where-Object { $_.Name.Value -in @('cores', $Family) })
    }

    foreach ($entry in $usage) {
        if ($null -eq $entry.CurrentValue -or $null -eq $entry.Limit) {
            throw "Unvollstaendige Quota-Werte fuer '$($entry.Name.Value)' in '$region'."
        }
        $remaining = [long]$entry.Limit - [long]$entry.CurrentValue
        [PSCustomObject]@{
            QueriedAtUtc     = $queriedAt
            SubscriptionId   = $context.Subscription.Id
            Location         = $region
            QuotaName        = $entry.Name.Value
            DisplayName      = if ($entry.Name.PSObject.Properties['LocalizedValue']) {
                $entry.Name.LocalizedValue
            } else { $null }
            CurrentValue     = $entry.CurrentValue
            Limit            = $entry.Limit
            Remaining        = $remaining
            RequiredVCpu     = if ($checkRequired) { $RequiredVCpu } else { $null }
            HasQuotaHeadroom = if ($checkRequired) {
                $remaining -ge $RequiredVCpu
            } else {
                $null
            }
        }

    }
}

if ($UseRest) {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'AzureComputeRest.psm1') -ErrorAction Stop
    $restParameters = @{
        Context       = $context
        Resource      = 'Usage'
        Location      = $Location
        ThrottleLimit = $ThrottleLimit
    }
    Get-AzureComputeRestData @restParameters | ForEach-Object -Process $processRegion
} else {
    Import-Module -Name Az.Compute -ErrorAction Stop
    foreach ($region in ($Location | Select-Object -Unique)) {
        Write-Verbose "Lese VM-Quota: $region"
        [PSCustomObject]@{
            Location = $region
            Items    = @(Get-AzVMUsage -Location $region -DefaultProfile $context -ErrorAction Stop)
        } | ForEach-Object -Process $processRegion
    }
}
