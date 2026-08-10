$ErrorActionPreference = 'Stop'

Describe 'SUPERBLOCK 2 L3 transition surface discovery V2 contract' {
    BeforeAll {
        function Get-NxbL3V2TestRoot {
            $root = [string]$env:NXB_PLATFORM_L3_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_PLATFORM_L3_REPOSITORY_ROOT is required.' }
            return [IO.Path]::GetFullPath($root)
        }
    }

    It 'keeps active L3 components repo-owned' {
        $root = Get-NxbL3V2TestRoot
        foreach ($relative in @(
            'scripts\Get-NxbTransitionSurfaceDiscovery.ps1',
            'scripts\Invoke-NxbPlatformSurfaceDiscoveryReplay.ps1',
            'tools\validate_transition_surface_discovery.py',
            'tools\analyze_platform_transition_eligibility.py',
            'scripts\Invoke-NxbSuperblock2TransitionSurfaceDiscoveryCertificationV2.ps1'
        )) { Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf | Should -BeTrue }
    }

    It 'discovers provider families dynamically from Windows metadata' {
        $root = Get-NxbL3V2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbTransitionSurfaceDiscovery.ps1') -Raw
        $source | Should -Match ([regex]::Escape('Get-WinEvent -ListProvider *'))
        $source | Should -Match ([regex]::Escape("pnp = '(?i)(pnp|device|setup|install)'"))
        $source | Should -Match ([regex]::Escape("power = '(?i)(power|energy|battery|processor)'"))
    }

    It 'discovers attached logs and preserves explicit availability state' {
        $root = Get-NxbL3V2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbTransitionSurfaceDiscovery.ps1') -Raw
        foreach ($needle in @('LogLinks','Get-WinEvent -ListLog $logName',"status = 'available'","status = 'disabled'","status = 'unavailable'")) {
            $source | Should -Match ([regex]::Escape($needle))
        }
        $source | Should -Not -Match ('(?is)catch\s*\{\s*\}')
        $source | Should -Match ([regex]::Escape("reason = 'list_log_failed'"))
    }

    It 'bounds provider surface and family replay cardinality' {
        $root = Get-NxbL3V2TestRoot
        $discovery = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbTransitionSurfaceDiscovery.ps1') -Raw
        $replay = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformSurfaceDiscoveryReplay.ps1') -Raw
        $discovery | Should -Match ([regex]::Escape('[ValidateRange(8,128)][int]$MaxProviders = 64'))
        $discovery | Should -Match ([regex]::Escape('[ValidateRange(8,256)][int]$MaxSurfaces = 128'))
        $replay | Should -Match ([regex]::Escape('[ValidateRange(4,64)][int]$MaxFamilySurfaces = 32'))
    }

    It 'uses ordinal set UTF8 ordering and fingerprint contracts' {
        $root = Get-NxbL3V2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbTransitionSurfaceDiscovery.ps1') -Raw
        $source | Should -Match ([regex]::Escape('[Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)'))
        $source | Should -Match ([regex]::Escape('[Text.Encoding]::UTF8.GetBytes([string]$Value)'))
        $source | Should -Match ([regex]::Escape('Get-NxbSurfaceOrdinalHexKey'))
        $source | Should -Match ([regex]::Escape("fingerprint_contract = 'ordinal_tsv_v1'"))
        $source | Should -Match ([regex]::Escape('$fingerprintMaterial = $fingerprintLines -join'))
    }

    It 'has independent Python discovery fingerprint recomputation' {
        $root = Get-NxbL3V2TestRoot
        $validator = Get-Content -LiteralPath (Join-Path $root 'tools\validate_transition_surface_discovery.py') -Raw
        foreach ($needle in @('recompute_fingerprint','ordinal_key','ordinal_tsv_v1','discovery fingerprint mismatch')) {
            $validator | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'keeps discovery claims structural and conservative' {
        $root = Get-NxbL3V2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbTransitionSurfaceDiscovery.ps1') -Raw
        foreach ($needle in @('provider_name_family_discovery = $true','attached_log_discovery = $true','event_id_semantics = $false','device_lifecycle_semantics = $false','power_causality = $false')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'selects only available discovery surfaces by family' {
        $root = Get-NxbL3V2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformSurfaceDiscoveryReplay.ps1') -Raw
        $source | Should -Match ([regex]::Escape("status -ceq 'available'"))
        $source | Should -Match ([regex]::Escape("-contains 'pnp'"))
        $source | Should -Match ([regex]::Escape("-contains 'power'"))
    }

    It 'runs the same eight matched control stimulus scenario IDs' {
        $root = Get-NxbL3V2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformSurfaceDiscoveryReplay.ps1') -Raw
        foreach ($scenario in @('idle_pnp_a','pnp_rescan_a','idle_pnp_b','pnp_rescan_b','idle_power_a','power_transition_a','idle_power_b','power_transition_b')) {
            $source | Should -Match ([regex]::Escape("id='$scenario'"))
        }
    }

    It 'limits PnP mutation to scan-devices' {
        $root = Get-NxbL3V2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformSurfaceDiscoveryReplay.ps1') -Raw
        $source | Should -Match ([regex]::Escape('/scan-devices'))
        foreach ($forbidden in @('/disable-device','/remove-device','/add-driver','/install')) {
            $source | Should -Not -Match ([regex]::Escape($forbidden))
        }
    }

    It 'uses owned reversible temporary power scheme transitions' {
        $root = Get-NxbL3V2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformSurfaceDiscoveryReplay.ps1') -Raw
        foreach ($needle in @('/duplicatescheme','/setactive $temporaryGuid','/setactive $originalGuid','/delete $temporaryGuid','Original power scheme was not restored')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'retries restore and owned cleanup from finally' {
        $root = Get-NxbL3V2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformSurfaceDiscoveryReplay.ps1') -Raw
        $source | Should -Match ('finally\s*\{[\s\S]{0,1800}/setactive \$originalGuid[\s\S]{0,1800}/delete \$temporaryGuid')
    }

    It 'avoids automatic Matches assignment' {
        $root = Get-NxbL3V2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformSurfaceDiscoveryReplay.ps1') -Raw
        $source | Should -Not -Match ('(?im)^\s*\$matches\s*=')
        $source | Should -Match ([regex]::Escape('$guidMatch = [regex]::Match'))
    }

    It 'keeps raw event message XML and payload out of replay evidence' {
        $root = Get-NxbL3V2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformSurfaceDiscoveryReplay.ps1') -Raw
        $source | Should -Not -Match ([regex]::Escape('FormatDescription'))
        $source | Should -Not -Match ([regex]::Escape('ToXml'))
        foreach ($needle in @('raw_event_message_exposed = $false','raw_event_xml_exposed = $false','raw_event_payload_exposed = $false')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'distinguishes measured zero from unavailable query state' {
        $root = Get-NxbL3V2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformSurfaceDiscoveryReplay.ps1') -Raw
        $source | Should -Match ([regex]::Escape("StartsWith('NoMatchingEventsFound'"))
        $source | Should -Match ([regex]::Escape('sampled_event_count = 0'))
        $source | Should -Match ([regex]::Escape('sampled_event_count = $null'))
    }

    It 'binds replay to discovery and canonical L2 evidence' {
        $root = Get-NxbL3V2TestRoot
        $replay = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformSurfaceDiscoveryReplay.ps1') -Raw
        $cert = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock2TransitionSurfaceDiscoveryCertificationV2.ps1') -Raw
        $replay | Should -Match ([regex]::Escape('discovery_fingerprint_sha256'))
        $cert | Should -Match ([regex]::Escape('d9c355d631bfa7b9248309bedd8e47d4b46b4b35b162ac3a6a7374dc354efaa4'))
    }

    It 'reuses deterministic differential eligibility analysis conservatively' {
        $root = Get-NxbL3V2TestRoot
        $analyzer = Get-Content -LiteralPath (Join-Path $root 'tools\analyze_platform_transition_eligibility.py') -Raw
        $analyzer | Should -Match ([regex]::Escape('repeated_positive_delta_shape_count'))
        $analyzer | Should -Match ([regex]::Escape('mapping_eligible'))
        $analyzer | Should -Match ([regex]::Escape('"event_id_semantics": False'))
        $analyzer | Should -Match ([regex]::Escape('"power_causality": False'))
    }

    It 'accepts measured zero candidates without promoting semantics' {
        $root = Get-NxbL3V2TestRoot
        $cert = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock2TransitionSurfaceDiscoveryCertificationV2.ps1') -Raw
        $cert | Should -Not -Match ('repeated_positive_delta_shape_count[^\r\n]{0,120}-le\s+0')
        $cert | Should -Not -Match ('mapping_eligible[^\r\n]{0,120}-ne\s+\$true')
    }

    It 'requires stable discovery A B and byte-identical analysis replay' {
        $root = Get-NxbL3V2TestRoot
        $cert = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock2TransitionSurfaceDiscoveryCertificationV2.ps1') -Raw
        foreach ($needle in @('transition-surface-discovery-a.json','transition-surface-discovery-b.json','discovery fingerprint changed between snapshots','analysis replay mismatch')) {
            $cert | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'keeps L3 review ZIP bounded and free of raw trace exports' {
        $root = Get-NxbL3V2TestRoot
        $cert = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock2TransitionSurfaceDiscoveryCertificationV2.ps1') -Raw
        $cert | Should -Match ([regex]::Escape('(?i)\.(etl|evtx|xml|jsonl|exe|obj|pdb)$'))
        $cert | Should -Match ([regex]::Escape('(?i)"(message|xml|payload|properties|event_data|user_data|raw_event)"\s*:'))
        $cert | Should -Match ([regex]::Escape('Forbidden L3 review artifact:'))
        $cert | Should -Match ([regex]::Escape('Forbidden L3 review artifact content:'))
    }
}
