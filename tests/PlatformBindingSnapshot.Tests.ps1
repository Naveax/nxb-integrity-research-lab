$ErrorActionPreference = 'Stop'

Describe 'SUPERBLOCK 2 platform binding snapshot contract' {
    BeforeAll {
        function Get-NxbPlatformBindingTestRoot {
            $root = [string]$env:NXB_PLATFORM_BINDING_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) {
                throw 'NXB_PLATFORM_BINDING_REPOSITORY_ROOT is required.'
            }
            $fullRoot = [IO.Path]::GetFullPath($root)
            if (-not (Test-Path -LiteralPath $fullRoot -PathType Container)) {
                throw "Platform-binding repository root does not exist: $fullRoot"
            }
            return $fullRoot
        }
    }

    It 'keeps schema collector wrapper validator and certification repo-owned' {
        $root = Get-NxbPlatformBindingTestRoot
        foreach ($relative in @(
            'schemas\platform-binding-snapshot.schema.json',
            'scripts\Get-NxbPlatformBindingSnapshot.ps1',
            'scripts\Test-NxbPlatformBindingSnapshot.ps1',
            'tools\validate_platform_binding_snapshot.py',
            'scripts\Invoke-NxbSuperblock2PlatformBindingCertification.ps1'
        )) {
            Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf | Should -BeTrue
        }
    }

    It 'hashes machine identity and never emits raw machine identifiers' {
        $root = Get-NxbPlatformBindingTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        $source | Should -Match ([regex]::Escape('machine_id_sha256'))
        $source | Should -Match ([regex]::Escape('Get-NxbPlatformSha256Text -Text $rawMachineId'))
        $source | Should -Not -Match ([regex]::Escape('machine_id = $rawMachineId'))
        $source | Should -Not -Match ([regex]::Escape('computer_name ='))
    }

    It 'binds every snapshot to boot and OS identity' {
        $root = Get-NxbPlatformBindingTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        foreach ($needle in @('LastBootUpTime','boot_utc','os_version','os_build','os_architecture')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'collects PnP inventory with hashed instance identifiers and problem counts' {
        $root = Get-NxbPlatformBindingTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        foreach ($needle in @('Win32_PnPEntity','device_id_sha256','config_manager_error_code','problem_count','pci_count')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'collects bounded signed-driver provenance without raw device IDs' {
        $root = Get-NxbPlatformBindingTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        foreach ($needle in @('Win32_PnPSignedDriver','driver_version','driver_provider','inf_name','is_signed','Select-Object -First 1024')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
        $source | Should -Not -Match ([regex]::Escape('pnp_device_id ='))
    }

    It 'collects bounded system-driver inventory' {
        $root = Get-NxbPlatformBindingTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        foreach ($needle in @('Win32_SystemDriver','start_mode','service_type','system_drivers')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'attempts PCI property enrichment without promoting BDF semantics' {
        $root = Get-NxbPlatformBindingTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        foreach ($needle in @('DEVPKEY_Device_BusNumber','DEVPKEY_Device_Address','DEVPKEY_Device_LocationInfo','DEVPKEY_Device_LocationPaths')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
        $source | Should -Match ([regex]::Escape('pcie_bdf_semantics = $false'))
    }

    It 'discovers exactly the intended eight platform event providers' {
        $root = Get-NxbPlatformBindingTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        foreach ($provider in @(
            'Microsoft-Windows-Kernel-PnP','Microsoft-Windows-UserPnp','Microsoft-Windows-WHEA-Logger',
            'Microsoft-Windows-Kernel-Power','Microsoft-Windows-Kernel-Processor-Power','Microsoft-Windows-Kernel-Boot',
            'Microsoft-Windows-CodeIntegrity','Microsoft-Windows-DeviceGuard'
        )) {
            $source | Should -Match ([regex]::Escape("'$provider'"))
        }
        ([regex]::Matches($source,[regex]::Escape("'Microsoft-Windows-"))).Count | Should -Be 8
        $source | Should -Match ([regex]::Escape('function Get-NxbPlatformEventSourceInventory'))
    }

    It 'reuses canonical active-power-policy resolution' {
        $root = Get-NxbPlatformBindingTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        $source | Should -Match ([regex]::Escape('Join-Path $PSScriptRoot ''Get-NxbActivePowerPolicy.ps1'''))
        $source | Should -Match ([regex]::Escape('scheme_guid'))
    }

    It 'keeps processor clock state volatile and outside the binding fingerprint' {
        $root = Get-NxbPlatformBindingTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        $source | Should -Match ([regex]::Escape('CurrentClockSpeed'))
        $source | Should -Match ([regex]::Escape('volatile_state = $volatileState'))
        $source | Should -Match ([regex]::Escape('volatile_state_in_binding_fingerprint = $false'))
        $source | Should -Not -Match ([regex]::Escape('volatile_state = $volatileState') + '.{0,200}' + [regex]::Escape('$fingerprintMaterial'))
    }

    It 'collects battery state as volatile evidence' {
        $root = Get-NxbPlatformBindingTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        foreach ($needle in @('Win32_Battery','estimated_charge_remaining','battery_status','volatile.battery')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'collects thermal zones with hashed zone identity and no representativeness claim' {
        $root = Get-NxbPlatformBindingTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        foreach ($needle in @('MSAcpi_ThermalZoneTemperature','zone_id_sha256','current_temperature_celsius','representative_temperature_claimed = $false','thermal_representativeness = $false')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'collects BIOS and baseboard metadata without serial numbers' {
        $root = Get-NxbPlatformBindingTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        $source | Should -Match ([regex]::Escape('Win32_BIOS'))
        $source | Should -Match ([regex]::Escape('Win32_BaseBoard'))
        $source | Should -Not -Match ([regex]::Escape('SerialNumber'))
        $source | Should -Match ([regex]::Escape('serial_number_exposed = $false'))
    }

    It 'models Secure Boot as available or explicitly unavailable instead of missing false' {
        $root = Get-NxbPlatformBindingTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        foreach ($needle in @('UEFISecureBootEnabled','Confirm-SecureBootUEFI','secure_boot_interface_unavailable','secure_boot_query_failed')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'collects TPM state through the Microsoft TPM CIM namespace with explicit unavailable state' {
        $root = Get-NxbPlatformBindingTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        foreach ($needle in @('root\cimv2\Security\MicrosoftTpm','Win32_Tpm','no_tpm_instance','tpm_query_failed')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'keeps Device Guard numeric status arrays as observed metadata' {
        $root = Get-NxbPlatformBindingTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        foreach ($needle in @('Win32_DeviceGuard','VirtualizationBasedSecurityStatus','SecurityServicesConfigured','SecurityServicesRunning','CodeIntegrityPolicyEnforcementStatus')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
        $source | Should -Match ([regex]::Escape('firmware_causality = $false'))
    }

    It 'collects hypervisor and SLAT capability without semantic promotion' {
        $root = Get-NxbPlatformBindingTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        foreach ($needle in @('HypervisorPresent','VirtualizationFirmwareEnabled','SecondLevelAddressTranslationExtensions','VMMonitorModeExtensions')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'hashes raw BCD output and emits only selected boot-state keys' {
        $root = Get-NxbPlatformBindingTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        foreach ($needle in @('bcdedit.exe','output_sha256','debug','testsigning','nointegritychecks','hypervisorlaunchtype')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
        $source | Should -Not -Match ([regex]::Escape('raw_bcd_output'))
    }

    It 'independently recomputes the stable binding fingerprint and rejects raw identifier leakage' {
        $root = Get-NxbPlatformBindingTestRoot
        $validator = Get-Content -LiteralPath (Join-Path $root 'tools\validate_platform_binding_snapshot.py') -Raw
        foreach ($needle in @('fingerprint_material','canonical_json','recomputed == fingerprint','validate_no_raw_identifiers','RAW_PNP_RE','forbidden raw identifier')) {
            $validator | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'requires two native snapshots with the same stable fingerprint and bounded review ZIP' {
        $root = Get-NxbPlatformBindingTestRoot
        $cert = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock2PlatformBindingCertification.ps1') -Raw
        foreach ($needle in @(
            'platform-binding-snapshot-a.json','platform-binding-snapshot-b.json',
            'binding fingerprint changed between snapshots','machine identity changed between snapshots',
            'boot identity changed between snapshots','Forbidden platform-binding review artifact'
        )) {
            $cert | Should -Match ([regex]::Escape($needle))
        }
        $cert | Should -Match ([regex]::Escape('continuous_trace_completeness = ''not_claimed'''))
    }
}
