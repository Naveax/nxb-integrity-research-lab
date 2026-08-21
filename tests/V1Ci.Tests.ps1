$ErrorActionPreference = 'Stop'

Describe 'NXB v1 CI and native authority automation contract' {
    BeforeAll {
        function Get-NxbV1CiTestContext {
            $root = [string]$env:NXB_V1_CI_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_V1_CI_REPOSITORY_ROOT is required.' }
            $full = [IO.Path]::GetFullPath($root)
            return [pscustomobject][ordered]@{
                root = $full
                policy = Join-Path $full 'config\nxb-v1-ci-policy.json'
                known_error_config = Join-Path $full 'config\nxb-v1-ci-known-error-signatures.json'
                workflow = Join-Path $full '.github\workflows\nxb-v1-ci.yml'
                hosted = Join-Path $full 'scripts\Invoke-NxbV1CiHostedValidation.ps1'
                known_error_scanner = Join-Path $full 'scripts\Invoke-NxbV1CiKnownErrorScan.ps1'
                validator = Join-Path $full 'tools\validate_v1_ci.py'
                native = Join-Path $full 'scripts\Invoke-NxbV1CiNativeValidation.ps1'
                bounded_native_smoke = Join-Path $full 'scripts\Invoke-NxbBoundedTriggerNativeSmoke.ps1'
                signing = Join-Path $full 'scripts\Invoke-NxbV1ProductionSigningCertification.ps1'
            }
        }
    }

    It 'keeps every CI authority component repo-owned' {
        $c = Get-NxbV1CiTestContext
        foreach ($path in @($c.policy,$c.known_error_config,$c.workflow,$c.hosted,$c.known_error_scanner,$c.validator,$c.native,$c.bounded_native_smoke,$c.signing)) { Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue }
        $validatorSource = Get-Content -LiteralPath $c.validator -Raw
        $validatorSource | Should -Match 'nxb-v1-ci-independent-v1'
        $validatorSource | Should -Match 'requirement_count'
        $validatorSource | Should -Match 'negative_count'
    }

    It 'binds CI to the native-certified CLI predecessor' {
        $p = Get-Content -LiteralPath (Get-NxbV1CiTestContext).policy -Raw | ConvertFrom-Json
        [string]$p.contract_id | Should -BeExactly 'nxb-v1-ci-v1'
        [string]$p.target_version | Should -BeExactly '1.0.1'
        [string]$p.predecessor_cli_head | Should -BeExactly 'e665e8c27cb085853d23c8804ffaa97a19807eb9'
        [string]$p.certified_cli_pointer | Should -BeExactly 'certified/nxb-v1-cli'
    }

    It 'keeps top-level workflow permissions read-only' {
        $source = Get-Content -LiteralPath (Get-NxbV1CiTestContext).workflow -Raw
        $source | Should -Match '(?m)^permissions:\s*$'
        $source | Should -Match '(?m)^\s{2}contents:\s*read\s*$'
        $source | Should -Not -Match '(?im)^\s*(?:actions|checks|contents|deployments|discussions|id-token|issues|packages|pages|pull-requests|repository-projects|security-events|statuses):\s*write\s*$'
    }

    It 'uses pull_request and manual dispatch without pull_request_target' {
        $source = Get-Content -LiteralPath (Get-NxbV1CiTestContext).workflow -Raw
        $source | Should -Match '(?m)^\s{2}pull_request:\s*$'
        $source | Should -Match '(?m)^\s{2}workflow_dispatch:\s*$'
        $source | Should -Not -Match '(?m)^\s*pull_request_target\s*:'
    }

    It 'pins external Actions to exact commit SHAs' {
        $c = Get-NxbV1CiTestContext
        $p = Get-Content -LiteralPath $c.policy -Raw | ConvertFrom-Json
        [string]$p.workflow.checkout_sha | Should -BeExactly '3d3c42e5aac5ba805825da76410c181273ba90b1'
        [string]$p.workflow.setup_python_sha | Should -BeExactly '5fda3b95a4ea91299a34e894583c3862153e4b97'
        [string]$p.workflow.upload_artifact_sha | Should -BeExactly 'ea165f8d65b6e75b540449e92b4886f43607fa02'
        $source = Get-Content -LiteralPath $c.workflow -Raw
        $source | Should -Match ([regex]::Escape('actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1'))
        $source | Should -Match ([regex]::Escape('actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97'))
        $source | Should -Match ([regex]::Escape('actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02'))
    }

    It 'defines stable check names for branch-protection use' {
        $p = Get-Content -LiteralPath (Get-NxbV1CiTestContext).policy -Raw | ConvertFrom-Json
        [string]$p.checks.hosted_contract | Should -BeExactly 'nxb-v1 / hosted-contract'
        [string]$p.checks.signed_release_verify | Should -BeExactly 'nxb-v1 / signed-release-verify'
        [string]$p.checks.native_wpt | Should -BeExactly 'nxb-v1 / native-wpt'
        [string]$p.checks.release_candidate | Should -BeExactly 'nxb-v1 / release-candidate'
    }

    It 'keeps native WPT authority manual and self-hosted only' {
        $c = Get-NxbV1CiTestContext
        $p = Get-Content -LiteralPath $c.policy -Raw | ConvertFrom-Json
        [bool]$p.native_runner.manual_dispatch_only | Should -BeTrue
        (@($p.native_runner.labels | ForEach-Object { [string]$_ }) -join '|') | Should -BeExactly 'self-hosted|Windows|X64|nxb-native|wpt'
        $source = Get-Content -LiteralPath $c.workflow -Raw
        $source | Should -Match ([regex]::Escape('runs-on: [self-hosted, Windows, X64, nxb-native, wpt]'))
        $source | Should -Match ([regex]::Escape("github.event_name == 'workflow_dispatch' && inputs.run_native"))
    }

    It 'requires native runner administrator and WPT toolchain preflight' {
        $source = Get-Content -LiteralPath (Get-NxbV1CiTestContext).workflow -Raw
        foreach ($token in @('WindowsPrincipal','Administrator','wpr.exe','xperf.exe','pwsh.exe','python')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'delegates native execution to the Phase 7 trusted native authority' {
        $c = Get-NxbV1CiTestContext
        $workflowSource = Get-Content -LiteralPath $c.workflow -Raw
        $nativeSource = Get-Content -LiteralPath $c.native -Raw
        $boundedSmokeSource = Get-Content -LiteralPath $c.bounded_native_smoke -Raw
        $workflowSource | Should -Match ([regex]::Escape('Invoke-NxbV1CiNativeValidation.ps1'))
        $workflowSource | Should -Match ([regex]::Escape('-RepetitionCount 1'))
        $workflowSource | Should -Match ([regex]::Escape('-WarmupCount 0'))
        $workflowSource | Should -Match ([regex]::Escape('Upload native validation evidence'))
        $workflowSource | Should -Match ([regex]::Escape('nxb-v1-native-validation-${{ env.NXB_EXPECTED_SHA }}'))
        $workflowSource | Should -Match ([regex]::Escape('${{ runner.temp }}/nxb-v1-native-validation'))
        $nativeSource | Should -Match ([regex]::Escape('Invoke-NxbV1CiHostedValidation.ps1'))
        $nativeSource | Should -Match ([regex]::Escape('$hostedOutput = @(& $hostedAuthority'))
        $nativeSource | Should -Match ([regex]::Escape('$_.PSObject.Properties[''authority'']'))
        $nativeSource | Should -Match ([regex]::Escape('Native replay hosted receipt cardinality drift'))
        $nativeSource | Should -Match ([regex]::Escape('Native replay hosted receipt missing required field'))
        $nativeSource | Should -Match ([regex]::Escape("'ps51_excluded_tag','ps51_expected_excluded'"))
        $nativeSource | Should -Match ([regex]::Escape('$ps7Passed -ne $ps7Total'))
        $nativeSource | Should -Match ([regex]::Escape('$ps51ExcludedTag -cne ''PS7Only'''))
        $nativeSource | Should -Match ([regex]::Escape('$ps51Total -ne $ps7Total'))
        $nativeSource | Should -Match ([regex]::Escape('$ps51Passed -ne ($ps51Total - $expectedPs51Excluded)'))
        $nativeSource | Should -Not -Match ([regex]::Escape("'893/893'"))
        $nativeSource | Should -Not -Match ([regex]::Escape("'886/893'"))
        $nativeSource | Should -Match ([regex]::Escape('Invoke-CollectorOverheadCalibration.ps1'))
        $nativeSource | Should -Match ([regex]::Escape('Invoke-NxbBoundedTriggerNativeSmoke.ps1'))
        $nativeSource | Should -Match ([regex]::Escape("bounded_trigger_smoke_authority = 'nxb-bounded-trigger-native-smoke-v1'"))
        $nativeSource | Should -Match ([regex]::Escape('bounded_trigger_smoke_valid = $true'))
        $nativeSource | Should -Match ([regex]::Escape("'bounded-trigger-native-smoke.json' = $boundedSmokePath"))
        $nativeSource | Should -Match ([regex]::Escape("authority = 'nxb-v1-ci-native-v1'"))
        $nativeSource | Should -Match ([regex]::Escape('review_entries = 8'))
        $nativeSource | Should -Not -Match ([regex]::Escape('review_entries = 7'))
        $nativeSource | Should -Match ([regex]::Escape('production_release_updated = $false'))
        $boundedSmokeSource | Should -Match ([regex]::Escape("authority = 'nxb-bounded-trigger-native-smoke-v1'"))
        $boundedSmokeSource | Should -Match ([regex]::Escape('etl_retained_in_review_artifact = $false'))
    }

    It 'delegates signed-release verification with fail-closed result-shape checks' {
        $source = Get-Content -LiteralPath (Get-NxbV1CiTestContext).workflow -Raw
        $source | Should -Match ([regex]::Escape('Invoke-NxbV1ProductionSigningCertification.ps1'))
        $source | Should -Match ([regex]::Escape("PSObject.Properties['actual_production_release_signed']"))
        $source | Should -Match ([regex]::Escape("PSObject.Properties['production_signer_claimed']"))
        $source | Should -Match ([regex]::Escape('result shape is missing a required production-boundary field'))
        $source | Should -Not -Match '(?i)secrets\.'
        $source | Should -Not -Match '\$result\.actual_release_signed\b'
    }

    It 'keeps hosted validation free of native WPR execution' {
        $source = Get-Content -LiteralPath (Get-NxbV1CiTestContext).hosted -Raw
        $source | Should -Match ([regex]::Escape('Test-PublicRepositoryContent.ps1'))
        $source | Should -Match ([regex]::Escape('Test-Repository.ps1'))
        $source | Should -Not -Match '(?i)\bwpr(?:\.exe)?\b'
        $source | Should -Not -Match 'Invoke-NxbV1CiNativeValidation\.ps1'
    }

    It 'runs hosted known-error analyzer and Python syntax gates' {
        $c = Get-NxbV1CiTestContext
        $source = Get-Content -LiteralPath $c.hosted -Raw
        $scannerSource = Get-Content -LiteralPath $c.known_error_scanner -Raw
        $knownErrorConfig = Get-Content -LiteralPath $c.known_error_config -Raw | ConvertFrom-Json
        $source | Should -Match ([regex]::Escape('Invoke-NxbV1CiKnownErrorScan.ps1'))
        $source | Should -Match ([regex]::Escape("known_error_authority='nxb-v1-ci-known-error-scan-v1'"))
        $scannerSource | Should -Match ([regex]::Escape('Invoke-NxbKnownErrorScan.ps1'))
        $scannerSource | Should -Match ([regex]::Escape('Invoke-NxbProductionKnownErrorScan.ps1'))
        foreach ($token in @('nxb-v1-release-known-error-signatures.json','nxb-v1-signing-known-error-signatures.json','nxb-v1-installer-known-error-signatures.json','nxb-v1-update-known-error-signatures.json','nxb-v1-cli-known-error-signatures.json')) { $scannerSource | Should -Match ([regex]::Escape($token)) }
        [string]$knownErrorConfig.contract_id | Should -BeExactly 'nxb-v1-ci-known-error-signatures-v1'
        @($knownErrorConfig.rules).Count | Should -Be 6
        $source | Should -Match ([regex]::Escape('Invoke-NxbV1CiNativeProcess'))
        $source | Should -Match ([regex]::Escape('Get-Command pwsh.exe'))
        $source | Should -Match ([regex]::Escape('Import-Module $AnalyzerModulePath -Force'))
        $source | Should -Match ([regex]::Escape('Invoke-ScriptAnalyzer -Path (Join-Path $RepositoryRoot ''scripts'') -Recurse -Settings $SettingsPath'))
        $source | Should -Match ([regex]::Escape('Invoke-ScriptAnalyzer -Path (Join-Path $RepositoryRoot ''tests'') -Recurse -Settings $SettingsPath'))
        $source | Should -Match ([regex]::Escape('nxb-v1-ci-analyzer-isolated-v1'))
        $source | Should -Match ([regex]::Escape('main process must remain Pester-assembly-free'))
        $source | Should -Match ([regex]::Escape('contaminated the main Pester assembly context'))
        $source | Should -Not -Match '(?m)^\s*Import-Module\s+\$analyzerModule\.Path\s+-Force\s*$'
        $source | Should -Match ([regex]::Escape('-m py_compile'))
        $source | Should -Match ([regex]::Escape('Join-Path $repositoryRoot ''tools'''))
        $source | Should -Match ([regex]::Escape('m.version("jsonschema") == "4.26.0"'))
    }

    It 'runs complete PS7 and explicit Windows PowerShell 5.1 compatible Pester partitions' {
        $c = Get-NxbV1CiTestContext
        $source = Get-Content -LiteralPath $c.hosted -Raw
        $workflow = Get-Content -LiteralPath $c.workflow -Raw
        $source | Should -Match ([regex]::Escape('Join-Path $repositoryRoot ''tests'''))
        $source | Should -Match ([regex]::Escape('New-PesterConfiguration'))
        $source | Should -Match ([regex]::Escape('WindowsPowerShell\v1.0\powershell.exe'))
        $source | Should -Match ([regex]::Escape('Pester\5.7.1\Pester.psd1'))
        $source | Should -Match ([regex]::Escape('NXB_[A-Z0-9_]+_REPOSITORY_ROOT'))
        $source | Should -Match ([regex]::Escape('[Environment]::SetEnvironmentVariable($rootVariableName,$repositoryRoot,[EnvironmentVariableTarget]::Process)'))
        $source | Should -Match ([regex]::Escape('$ps51ExcludedTag = ''PS7Only'''))
        $source | Should -Match ([regex]::Escape('$expectedPs51ExcludedTests = 7'))
        $source | Should -Match ([regex]::Escape('$config.Filter.ExcludeTag=@($ExcludedTag)'))
        $source | Should -Match ([regex]::Escape('NotRunCount'))
        $taggedCount = 0
        foreach ($testFile in @(Get-ChildItem -LiteralPath (Join-Path $c.root 'tests') -Filter '*.ps1' -File)) {
            $testText = Get-Content -LiteralPath $testFile.FullName -Raw
            $taggedCount += [regex]::Matches($testText,"(?m)^\s*It\s+'[^']+'[^\r\n]*-Tag\s+'PS7Only'(?:\s|$)").Count
        }
        $taggedCount | Should -Be 7
        $workflow | Should -Match ([regex]::Escape('nxb-v1-hosted-validation-${{ env.NXB_EXPECTED_SHA }}'))
        $workflow | Should -Match ([regex]::Escape('${{ runner.temp }}/nxb-v1-hosted-validation'))
    }

    It 'pins CI dependency versions in policy and workflow bootstrap' {
        $c = Get-NxbV1CiTestContext
        $p = Get-Content -LiteralPath $c.policy -Raw | ConvertFrom-Json
        [string]$p.workflow.pester_version | Should -BeExactly '5.7.1'
        [string]$p.workflow.psscriptanalyzer_version | Should -BeExactly '1.25.0'
        [string]$p.workflow.pyyaml_version | Should -BeExactly '6.0.3'
        [string]$p.workflow.jsonschema_version | Should -BeExactly '4.26.0'
        $source = Get-Content -LiteralPath $c.workflow -Raw
        foreach ($token in @('Pester -RequiredVersion 5.7.1','PSScriptAnalyzer -RequiredVersion 1.25.0','PyYAML==6.0.3','jsonschema==4.26.0')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'keeps production release mutation claims false' {
        $p = Get-Content -LiteralPath (Get-NxbV1CiTestContext).policy -Raw | ConvertFrom-Json
        [bool]$p.safety.auto_apply | Should -BeFalse
        [bool]$p.safety.production_release_updated | Should -BeFalse
        [bool]$p.safety.production_tag_created | Should -BeFalse
        [bool]$p.safety.production_merge_performed | Should -BeFalse
    }

    It 'forbids workflow secrets and continue-on-error bypasses' {
        $c = Get-NxbV1CiTestContext
        $p = Get-Content -LiteralPath $c.policy -Raw | ConvertFrom-Json
        [bool]$p.safety.workflow_secrets_forbidden | Should -BeTrue
        [bool]$p.safety.continue_on_error_forbidden | Should -BeTrue
        $source = Get-Content -LiteralPath $c.workflow -Raw
        $source | Should -Not -Match '(?i)secrets\.'
        $source | Should -Not -Match '(?im)continue-on-error:\s*true'
    }

    It 'locks the CI contract at exactly seventeen tests' {
        $testSource = Get-Content -LiteralPath $PSCommandPath -Raw
        [regex]::Matches($testSource,"(?m)^\s*It\s+'").Count | Should -Be 17
    }
}
