# Azure GPU capacity queries

Lesende PowerShell-Abfragen fuer GPU-VM-SKUs, Regionen, Zonen,
Subscription-Einschraenkungen und VM-Quotas zur UAT-Planung.
Die Skripte erstellen, starten oder reservieren keine Azure-Ressourcen.

## Inhalt

| Datei | Zweck |
|---|---|
| [Get-AzureGpuSku.ps1](./Get-AzureGpuSku.ps1) | GPU-SKUs nach Region oder regionsuebergreifend abfragen |
| [Get-AzureVmQuota.ps1](./Get-AzureVmQuota.ps1) | VM-Quota, Verbrauch und optional zusaetzlichen vCPU-Bedarf pruefen |
| [AzureComputeRest.psm1](./AzureComputeRest.psm1) | Gemeinsamer REST-Transport mit begrenzter Parallelitaet, Pagination und Retries |
| [AzureGpuCapacity.Tests.ps1](./AzureGpuCapacity.Tests.ps1) | Offline-Pester-Tests mit simulierten HTTP-Antworten |
| [beispiele.md](./beispiele.md) | Kopierbare Praxisbeispiele, UAT-Bedarfspruefung, Exporte und Fehlersuche |

## Voraussetzungen und Anmeldung

- Windows PowerShell 5.1 oder PowerShell 7.
- Installiertes Modul `Az.Accounts`; fuer den bisherigen Modus auch `Az.Compute`.
- Azure-Anmeldung mit Leserechten fuer Compute-SKUs und Usage in der
  Subscription, beispielsweise Reader auf Subscription-Ebene.
- Ausgehender Zugriff auf Azure-Anmeldung und Azure Resource Manager.
- Fuer Quota-Abfragen muss `Microsoft.Compute` in der Subscription
  registriert sein. Sonst kann Azure HTTP 200 mit einer leeren Usage-Liste
  liefern, auch ueber die Az-Cmdlets. Das ist kein Quota-Wert von null.

Nur falls die Module fehlen, einmalig installieren:

```powershell
Install-Module -Name Az.Accounts, Az.Compute -Scope CurrentUser -Repository PSGallery
```

Anschliessend anmelden und die Ziel-Subscription explizit auswaehlen:

```powershell
Set-Location -LiteralPath 'C:\temp\Troubleshoot\AzureGpuCapacity'

$subscriptionId = '<subscription-id>'
Connect-AzAccount
Set-AzContext -SubscriptionId $subscriptionId
Get-AzContext
```

Bei mehreren Tenants `Connect-AzAccount -Tenant '<tenant-id>'` verwenden.
Die Skripte melden sich nicht automatisch an und wechseln den Kontext nicht.
Sie brechen ab, wenn der aktuelle Kontext nicht zur uebergebenen
Subscription-ID passt. Es werden keine Zugangsdaten gespeichert.

Bei einer leeren Quota-Liste laesst sich die Provider-Registrierung rein
lesend pruefen:

```powershell
$providerPath = '/subscriptions/{0}/providers/Microsoft.Compute?api-version=2021-04-01' -f $subscriptionId
$provider = Invoke-AzRestMethod -Path $providerPath -Method GET -ErrorAction Stop
(ConvertFrom-Json -InputObject $provider.Content).registrationState
```

Erwartet wird `Registered`. Eine Registrierung ist eine separate
Subscription-Aenderung und wird von diesen Skripten nicht ausgeloest.
Bei `NotRegistered` eine freigegebene Registrierung durch einen
entsprechend berechtigten Administrator veranlassen oder eine bereits
registrierte Subscription fuer den Test waehlen.

## Optionaler paralleler REST-Modus

Mit `-UseRest` fragen beide Skripte Azure Resource Manager direkt ueber
`HttpClient` ab. Ohne diesen Schalter bleiben die bisherigen
Az.Compute-Aufrufe aktiv. Ausgabeobjekte und Kapazitaetsgrenzen bleiben
gleich. Die Hilfsdatei [AzureComputeRest.psm1](./AzureComputeRest.psm1)
muss im gleichen Verzeichnis wie die beiden Skripte liegen.

```powershell
$query = @{
    SubscriptionId = $subscriptionId
    Location       = @('westeurope', 'northeurope', 'germanywestcentral')
    UseRest        = $true
    ThrottleLimit  = 4
}
$gpu = @(.\Get-AzureGpuSku.ps1 @query)
$quota = @(.\Get-AzureVmQuota.ps1 @query)
```

- `ThrottleLimit` begrenzt gleichzeitig abgefragte Regionen: 1 bis 16,
  Standard 4. Es wirkt nur im REST-Modus.
- SKU-Abfragen nutzen den serverseitigen Regionsfilter. Azure bietet hier
  keinen serverseitigen SKU-Namensfilter; Namen werden lokal ausgewertet.
- `AllLocations` liest einen globalen SKU-Katalog mit einer Pagination-Kette
  statt fuer jede Region den gesamten Katalog erneut zu laden.
- Alle `nextLink`-Seiten werden verfolgt. Seiten einer Region bleiben
  sequenziell; verschiedene Regionen werden parallel abgefragt.
- HTTP 408, 429, 500, 502, 503 und 504 werden maximal dreimal pro Seite
  wiederholt. `Retry-After` wird beruecksichtigt, sonst 2/4/8 Sekunden Pause.
  Verbindungsabbrueche und Request-Timeouts werden ebenfalls begrenzt
  wiederholt. Jede Anfrage hat ein Timeout von 120 Sekunden.
- GZip-/Deflate-Kompression reduziert die Uebertragungsmenge, sofern Azure
  die Antwort entsprechend komprimiert.
- Authentifizierung erfolgt ueber `Get-AzAccessToken` fuer den
  Resource-Manager-Endpunkt des aktuellen Azure-Kontexts. Tokens werden
  nicht protokolliert oder gespeichert. Weiterleitungen und fremde
  Pagination-Ziele werden abgelehnt.
- Permanente HTTP-/JSON-Fehler brechen ab. Es gibt keinen stillen
  Wechsel in den Az-Modus und keine vermeintlichen Erfolgsergebnisse.
- Die Reihenfolge der Regionen richtet sich nach dem Abschluss der
  Requests. Fuer Vergleiche explizit nach `Location` und SKU/Quota sortieren.

**REST ist kein anderer Kapazitaetsdatenbestand.** Auch die Az-Cmdlets
nutzen Azure-APIs. Der moegliche Vorteil liegt in weniger SDK-/Modul-Overhead
und paralleler I/O, insbesondere bei vielen Regionen. Fuer eine einzelne
Region oder einen globalen Katalog kann der Unterschied gering sein.
Eine Laufzeit von beispielsweise 15 Sekunden fuer zehn Regionen ist keine
Zusage: Seitenanzahl, Netzwerk, Azure-Last und Throttling beeinflussen sie.

Der verlinkte
[Get-AzVMAvailability-Ansatz](https://github.com/ZacharyLuz/Get-AzVMAvailability)
dient als fachlicher Vergleich; dessen Code wurde nicht uebernommen.
Pricing, Lifecycle-Inventar, Excel und Spot Placement Scores werden durch
diese Erweiterung nicht implementiert. Spot-Scores waeren zudem keine
Kapazitaetsbewertung fuer regulaere VMs.

## GPU-SKUs in bestimmten Regionen

```powershell
$query = @{
    SubscriptionId = $subscriptionId
    Location       = @('westeurope', 'northeurope')
}
$gpu = @(.\Get-AzureGpuSku.ps1 @query)

$gpu |
    Format-Table Location, SkuName, VCpus, GpuCapability, Zones, HasReportedRestrictions -AutoSize
```

Ohne `SkuName` werden alle GPU-Hersteller ausgegeben.
Die Abfragen liefern VM-Groessen aus dem Katalog, keine vorhandenen VMs.
GPU-SKUs mit gemeldeten Einschraenkungen bleiben sichtbar.

## NVIDIA-Beispiele und Suche nach Regionen

NVIDIA-GPUs werden ueber explizite, fachlich gepruefte SKU-Namen ausgewaehlt.
Es gibt hier bewusst keinen vermeintlich universellen Herstellerfilter:
Nicht jede N-/NV-Serie nutzt NVIDIA, und eine AMD-CPU kann mit einer
NVIDIA-GPU kombiniert sein.

`SkuName` bleibt ein exakter Filter. Optional kann stattdessen `SkuPattern`
mit PowerShell-Wildcards verwendet werden, zum Beispiel
`-SkuPattern 'Standard_NV*ads_A10_v5'`. Beide Parameter nicht kombinieren.
Auch mit Wildcards liefert das Skript nur GPU-SKUs; ein D-Serien-Muster
wie `Standard_D*_v5` liefert hier absichtlich keine CPU-only-VMs.

Beispiele, keine vollstaendige oder garantierte regionale Angebotsliste:

| SKU | NVIDIA-GPU |
|---|---|
| `Standard_NC4as_T4_v3` | T4 |
| `Standard_NC24ads_A100_v4` | A100 |
| `Standard_NV6ads_A10_v5` | Anteil einer A10 |

Regionsuebergreifende Suche nach diesen Groessen:

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
$gpu | Format-Table Location, SkuName, Zones, HasReportedRestrictions -AutoSize
```

`AllLocations` kann laenger dauern. Fuer regelmaessige Abfragen moeglichst
konkrete Regionen angeben. Keine Treffer werden explizit als Warnung gemeldet.
Ein nicht gelieferter SKU ist keine Aussage ueber freie Hardware.

## Ergebnisse richtig interpretieren

| Feld | Bedeutung |
|---|---|
| `QueriedAtUtc` | Zeitpunkt des Abfragestarts in UTC |
| `Family` | Quota-Familienname fuer die anschliessende Pruefung |
| `GpuCapability` | Originalwert der GPU-Capability; kein Hersteller und nicht zwingend eine dedizierte volle GPU |
| `Zones` | Fuer die Region beworbene Zonen; leer bedeutet keine gemeldeten Zonen |
| `HasReportedRestrictions` | Mindestens eine Einschraenkung am SKU gemeldet |
| `RestrictionsJson` | Vollstaendige gemeldete Einschraenkungen samt Region-/Zonenbezug |
| `PhysicalCapacity` | Immer `NotQueried`: kein Live-Inventar freier Hardware |

Bei regionsuebergreifenden Abfragen koennen die SKU-Einschraenkungen mehrere
Regionen betreffen. `HasReportedRestrictions` ist deshalb **kein**
abschliessendes Deploybarkeitsurteil fuer eine einzelne Region oder Zone.
Immer `RestrictionsJson`, insbesondere `RestrictionInfo`, `Type` und
`ReasonCode`, fuer den geplanten Standort auswerten.

```powershell
$gpu | Where-Object HasReportedRestrictions | Format-List *
```

Keine gemeldete Einschraenkung bedeutet weder ausreichende Quota noch
garantierte physische Kapazitaet. Auch eine leere Zonenliste ist keine
Kapazitaetsaussage.

## Quota und zusaetzlichen UAT-Bedarf pruefen

Alle regionalen Quota-Werte anzeigen:

```powershell
$quota = @(.\Get-AzureVmQuota.ps1 -SubscriptionId $subscriptionId -Location westeurope)
$quota | Format-Table QuotaName, DisplayName, CurrentValue, Limit, Remaining -AutoSize
```

Fuer eine GPU-Groesse erst deren Familie und vCPU-Anzahl ermitteln.
Dieses Beispiel prueft zehn zusaetzliche VMs:

```powershell
$query = @{
    SubscriptionId = $subscriptionId
    Location       = 'westeurope'
    SkuName        = 'Standard_NV6ads_A10_v5'
}
$selected = @(.\Get-AzureGpuSku.ps1 @query)
if ($selected.Count -ne 1) {
    throw 'Erwartet wurde genau eine SKU in einer Region. Auswahl pruefen.'
}
if ([string]::IsNullOrWhiteSpace($selected[0].VCpus)) {
    throw 'Keine vCPU-Anzahl gemeldet. Bedarf nicht berechenbar.'
}
$requiredVCpu = 10 * [int]$selected[0].VCpus

$quotaQuery = @{
    SubscriptionId = $subscriptionId
    Location       = $selected[0].Location
    Family         = $selected[0].Family
    RequiredVCpu   = $requiredVCpu
}
$quota = @(.\Get-AzureVmQuota.ps1 @quotaQuery)
$quota | Format-Table QuotaName, CurrentValue, Limit, Remaining, RequiredVCpu, HasQuotaHeadroom
```

**Beide Zeilen muessen ausreichend Headroom haben:** VM-Familie und
`cores` (Total Regional vCPUs). Geprueft wird der zusaetzliche Bedarf;
bestehender Verbrauch ist bereits in `CurrentValue` enthalten.
Fehlende Quotas fuehren zum Fehler, nicht zu einem positiven Ergebnis.
Ohne `RequiredVCpu` bleiben die beiden Prueffelder leer.

Die Planung gilt fuer regulaere VMs. Spot hat separate Quotas und
Kapazitaetsbedingungen und wird hier nicht als deploybar bewertet.
Bei mehreren VM-Familien den gemeinsamen regionalen Bedarf zusaetzlich
ueber alle Familien summieren.

## CSV und JSON speichern

Die Skripte geben PowerShell-Objekte aus; die Speicherung ist optional.
Erst eine vollstaendig erfolgreiche Abfrage sammeln, dann exportieren.
So wird bei einem Abbruch kein Teilbericht als fertiger Report exportiert.

```powershell
$query = @{
    SubscriptionId = $subscriptionId
    Location       = @('westeurope', 'northeurope')
}
$gpu = @(.\Get-AzureGpuSku.ps1 @query)
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csvPath = Join-Path -Path $PWD.Path -ChildPath "gpu-skus-$stamp.csv"
$jsonPath = Join-Path -Path $PWD.Path -ChildPath "gpu-skus-$stamp.json"
$gpu | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
ConvertTo-Json -InputObject $gpu -Depth 20 |
    Set-Content -LiteralPath $jsonPath -Encoding UTF8
```

`RestrictionsJson` bleibt auch im CSV eine JSON-Zeichenkette.
Die Berichte enthalten Subscription-IDs; nach internen Vorgaben behandeln.
API- und Berechtigungsfehler brechen die Skripte ab.
Warnungen zu fehlenden Treffern bei der Auswertung beruecksichtigen.

## Alternative mit Azure CLI

Diese Befehle werden in PowerShell ausgefuehrt. Die Azure-CLI-Anmeldung
ist unabhaengig von `Connect-AzAccount`.

```powershell
az login
az account set --subscription $subscriptionId

az vm list-skus --location westeurope --resource-type virtualMachines --all --size Standard_NV --output table
az vm list-skus --resource-type virtualMachines --all --size Standard_NV6ads_A10_v5 --output json
az vm list-usage --location westeurope --output table
```

`--size` sucht nach Teilnamen. Bei automatisierter Verarbeitung exakt
auf `name` filtern. `--all` behaelt eingeschraenkte SKUs im Ergebnis.
Beim Einbau in eigene Skripte nach jedem CLI-Aufruf `$LASTEXITCODE`
pruefen und bei Fehlern abbrechen.

## Monitoring und Grenzen der Kapazitaetsplanung

Die Skripte sind Abfragebausteine, kein bereits eingerichtetes Monitoring.
Fuer einen geplanten Runbook-/Pipeline-Lauf vorher einen nichtinteraktiven
Azure-Kontext herstellen, beispielsweise `Connect-AzAccount -Identity`
mit passend berechtigter Managed Identity, dann `Set-AzContext`.

- Ergebnisse mit Zeitstempel regelmaessig speichern.
- Aenderungen an SKUs und relevanten Region-/Zonenrestriktionen melden.
- Familien- und regionale Quota gegen UAT-Bedarf plus Puffer pruefen.
- Fehlgeschlagene Abfragen als Fehler alarmieren, nicht als freie Kapazitaet.
- Deployment-/Startfehler separat ueber Azure Monitor/Activity Log erfassen.

Azure stellt hierueber keine allgemeine Anzahl freier GPU-VMs bereit.
Eine erfolgreiche Testallokation beweist nur Kapazitaet zu diesem Zeitpunkt,
verursacht Kosten und wird von diesen Skripten nicht durchgefuehrt.
ARM-Validierung und What-if reservieren keine Hardware.

Fuer zeitkritische UAT-Termine On-demand Capacity Reservation fuer die
**konkret unterstuetzte** GPU-Serie und Konfiguration pruefen.
Nicht alle GPU-Serien sind unterstuetzt; ungenutzte Reservierungen kosten.
Reserved Instances und Savings Plans garantieren keine Hardwarekapazitaet.
Beim Deallokieren einer VM wird deren Compute-Allokation freigegeben.

## Live-Pruefung vom 20. Oktober 2026

Die Abfragen wurden in einer freigegebenen Azure-Subscription mit
registriertem `Microsoft.Compute` rein lesend ausgefuehrt. Verglichen wurden
West Europe, North Europe und Germany West Central unter PowerShell 7.

| Abfrage | Az-Modus | REST-Modus | Ergebniszeilen je Modus |
|---|---:|---:|---:|
| GPU-SKUs, drei Regionen | 25,59 s | 10,41 s | 71 |
| VM-Quota, drei Regionen | 1,82 s | 0,95 s | 698 |

Die verglichenen SKU-Felder einschliesslich Zonen und Restriktionsflag
sowie die Quota-Namen, Limits und Verbrauchswerte zeigten keine Abweichung.
Wildcard-Filter und der Vergleich eines zusaetzlichen UAT-vCPU-Bedarfs
gegen regionale und Familienquota wurden ebenfalls live geprueft.
Unter Windows PowerShell 5.1 wurden zusaetzlich eine NVIDIA-A10-SKU und
die zugehoerige regionale und Familienquota erfolgreich per REST abgefragt.

Dies sind Messwerte eines einzelnen Laufs, kein garantierter Benchmark.
Es wurden keine VMs erstellt, Provider registriert oder Reservierungen
angelegt. Eine leere Usage-Liste bei einem nicht registrierten
Compute-Provider wurde ebenfalls beobachtet und wird explizit als Fehler
behandelt, nicht als positive Kapazitaetsaussage.

## Offline-Tests

Die Tests benoetigen Pester 5.3 oder neuer innerhalb der 5.x-Reihe und
`Az.Accounts`/`Az.Compute`. Sie verwenden einen simulierten HTTP-Handler
und erzeugen weder Azure-Abfragen noch Ressourcen. Geprueft werden unter
anderem beide Transportmodi, Pagination, Parallelitaetsgrenzen, Wildcards,
Quota-Grenzwerte, HTTP-/Transportfehler und ungueltige Pagination-Ziele.
Zum dokumentierten Teststand bestanden jeweils 29 Tests unter
Windows PowerShell 5.1 und PowerShell 7; Syntaxpruefung und
PSScriptAnalyzer meldeten keine Warnungen oder Fehler im Produktivcode.

Aus dem Projektverzeichnis in einem separaten Prozess ausfuehren:

```powershell
$log = Join-Path -Path $env:TEMP -ChildPath 'azure-gpu-tests.out.log'
$errorLog = Join-Path -Path $env:TEMP -ChildPath 'azure-gpu-tests.err.log'
$done = Join-Path -Path $env:TEMP -ChildPath 'azure-gpu-tests.done'
if (Test-Path -LiteralPath $done) {
    Remove-Item -LiteralPath $done -ErrorAction Stop
}
$command = @'
try {
    Import-Module -Name Pester -MinimumVersion 5.3.0 -MaximumVersion 5.999.999 -ErrorAction Stop
    $testPath = Join-Path -Path $PWD.Path -ChildPath 'AzureGpuCapacity.Tests.ps1'
    $result = Invoke-Pester -Path $testPath -PassThru -Output Detailed
    if ($result.FailedCount -gt 0 -or $result.PassedCount -eq 0) {
        exit 1
    }
} finally {
    Set-Content -LiteralPath "$env:TEMP\azure-gpu-tests.done" -Value 'done'
}
'@
$process = Start-Process -FilePath pwsh -WorkingDirectory $PWD.Path -ArgumentList @(
    '-NoProfile', '-NonInteractive', '-Command', $command
) -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError $errorLog -PassThru
$process | Select-Object Id, HasExited
```

Nach Abschluss den Marker und die letzten Logzeilen pruefen:

```powershell
Test-Path -LiteralPath $done
Get-Content -LiteralPath $log -Tail 20
Get-Content -LiteralPath $errorLog -Tail 10
```

Fuer Windows PowerShell 5.1 statt `pwsh` den Prozess `powershell.exe`
starten. Der Marker zeigt das Ende des Laufs, nicht dessen Erfolg;
dafuer die Pester-Zusammenfassung und Fehlerausgabe pruefen.

## Weitere Informationen

- [SKU-Verfuegbarkeit und Einschraenkungen](https://learn.microsoft.com/en-us/azure/azure-resource-manager/troubleshooting/error-sku-not-available)
- [Get-AzComputeResourceSku](https://learn.microsoft.com/en-us/powershell/module/az.compute/get-azcomputeresourcesku)
- [Get-AzVMUsage](https://learn.microsoft.com/en-us/powershell/module/az.compute/get-azvmusage)
- [NVadsA10-v5-Serie](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/gpu-accelerated/nvadsa10v5-series)
- [On-demand Capacity Reservation](https://learn.microsoft.com/en-us/azure/virtual-machines/capacity-reservation-overview)
- [Resource SKUs REST API](https://learn.microsoft.com/en-us/rest/api/compute/resource-skus/list?view=rest-compute-2021-07-01)
- [Compute Usage REST API](https://learn.microsoft.com/en-us/rest/api/compute/usage/list?view=rest-compute-2025-04-01)
