# Beispiele fuer Azure-GPU- und Quota-Abfragen

Kopierbare PowerShell-Beispiele fuer
[Get-AzureGpuSku.ps1](./Get-AzureGpuSku.ps1) und
[Get-AzureVmQuota.ps1](./Get-AzureVmQuota.ps1).
Zuerst die Vorbereitung ausfuehren, danach das gewuenschte Beispiel.
Die Anmeldung und `$subscriptionId` gelten fuer die aktuelle Sitzung.

**Wichtig:** Die Skripte lesen den SKU-Katalog und Quota-Werte.
Sie erstellen keine VMs und reservieren keine Hardware.
Ausreichende Quota und ein gelisteter SKU garantieren keine freie Kapazitaet.

## 1. Vorbereitung und Anmeldung

Voraussetzung: Windows PowerShell 5.1 oder PowerShell 7 sowie Leserechte
auf die Ziel-Subscription. Nur bei fehlenden Modulen installieren:

```powershell
Install-Module -Name Az.Accounts, Az.Compute -Scope CurrentUser -Repository PSGallery
```

In einer PowerShell-Sitzung anmelden. Den Platzhalter durch die eigene
Subscription-ID im GUID-Format ersetzen:

```powershell
Set-Location -LiteralPath 'C:\temp\Troubleshoot\AzureGpuCapacity'
$ErrorActionPreference = 'Stop'
$subscriptionId = '<subscription-id>'

Connect-AzAccount
Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop
Get-AzContext
```

Bei mehreren Tenants kann die Anmeldung stattdessen mit
`Connect-AzAccount -Tenant '<tenant-id>'` erfolgen.
Die Skripte erwarten einen bereits passenden Kontext und wechseln diesen
nicht automatisch.

## 2. Alle GPU-Groessen in einer Region anzeigen

```powershell
$gpu = @(
    .\Get-AzureGpuSku.ps1 -SubscriptionId $subscriptionId -Location westeurope
)

$gpu |
    Sort-Object -Property SkuName |
    Format-Table SkuName, Family, VCpus, GpuCapability, Zones, HasReportedRestrictions -AutoSize
```

Das Ergebnis enthaelt alle gemeldeten GPU-Hersteller, nicht nur NVIDIA.
Eingeschraenkte SKUs werden nicht ausgeblendet.
`GpuCapability` ist der Originalwert aus Azure, keine Herstellerkennung
oder Garantie einer vollstaendigen dedizierten GPU.

## 3. Mehrere Regionen vergleichen

```powershell
$query = @{
    SubscriptionId = $subscriptionId
    Location       = @('westeurope', 'northeurope', 'germanywestcentral')
}
$gpu = @(.\Get-AzureGpuSku.ps1 @query)

$gpu |
    Sort-Object -Property SkuName, Location |
    Format-Table Location, SkuName, Zones, HasReportedRestrictions -AutoSize
```

Eine Ergebniszeile steht fuer einen SKU in einer Region.
Warnungen zu nicht gemeldeten SKUs sind keine Live-Kapazitaetsmessung.

## 4. Regionen fuer NVIDIA-Beispielgroessen finden

Die Liste ist eine explizite Auswahl bekannter NVIDIA-Groessen, kein
vollstaendiger NVIDIA-Katalog und keine Zusage regionaler Verfuegbarkeit.

```powershell
$query = @{
    SubscriptionId = $subscriptionId
    AllLocations   = $true
    SkuName        = @(
        'Standard_NC4as_T4_v3'
        'Standard_NC24ads_A100_v4'
        'Standard_NV6ads_A10_v5'
    )
}
$gpu = @(.\Get-AzureGpuSku.ps1 @query)

$gpu |
    Sort-Object -Property SkuName, Location |
    Format-Table SkuName, Location, Zones, HasReportedRestrictions -AutoSize
```

Die Beispiele verwenden T4, A100 beziehungsweise einen Anteil einer A10.
`SkuName` akzeptiert exakte Namen. Fuer Wildcards stattdessen `SkuPattern`
verwenden; beide Parameter nicht kombinieren.
`AllLocations` darf nicht zusammen mit `Location` verwendet werden.
Die regionsuebergreifende Abfrage kann laenger dauern.

## 5. Einschraenkungen und Zonen genauer ansehen

```powershell
$query = @{
    SubscriptionId = $subscriptionId
    Location       = 'westeurope'
    SkuName        = 'Standard_NV6ads_A10_v5'
}
$gpu = @(.\Get-AzureGpuSku.ps1 @query)

$gpu | Format-List Location, SkuName, Zones, HasReportedRestrictions, RestrictionsJson

foreach ($row in $gpu) {
    Write-Information -MessageData "$($row.SkuName) / $($row.Location)" -InformationAction Continue
    ConvertFrom-Json -InputObject $row.RestrictionsJson | Format-List *
}
```

`HasReportedRestrictions` meldet Einschraenkungen am SKU.
Bei globalen Abfragen koennen diese auch andere Regionen betreffen.
In `RestrictionsJson` insbesondere `Type`, `ReasonCode` und
`RestrictionInfo` mit dem geplanten Standort und der Zone vergleichen.

`Zones` zeigt beworbene Zonen, nicht deren freie Hardwarekapazitaet.
Ein leeres `RestrictionsJson`-Array ist keine Deploybarkeitsgarantie.

## 6. Alle VM-Quotas einer oder mehrerer Regionen anzeigen

```powershell
$query = @{
    SubscriptionId = $subscriptionId
    Location       = @('westeurope', 'northeurope')
}
$quota = @(.\Get-AzureVmQuota.ps1 @query)

$quota |
    Sort-Object -Property Location, QuotaName |
    Format-Table Location, QuotaName, CurrentValue, Limit, Remaining -AutoSize
```

`Remaining` entspricht `Limit - CurrentValue`.
Ohne `Family` werden auch andere VM-Quota-Kategorien ausgegeben.
Ohne `RequiredVCpu` bleiben `RequiredVCpu` und `HasQuotaHeadroom` leer:
Es wurde dann kein konkreter Zusatzbedarf geprueft.

## 7. Vollstaendiges UAT-Beispiel fuer zehn zusaetzliche GPU-VMs

Dieses Beispiel ermittelt Familie und vCPUs aus dem SKU-Katalog.
Anschliessend prueft es den zusaetzlichen Bedarf gegen die Familienquota
und die gesamte regionale vCPU-Quota.

```powershell
$vmCount = 10
$skuQuery = @{
    SubscriptionId = $subscriptionId
    Location       = 'westeurope'
    SkuName        = 'Standard_NV6ads_A10_v5'
}
$selected = @(.\Get-AzureGpuSku.ps1 @skuQuery)

if ($selected.Count -ne 1) {
    throw 'Keine eindeutige SKU fuer diese Region gemeldet. Auswahl pruefen.'
}
$sku = $selected[0]
if ([string]::IsNullOrWhiteSpace($sku.VCpus) -or
    [string]::IsNullOrWhiteSpace($sku.Family)) {
    throw 'vCPUs oder Quota-Familie fehlen. Kein verlaesslicher Vergleich moeglich.'
}
if ([int]$sku.VCpus -lt 1) {
    throw 'Die gemeldete vCPU-Anzahl ist ungueltig.'
}

$quotaQuery = @{
    SubscriptionId = $subscriptionId
    Location       = $sku.Location
    Family         = $sku.Family
    RequiredVCpu   = $vmCount * [int]$sku.VCpus
}
$quota = @(.\Get-AzureVmQuota.ps1 @quotaQuery)

$sku | Format-List SkuName, Location, Family, VCpus, Zones, RestrictionsJson
$quota |
    Format-Table QuotaName, CurrentValue, Limit, Remaining, RequiredVCpu, HasQuotaHeadroom -AutoSize

$insufficient = @($quota | Where-Object { $_.HasQuotaHeadroom -eq $false })
if ($quota.Count -ne 2) {
    throw 'Erwartet wurden Familienquota und gesamte regionale vCPU-Quota.'
}
if ($insufficient.Count -gt 0) {
    Write-Warning 'Mindestens eine Quota reicht fuer den zusaetzlichen UAT-Bedarf nicht aus.'
} else {
    Write-Information -MessageData (
        'Beide Quotas reichen aus. SKU-/Zonenrestriktionen und physische Kapazitaet separat pruefen.'
    ) -InformationAction Continue
}
```

Beispielwerte zur Erklaerung, **keine echten Azure-Abfrageergebnisse**:

| Quota | Aktuell | Limit | Rest | Zusatzbedarf | Ausreichend |
|---|---:|---:|---:|---:|---|
| Regionale vCPUs (`cores`) | 20 | 100 | 80 | 60 | Ja |
| GPU-Familie | 12 | 60 | 48 | 60 | Nein |

Obwohl die regionale Quota ausreicht, fehlen in diesem Beispiel
12 vCPUs in der Familienquota.
Bei mehreren Familien muss auch deren gemeinsamer regionaler Zusatzbedarf
beruecksichtigt werden. Die Beispiele bewerten keine Spot-Deployments.

## 8. GPU- und Quota-Ergebnisse als CSV und JSON speichern

Die Abfragen werden vor dem Export vollstaendig abgeschlossen.
Bei Fehlern bricht das Beispiel ab, statt einen Teilbericht zu exportieren.
Die Dateien werden im aktuellen Skriptverzeichnis gespeichert.

```powershell
$query = @{
    SubscriptionId = $subscriptionId
    Location       = @('westeurope', 'northeurope')
}
$gpu = @(.\Get-AzureGpuSku.ps1 @query)
$quota = @(.\Get-AzureVmQuota.ps1 @query)
if ($gpu.Count -eq 0) {
    throw 'Keine GPU-SKUs gemeldet. Warnungen pruefen; kein GPU-Bericht exportiert.'
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$gpuCsv = Join-Path -Path $PWD.Path -ChildPath "gpu-skus-$stamp.csv"
$gpuJson = Join-Path -Path $PWD.Path -ChildPath "gpu-skus-$stamp.json"
$quotaCsv = Join-Path -Path $PWD.Path -ChildPath "vm-quota-$stamp.csv"

$gpu | Export-Csv -LiteralPath $gpuCsv -NoTypeInformation -Encoding UTF8
ConvertTo-Json -InputObject $gpu -Depth 20 |
    Set-Content -LiteralPath $gpuJson -Encoding UTF8
$quota | Export-Csv -LiteralPath $quotaCsv -NoTypeInformation -Encoding UTF8
```

`RestrictionsJson` bleibt im CSV als JSON-Zeichenkette erhalten.
Warnungen ueber einzelne fehlende SKUs oder Regionen weiterhin beachten.
Berichte enthalten Subscription-IDs und sind intern entsprechend zu
behandeln. Die gespeicherten Werte sind Momentaufnahmen.

## 9. Hilfe und Fehlersuche

```powershell
Get-Help -Name .\Get-AzureGpuSku.ps1 -Full
Get-Help -Name .\Get-AzureVmQuota.ps1 -Examples

.\Get-AzureVmQuota.ps1 -SubscriptionId $subscriptionId -Location westeurope -Verbose
```

| Meldung oder Situation | Vorgehen |
|---|---|
| Module fehlen | `Az.Accounts` und `Az.Compute` installieren |
| Kein Azure-Kontext | `Connect-AzAccount` und `Set-AzContext` ausfuehren |
| Falsche Subscription | GUID und aktuellen Az-Kontext vergleichen |
| Zugriff verweigert | Leserechte fuer Compute-SKUs und Usage pruefen lassen |
| GPU-SKU nicht gemeldet | Exakten Namen und Region pruefen; keine Kapazitaetsaussage ableiten |
| Quota nicht gemeldet | `Family` aus dem SKU-Ergebnis uebernehmen; Namen nicht erraten |
| Keine VM-Quota-Daten geliefert | `Microsoft.Compute`-Registrierung pruefen; eine leere Liste ist keine Quota von `0` |
| Quota-Limit ist `0` vCPUs | Vor Deployment Quota-Erhoehung pruefen |
| `HasQuotaHeadroom` ist leer | Fuer einen Vergleich `Family` und `RequiredVCpu` gemeinsam angeben |

API-Fehler nicht als leere oder erfolgreiche Abfrage behandeln.
Eine physische Kapazitaetszusage erfordert einen anderen Mechanismus,
beispielsweise eine erfolgreiche, fuer die konkrete GPU-Serie unterstuetzte
On-demand Capacity Reservation. Diese ist kostenpflichtig und wird durch
keines der Beispiele eingerichtet.

## 10. Viele Regionen parallel ueber REST abfragen

Die Beispiele 1 bis 9 funktionieren weiterhin unveraendert.
`UseRest` schaltet nur den Transport um; `ThrottleLimit` begrenzt
gleichzeitig abgefragte Regionen. Der REST-Modus benoetigt `Az.Accounts`
und die mitgelieferte [AzureComputeRest.psm1](./AzureComputeRest.psm1).
Er funktioniert unter Windows PowerShell 5.1 und PowerShell 7.

```powershell
$query = @{
    SubscriptionId = $subscriptionId
    Location       = @(
        'westeurope'
        'northeurope'
        'germanywestcentral'
        'francecentral'
        'uksouth'
        'swedencentral'
        'switzerlandnorth'
        'italynorth'
        'polandcentral'
        'spaincentral'
    )
    UseRest        = $true
    ThrottleLimit  = 4
}
$gpu = @(.\Get-AzureGpuSku.ps1 @query)
$quota = @(.\Get-AzureVmQuota.ps1 @query)

$gpu |
    Sort-Object -Property Location, SkuName |
    Format-Table Location, SkuName, Zones, HasReportedRestrictions -AutoSize
$quota |
    Where-Object { $_.QuotaName -eq 'cores' } |
    Sort-Object -Property Location |
    Format-Table Location, CurrentValue, Limit, Remaining -AutoSize
```

Die Regionenauswahl ist beispielhaft; GPU-Angebot und Subscription-Zugriff
koennen sich je Region unterscheiden. Eine fehlgeschlagene Regionsabfrage
bricht den Lauf ab. Warnungen und Fehler nicht als freie Kapazitaet werten.
Die Ausgabe wird wegen paralleler Requests nicht zwingend in Eingabereihenfolge
geliefert; deshalb wird sie explizit sortiert.

Auch Quota-Vergleiche aus Beispiel 7 koennen REST verwenden:

```powershell
$skuQuery = @{
    SubscriptionId = $subscriptionId
    Location       = 'westeurope'
    SkuName        = 'Standard_NV6ads_A10_v5'
    UseRest        = $true
}
$selected = @(.\Get-AzureGpuSku.ps1 @skuQuery)
if ($selected.Count -ne 1 -or [string]::IsNullOrWhiteSpace($selected[0].Family) -or
    [string]::IsNullOrWhiteSpace($selected[0].VCpus)) {
    throw 'Keine eindeutige SKU mit Familie und vCPU-Anzahl gemeldet.'
}
if ([int]$selected[0].VCpus -lt 1) {
    throw 'Ungueltige vCPU-Anzahl.'
}
$quotaQuery = @{
    SubscriptionId = $subscriptionId
    Location       = $selected[0].Location
    Family         = $selected[0].Family
    RequiredVCpu   = 10 * [int]$selected[0].VCpus
    UseRest        = $true
}
.\Get-AzureVmQuota.ps1 @quotaQuery |
    Format-Table QuotaName, Remaining, RequiredVCpu, HasQuotaHeadroom -AutoSize
```

## 11. GPU-Namen mit Wildcards filtern

```powershell
$query = @{
    SubscriptionId = $subscriptionId
    Location       = @('westeurope', 'northeurope')
    SkuPattern     = @('Standard_NV*ads_A10_v5', 'Standard_NC*as_T4_v3')
    UseRest        = $true
    ThrottleLimit  = 4
}
$gpu = @(.\Get-AzureGpuSku.ps1 @query)
$gpu | Format-Table Location, SkuName, Family, VCpus -AutoSize
```

`SkuPattern` funktioniert auch ohne REST. Es gelten PowerShell-Wildcards:
`*`, `?` und Zeichenklassen. Die Filterung erfolgt lokal nach dem Abruf,
weil die SKU-API nur den Regionsfilter serverseitig unterstuetzt.
Das Skript bleibt auf GPU-VMs beschraenkt; `Standard_D*_v5` waere daher
kein sinnvoller Filter. Wildcards erkennen keinen GPU-Hersteller automatisch.

## 12. Laufzeit auf der eigenen Verbindung vergleichen

Das Beispiel fuehrt echte lesende Azure-Abfragen in beiden Modi aus.
Beide Modi liefern die gleichen Datenarten; REST bietet kein Live-Inventar
freier Hardware. Mit `ThrottleLimit = 1` laesst sich auch der REST-Modus
bewusst sequenziell ausfuehren.

```powershell
$benchmarkQuery = @{
    SubscriptionId = $subscriptionId
    Location       = @('westeurope', 'northeurope', 'germanywestcentral')
}
$azTime = Measure-Command {
    $null = @(.\Get-AzureGpuSku.ps1 @benchmarkQuery)
}
$restTime = Measure-Command {
    $null = @(.\Get-AzureGpuSku.ps1 @benchmarkQuery -UseRest -ThrottleLimit 4)
}
[PSCustomObject]@{
    AzSeconds   = [Math]::Round($azTime.TotalSeconds, 2)
    RestSeconds = [Math]::Round($restTime.TotalSeconds, 2)
}
```

Erste Modulimporte, Token-Caches und wechselnde Azure-Last beeinflussen den
Vergleich. Fuer eine belastbare Messung mehrere erfolgreiche Durchlaeufe
mit wechselnder Reihenfolge vergleichen. Keine feste Laufzeit zusichern.
Bei HTTP 429 oder temporaeren Serverfehlern werden bis zu drei
Wiederholungen pro Seite durchgefuehrt; `Retry-After` wird beachtet.

## Weitere Informationen

- [Grundlagen, Voraussetzungen und Kapazitaetsgrenzen](./README.md)
- [GPU-SKU-Abfrageskript](./Get-AzureGpuSku.ps1)
- [VM-Quota-Abfrageskript](./Get-AzureVmQuota.ps1)
