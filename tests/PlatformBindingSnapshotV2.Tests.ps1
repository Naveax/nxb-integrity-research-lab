$ErrorActionPreference = 'Stop'

Describe 'SUPERBLOCK 2 platform binding V2 contract' {
    BeforeAll {
        function Get-NxbPlatformBindingV2TestRoot {
            $root = [string]$env:NXB_PLATFORM_BINDING_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_PLATFORM_BINDING_REPOSITORY_ROOT is required.' }
            $fullRoot = [IO.Path]::GetFullPath($root)
            if (-not (Test-Path -LiteralPath $fullRoot -PathType Container)) { throw "Repository root missing: $fullRoot" }
            return $fullRoot
        }
    }

    It 'keeps V1 collector V2 canonicalizer validator and V2 certification repo-owned' {
        $root = Get-NxbPlatformBindingV2TestRoot
        foreach ($relative in @(
            'scripts\Get-NxbPlatformBindingSnapshot.ps1',
            'scripts\Get-NxbPlatformBindingSnapshotV2.ps1',
            'scripts\Test-NxbPlatformBindingSnapshot.ps1',
            'tools\validate_platform_binding_snapshot.py',
            'scripts\Invoke-NxbSuperblock2PlatformBindingCertificationV2.ps1'
        )) { Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf | Should -BeTrue }
    }

    It 'preserves empty single and multi element arrays during canonicalization' {
        $root = Get-NxbPlatformBindingV2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshotV2.ps1') -Raw
        $source | Should -Match ([regex]::Escape('$items = @($Value | ForEach-Object'))
        $source | Should -Match ([regex]::Escape('Write-Output -NoEnumerate $items'))
        $source | Should -Not -Match ([regex]::Escape('return @($Value | ForEach-Object'))
    }

    It 'reuses the sanitized V1 collector instead of duplicating host discovery' {
        $root = Get-NxbPlatformBindingV2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshotV2.ps1') -Raw
        $source | Should -Match ([regex]::Escape("Join-Path `$PSScriptRoot 'Get-NxbPlatformBindingSnapshot.ps1'"))
        $source | Should -Match ([regex]::Escape('& $collectorV1 -OutputPath $tempPath -PassThru'))
    }

    It 'fingerprints only identity bindings and event sources' {
        $root = Get-NxbPlatformBindingV2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshotV2.ps1') -Raw
        foreach ($needle in @('identity = $snapshot.identity','bindings = $snapshot.bindings','event_sources = $snapshot.event_sources')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
        $source | Should -Not -Match ([regex]::Escape('volatile_state = $snapshot.volatile_state'))
    }

    It 'rewrites the binding fingerprint from V2 canonical JSON' {
        $root = Get-NxbPlatformBindingV2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshotV2.ps1') -Raw
        $source | Should -Match ([regex]::Escape('$canonicalMaterial | ConvertTo-Json -Depth 40 -Compress'))
        $source | Should -Match ([regex]::Escape('$snapshot.binding_fingerprint_sha256 = Get-NxbPlatformV2Sha256Text'))
    }

    It 'removes the transient V1 snapshot in finally' {
        $root = Get-NxbPlatformBindingV2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshotV2.ps1') -Raw
        $source | Should -Match ([regex]::Escape("'.v1.tmp'"))
        $source | Should -Match ([regex]::Escape('Remove-Item -LiteralPath $tempPath -Force'))
    }

    It 'keeps machine identity hashed in the V1 source' {
        $root = Get-NxbPlatformBindingV2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        $source | Should -Match ([regex]::Escape('machine_id_sha256'))
        $source | Should -Not -Match ([regex]::Escape('machine_id = $rawMachineId'))
    }

    It 'keeps PnP identity hashed and inventory counted' {
        $root = Get-NxbPlatformBindingV2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        foreach ($needle in @('Win32_PnPEntity','device_id_sha256','pci_count','problem_count')) { $source | Should -Match ([regex]::Escape($needle)) }
    }

    It 'keeps signed and system driver inventories bounded' {
        $root = Get-NxbPlatformBindingV2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        foreach ($needle in @('Win32_PnPSignedDriver','Win32_SystemDriver','Select-Object -First 1024')) { $source | Should -Match ([regex]::Escape($needle)) }
    }

    It 'reuses canonical active power policy resolution' {
        $root = Get-NxbPlatformBindingV2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        $source | Should -Match ([regex]::Escape('Join-Path $PSScriptRoot ''Get-NxbActivePowerPolicy.ps1'''))
    }

    It 'keeps processor clock battery and thermal state volatile' {
        $root = Get-NxbPlatformBindingV2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        foreach ($needle in @('CurrentClockSpeed','Win32_Battery','MSAcpi_ThermalZoneTemperature','volatile_state_in_binding_fingerprint = $false')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'keeps thermal representativeness false' {
        $root = Get-NxbPlatformBindingV2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        $source | Should -Match ([regex]::Escape('representative_temperature_claimed = $false'))
        $source | Should -Match ([regex]::Escape('thermal_representativeness = $false'))
    }

    It 'models Secure Boot as available or explicitly unavailable' {
        $root = Get-NxbPlatformBindingV2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        foreach ($needle in @('UEFISecureBootEnabled','Confirm-SecureBootUEFI','secure_boot_query_failed')) { $source | Should -Match ([regex]::Escape($needle)) }
    }

    It 'models TPM as observed or explicitly unavailable' {
        $root = Get-NxbPlatformBindingV2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        foreach ($needle in @('Win32_Tpm','no_tpm_instance','tpm_query_failed')) { $source | Should -Match ([regex]::Escape($needle)) }
    }

    It 'keeps Device Guard and virtualization metadata without causality promotion' {
        $root = Get-NxbPlatformBindingV2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        foreach ($needle in @('Win32_DeviceGuard','HypervisorPresent','SecondLevelAddressTranslationExtensions','firmware_causality = $false')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'hashes BCD output and emits selected state only' {
        $root = Get-NxbPlatformBindingV2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        foreach ($needle in @('bcdedit.exe','output_sha256','testsigning','nointegritychecks','hypervisorlaunchtype')) { $source | Should -Match ([regex]::Escape($needle)) }
        $source | Should -Not -Match ([regex]::Escape('raw_bcd_output'))
    }

    It 'discovers exactly eight platform event providers' {
        $root = Get-NxbPlatformBindingV2TestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformBindingSnapshot.ps1') -Raw
        ([regex]::Matches($source,[regex]::Escape("'Microsoft-Windows-"))).Count | Should -Be 8
    }

    It 'keeps the Python validator independently recomputing canonical JSON' {
        $root = Get-NxbPlatformBindingV2TestRoot
        $validator = Get-Content -LiteralPath (Join-Path $root 'tools\validate_platform_binding_snapshot.py') -Raw
        foreach ($needle in @('sort_keys=True','separators=(",", ":")','fingerprint_material','recomputed == fingerprint')) {
            $validator | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'rejects raw machine PnP and serial identifier leakage' {
        $root = Get-NxbPlatformBindingV2TestRoot
        $validator = Get-Content -LiteralPath (Join-Path $root 'tools\validate_platform_binding_snapshot.py') -Raw
        foreach ($needle in @('validate_no_raw_identifiers','RAW_PNP_RE','serial_number','raw_machine_id','raw_device_id')) {
            $validator | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'requires two V2 snapshots stable fingerprint and bounded review output' {
        $root = Get-NxbPlatformBindingV2TestRoot
        $cert = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock2PlatformBindingCertificationV2.ps1') -Raw
        foreach ($needle in @('platform-binding-snapshot-a.json','platform-binding-snapshot-b.json','binding fingerprint changed between snapshots','Forbidden platform-binding review artifact')) {
            $cert | Should -Match ([regex]::Escape($needle))
        }
        $cert | Should -Match ([regex]::Escape('continuous_trace_completeness = ''not_claimed'''))
    }
}
