$ErrorActionPreference = 'Stop'

Describe 'SUPERBLOCK 2 L4 direct-state transition contract' {
    BeforeAll {
        function Get-NxbL4TestRoot {
            $root = [string]$env:NXB_PLATFORM_L4_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_PLATFORM_L4_REPOSITORY_ROOT is required.' }
            return [IO.Path]::GetFullPath($root)
        }
    }

    It 'keeps active L4 components repo-owned' {
        $root = Get-NxbL4TestRoot
        foreach ($relative in @(
            'scripts\Invoke-NxbPlatformDirectStateTransitions.ps1',
            'tools\validate_platform_direct_state_transitions.py',
            'scripts\Invoke-NxbSuperblock2DirectStateTransitionCertification.ps1'
        )) { Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf | Should -BeTrue }
    }

    It 'collects sanitized PnP state through Win32 PnPEntity' {
        $root = Get-NxbL4TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformDirectStateTransitions.ps1') -Raw
        $source | Should -Match ([regex]::Escape('Get-CimInstance -ClassName Win32_PnPEntity'))
        $source | Should -Match ([regex]::Escape("-Name 'PNPDeviceID'"))
        $source | Should -Match ([regex]::Escape('$identityHash = Get-NxbL4Sha256Text -Text $rawIdentity'))
    }

    It 'keeps raw PnP identifiers out of review object fields' {
        $root = Get-NxbL4TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformDirectStateTransitions.ps1') -Raw
        foreach ($forbidden in @('pnp_device_id =','device_id =','raw_identity =','device_name =')) {
            $source | Should -Not -Match ([regex]::Escape($forbidden))
        }
        $source | Should -Match ([regex]::Escape('record_hashes = $ordered'))
    }

    It 'builds deterministic PnP inventory fingerprints from sorted hashes' {
        $root = Get-NxbL4TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformDirectStateTransitions.ps1') -Raw
        $source | Should -Match ([regex]::Escape('$ordered = @($records | Sort-Object)'))
        $source | Should -Match ([regex]::Escape('$fingerprint = Get-NxbL4Sha256Text -Text ($ordered -join'))
        $source | Should -Match ([regex]::Escape('inventory_fingerprint_sha256 = $fingerprint'))
    }

    It 'runs exactly two bounded PnP rescan repeats' {
        $root = Get-NxbL4TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformDirectStateTransitions.ps1') -Raw
        $source | Should -Match ([regex]::Escape('Invoke-NxbL4PnpRepeat -Repeat A'))
        $source | Should -Match ([regex]::Escape('Invoke-NxbL4PnpRepeat -Repeat B'))
        $source | Should -Match ([regex]::Escape('/scan-devices'))
    }

    It 'does not disable remove or install PnP devices' {
        $root = Get-NxbL4TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformDirectStateTransitions.ps1') -Raw
        foreach ($forbidden in @('/disable-device','/remove-device','/add-driver','/install')) {
            $source | Should -Not -Match ([regex]::Escape($forbidden))
        }
        foreach ($needle in @('device_disable_used = $false','device_remove_used = $false','device_install_used = $false')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'measures PnP state before and after each rescan' {
        $root = Get-NxbL4TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformDirectStateTransitions.ps1') -Raw
        $source | Should -Match ('\$before\s*=\s*Get-NxbL4PnpSnapshot')
        $source | Should -Match ('\$after\s*=\s*Get-NxbL4PnpSnapshot')
        $source | Should -Match ([regex]::Escape('inventory_stable ='))
    }

    It 'does not require PnP inventory stability for certification success' {
        $root = Get-NxbL4TestRoot
        $cert = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock2DirectStateTransitionCertification.ps1') -Raw
        $cert | Should -Not -Match ('pnp_inventory_stable_both[^\r\n]{0,120}-ne\s+\$true')
        $cert | Should -Not -Match ('inventory_stable_both[^\r\n]{0,120}-not')
    }

    It 'creates activates restores and deletes owned temporary power schemes' {
        $root = Get-NxbL4TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformDirectStateTransitions.ps1') -Raw
        foreach ($needle in @('/duplicatescheme $originalGuid','/setactive $temporaryGuid','/setactive $originalGuid','/delete $temporaryGuid')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'observes temporary power state directly before promotion' {
        $root = Get-NxbL4TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformDirectStateTransitions.ps1') -Raw
        $source | Should -Match ([regex]::Escape('$duringGuid = Get-NxbL4ActivePowerSchemeGuid'))
        $source | Should -Match ([regex]::Escape('$activated = ($duringGuid -ceq $temporaryGuid)'))
        $source | Should -Match ([regex]::Escape("throw 'Temporary power scheme was not observed active.'"))
    }

    It 'observes restored original power state directly' {
        $root = Get-NxbL4TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformDirectStateTransitions.ps1') -Raw
        $source | Should -Match ([regex]::Escape('$restoredGuid = Get-NxbL4ActivePowerSchemeGuid'))
        $source | Should -Match ([regex]::Escape('$restored = ($restoredGuid -ceq $originalGuid)'))
        $source | Should -Match ([regex]::Escape("throw 'Original power scheme was not observed restored.'"))
    }

    It 'verifies temporary scheme visibility and deletion' {
        $root = Get-NxbL4TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformDirectStateTransitions.ps1') -Raw
        $source | Should -Match ([regex]::Escape('$afterCreateInventory -notcontains $temporaryGuid'))
        $source | Should -Match ([regex]::Escape('$afterDeleteInventory -notcontains $temporaryGuid'))
    }

    It 'retries power restore and cleanup from finally' {
        $root = Get-NxbL4TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformDirectStateTransitions.ps1') -Raw
        $source | Should -Match ('finally\s*\{[\s\S]{0,2400}/setactive \$originalGuid[\s\S]{0,2400}/delete \$temporaryGuid')
    }

    It 'runs exactly two direct-state power repeats' {
        $root = Get-NxbL4TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformDirectStateTransitions.ps1') -Raw
        $source | Should -Match ([regex]::Escape('Invoke-NxbL4PowerRepeat -Repeat A'))
        $source | Should -Match ([regex]::Escape('Invoke-NxbL4PowerRepeat -Repeat B'))
    }

    It 'promotes only direct power-policy mapping' {
        $root = Get-NxbL4TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformDirectStateTransitions.ps1') -Raw
        $source | Should -Match ([regex]::Escape('power_policy_transition_mapping = $powerMappingValidated'))
        $source | Should -Match ([regex]::Escape('power_causality = $false'))
        $source | Should -Match ([regex]::Escape('pnp_lifecycle_semantics = $false'))
    }

    It 'keeps firmware and security mutation disabled' {
        $root = Get-NxbL4TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformDirectStateTransitions.ps1') -Raw
        foreach ($needle in @('firmware_state_changed = $false','secure_boot_changed = $false','tpm_state_changed = $false','device_guard_changed = $false')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'independently recomputes PnP inventory fingerprints in Python' {
        $root = Get-NxbL4TestRoot
        $validator = Get-Content -LiteralPath (Join-Path $root 'tools\validate_platform_direct_state_transitions.py') -Raw
        $validator | Should -Match ([regex]::Escape('recompute_inventory_fingerprint'))
        $validator | Should -Match ([regex]::Escape('inventory fingerprint mismatch'))
        $validator | Should -Match ([regex]::Escape('hashlib.sha256'))
    }

    It 'independently validates power state relations in Python' {
        $root = Get-NxbL4TestRoot
        $validator = Get-Content -LiteralPath (Join-Path $root 'tools\validate_platform_direct_state_transitions.py') -Raw
        foreach ($needle in @('before == original','during == temporary','restored == original','temporary scheme must differ from original')) {
            $validator | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'binds certification to canonical L3 evidence' {
        $root = Get-NxbL4TestRoot
        $cert = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock2DirectStateTransitionCertification.ps1') -Raw
        $cert | Should -Match ([regex]::Escape('2a8ef6942285af0df07cb2e124eaa7edda8dac746a5c756b1a0b133d3a5446b4'))
        $cert | Should -Match ([regex]::Escape('9f418cbb5aee79cb88093a5894ed2f68b165a344'))
        $cert | Should -Match ([regex]::Escape('transition-surface-certification-receipt.json'))
    }

    It 'keeps L4 review evidence bounded and uses no WPR ETL or raw event collection' {
        $root = Get-NxbL4TestRoot
        $cert = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock2DirectStateTransitionCertification.ps1') -Raw
        $runtime = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbPlatformDirectStateTransitions.ps1') -Raw
        $cert | Should -Match ([regex]::Escape('(?i)\.(etl|evtx|xml|jsonl|exe|obj|pdb)$'))
        $cert | Should -Match ([regex]::Escape('PCI\\VEN_'))
        $cert | Should -Match ([regex]::Escape('PNPDeviceID'))
        $cert | Should -Match ([regex]::Escape('Forbidden L4 review artifact content:'))
        $runtime | Should -Not -Match ('(?i)\bwpr(?:\.exe)?\b')
        $runtime | Should -Not -Match ('(?i)\.etl\b')
        $runtime | Should -Not -Match ([regex]::Escape('Get-WinEvent'))
    }
}
