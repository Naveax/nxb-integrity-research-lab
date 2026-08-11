$ErrorActionPreference = 'Stop'

Describe 'NXB IRL-006 Part 2 semantic hardening contract' {
    BeforeAll {
        function Get-NxbSemanticHardeningTestContext {
            $root = [string]$env:NXB_SEMANTIC_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_SEMANTIC_REPOSITORY_ROOT is required.' }
            $fullRoot = [IO.Path]::GetFullPath($root)
            return [pscustomobject][ordered]@{
                root = $fullRoot
                config = Join-Path $fullRoot 'config\nxb-semantic-hardening-experiments.json'
                pnp = Join-Path $fullRoot 'scripts\Invoke-NxbSemanticPnpEventExperiment.ps1'
                pcie = Join-Path $fullRoot 'scripts\Invoke-NxbSemanticPcieBdfExperiment.ps1'
                power = Join-Path $fullRoot 'scripts\Invoke-NxbSemanticPowerFirmwareExperiment.ps1'
                root_trace = Join-Path $fullRoot 'scripts\Invoke-NxbSemanticRootTraceExperiment.ps1'
                certification = Join-Path $fullRoot 'scripts\Invoke-NxbSemanticHardeningCertification.ps1'
                top_certification = Join-Path $fullRoot 'scripts\Invoke-NxbSemanticHardeningCertificationV2.ps1'
                host_preflight = Join-Path $fullRoot 'scripts\Test-NxbSemanticHardeningHostCapability.ps1'
                profile = Join-Path $fullRoot 'profiles\Nxb.SemanticHardeningSequential.wprp'
                python = Join-Path $fullRoot 'tools\validate_semantic_hardening.py'
                deep_python = Join-Path $fullRoot 'tools\validate_semantic_root_trace_evidence.py'
                policy = Join-Path $fullRoot 'config\adaptive-observability-policy.default.json'
                ledger = Join-Path $fullRoot 'docs\NXB-KNOWN-ERROR-LEDGER.md'
            }
        }
    }

    It 'keeps every current Part 2 component repo-owned' {
        $context = Get-NxbSemanticHardeningTestContext
        foreach ($path in @(
            $context.config,$context.pnp,$context.pcie,$context.power,$context.root_trace,$context.certification,
            $context.top_certification,$context.host_preflight,$context.profile,$context.python,$context.deep_python
        )) {
            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        }
    }

    It 'maps exactly eight unique claims across four experiment families' {
        $context = Get-NxbSemanticHardeningTestContext
        $config = Get-Content -LiteralPath $context.config -Raw | ConvertFrom-Json
        @($config.experiment_families).Count | Should -Be 4
        $claims = @($config.experiment_families | ForEach-Object { @($_.claims) })
        $claims.Count | Should -Be 8
        @($claims | Sort-Object -Unique).Count | Should -Be 8
    }

    It 'uses the Windows Software Device API for owned PnP lifecycle controls' {
        $context = Get-NxbSemanticHardeningTestContext
        $source = Get-Content -LiteralPath $context.pnp -Raw
        $source | Should -Match ([regex]::Escape('SwDeviceCreate'))
        $source | Should -Match ([regex]::Escape('SwDeviceClose'))
        $source | Should -Match ([regex]::Escape('HTREE\\ROOT\\0'))
        $source | Should -Not -Match '(?i)Disable-PnpDevice|Remove-PnpDevice|Uninstall-PnpDevice'
    }

    It 'keeps PnP raw identifiers payloads and formatted messages out of review claims' {
        $context = Get-NxbSemanticHardeningTestContext
        $source = Get-Content -LiteralPath $context.pnp -Raw
        $source | Should -Match ([regex]::Escape('raw_device_instance_id_reviewable = $false'))
        $source | Should -Match ([regex]::Escape('raw_event_payload_reviewable = $false'))
        $source | Should -Match ([regex]::Escape('formatted_event_message_reviewable = $false'))
    }

    It 'cross-checks PCIe address decoding against sanitized location-path semantics' {
        $context = Get-NxbSemanticHardeningTestContext
        $source = Get-Content -LiteralPath $context.pcie -Raw
        $source | Should -Match ([regex]::Escape('DEVPKEY_Device_BusNumber'))
        $source | Should -Match ([regex]::Escape('DEVPKEY_Device_Address'))
        $source | Should -Match ([regex]::Escape('DEVPKEY_Device_LocationPaths'))
        $source | Should -Match ([regex]::Escape('$address -shr 16'))
        $source | Should -Match ([regex]::Escape('location_path_cross_check_matches'))
    }

    It 'requires three same-boot PCIe snapshots without cross-boot promotion' {
        $context = Get-NxbSemanticHardeningTestContext
        $source = Get-Content -LiteralPath $context.pcie -Raw
        $source | Should -Match ([regex]::Escape('foreach ($index in 1..3)'))
        $source | Should -Match ([regex]::Escape('cross_boot_bdf_stability_claimed = $false'))
    }

    It 'uses reversible temporary power-scheme transitions with cleanup' {
        $context = Get-NxbSemanticHardeningTestContext
        $source = Get-Content -LiteralPath $context.power -Raw
        foreach ($token in @('/duplicatescheme','/setactive','/delete','original_scheme_restored','temporary_scheme_deleted')) {
            $source | Should -Match ([regex]::Escape($token))
        }
    }

    It 'confines firmware transition evidence to an ephemeral unstarted Generation 2 VM' {
        $context = Get-NxbSemanticHardeningTestContext
        $source = Get-Content -LiteralPath $context.power -Raw
        $source | Should -Match ([regex]::Escape('-Generation 2'))
        $source | Should -Match ([regex]::Escape('-NoVHD'))
        $source | Should -Match ([regex]::Escape('Set-VMFirmware'))
        $source | Should -Match ([regex]::Escape('Remove-VM'))
        $source | Should -Not -Match '(?im)^\s*Start-VM\b'
    }

    It 'uses sequential bounded WPR collectors and scenario continuity for trace completeness' {
        $context = Get-NxbSemanticHardeningTestContext
        [xml]$xml = Get-Content -LiteralPath $context.profile -Raw
        $fileCollectors = @($xml.WindowsPerformanceRecorder.Profiles.SystemCollector,$xml.WindowsPerformanceRecorder.Profiles.EventCollector)
        @($fileCollectors | Where-Object { $_.Id -match 'File$' }).Count | Should -Be 2
        foreach ($collector in @($fileCollectors | Where-Object { $_.Id -match 'File$' })) {
            [string]$collector.MaximumFileSize.FileMode | Should -BeExactly 'Sequential'
            [int]$collector.MaximumFileSize.Value | Should -Be 512
        }
        $source = Get-Content -LiteralPath $context.root_trace -Raw
        $source | Should -Match ([regex]::Escape('scenario_count=10'))
        $source | Should -Match ([regex]::Escape('observation_gap_count=$observationGapCount'))
        $source | Should -Match ([regex]::Escape('sequential_capacity_reached=$capacityReached'))
    }

    It 'requires independent validators to own all final claim and deep evidence gates' {
        $context = Get-NxbSemanticHardeningTestContext
        $source = Get-Content -LiteralPath $context.python -Raw
        foreach ($claim in @(
            'pnp_lifecycle_semantics','pcie_bdf_semantics','event_id_semantics','event_task_opcode_semantics',
            'power_causality','firmware_causality','root_cause_validated','continuous_trace_completeness'
        )) {
            $source | Should -Match ([regex]::Escape('"' + $claim + '"'))
        }
        $source | Should -Match ([regex]::Escape('requested=8 validated=8'))

        $deepSource = Get-Content -LiteralPath $context.deep_python -Raw
        foreach ($token in @('events_lost','buffers_lost','buffers_written','all_on_domain_counts','kernel_interventions','summary_replay','events_replay')) {
            $deepSource | Should -Match ([regex]::Escape($token))
        }
    }

    It 'does not pre-promote the eight Part 2 semantic targets inside the repository default policy' {
        $context = Get-NxbSemanticHardeningTestContext
        $policy = Get-Content -LiteralPath $context.policy -Raw | ConvertFrom-Json
        $part2Names = @(
            'pnp_lifecycle_semantics','pcie_bdf_semantics','event_id_semantics','event_task_opcode_semantics',
            'power_causality','firmware_causality','root_cause_validated','continuous_trace_completeness'
        )
        $targets = @($policy.claim_targets)
        $part2Targets = @($targets | Where-Object { $part2Names -contains [string]$_.name })
        $part2Targets.Count | Should -Be 8
        @($part2Targets | ForEach-Object { [string]$_.name } | Sort-Object -Unique).Count | Should -Be 8
        @($part2Targets | Where-Object { [bool]$_.validated }).Count | Should -Be 0
        @($part2Targets | Where-Object { -not [bool]$_.target_requested }).Count | Should -Be 0
    }

    It 'binds receipts only after 8-of-8 validation and keeps inherited regressions out of the runtime surface' {
        $context = Get-NxbSemanticHardeningTestContext
        $source = Get-Content -LiteralPath $context.certification -Raw
        $matrixPosition = $source.IndexOf('[5/8] Independent Python 8/8 replay',[StringComparison]::Ordinal)
        $receiptPosition = $source.IndexOf('[6/8] Generate and independently validate eight Part 1-compatible receipts',[StringComparison]::Ordinal)
        $matrixPosition | Should -BeGreaterThan -1
        $receiptPosition | Should -BeGreaterThan $matrixPosition
        $source | Should -Match ([regex]::Escape("status='validated'"))
        $source | Should -Match ([regex]::Escape('independent_validation_passed=$true'))

        $topSource = Get-Content -LiteralPath $context.top_certification -Raw
        $topSource | Should -Match ([regex]::Escape('Fail-fast native host capability gate'))
        $topSource | Should -Match ([regex]::Escape('Deep independent root-cause + trace evidence replay'))
        $topSource | Should -Match ([regex]::Escape('deep_root_trace_validation = $true'))
        $preflightSource = Get-Content -LiteralPath $context.host_preflight -Raw
        $preflightSource | Should -Match ([regex]::Escape('No Windows feature enablement, reboot, persistent PATH change, host-firmware mutation, or service start was attempted.'))

        foreach ($path in @($context.pnp,$context.pcie,$context.power,$context.root_trace,$context.certification,$context.top_certification,$context.host_preflight)) {
            $runtimeSource = Get-Content -LiteralPath $path -Raw
            $runtimeSource | Should -Not -Match '(?im)^\s*\$matches\s*='
            $runtimeSource | Should -Not -Match '(?im)^\s*\$profile\s*='
            $runtimeSource | Should -Not -Match '(?ims)catch\s*\{\s*\}'
        }
        $powerSource = Get-Content -LiteralPath $context.power -Raw
        $powerSource | Should -Match ([regex]::Escape('function Invoke-NxbSemanticPowerNative'))
        $powerSource | Should -Match ([regex]::Escape('$previousErrorActionPreference = $ErrorActionPreference'))
        $powerSource | Should -Not -Match '(?im)^\s*\$[A-Za-z_][A-Za-z0-9_]*\s*=\s*@\(&\s*\$PowerCfgPath\b[^\r\n]*2>&1\)'

        $ledger = Get-Content -LiteralPath $context.ledger -Raw
        $ledger | Should -Match ([regex]::Escape('NXB-ERR-022'))
    }
}
