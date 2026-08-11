$ErrorActionPreference = 'Stop'

Describe 'NXB IRL-005 adaptive capture manifest contract' {
    BeforeAll {
        function Get-NxbAdaptiveManifestRoot {
            $root = [string]$env:NXB_ADAPTIVE_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_ADAPTIVE_REPOSITORY_ROOT is required.' }
            return [IO.Path]::GetFullPath($root)
        }

        function Get-NxbAdaptiveManifestTestPlanPath {
            param(
                [Parameter(Mandatory)][string[]]$Domains,
                [Parameter(Mandatory)][ValidateSet('none','summary','structural','semantic','payload')][string]$Detail,
                [Parameter()][ValidateSet('off','minimal','normal','deep','forensic')][string]$Mode = 'deep'
            )
            $path = Join-Path $TestDrive ('plan-{0}.json' -f [Guid]::NewGuid().ToString('N'))
            $plan = [pscustomobject][ordered]@{
                schema_version = 1
                policy_id = 'nxb-adaptive-default-v1'
                effective_mode = $Mode
                detail = $Detail
                active_domains = $Domains
                active_trigger_ids = @()
                reasons = @('test')
                budgets = [pscustomobject][ordered]@{
                    max_event_rate_per_second = 1000
                    max_disk_mb_per_hour = 64
                    max_session_seconds = 60
                    pretrigger_seconds = 5
                    posttrigger_seconds = 10
                }
                privacy = [pscustomobject][ordered]@{
                    raw_identifiers = $false
                    formatted_messages = $false
                    payload_fields = $false
                    network_payload = $false
                }
                claims = [pscustomobject][ordered]@{ pending = @(); validated = @() }
                plan_fingerprint_sha256 = ('a' * 64)
            }
            [IO.File]::WriteAllText($path,(($plan | ConvertTo-Json -Depth 20) + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
            return $path
        }

        function Get-NxbAdaptiveManifestTestResult {
            param(
                [Parameter(Mandatory)][string[]]$Domains,
                [Parameter(Mandatory)][string]$Detail,
                [Parameter()][string]$Mode = 'deep'
            )
            $root = Get-NxbAdaptiveManifestRoot
            $resolver = Join-Path $root 'scripts\Resolve-NxbAdaptiveCaptureManifest.ps1'
            $map = Join-Path $root 'config\adaptive-observability-domain-map.json'
            $plan = Get-NxbAdaptiveManifestTestPlanPath -Domains $Domains -Detail $Detail -Mode $Mode
            return (& $resolver -PlanPath $plan -DomainMapPath $map -PassThru)
        }
    }

    It 'keeps domain map resolver and independent validator repo-owned' {
        $root = Get-NxbAdaptiveManifestRoot
        foreach ($relative in @(
            'config\adaptive-observability-domain-map.json',
            'scripts\Resolve-NxbAdaptiveCaptureManifest.ps1',
            'tools\validate_adaptive_capture_manifest.py'
        )) {
            Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf | Should -BeTrue
        }
        $resolverSource = Get-Content -LiteralPath (Join-Path $root 'scripts\Resolve-NxbAdaptiveCaptureManifest.ps1') -Raw
        $testSource = Get-Content -LiteralPath (Join-Path $root 'tests\AdaptiveCaptureManifest.Tests.ps1') -Raw
        $resolverSource | Should -Not -Match '(?im)^\s*\$matches\s*='
        $resolverSource | Should -Match ([regex]::Escape('$domainMappings = @('))
        $testSource | Should -Not -Match '(?im)^\s*function\s+New-NxbAdaptiveManifest'
        $testSource | Should -Match ([regex]::Escape('function Get-NxbAdaptiveManifestTestPlanPath'))
    }

    It 'maps all fourteen adaptive domains exactly once' {
        $root = Get-NxbAdaptiveManifestRoot
        $map = Get-Content -LiteralPath (Join-Path $root 'config\adaptive-observability-domain-map.json') -Raw | ConvertFrom-Json
        $names = @($map.domains | ForEach-Object { [string]$_.name })
        $names.Count | Should -Be 14
        @($names | Select-Object -Unique).Count | Should -Be 14
        foreach ($name in @('cpu','memory','storage','gpu','network','pnp','pcie','kernel','registry','power','thermal','firmware','security','correlation')) {
            $names | Should -Contain $name
        }
    }

    It 'references only existing repo assets for non-pending adapters' {
        $root = Get-NxbAdaptiveManifestRoot
        $map = Get-Content -LiteralPath (Join-Path $root 'config\adaptive-observability-domain-map.json') -Raw | ConvertFrom-Json
        foreach ($mapping in @($map.domains | Where-Object { [string]$_.adapter_kind -cne 'pending_semantic_adapter' })) {
            foreach ($asset in @($mapping.base_assets) + @($mapping.deep_assets)) {
                Test-Path -LiteralPath (Join-Path $root (([string]$asset) -replace '/','\')) -PathType Leaf | Should -BeTrue
            }
        }
    }

    It 'uses only base assets for summary detail' {
        $manifest = Get-NxbAdaptiveManifestTestResult -Domains @('cpu') -Detail 'summary' -Mode 'minimal'
        $entry = @($manifest.capture.domains)[0]
        @($entry.assets | ForEach-Object { [string]$_.path }) | Should -Contain 'profiles/Nxb.MinimalCpuScheduler.wprp'
        @($entry.assets | ForEach-Object { [string]$_.path }) | Should -Not -Contain 'profiles/Nxb.Superblock1MultiDomain.wprp'
        [string]$entry.availability | Should -BeExactly 'ready'
    }

    It 'adds deep assets for semantic detail' {
        $manifest = Get-NxbAdaptiveManifestTestResult -Domains @('gpu') -Detail 'semantic'
        $entry = @($manifest.capture.domains)[0]
        $paths = @($entry.assets | ForEach-Object { [string]$_.path })
        $paths | Should -Contain 'profiles/Nxb.GpuDxgkrnlPresent.wprp'
        $paths | Should -Contain 'profiles/Nxb.Superblock1MultiDomain.wprp'
        $paths | Should -Contain 'scripts/Invoke-NxbSuperblock1CorrelationAnalysis.ps1'
        [string]$entry.availability | Should -BeExactly 'ready'
    }

    It 'keeps registry explicitly pending instead of fabricating readiness' {
        $manifest = Get-NxbAdaptiveManifestTestResult -Domains @('registry') -Detail 'semantic'
        $entry = @($manifest.capture.domains)[0]
        [string]$entry.adapter_kind | Should -BeExactly 'pending_semantic_adapter'
        [string]$entry.availability | Should -BeExactly 'pending'
        [string]$entry.reason | Should -BeExactly 'semantic_adapter_not_yet_certified'
        @($entry.assets).Count | Should -Be 0
    }

    It 'preserves active-domain priority order in the capture manifest' {
        $manifest = Get-NxbAdaptiveManifestTestResult -Domains @('security','firmware','kernel','correlation') -Detail 'semantic' -Mode 'forensic'
        $names = @($manifest.capture.domains | ForEach-Object { [string]$_.domain })
        ($names -join ',') | Should -BeExactly 'security,firmware,kernel,correlation'
    }

    It 'keeps readiness summary counts internally consistent' {
        $manifest = Get-NxbAdaptiveManifestTestResult -Domains @('cpu','registry','gpu') -Detail 'semantic'
        [int]$manifest.capture.domain_count | Should -Be 3
        ([int]$manifest.capture.ready_count + [int]$manifest.capture.pending_count + [int]$manifest.capture.unavailable_count) | Should -Be 3
        [int]$manifest.capture.pending_count | Should -Be 1
    }

    It 'surfaces capture manifest and adapter readiness through the local panel' {
        $root = Get-NxbAdaptiveManifestRoot
        $server = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-NxbAdaptiveObservabilityPanel.ps1') -Raw
        $html = Get-Content -LiteralPath (Join-Path $root 'ui\adaptive-observability-panel.html') -Raw
        $server | Should -Match ([regex]::Escape('Resolve-NxbAdaptiveCaptureManifest.ps1'))
        $server | Should -Match ([regex]::Escape('capture_manifest = $manifest'))
        $html | Should -Match ([regex]::Escape('Capture adapters'))
        $html | Should -Match ([regex]::Escape('renderAdapters(s.capture_manifest)'))
        $html | Should -Match ([regex]::Escape('unavailable_count'))
    }

    It 'independently recomputes asset selection and availability in Python' {
        $root = Get-NxbAdaptiveManifestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'tools\validate_adaptive_capture_manifest.py') -Raw
        $source | Should -Match ([regex]::Escape('manifest domain order mismatch'))
        $source | Should -Match ([regex]::Escape('asset selection mismatch'))
        $source | Should -Match ([regex]::Escape('repo_owned mismatch'))
        $source | Should -Match ([regex]::Escape('availability mismatch'))
        $source | Should -Match ([regex]::Escape('semantic_adapter_not_yet_certified'))
    }
}
