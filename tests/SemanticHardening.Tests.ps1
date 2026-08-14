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
                pnp_fixture = Join-Path $fullRoot 'scripts\NxbSemanticPnpFixture.cs'
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
            $context.config,$context.pnp,$context.pnp_fixture,$context.pcie,$context.power,$context.root_trace,$context.certification,
            $context.top_certification,$context.host_preflight,$context.profile,$context.python,$context.deep_python
        )) { Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue }
    }

    It 'maps exactly eight unique claims across four experiment families' {
        $context = Get-NxbSemanticHardeningTestContext
        $config = Get-Content -LiteralPath $context.config -Raw | ConvertFrom-Json
        @($config.experiment_families).Count | Should -Be 4
        $claims = @($config.experiment_families | ForEach-Object { @($_.claims) })
        $claims.Count | Should -Be 8
        @($claims | Sort-Object -Unique).Count | Should -Be 8
    }

    It 'uses one owned PnP fixture with native lifecycle checks and repo-owned EventSource metadata authority' {
        $context = Get-NxbSemanticHardeningTestContext
        $source = Get-Content -LiteralPath $context.pnp -Raw
        $fixtureSource = Get-Content -LiteralPath $context.pnp_fixture -Raw
        foreach ($token in @(
            'SwDeviceCreate','SwDeviceClose','HTREE\\ROOT\\0','SetupDiCreateDeviceInfoW','SetupDiCallClassInstaller',
            'DIF_REGISTERDEVICE','DiUninstallDevice','CleanupRebootRequired','CM_Locate_DevNodeW','0x8007007E','setupapi_root_fallback',
            'EventSource','EventListener','NXB-Semantic-PnP-Fixture','EmitCreateIfPresent','EmitRemoveIfAbsent','FixtureCreateConfirmed','FixtureRemoveConfirmed'
        )) { $fixtureSource | Should -Match ([regex]::Escape($token)) }
        $fixtureSource | Should -Match ([regex]::Escape('CleanupAttempts = 3'))
        $source | Should -Match ([regex]::Escape('Nxb.Semantic.PnpFixtureLease'))
        $source | Should -Match ([regex]::Escape('Nxb.Semantic.PnpLifecycleCollector'))
        $source | Should -Match ([regex]::Escape('repo_owned_eventsource_lifecycle_bridge_v1'))
        $source | Should -Match ([regex]::Escape('optional_windows_eventlog_used_as_authority = $false'))
        $source | Should -Match ([regex]::Escape('cim_presence_probe_used = $false'))
        $source | Should -Match ([regex]::Escape('[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Record'))
        $source | Should -Match ([regex]::Escape('if ($Record.Count -eq 0) { return @() }'))
        $source | Should -Not -Match ([regex]::Escape('[Parameter(Mandatory)][object[]]$Record'))
        $source | Should -Not -Match '(?im)\bGet-WinEvent\b'
        $source | Should -Not -Match '(?im)Get-CimInstance\s+Win32_PnPEntity\b'
        $source | Should -Not -Match '(?i)Disable-PnpDevice|Remove-PnpDevice|Uninstall-PnpDevice'
    }

    It 'keeps PnP raw identifiers payloads and formatted messages out of review claims' {
        $context = Get-NxbSemanticHardeningTestContext
        $source = Get-Content -LiteralPath $context.pnp -Raw
        $source | Should -Match ([regex]::Escape('raw_device_instance_id_reviewable = $false'))
        $source | Should -Match ([regex]::Escape('raw_event_payload_reviewable = $false'))
        $source | Should -Match ([regex]::Escape('formatted_event_message_reviewable = $false'))
        $source | Should -Match ([regex]::Escape('primary_failure_localized_text_reviewable = $false'))
    }

    It 'cross-checks PCIe address decoding against sanitized location-path semantics' {
        $context = Get-NxbSemanticHardeningTestContext
        $source = Get-Content -LiteralPath $context.pcie -Raw
        foreach ($token in @('DEVPKEY_Device_BusNumber','DEVPKEY_Device_Address','DEVPKEY_Device_LocationPaths','$address -shr 16','location_path_cross_check_matches')) {
            $source | Should -Match ([regex]::Escape($token))
        }
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

    It 'confines firmware transition evidence to an ephemeral unstarted Generation 2 VM with shape-safe Secure Boot readback' {
        $context = Get-NxbSemanticHardeningTestContext
        $source = Get-Content -LiteralPath $context.power -Raw
        $source | Should -Match ([regex]::Escape('-Generation 2'))
        $source | Should -Match ([regex]::Escape('-NoVHD'))
        $source | Should -Match ([regex]::Escape('Set-VMFirmware'))
        $source | Should -Match ([regex]::Escape('-EnableSecureBoot $alternate'))
        $source | Should -Match ([regex]::Escape('function Get-NxbSemanticFirmwareSecureBootState'))
        $source | Should -Match ([regex]::Escape('foreach ($propertyName in @(''SecureBoot'',''EnableSecureBoot''))'))
        $source | Should -Match ([regex]::Escape('secure_boot_readback = ''vmfirmware_property_adapter_v1'''))
        $source | Should -Not -Match '(?im)\(\s*Get-VMFirmware\b[^\r\n]*\)\.EnableSecureBoot\b'
        $source | Should -Match ([regex]::Escape('Remove-VM'))
        $source | Should -Not -Match '(?im)^\s*Start-VM\b'
    }

    It 'uses sequential bounded matched-WPT WPR collectors scenario continuity and measured dictionary-safe trace counters' {
        $context = Get-NxbSemanticHardeningTestContext
        [xml]$xml = Get-Content -LiteralPath $context.profile -Raw
        $fileCollectors = @($xml.WindowsPerformanceRecorder.Profiles.SystemCollector) + @($xml.WindowsPerformanceRecorder.Profiles.EventCollector)
        $fileCollectors = @($fileCollectors | Where-Object { $_.Id -match 'File$' })
        $fileCollectors.Count | Should -Be 2
        foreach ($collector in $fileCollectors) {
            [string]$collector.MaximumFileSize.FileMode | Should -BeExactly 'Sequential'
            [int]$collector.MaximumFileSize.Value | Should -Be 512
        }
        $source = Get-Content -LiteralPath $context.root_trace -Raw
        $source | Should -Match ([regex]::Escape('scenario_count=10'))
        $source | Should -Match ([regex]::Escape('observation_gap_count=$observationGapCount'))
        $source | Should -Match ([regex]::Escape('sequential_capacity_reached=$capacityReached'))
        $source | Should -Match ([regex]::Escape('if ($current -is [System.Collections.IDictionary])'))
        $source | Should -Match ([regex]::Escape('if (-not $current.Contains($segment)) { return $DefaultValue }'))
        $source | Should -Match ([regex]::Escape('$current = $current[$segment]'))
        $source | Should -Match ([regex]::Escape('$statisticsStatus -cne ''measured'''))
        $source | Should -Match ([regex]::Escape('$eventsLostStatus -cne ''measured'''))
        $source | Should -Match ([regex]::Escape('$buffersLostStatus -cne ''measured'''))
        $source | Should -Match ([regex]::Escape('$buffersWrittenStatus -cne ''measured'''))
        $source | Should -Match ([regex]::Escape('$eventsLost -ne 0 -or $buffersLost -ne 0 -or $buffersWritten -eq 0'))
        $source | Should -Match ([regex]::Escape('$pairedWpr = Join-Path $xperfDirectory ''wpr.exe'''))
        $source | Should -Match ([regex]::Escape('Matched WPT toolchain unavailable: xperf sibling wpr.exe missing beside {0}'))
        $source | Should -Match ([regex]::Escape('''-recordtempto'',$wprTempRoot,''-instancename'',$wprInstanceName'))
        $source | Should -Match ([regex]::Escape('$stop.exit_code -eq -2147417850'))
        $source | Should -Match ([regex]::Escape('$statusAfterStop.exit_code -ne -984076288'))
        $source | Should -Match ([regex]::Escape('$mergeArguments.Add(''-merge'')'))
        $source | Should -Match ([regex]::Escape('toolchain_binding=''xperf_sibling_wpr_v1'''))
        $source | Should -Match ([regex]::Escape('wpr_stop_recovery_used=$wprStopRecoveryUsed'))
        $source | Should -Not -Match '(?im)^\s*\$wpr\s*=\s*\(Get-Command\s+wpr\.exe\b'
        $legacyStartPattern = '(?im)@\(''-start'',\$profileReference,''-filemode''\)'
        $source | Should -Not -Match $legacyStartPattern
    }

    It 'requires independent validators to own all final claim and deep evidence gates' {
        $context = Get-NxbSemanticHardeningTestContext
        $source = Get-Content -LiteralPath $context.python -Raw
        foreach ($claim in @(
            'pnp_lifecycle_semantics','pcie_bdf_semantics','event_id_semantics','event_task_opcode_semantics',
            'power_causality','firmware_causality','root_cause_validated','continuous_trace_completeness'
        )) { $source | Should -Match ([regex]::Escape('"' + $claim + '"')) }
        foreach ($token in @('requested=8 validated=8','setupapi_root_fallback','cim_presence_probe_used','PNP_EVENT_SOURCE','PNP_CREATE_EVENT_ID','PNP_REMOVE_EVENT_ID','PNP_CREATE_OPCODE','PNP_REMOVE_OPCODE')) {
            $source | Should -Match ([regex]::Escape($token))
        }

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

    It 'binds receipts only after 8-of-8 validation and keeps inherited regressions out of runtime surface' {
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
        $preflightSource = Get-Content -LiteralPath $context.host_preflight -Raw
        $preflightSource | Should -Match ([regex]::Escape('lifecycle_probe_executed = $pnpFixtureSourcePresent'))
        $preflightSource | Should -Match ([regex]::Escape('physical_pnp_device_modified = $false'))
        $preflightSource | Should -Match ([regex]::Escape('cleanup_reboot_required = $pnpFixtureCleanupRebootRequired'))

        foreach ($path in @($context.pnp,$context.pcie,$context.power,$context.root_trace,$context.certification,$context.top_certification,$context.host_preflight)) {
            $runtimeSource = Get-Content -LiteralPath $path -Raw
            $runtimeSource | Should -Not -Match '(?im)^\s*\$matches\s*='
            $runtimeSource | Should -Not -Match '(?im)^\s*\$profile\s*='
            $runtimeSource | Should -Not -Match '(?ims)catch\s*\{\s*\}'
        }
        $ledger = Get-Content -LiteralPath $context.ledger -Raw
        $ledger | Should -Match ([regex]::Escape('NXB-ERR-032'))
        $ledger | Should -Match ([regex]::Escape('NXB-ERR-034'))
    }
}
