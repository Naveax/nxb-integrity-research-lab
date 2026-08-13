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
                workflow = Join-Path $full '.github\workflows\nxb-v1-ci.yml'
                hosted = Join-Path $full 'scripts\Invoke-NxbV1CiHostedValidation.ps1'
                validator = Join-Path $full 'tools\validate_v1_ci.py'
                native = Join-Path $full 'scripts\Invoke-NxbV1CiNativeValidation.ps1'
                signing = Join-Path $full 'scripts\Invoke-NxbV1ProductionSigningCertification.ps1'
            }
        }
    }

    It 'keeps every CI authority component repo-owned' {
        $c = Get-NxbV1CiTestContext
        foreach ($path in @($c.policy,$c.workflow,$c.hosted,$c.validator,$c.native,$c.signing)) { Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue }
        $validatorSource = Get-Content -LiteralPath $c.validator -Raw
        $validatorSource | Should -Match 'nxb-v1-ci-independent-v1'
        $validatorSource | Should -Match 'requirement_count'
        $validatorSource | Should -Match 'negative_count'
    }

    It 'binds CI to the native-certified CLI predecessor' {
        $p = Get-Content -LiteralPath (Get-NxbV1CiTestContext).policy -Raw | ConvertFrom-Json
        [string]$p.contract_id | Should -BeExactly 'nxb-v1-ci-v1'
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
        $workflowSource | Should -Match ([regex]::Escape('Invoke-NxbV1CiNativeValidation.ps1'))
        $workflowSource | Should -Match ([regex]::Escape('-RepetitionCount 1'))
        $workflowSource | Should -Match ([regex]::Escape('-WarmupCount 0'))
        $nativeSource | Should -Match ([regex]::Escape('Invoke-NxbV1CiHostedValidation.ps1'))
        $nativeSource | Should -Match ([regex]::Escape('Invoke-CollectorOverheadCalibration.ps1'))
        $nativeSource | Should -Match ([regex]::Escape("authority = 'nxb-v1-ci-native-v1'"))
        $nativeSource | Should -Match ([regex]::Escape('review_entries = 7'))
        $nativeSource | Should -Match ([regex]::Escape('production_release_updated = $false'))
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

    It 'runs hosted analyzer and Python syntax gates' {
        $source = Get-Content -LiteralPath (Get-NxbV1CiTestContext).hosted -Raw
        $source | Should -Match ([regex]::Escape('Invoke-ScriptAnalyzer'))
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
