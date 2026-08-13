$ErrorActionPreference = 'Stop'

Describe 'SUPERBLOCK 2 L3 transition surface discovery contract' {
    BeforeAll {
        function Get-NxbL3TestRoot {
            $root = [string]$env:NXB_PLATFORM_L3_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_PLATFORM_L3_REPOSITORY_ROOT is required.' }
            return [IO.Path]::GetFullPath($root)
        }
    }

    It 'keeps discovery replay validator analyzer and certification repo-owned' {
        $root = Get-NxbL3TestRoot
        foreach ($relative in @(
            'scripts\Get-NxbTransitionSurfaceDiscovery.ps1',
            'scripts\Invoke-NxbPlatformSurfaceDiscoveryReplay.ps1',
            'tools\validate_transition_surface_discovery.py',
            'tools\analyze_platform_transition_eligibility.py',
            'scripts\Invoke-NxbSuperblock2TransitionSurfaceDiscoveryCertification.ps1'
        )) { Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf | Should -BeTrue }
    }

    It 'discovers providers from Windows metadata instead of fixed provider IDs' {
        $root = Get-NxbL3TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbTransitionSurfaceDiscovery.ps1') -Raw
        $source | Should -Match ([regex]::Escape('Get-WinEvent -ListProvider *'))
        $source | Should -Match ([regex]::Escape("pnp = '(?i)(pnp|device|setup|install)'"))
        $source | Should -Match ([regex]::Escape("power = '(?i)(power|energy|battery|processor)'"))
    }

    It 'discovers attached logs and their enabled state' {
        $root = Get-NxbL3TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbTransitionSurfaceDiscovery.ps1') -Raw
        foreach ($needle in @('LogLinks','LogName','Get-WinEvent -ListLog $logName','log_disabled','list_log_failed')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'bounds provider and surface discovery' {
        $root = Get-NxbL3TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbTransitionSurfaceDiscovery.ps1') -Raw
        $source | Should -Match ([regex]::Escape('[ValidateRange(8,128)][int]$MaxProviders = 64'))
        $source | Should -Match ([regex]::Escape('[ValidateRange(8,256)][int]$MaxSurfaces = 128'))
        $source | Should -Match ([regex]::Escape('Select-Object -First $MaxProviders'))
        $source | Should -Match ([regex]::Escape('Select-Object -First $MaxSurfaces'))
    }

    It 'uses ordinal unique string inventories' {
        $root = Get-NxbL3TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbTransitionSurfaceDiscovery.ps1') -Raw
        $source | Should -Match ([regex]::Escape('[Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)'))
        $source | Should -Match ([regex]::Escape('Get-NxbSurfaceOrderedStringInventory'))
    }

    It 'uses ordinal provider and log ordering keys' {
        $root = Get-NxbL3TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbTransitionSurfaceDiscovery.ps1') -Raw
        $source | Should -Match ([regex]::Escape('[Text.Encoding]::UTF8.GetBytes([string]$Value)'))
        $source | Should -Match ([regex]::Escape('Get-NxbSurfaceOrdinalHexKey -Value $_.provider_name'))
        $source | Should -Match ([regex]::Escape('Get-NxbSurfaceOrdinalHexKey -Value $_.log_name'))
    }

    It 'uses an explicit cross-runtime fingerprint contract' {
        $root = Get-NxbL3TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbTransitionSurfaceDiscovery.ps1') -Raw
        foreach ($needle in @(
            'fingerprint_contract = ''ordinal_tsv_v1''',
            '''binding'' + "`t"',
            '''metadata'' + "`t"',
            '''P'' + "`t"',
            '''S'' + "`t"'
        )) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'independently recomputes discovery fingerprint in Python' {
        $root = Get-NxbL3TestRoot
        $validator = Get-Content -LiteralPath (Join-Path $root 'tools\validate_transition_surface_discovery.py') -Raw
        foreach ($needle in @('recompute_fingerprint','ordinal_key','ordinal_tsv_v1','discovery fingerprint mismatch')) {
            $validator | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'keeps discovery claims structural only' {
        $root = Get-NxbL3TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbTransitionSurfaceDiscovery.ps1') -Raw
        foreach ($needle in @('provider_name_family_discovery = $true','attached_log_discovery = $true','event_id_semantics = $false','device_lifecycle_semantics = $false','power_causality = $false')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'selects only discovered available surfaces for replay' {
        $root = Get-NxbL3TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformSurfaceDiscoveryReplay.ps1') -Raw
        $source | Should -Match ([regex]::Escape('$_.status -ceq ''available'''))
        $source | Should -Match ([regex]::Escape('@($_.families) -contains ''pnp'''))
        $source | Should -Match ([regex]::Escape('@($_.families) -contains ''power'''))
    }

    It 'caps replay surfaces per family' {
        $root = Get-NxbL3TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformSurfaceDiscoveryReplay.ps1') -Raw
        $source | Should -Match ([regex]::Escape('[ValidateRange(4,64)][int]$MaxFamilySurfaces = 32'))
        $source | Should -Match ([regex]::Escape('Select-Object -First $MaxFamilySurfaces'))
    }

    It 'runs exactly the matched eight scenario IDs' {
        $root = Get-NxbL3TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformSurfaceDiscoveryReplay.ps1') -Raw
        foreach ($scenario in @('idle_pnp_a','pnp_rescan_a','idle_pnp_b','pnp_rescan_b','idle_power_a','power_transition_a','idle_power_b','power_transition_b')) {
            $source | Should -Match ([regex]::Escape("id='$scenario'"))
        }
    }

    It 'keeps PnP stimulus to scan-devices only' {
        $root = Get-NxbL3TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformSurfaceDiscoveryReplay.ps1') -Raw
        $source | Should -Match ([regex]::Escape('/scan-devices'))
        foreach ($forbidden in @('/disable-device','/remove-device','/add-driver','/install')) {
            $source | Should -Not -Match ([regex]::Escape($forbidden))
        }
    }

    It 'requires reversible owned temporary power schemes' {
        $root = Get-NxbL3TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformSurfaceDiscoveryReplay.ps1') -Raw
        foreach ($needle in @('/duplicatescheme','/setactive $temporaryGuid','/setactive $originalGuid','/delete $temporaryGuid','Original power scheme was not restored')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'retries power restore and cleanup in finally' {
        $root = Get-NxbL3TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformSurfaceDiscoveryReplay.ps1') -Raw
        $source | Should -Match ('finally\s*\{[\s\S]{0,1800}/setactive \$originalGuid[\s\S]{0,1800}/delete \$temporaryGuid')
    }

    It 'does not assign to the automatic Matches variable' {
        $root = Get-NxbL3TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformSurfaceDiscoveryReplay.ps1') -Raw
        $source | Should -Not -Match ('(?im)^\s*\$matches\s*=')
        $source | Should -Match ([regex]::Escape('$guidMatch = [regex]::Match'))
    }

    It 'keeps raw event content out of replay evidence' {
        $root = Get-NxbL3TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformSurfaceDiscoveryReplay.ps1') -Raw
        $source | Should -Not -Match ([regex]::Escape('FormatDescription'))
        $source | Should -Not -Match ([regex]::Escape('ToXml'))
        foreach ($needle in @('raw_event_message_exposed = $false','raw_event_xml_exposed = $false','raw_event_payload_exposed = $false')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'treats no matching events as measured zero' {
        $root = Get-NxbL3TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformSurfaceDiscoveryReplay.ps1') -Raw
        $source | Should -Match ([regex]::Escape("StartsWith('NoMatchingEventsFound'"))
        $source | Should -Match ([regex]::Escape('sampled_event_count = 0'))
    }

    It 'keeps unavailable query counts null' {
        $root = Get-NxbL3TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformSurfaceDiscoveryReplay.ps1') -Raw
        $source | Should -Match ([regex]::Escape("status = 'unavailable'"))
        $source | Should -Match ([regex]::Escape('sampled_event_count = $null'))
    }

    It 'binds replay to discovery and L2 predecessor evidence' {
        $root = Get-NxbL3TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformSurfaceDiscoveryReplay.ps1') -Raw
        $source | Should -Match ([regex]::Escape('discovery_fingerprint_sha256'))
        $source | Should -Match ([regex]::Escape("platform-transition-certification-receipt.json"))
        $source | Should -Match ([regex]::Escape("fingerprint_contract -cne 'ordinal_tsv_v1'"))
    }

    It 'reuses deterministic differential analysis without semantic promotion' {
        $root = Get-NxbL3TestRoot
        $analyzer = Get-Content -LiteralPath (Join-Path $root 'tools\analyze_platform_transition_eligibility.py') -Raw
        $analyzer | Should -Match ([regex]::Escape('repeated_positive_delta_shape_count'))
        $analyzer | Should -Match ([regex]::Escape('mapping_eligible'))
        $analyzer | Should -Match ([regex]::Escape('"event_id_semantics": False'))
        $analyzer | Should -Match ([regex]::Escape('"power_causality": False'))
    }

    It 'does not require a positive candidate count for certification' {
        $root = Get-NxbL3TestRoot
        $cert = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock2TransitionSurfaceDiscoveryCertification.ps1') -Raw
        $cert | Should -Not -Match ('repeated_positive_delta_shape_count[^\r\n]{0,120}-le\s+0')
        $cert | Should -Not -Match ('mapping_eligible[^\r\n]{0,120}-ne\s+\$true')
    }

    It 'requires two discovery snapshots and stable discovery fingerprint' {
        $root = Get-NxbL3TestRoot
        $cert = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock2TransitionSurfaceDiscoveryCertification.ps1') -Raw
        foreach ($needle in @('transition-surface-discovery-a.json','transition-surface-discovery-b.json','discovery fingerprint changed between snapshots')) {
            $cert | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'requires deterministic differential replay' {
        $root = Get-NxbL3TestRoot
        $cert = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock2TransitionSurfaceDiscoveryCertification.ps1') -Raw
        $cert | Should -Match ([regex]::Escape('transition-surface-analysis.json'))
        $cert | Should -Match ([regex]::Escape('transition-surface-analysis-replay.json'))
        $cert | Should -Match ([regex]::Escape('analysis replay mismatch'))
    }

    It 'keeps review evidence bounded and free of raw trace exports' {
        $root = Get-NxbL3TestRoot
        $cert = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock2TransitionSurfaceDiscoveryCertification.ps1') -Raw
        $cert | Should -Match ([regex]::Escape('(?i)\.(etl|evtx|xml|jsonl|exe|obj|pdb)$'))
        $cert | Should -Match ([regex]::Escape('(?i)"(message|xml|payload|properties|event_data|user_data|raw_event)"\s*:'))
        $cert | Should -Match ([regex]::Escape('Forbidden L3 review artifact:'))
        $cert | Should -Match ([regex]::Escape('Forbidden L3 review artifact content:'))
    }
}
