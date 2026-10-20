#Requires -Version 5.1

BeforeAll {
    Import-Module -Name Az.Accounts, Az.Compute -ErrorAction Stop
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'AzureComputeRest.psm1') -ErrorAction Stop
    $script:gpuScript = Join-Path -Path $PSScriptRoot -ChildPath 'Get-AzureGpuSku.ps1'
    $script:quotaScript = Join-Path -Path $PSScriptRoot -ChildPath 'Get-AzureVmQuota.ps1'
    $script:subscriptionId = '11111111-1111-1111-1111-111111111111'
    $script:context = [PSCustomObject]@{
        Subscription = [PSCustomObject]@{ Id = $script:subscriptionId }
        Environment  = [PSCustomObject]@{ ResourceManagerUrl = 'https://management.azure.com/' }
    }
    $script:gpuBody = @'
{"value":[
  {"resourceType":"virtualMachines","name":"Standard_NV6ads_A10_v5",
   "family":"standardNVADSA10v5Family","locations":["westeurope","northeurope"],
   "capabilities":[{"name":"GPUs","value":"1"},{"name":"vCPUs","value":"6"}],
   "locationInfo":[{"location":"westeurope","zones":["1","2"]},{"location":"northeurope","zones":["3"]}],
   "restrictions":[{"type":"Zone","reasonCode":"NotAvailableForSubscription",
                    "restrictionInfo":{"locations":["westeurope"],"zones":["2"]}}]},
  {"resourceType":"virtualMachines","name":"Standard_NC4as_T4_v3",
   "family":"standardNCASv3_T4Family","locations":["westeurope"],
   "capabilities":[{"name":"GPUs","value":"1"},{"name":"vCPUs","value":"4"}]},
  {"resourceType":"virtualMachines","name":"Standard_D2s_v5",
   "capabilities":[{"name":"vCPUs","value":"2"}]},
  {"resourceType":"disks","name":"Disk"}
]}
'@
    $script:quotaBody = @'
{"value":[
 {"name":{"value":"cores","localizedValue":"Total Regional vCPUs"},"currentValue":20,"limit":100},
 {"name":{"value":"standardNVADSA10v5Family","localizedValue":"NVIDIA family"},"currentValue":12,"limit":72},
 {"name":{"value":"virtualMachines","localizedValue":"VM count"},"currentValue":1,"limit":1000}
]}
'@

    if (-not ('AzureGpuCapacityTests.Handler' -as [type])) {
        $definition = @'
using System;
using System.Collections.Concurrent;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace AzureGpuCapacityTests {
    public sealed class Handler : HttpMessageHandler {
        public string Body = "{\"value\":[]}";
        public string SecondBody = "{\"value\":[]}";
        public string Scenario = "Normal";
        public int DelayMilliseconds = 10;
        public int Active;
        public int MaximumActive;
        public bool Disposed;
        public bool InvalidAuthorization;
        public readonly ConcurrentQueue<string> Requests = new ConcurrentQueue<string>();
        private readonly ConcurrentDictionary<string, int> attempts = new ConcurrentDictionary<string, int>();

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken) {
            string uri = request.RequestUri.AbsoluteUri;
            Requests.Enqueue(uri);
            if (request.Method != HttpMethod.Get || request.Headers.Authorization == null ||
                request.Headers.Authorization.ToString() != "Bearer test-token-not-a-secret") {
                InvalidAuthorization = true;
            }
            int active = Interlocked.Increment(ref Active);
            int previous;
            do {
                previous = MaximumActive;
                if (active <= previous) break;
            } while (Interlocked.CompareExchange(ref MaximumActive, active, previous) != previous);
            try {
                await Task.Delay(DelayMilliseconds, cancellationToken).ConfigureAwait(false);
                int attempt = attempts.AddOrUpdate(uri, 1, (key, old) => old + 1);
                if (Scenario == "TransportAlways" || (Scenario == "TransportOnce" && attempt == 1)) {
                    throw new HttpRequestException("simulated connection reset");
                }
                HttpStatusCode status = HttpStatusCode.OK;
                string body = Body;
                if (Scenario == "RetryAlways" || (Scenario == "RetryOnce" && attempt == 1)) {
                    status = (HttpStatusCode)429;
                    body = "{\"error\":{\"message\":\"throttled\"}}";
                } else if (Scenario == "Forbidden") {
                    status = HttpStatusCode.Forbidden;
                    body = "{\"error\":{\"message\":\"permission denied\"}}";
                } else if (Scenario == "BadJson") {
                    body = "not json";
                } else if (Scenario == "MissingValue") {
                    body = "{}";
                } else if (Scenario == "MalformedValue") {
                    body = "{\"value\":{}}";
                } else if (Scenario == "NullItem") {
                    body = "{\"value\":[null]}";
                } else if (Scenario == "PageTwo") {
                    body = uri.Contains("page=2") ? SecondBody : AddLink(Body, uri + "&page=2");
                } else if (Scenario == "RepeatedNextLink") {
                    body = AddLink(Body, uri);
                } else if (Scenario == "ForeignNextLink") {
                    body = AddLink(Body, "https://example.invalid/steal");
                } else if (Scenario == "OtherPathNextLink") {
                    body = AddLink(Body, "https://management.azure.com/another/subscription");
                }
                var response = new HttpResponseMessage(status) { Content = new StringContent(body) };
                if ((int)status == 429) {
                    response.Headers.RetryAfter = new System.Net.Http.Headers.RetryConditionHeaderValue(
                        TimeSpan.Zero);
                }
                return response;
            } finally {
                Interlocked.Decrement(ref Active);
            }
        }

        private static string AddLink(string body, string link) {
            string trimmed = body.TrimEnd();
            return trimmed.Substring(0, trimmed.Length - 1) + ",\"nextLink\":\"" + link + "\"}";
        }

        protected override void Dispose(bool disposing) {
            Disposed = true;
            base.Dispose(disposing);
        }
    }
}
'@
        $references = @([System.Net.Http.HttpClient].Assembly.Location)
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            $references += 'System.dll'
        } else {
            $references += @(
                'System.Runtime.dll'
                'System.Collections.dll'
                'System.Collections.Concurrent.dll'
                'System.Threading.dll'
                'System.Threading.Tasks.dll'
                'System.Net.Primitives.dll'
            )
        }
        Add-Type -TypeDefinition $definition -ReferencedAssemblies $references -ErrorAction Stop
    }
}

Describe 'Get-AzureComputeRestData' -Tag 'Unit' {
    BeforeEach {
        $script:handler = [AzureGpuCapacityTests.Handler]::new()
        $handlerForMock = $script:handler
        Mock -ModuleName AzureComputeRest -CommandName Get-AzAccessToken -RemoveParameterType DefaultProfile -MockWith {
            [PSCustomObject]@{
                Token = ConvertTo-SecureString -String 'test-token-not-a-secret' -AsPlainText -Force
            }
        }
        Mock -ModuleName AzureComputeRest -CommandName Get-AzureComputeHttpClient -MockWith {
            [System.Net.Http.HttpClient]::new($handlerForMock)
        }.GetNewClosure()
        $script:rest = @{ Context = $script:context; Resource = 'Skus'; Location = @('westeurope') }
    }

    It 'Should issue one authenticated server-filtered regional request' {
        $result = @(Get-AzureComputeRestData @rest)
        $result.Count | Should -Be 1
        $handler.Requests.Count | Should -Be 1
        [uri]::UnescapeDataString($handler.Requests.ToArray()[0]) |
            Should -BeLike "*api-version=2021-07-01*&`$filter=location eq 'westeurope'"
        $handler.InvalidAuthorization | Should -BeFalse
        $handler.Disposed | Should -BeTrue
    }

    It 'Should scan all SKU locations with one unfiltered pagination chain' {
        $rest.Location = @('AllLocations')
        Get-AzureComputeRestData @rest | Out-Null
        $handler.Requests.ToArray()[0] | Should -Not -Match '\$filter'
    }

    It 'Should request the documented usage endpoint' {
        $rest.Resource = 'Usage'
        Get-AzureComputeRestData @rest | Out-Null
        $handler.Requests.ToArray()[0] | Should -BeLike '*/locations/westeurope/usages?api-version=2025-04-01'
    }

    It 'Should follow nextLink and combine all pages before emitting a region' {
        $handler.Scenario = 'PageTwo'
        $handler.Body = '{"value":[{"name":"first"}]}'
        $handler.SecondBody = '{"value":[{"name":"second"}]}'
        $result = @(Get-AzureComputeRestData @rest)
        $result[0].Items.Name | Should -Be @('first', 'second')
        $handler.Requests.Count | Should -Be 2
    }

    It 'Should retry HTTP 429 and honor a zero Retry-After' {
        $handler.Scenario = 'RetryOnce'
        $result = @(Get-AzureComputeRestData @rest -WarningAction SilentlyContinue)
        $result.Count | Should -Be 1
        $handler.Requests.Count | Should -Be 2
    }

    It 'Should stop after three retries without a success-shaped fallback' {
        $handler.Scenario = 'RetryAlways'
        { Get-AzureComputeRestData @rest -WarningAction SilentlyContinue } | Should -Throw '*HTTP 429*'
        $handler.Requests.Count | Should -Be 4
        $handler.Disposed | Should -BeTrue
    }

    It 'Should retry a transient connection reset' {
        $handler.Scenario = 'TransportOnce'
        $result = @(Get-AzureComputeRestData @rest -WarningAction SilentlyContinue)
        $result.Count | Should -Be 1
        $handler.Requests.Count | Should -Be 2
    }

    It 'Should fail explicitly after repeated transport errors' {
        $handler.Scenario = 'TransportAlways'
        { Get-AzureComputeRestData @rest -WarningAction SilentlyContinue } |
            Should -Throw '*Transportfehler nach drei Wiederholungen*'
        $handler.Requests.Count | Should -Be 4
        $handler.Disposed | Should -BeTrue
    }

    It 'Should reject <Scenario> responses' -ForEach @(
        @{ Scenario = 'Forbidden'; Message = '*HTTP 403*' }
        @{ Scenario = 'BadJson'; Message = '*' }
        @{ Scenario = 'MissingValue'; Message = '*value-Array*' }
        @{ Scenario = 'MalformedValue'; Message = '*value-Array*' }
        @{ Scenario = 'NullItem'; Message = '*Null-Eintrag*' }
        @{ Scenario = 'RepeatedNextLink'; Message = '*Wiederholter nextLink*' }
        @{ Scenario = 'ForeignNextLink'; Message = '*Unsicherer nextLink*' }
        @{ Scenario = 'OtherPathNextLink'; Message = '*Unsicherer nextLink*' }
    ) {
        $handler.Scenario = $Scenario
        { Get-AzureComputeRestData @rest } | Should -Throw $Message
        $handler.Disposed | Should -BeTrue
    }

    It 'Should bound concurrent requests and deduplicate regions' {
        $handler.DelayMilliseconds = 100
        $rest.Location = @('r1', 'r2', 'r3', 'r4', 'r5', 'r6', 'r1')
        $result = @(Get-AzureComputeRestData @rest -ThrottleLimit 3)
        $result.Count | Should -Be 6
        $handler.MaximumActive | Should -Be 3
        $handler.Requests.Count | Should -Be 6
    }
}

Describe 'GPU and quota scripts' -Tag 'Unit' {
    BeforeEach {
        $script:handler = [AzureGpuCapacityTests.Handler]::new()
        $contextForMock = $script:context
        $handlerForMock = $script:handler
        $skusForMock = (ConvertFrom-Json -InputObject $script:gpuBody).value
        $usageForMock = (ConvertFrom-Json -InputObject $script:quotaBody).value
        Mock -CommandName Get-AzContext -MockWith { $contextForMock }.GetNewClosure()
        Mock -ModuleName AzureComputeRest -CommandName Get-AzAccessToken -RemoveParameterType DefaultProfile -MockWith {
            [PSCustomObject]@{ Token = 'test-token-not-a-secret' }
        }
        Mock -ModuleName AzureComputeRest -CommandName Get-AzureComputeHttpClient -MockWith {
            [System.Net.Http.HttpClient]::new($handlerForMock)
        }.GetNewClosure()
        Mock -CommandName Get-AzComputeResourceSku -RemoveParameterType DefaultProfile -MockWith {
            $skusForMock
        }.GetNewClosure()
        Mock -CommandName Get-AzVMUsage -RemoveParameterType DefaultProfile -MockWith {
            $usageForMock
        }.GetNewClosure()
        $script:query = @{ SubscriptionId = $script:subscriptionId; Location = 'westeurope' }
    }

    It 'Should preserve the Az default and GPU result schema' {
        $result = @(& $gpuScript @query)
        $result.Count | Should -Be 2
        $result[0].Zones | Should -Be '1,2'
        $result[0].HasReportedRestrictions | Should -BeTrue
        $result[0].PhysicalCapacity | Should -Be 'NotQueried'
        $result[1].RestrictionsJson | Should -Be '[]'
        $result[1].Zones | Should -Be ''
        Should -Invoke -CommandName Get-AzComputeResourceSku -Times 1 -Exactly
        Should -Invoke -ModuleName AzureComputeRest -CommandName Get-AzAccessToken -Times 0 -Exactly
    }

    It 'Should return the same GPU data in REST and Az modes' {
        $handler.Body = $gpuBody
        $az = @(& $gpuScript @query)
        $rest = @(& $gpuScript @query -UseRest)
        $fields = @($az[0].PSObject.Properties.Name | Where-Object { $_ -ne 'QueriedAtUtc' })
        ConvertTo-Json -InputObject @($rest | Select-Object -Property $fields) -Depth 20 |
            Should -Be (ConvertTo-Json -InputObject @($az | Select-Object -Property $fields) -Depth 20)
    }

    It 'Should keep exact-name filtering and add opt-in wildcard filtering' {
        $handler.Body = $gpuBody
        @(& $gpuScript @query -UseRest -SkuName 'Standard_NV6ads_A10_v5').Count | Should -Be 1
        $result = @(& $gpuScript @query -UseRest -SkuPattern 'Standard_N*')
        $result.Count | Should -Be 2
        { & $gpuScript @query -SkuName 'exact' -SkuPattern '*' } | Should -Throw '*nicht kombinieren*'
    }

    It 'Should warn for an unmatched wildcard pattern' {
        $handler.Body = $gpuBody
        $messages = @()
        $result = @(
            & $gpuScript @query -UseRest -SkuPattern 'Missing*' -WarningVariable messages -WarningAction SilentlyContinue
        )
        $result.Count | Should -Be 0
        $messages.Count | Should -BeGreaterThan 0
    }

    It 'Should expose both regions and retain region-specific zones in a global scan' {
        $handler.Body = $gpuBody
        $result = @(& $gpuScript -SubscriptionId $subscriptionId -AllLocations -UseRest)
        $result.Count | Should -Be 3
        ($result | Where-Object Location -eq 'northeurope').Zones | Should -Be '3'
    }

    It 'Should preserve quota equality thresholds in both modes' -ForEach @(
        @{ RestMode = $false }
        @{ RestMode = $true }
    ) {
        $handler.Body = $quotaBody
        $result = @(
            & $quotaScript @query -Family standardNVADSA10v5Family -RequiredVCpu 60 -UseRest:$RestMode
        )
        $result.Count | Should -Be 2
        $result[1].Remaining | Should -Be 60
        @($result | Where-Object HasQuotaHeadroom -eq $false).Count | Should -Be 0
        $result = @(
            & $quotaScript @query -Family standardNVADSA10v5Family -RequiredVCpu 61 -UseRest:$RestMode
        )
        $result[0].HasQuotaHeadroom | Should -BeTrue
        $result[1].HasQuotaHeadroom | Should -BeFalse
    }

    It 'Should leave unevaluated quota headroom unknown' {
        $handler.Body = $quotaBody
        $result = @(& $quotaScript @query -UseRest)
        $result.Count | Should -Be 3
        $result[0].HasQuotaHeadroom | Should -BeNullOrEmpty
    }

    It 'Should fail when an expected quota family is absent' {
        $handler.Body = $quotaBody
        { & $quotaScript @query -UseRest -Family Missing -RequiredVCpu 1 } |
            Should -Throw "*Quota 'Missing'*"
    }

    It 'Should fail on an empty usage response' {
        { & $quotaScript @query -UseRest } | Should -Throw '*keine VM-Quota-Daten*'
    }

    It 'Should fail on a missing quota limit' {
        $handler.Body = '{"value":[{"name":{"value":"cores"},"currentValue":1,"limit":null}]}'
        { & $quotaScript @query -UseRest } | Should -Throw '*Unvollstaendige Quota-Werte*'
    }

    It 'Should reject the wrong subscription before acquiring a token' {
        $query.SubscriptionId = '22222222-2222-2222-2222-222222222222'
        { & $gpuScript @query -UseRest } | Should -Throw '*Falsche Subscription*'
        { & $quotaScript @query -UseRest } | Should -Throw '*Falsche Subscription*'
        Should -Invoke -ModuleName AzureComputeRest -CommandName Get-AzAccessToken -Times 0 -Exactly
    }
}
