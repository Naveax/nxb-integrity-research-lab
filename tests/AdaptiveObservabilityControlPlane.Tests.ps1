$ErrorActionPreference = 'Stop'

Describe 'NXB IRL-005 adaptive observability control-plane contract' {
    BeforeAll {
        function Get-NxbAdaptiveTestRoot {
            $root = [string]$env:NXB_ADAPTIVE_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_ADAPTIVE_REPOSITORY_ROOT is required.' }
            return [IO.Path]::GetFullPath($root)
        }

        function Write-NxbAdaptiveTestSignals {
            param([Parameter(Mandatory)][hashtable]$Signals)
            $path = Join-Path $TestDrive ('signals-{0}.json' -f [Guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText(
                $path,
                (($Signals | ConvertTo-Json -Depth 10) + [Environment]::NewLine),
                [Text.UTF8Encoding]::new($false)
            )
            return $path
        }

        function Get-NxbAdaptiveTestPlan {
            param(
                [Parameter(Mandatory)][hashtable]$Signals,
                [Parameter()][string]$OperatorMode
            )
            $root = Get-NxbAdaptiveTestRoot
            $policy = Join-Path $root 'config\adaptive-observability-policy.default.json'
            $resolver = Join-Path $root 'scripts\Resolve-NxbAdaptiveObservabilityPlan.ps1'
            $signalsPath = Write-NxbAdaptiveTestSignals -Signals $Signals
            if ([string]::IsNullOrWhiteSpace($OperatorMode)) {
                return (& $resolver -PolicyPath $policy -SignalsPath $signalsPath -PassThru)
            }
            return (& $resolver -PolicyPath $policy -SignalsPath $signalsPath -OperatorMode $OperatorMode -PassThru)
        }
    }

    It 'keeps all adaptive control-plane components repo-owned' {
        $root = Get-NxbAdaptiveTestRoot
        foreach ($relative in @(
            'schemas\adaptive-observability-policy.schema.json',
            'config\adaptive-observability-policy.default.json',
            'scripts\Resolve-NxbAdaptiveObservabilityPlan.ps1',
            'scripts\Start-NxbAdaptiveObservabilityPanel.ps1',
            'tools\validate_adaptive_observability_policy.py',
            'ui\adaptive-observability-panel.html'
        )) {
            Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf | Should -BeTrue
        }
    }

    It 'defines exactly five ordered logging modes' {
        $root = Get-NxbAdaptiveTestRoot
        $policy = Get-Content -LiteralPath (Join-Path $root 'config\adaptive-observability-policy.default.json') -Raw | ConvertFrom-Json
        @($policy.mode_profiles.PSObject.Properties.Name).Count | Should -Be 5
        foreach ($mode in @('off','minimal','normal','deep','forensic')) {
            $policy.mode_profiles.PSObject.Properties.Name | Should -Contain $mode
        }
    }

    It 'defaults to minimal while permitting bounded forensic escalation' {
        $root = Get-NxbAdaptiveTestRoot
        $policy = Get-Content -LiteralPath (Join-Path $root 'config\adaptive-observability-policy.default.json') -Raw | ConvertFrom-Json
        [string]$policy.default_mode | Should -BeExactly 'minimal'
        [string]$policy.maximum_mode | Should -BeExactly 'forensic'
    }

    It 'declares explicit global capture budgets' {
        $root = Get-NxbAdaptiveTestRoot
        $policy = Get-Content -LiteralPath (Join-Path $root 'config\adaptive-observability-policy.default.json') -Raw | ConvertFrom-Json
        [int]$policy.budgets.max_disk_mb_per_hour | Should -BeGreaterThan 0
        [int]$policy.budgets.max_event_rate_per_second | Should -BeGreaterThan 0
        [int]$policy.budgets.max_session_seconds | Should -BeGreaterThan 0
        [int]$policy.budgets.max_concurrent_domains | Should -BeGreaterThan 0
        [int]$policy.budgets.pretrigger_seconds | Should -BeGreaterThan 0
        [int]$policy.budgets.posttrigger_seconds | Should -BeGreaterThan 0
    }

    It 'keeps sensitive payload classes disabled by default' {
        $root = Get-NxbAdaptiveTestRoot
        $policy = Get-Content -LiteralPath (Join-Path $root 'config\adaptive-observability-policy.default.json') -Raw | ConvertFrom-Json
        [bool]$policy.privacy.raw_identifiers | Should -BeFalse
        [bool]$policy.privacy.formatted_messages | Should -BeFalse
        [bool]$policy.privacy.payload_fields | Should -BeFalse
        [bool]$policy.privacy.network_payload | Should -BeFalse
    }

    It 'locks the operator panel to localhost' {
        $root = Get-NxbAdaptiveTestRoot
        $policy = Get-Content -LiteralPath (Join-Path $root 'config\adaptive-observability-policy.default.json') -Raw | ConvertFrom-Json
        [bool]$policy.panel.local_only | Should -BeTrue
        [string]$policy.panel.bind_address | Should -BeExactly '127.0.0.1'
    }

    It 'requests all eight semantic-hardening targets' {
        $root = Get-NxbAdaptiveTestRoot
        $policy = Get-Content -LiteralPath (Join-Path $root 'config\adaptive-observability-policy.default.json') -Raw | ConvertFrom-Json
        $required = @(
            'pnp_lifecycle_semantics','pcie_bdf_semantics','event_id_semantics',
            'event_task_opcode_semantics','power_causality','firmware_causality',
            'root_cause_validated','continuous_trace_completeness'
        )
        foreach ($name in $required) {
            $claim = @($policy.claim_targets | Where-Object { [string]$_.name -ceq $name })
            $claim.Count | Should -Be 1
            [bool]$claim[0].target_requested | Should -BeTrue
        }
    }

    It 'does not pre-certify semantic targets without evidence' {
        $root = Get-NxbAdaptiveTestRoot
        $policy = Get-Content -LiteralPath (Join-Path $root 'config\adaptive-observability-policy.default.json') -Raw | ConvertFrom-Json
        @($policy.claim_targets | Where-Object { [bool]$_.validated }).Count | Should -Be 0
        @($policy.claim_targets | Where-Object { $null -ne $_.evidence_receipt_sha256 }).Count | Should -Be 0
    }

    It 'uses an explicit ordered mode rank' {
        $root = Get-NxbAdaptiveTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Resolve-NxbAdaptiveObservabilityPlan.ps1') -Raw
        $source | Should -Match ([regex]::Escape("@('off','minimal','normal','deep','forensic')"))
        $source | Should -Match ([regex]::Escape('[Math]::Min($operatorRank,$maximumRank)'))
    }

    It 'sorts active triggers by priority then id' {
        $root = Get-NxbAdaptiveTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Resolve-NxbAdaptiveObservabilityPlan.ps1') -Raw
        $source | Should -Match ('Sort-Object\s+-Property\s+@\{Expression=''priority'';Descending=\$true\},\s+@\{Expression=''id'';Descending=\$false\}')
    }

    It 'preserves first-occurrence domain priority' {
        $root = Get-NxbAdaptiveTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Resolve-NxbAdaptiveObservabilityPlan.ps1') -Raw
        $source | Should -Match ([regex]::Escape('Get-NxbStableUniqueDomains'))
        $source | Should -Match ([regex]::Escape('if ($seen.Add($domain)) { $ordered.Add($domain) }'))
    }

    It 'applies the concurrent-domain budget after trigger domains are inserted' {
        $root = Get-NxbAdaptiveTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Resolve-NxbAdaptiveObservabilityPlan.ps1') -Raw
        $triggerIndex = $source.IndexOf('foreach ($trigger in $activeTriggers)')
        $budgetIndex = $source.IndexOf('$maxDomains = [int]$policy.budgets.max_concurrent_domains')
        $triggerIndex | Should -BeGreaterThanOrEqual 0
        $budgetIndex | Should -BeGreaterThan $triggerIndex
    }

    It 'clamps per-mode rate and disk budgets to global policy limits' {
        $root = Get-NxbAdaptiveTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Resolve-NxbAdaptiveObservabilityPlan.ps1') -Raw
        $source | Should -Match ([regex]::Escape('[Math]::Min([int]$profile.max_event_rate_per_second,[int]$policy.budgets.max_event_rate_per_second)'))
        $source | Should -Match ([regex]::Escape('[Math]::Min([int]$profile.max_disk_mb_per_hour,[int]$policy.budgets.max_disk_mb_per_hour)'))
    }

    It 'clamps forensic payload detail when payload privacy is disabled' {
        $root = Get-NxbAdaptiveTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Resolve-NxbAdaptiveObservabilityPlan.ps1') -Raw
        $source | Should -Match ([regex]::Escape("if ($detail -ceq 'payload' -and -not [bool]$policy.privacy.payload_fields)"))
        $source | Should -Match ([regex]::Escape("$detail = 'semantic'"))
    }

    It 'emits a deterministic SHA-256 plan fingerprint' {
        $root = Get-NxbAdaptiveTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Resolve-NxbAdaptiveObservabilityPlan.ps1') -Raw
        $source | Should -Match ([regex]::Escape('$planFingerprint = Get-NxbSha256Text -Text $material'))
        $source | Should -Match ([regex]::Escape('plan_fingerprint_sha256 = $planFingerprint'))
    }

    It 'resolves empty signals to minimal mode' {
        $plan = Get-NxbAdaptiveTestPlan -Signals @{}
        [string]$plan.effective_mode | Should -BeExactly 'minimal'
        [string]$plan.detail | Should -BeExactly 'summary'
        @($plan.active_trigger_ids).Count | Should -Be 0
    }

    It 'escalates a frame spike to deep mode' {
        $plan = Get-NxbAdaptiveTestPlan -Signals @{ frame_time_ms = 40 }
        [string]$plan.effective_mode | Should -BeExactly 'deep'
        @($plan.active_trigger_ids) | Should -Contain 'frame-spike'
        @($plan.active_domains) | Should -Contain 'gpu'
        @($plan.active_domains) | Should -Contain 'correlation'
    }

    It 'escalates an explicit root-cause request to forensic mode' {
        $plan = Get-NxbAdaptiveTestPlan -Signals @{ root_cause_request = $true }
        [string]$plan.effective_mode | Should -BeExactly 'forensic'
        @($plan.active_trigger_ids) | Should -Contain 'root-cause-request'
        [string]$plan.detail | Should -BeExactly 'semantic'
    }

    It 'prioritizes security trigger domains before forensic profile fallback' {
        $plan = Get-NxbAdaptiveTestPlan -Signals @{ security_state_changed = $true }
        [string]$plan.effective_mode | Should -BeExactly 'forensic'
        @($plan.active_domains)[0] | Should -BeExactly 'security'
        @($plan.active_domains)[1] | Should -BeExactly 'firmware'
        @($plan.active_domains)[2] | Should -BeExactly 'kernel'
        @($plan.active_domains)[3] | Should -BeExactly 'correlation'
    }

    It 'permits operator forensic override but retains privacy clamping' {
        $plan = Get-NxbAdaptiveTestPlan -Signals @{} -OperatorMode forensic
        [string]$plan.effective_mode | Should -BeExactly 'forensic'
        [string]$plan.detail | Should -BeExactly 'semantic'
        @($plan.reasons) | Should -Contain 'operator:forensic'
        @($plan.reasons) | Should -Contain 'privacy:payload_fields_clamped'
    }

    It 'hard-locks the panel server to local bind choices' {
        $root = Get-NxbAdaptiveTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-NxbAdaptiveObservabilityPanel.ps1') -Raw
        $source | Should -Match ([regex]::Escape("[ValidateSet('127.0.0.1','localhost')]"))
        $source | Should -Match ([regex]::Escape("if ($BindAddress -notin @('127.0.0.1','localhost'))"))
    }

    It 'bounds manual override duration and maximum mode' {
        $root = Get-NxbAdaptiveTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-NxbAdaptiveObservabilityPanel.ps1') -Raw
        $source | Should -Match ([regex]::Escape('manual_override_max_seconds'))
        $source | Should -Match ([regex]::Escape('Requested override exceeds policy maximum_mode.'))
        $source | Should -Match ([regex]::Escape('Override duration is outside the policy boundary.'))
    }

    It 'expires stale overrides instead of making them sticky' {
        $root = Get-NxbAdaptiveTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-NxbAdaptiveObservabilityPanel.ps1') -Raw
        $source | Should -Match ([regex]::Escape('if ($expires -le [DateTime]::UtcNow)'))
        $source | Should -Match ([regex]::Escape('Remove-Item -LiteralPath $overridePath'))
    }

    It 'requires evidence receipt and scope before Python accepts validated claims' {
        $root = Get-NxbAdaptiveTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'tools\validate_adaptive_observability_policy.py') -Raw
        $source | Should -Match ([regex]::Escape('validated claim {name} requires non-empty scope'))
        $source | Should -Match ([regex]::Escape('validated claim {name} requires a 64-hex evidence receipt'))
    }

    It 'independently verifies plan budgets privacy and fingerprint in Python' {
        $root = Get-NxbAdaptiveTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'tools\validate_adaptive_observability_policy.py') -Raw
        $source | Should -Match ([regex]::Escape('plan exceeds max_concurrent_domains'))
        $source | Should -Match ([regex]::Escape('plan privacy drift'))
        $source | Should -Match ([regex]::Escape('plan fingerprint mismatch'))
        $source | Should -Match ([regex]::Escape('REQUIRED_TARGETS'))
    }
}
