$ErrorActionPreference = 'Stop'

Describe 'SUPERBLOCK 2 controlled transition eligibility contract' {
    BeforeAll {
        function Get-NxbTransitionTestRoot {
            $root = [string]$env:NXB_PLATFORM_TRANSITION_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_PLATFORM_TRANSITION_REPOSITORY_ROOT is required.' }
            $fullRoot = [IO.Path]::GetFullPath($root)
            if (-not (Test-Path -LiteralPath $fullRoot -PathType Container)) { throw "Repository root missing: $fullRoot" }
            return $fullRoot
        }
    }

    It 'keeps active runtime analyzer and certification repo-owned' {
        $root = Get-NxbTransitionTestRoot
        foreach ($relative in @(
            'scripts\Invoke-NxbPlatformControlledTransitionsV2.ps1',
            'tools\analyze_platform_transition_eligibility.py',
            'scripts\Invoke-NxbSuperblock2TransitionEligibilityCertification.ps1'
        )) { Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf | Should -BeTrue }
    }

    It 'binds runtime to canonical L1 review evidence' {
        $root = Get-NxbTransitionTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformControlledTransitionsV2.ps1') -Raw
        foreach ($needle in @('platform-event-certification-receipt.json','platform-event-baseline-a.json','ProviderMetadataFingerprintSha256','BindingFingerprintSha256')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'uses only pnputil scan-devices for the PnP stimulus' {
        $root = Get-NxbTransitionTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformControlledTransitionsV2.ps1') -Raw
        $source | Should -Match ([regex]::Escape('/scan-devices'))
        foreach ($forbidden in @('/disable-device','/remove-device','/delete-driver','/add-driver','/install')) {
            $source | Should -Not -Match ([regex]::Escape($forbidden))
        }
    }

    It 'records that PnP disable remove and install are unused' {
        $root = Get-NxbTransitionTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformControlledTransitionsV2.ps1') -Raw
        foreach ($needle in @('device_disable_used = $false','device_remove_used = $false','device_install_used = $false')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'uses a temporary duplicate power scheme and restores the original' {
        $root = Get-NxbTransitionTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformControlledTransitionsV2.ps1') -Raw
        foreach ($needle in @('/duplicatescheme $originalGuid','/setactive $temporaryGuid','/setactive $originalGuid','/delete $temporaryGuid','Original power scheme was not restored')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'guards power cleanup in finally' {
        $root = Get-NxbTransitionTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformControlledTransitionsV2.ps1') -Raw
        $source | Should -Match ([regex]::Escape('finally {'))
        $source | Should -Match ([regex]::Escape('if ($created -and -not $restored)'))
        $source | Should -Match ([regex]::Escape('if ($created -and -not $deleted'))
    }

    It 'hashes the original power scheme identifier instead of reviewing it raw' {
        $root = Get-NxbTransitionTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformControlledTransitionsV2.ps1') -Raw
        $source | Should -Match ([regex]::Escape('original_scheme_guid_sha256 = $originalHash'))
        $source | Should -Not -Match ([regex]::Escape('original_scheme_guid = $originalGuid'))
    }

    It 'does not mutate firmware Secure Boot TPM or Device Guard' {
        $root = Get-NxbTransitionTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformControlledTransitionsV2.ps1') -Raw
        foreach ($needle in @('firmware_state_changed = $false','secure_boot_changed = $false','tpm_state_changed = $false','device_guard_changed = $false')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'derives PnP and power surfaces from L1 available logs' {
        $root = Get-NxbTransitionTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformControlledTransitionsV2.ps1') -Raw
        foreach ($needle in @("Microsoft-Windows-Kernel-PnP","Microsoft-Windows-UserPnp","Microsoft-Windows-Kernel-Power","Microsoft-Windows-Kernel-Processor-Power","status -ceq 'available'")) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'uses exactly eight ordered matched-control scenarios' {
        $root = Get-NxbTransitionTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformControlledTransitionsV2.ps1') -Raw
        foreach ($scenario in @('idle_pnp_a','pnp_rescan_a','idle_pnp_b','pnp_rescan_b','idle_power_a','power_transition_a','idle_power_b','power_transition_b')) {
            $source | Should -Match ([regex]::Escape("'$scenario'"))
        }
        $source | Should -Match ([regex]::Escape('scenario_count = 8'))
    }

    It 'bounds idle and post-stimulus windows and per-log events' {
        $root = Get-NxbTransitionTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformControlledTransitionsV2.ps1') -Raw
        foreach ($needle in @('[ValidateRange(500,5000)][int]$IdleWindowMilliseconds = 1500','[ValidateRange(500,5000)][int]$PostStimulusMilliseconds = 1500','[ValidateRange(1,512)][int]$MaxEventsPerLog = 256')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'aggregates structural event shapes and does not retain event records' {
        $root = Get-NxbTransitionTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformControlledTransitionsV2.ps1') -Raw
        foreach ($needle in @('Group-Object { Get-NxbTransitionV2ShapeKey','sampled_event_count','shapes = $shapes','id =','version =','level =','task =','opcode =','count =')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'treats NoMatchingEventsFound as a measured zero rather than unavailable' {
        $root = Get-NxbTransitionTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformControlledTransitionsV2.ps1') -Raw
        $source | Should -Match ([regex]::Escape("NoMatchingEventsFound"))
        $source | Should -Match ([regex]::Escape("status = 'available'"))
        $source | Should -Match ([regex]::Escape('sampled_event_count = 0'))
    }

    It 'keeps other bounded query failures unavailable with null counts' {
        $root = Get-NxbTransitionTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformControlledTransitionsV2.ps1') -Raw
        $source | Should -Match ([regex]::Escape("status = 'unavailable'"))
        $source | Should -Match ([regex]::Escape('sampled_event_count = $null'))
        $source | Should -Match ([regex]::Escape("reason = 'bounded_query_failed'"))
    }

    It 'forbids raw event message XML payload and WPR exposure' {
        $root = Get-NxbTransitionTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformControlledTransitionsV2.ps1') -Raw
        foreach ($needle in @('raw_event_message_exposed = $false','raw_event_xml_exposed = $false','raw_event_payload_exposed = $false','wpr_used = $false')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
        foreach ($forbidden in @('FormatDescription','ToXml','Start-Wpr','wpr.exe')) {
            $source | Should -Not -Match ([regex]::Escape($forbidden))
        }
    }

    It 'uses analyzer-safe active power GUID variable naming' {
        $root = Get-NxbTransitionTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformControlledTransitionsV2.ps1') -Raw
        $source | Should -Match ([regex]::Escape('$guidMatch = [regex]::Match'))
        $source | Should -Not -Match ([regex]::Escape('$match = [regex]::Match'))
    }

    It 'analyzes matched idle deltas independently in Python' {
        $root = Get-NxbTransitionTestRoot
        $analyzer = Get-Content -LiteralPath (Join-Path $root 'tools\analyze_platform_transition_eligibility.py') -Raw
        foreach ($needle in @('positive_delta','analyze_pair','idle_pnp_a','pnp_rescan_a','idle_power_a','power_transition_a')) {
            $analyzer | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'requires repeated positive deltas before mapping eligibility becomes true' {
        $root = Get-NxbTransitionTestRoot
        $analyzer = Get-Content -LiteralPath (Join-Path $root 'tools\analyze_platform_transition_eligibility.py') -Raw
        $analyzer | Should -Match ([regex]::Escape('repeated = sorted(set(delta_a) & set(delta_b))'))
        $analyzer | Should -Match ([regex]::Escape('"mapping_eligible": bool(candidates)'))
    }

    It 'does not fail merely because a controlled family produces zero repeated signal' {
        $root = Get-NxbTransitionTestRoot
        $analyzer = Get-Content -LiteralPath (Join-Path $root 'tools\analyze_platform_transition_eligibility.py') -Raw
        $analyzer | Should -Match ([regex]::Escape('"repeated_positive_delta_shape_count": len(candidates)'))
        $analyzer | Should -Not -Match ([regex]::Escape('require(bool(candidates)'))
    }

    It 'keeps event semantics causality and completeness conservative' {
        $root = Get-NxbTransitionTestRoot
        $analyzer = Get-Content -LiteralPath (Join-Path $root 'tools\analyze_platform_transition_eligibility.py') -Raw
        foreach ($needle in @('"event_id_semantics": False','"event_task_opcode_semantics": False','"device_lifecycle_semantics": False','"power_causality": False','"firmware_causality": False','"root_cause_validated": False','"continuous_trace_completeness": "not_claimed"')) {
            $analyzer | Should -Match ([regex]::Escape($needle))
        }
    }
}
