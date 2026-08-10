$ErrorActionPreference = 'Stop'

Describe 'NXB adaptive observability control-plane contract' {
    BeforeAll {
        $root = [string]$env:NXB_ADAPTIVE_REPOSITORY_ROOT
        if ([string]::IsNullOrWhiteSpace($root)) { $root = Split-Path -Parent $PSScriptRoot }
        $policyPath = Join-Path $root 'config\adaptive-observability.default.json'
        $claimsPath = Join-Path $root 'config\semantic-claim-targets.json'
        $plannerPath = Join-Path $root 'scripts\Get-NxbAdaptiveObservabilityPlan.ps1'
        $panelPath = Join-Path $root 'scripts\New-NxbAdaptiveObservabilityPanel.ps1'
        $controllerPath = Join-Path $root 'scripts\Invoke-NxbAdaptiveObservabilityControlPlane.ps1'
        $validatorPath = Join-Path $root 'tools\validate_adaptive_observability.py'
        $schemaPath = Join-Path $root 'schemas\adaptive-observability-policy.schema.json'
        $policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
        $claims = Get-Content -LiteralPath $claimsPath -Raw | ConvertFrom-Json
        $plannerSource = Get-Content -LiteralPath $plannerPath -Raw
        $panelSource = Get-Content -LiteralPath $panelPath -Raw
        $controllerSource = Get-Content -LiteralPath $controllerPath -Raw
        $validatorSource = Get-Content -LiteralPath $validatorPath -Raw
    }

    It 'keeps all adaptive foundation components repo-owned' {
        foreach ($path in @($policyPath,$claimsPath,$plannerPath,$panelPath,$controllerPath,$validatorPath,$schemaPath)) {
            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        }
    }

    It 'uses exact ordered capture levels' {
        [int]$policy.levels.off.rank | Should -Be 0
        [int]$policy.levels.baseline.rank | Should -Be 1
        [int]$policy.levels.focused.rank | Should -Be 2
        [int]$policy.levels.forensic.rank | Should -Be 3
    }

    It 'defaults to low-overhead baseline collection' {
        [string]$policy.default_level | Should -BeExactly 'baseline'
    }

    It 'forbids raw payload outside forensic level' {
        [bool]$policy.levels.off.raw_payload_allowed | Should -BeFalse
        [bool]$policy.levels.baseline.raw_payload_allowed | Should -BeFalse
        [bool]$policy.levels.focused.raw_payload_allowed | Should -BeFalse
    }

    It 'keeps raw payload disabled by default and hashes identifiers' {
        [bool]$policy.retention.raw_payload_default | Should -BeFalse
        [bool]$policy.retention.hash_raw_identifiers | Should -BeTrue
        [bool]$policy.retention.redact_messages_by_default | Should -BeTrue
    }

    It 'always retains high-value evidence classes' {
        foreach ($name in @('control_plane_transition','capture_receipt','hash_manifest','loss_accounting','claim_evidence','error_boundary')) {
            @($policy.retention.always_keep) | Should -Contain $name
        }
    }

    It 'bounds simultaneous elevated domains' {
        [int]$policy.budgets.max_concurrent_elevated_domains | Should -BeGreaterThan 0
        ([int]$policy.budgets.max_concurrent_elevated_domains -le 4) | Should -BeTrue
        $plannerSource | Should -Match ([regex]::Escape('max_concurrent_elevated_domains'))
        $plannerSource | Should -Match ([regex]::Escape('budget_suppressed'))
    }

    It 'bounds capture duration and review evidence size' {
        ([int]$policy.budgets.max_capture_seconds -le 300) | Should -BeTrue
        ([int64]$policy.budgets.max_review_bytes -le 67108864) | Should -BeTrue
    }

    It 'supports manual focused and forensic escalation' {
        @($policy.rules.signal) | Should -Contain 'manual_focus'
        @($policy.rules.signal) | Should -Contain 'manual_forensic'
    }

    It 'supports anomaly and semantic calibration signals' {
        foreach ($signal in @('frame_latency_spike','device_transition','power_transition','error_burst','semantic_calibration')) {
            @($policy.rules.signal) | Should -Contain $signal
        }
    }

    It 'expires rule-driven elevation with TTL semantics' {
        $plannerSource | Should -Match ([regex]::Escape('$expiry = $captured.AddSeconds($ttl)'))
        $plannerSource | Should -Match ([regex]::Escape('if ($evaluation -gt $expiry) { continue }'))
    }

    It 'allows manual signals to narrow affected domains' {
        $plannerSource | Should -Match ([regex]::Escape('$signalDomains.Count -gt 0'))
        $plannerSource | Should -Match ([regex]::Escape('$signalDomains -notcontains $ruleDomain'))
    }

    It 'keeps every semantic target desired true but current false before proof' {
        foreach ($claim in @($claims.claims)) {
            [bool]$claim.desired_state | Should -BeTrue
            [bool]$claim.current_state | Should -BeFalse
        }
    }

    It 'requires isolated reboot-capable scope for firmware causality' {
        $claim = @($claims.claims | Where-Object { $_.claim_id -ceq 'firmware_causality' })[0]
        [string]$claim.scope | Should -BeExactly 'isolated_reboot_capable_fixture_only'
        [string]$claim.risk_class | Should -BeExactly 'high_risk_reboot_state_changing'
    }

    It 'scopes continuous completeness to a declared interval' {
        $claim = @($claims.claims | Where-Object { $_.claim_id -ceq 'continuous_trace_completeness' })[0]
        [string]$claim.scope | Should -BeExactly 'declared_observation_interval'
    }

    It 'uses an independent Python validator for policy claims and plan' {
        $validatorSource | Should -Match ([regex]::Escape('validate_policy'))
        $validatorSource | Should -Match ([regex]::Escape('validate_claim_targets'))
        $validatorSource | Should -Match ([regex]::Escape('validate_plan'))
        $controllerSource | Should -Match ([regex]::Escape('--plan $planPath'))
    }

    It 'keeps the local panel read-only without an HTTP listener' {
        $panelSource | Should -Match ([regex]::Escape('The panel is read-only'))
        $panelSource | Should -Not -Match ([regex]::Escape('HttpListener'))
        $panelSource | Should -Not -Match ([regex]::Escape('TcpListener'))
    }

    It 'does not execute capture adapters from the foundation controller' {
        $controllerSource | Should -Match ([regex]::Escape('capture_adapters_executed = $false'))
        $controllerSource | Should -Not -Match ('(?i)\bwpr(?:\.exe)?\b')
        $controllerSource | Should -Not -Match ([regex]::Escape('Get-WinEvent'))
    }

    It 'hash-binds policy claims signals plan and panel in the receipt' {
        foreach ($field in @('policy_sha256','claim_targets_sha256','signals_sha256','plan_sha256','panel_sha256')) {
            $controllerSource | Should -Match ([regex]::Escape($field))
        }
    }

    It 'preserves evidence discipline instead of force-promoting claims' {
        $validatorSource | Should -Match ([regex]::Escape('cannot be promoted before evidence gate'))
        $panelSource | Should -Match ([regex]::Escape('Promotion occurs only after every required evidence gate'))
        $plannerSource | Should -Match ([regex]::Escape('policy_driven_adaptive'))
    }
}
