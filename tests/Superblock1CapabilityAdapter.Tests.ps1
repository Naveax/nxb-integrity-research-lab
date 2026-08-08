BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:AdapterPath = Join-Path $script:RepositoryRoot 'scripts\ConvertTo-NxbSuperblock1CapabilityAdapter.ps1'
    $script:Source = Get-Content -LiteralPath $script:AdapterPath -Raw
}

Describe 'NXB SUPERBLOCK 1 capability adapter contract' {
    It 'parses without PowerShell syntax errors' {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $script:AdapterPath,
            [ref]$tokens,
            [ref]$errors
        )
        @($errors).Count | Should -Be 0
    }

    It 'requires the five remaining capability domains' {
        foreach ($domain in @('network','bus_and_devices','firmware','security','power')) {
            $script:Source | Should -Match ("'" + $domain + "'")
        }
        $script:Source | Should -Match 'missing required domain'
    }

    It 'normalizes network and device counts without raw payload export' {
        $script:Source | Should -Match 'adapter_count'
        $script:Source | Should -Match 'configuration_count'
        $script:Source | Should -Match 'device_class_row_count'
        $script:Source | Should -Match 'signed_driver_count'
        $script:Source | Should -Not -Match 'mac_address ='
        $script:Source | Should -Not -Match 'serial_number ='
    }

    It 'normalizes firmware security and power presence conservatively' {
        $script:Source | Should -Match 'bios_record_present'
        $script:Source | Should -Match 'baseboard_record_present'
        $script:Source | Should -Match 'secure_boot ='
        $script:Source | Should -Match 'device_guard_record_present'
        $script:Source | Should -Match 'active_power_scheme_present'
        $script:Source | Should -Match 'battery_count'
    }

    It 'never synthesizes unavailable counts as zero' {
        $script:Source | Should -Match 'unavailable_counts_are_null = \$true'
        $script:Source | Should -Match 'missing_is_zero = \$false'
        $script:Source | Should -Match 'return \$null'
    }

    It 'does not emit raw identifiers that are unnecessary for the adapter' {
        $script:Source | Should -Match 'raw_mac_addresses_emitted = \$false'
        $script:Source | Should -Match 'raw_serial_numbers_emitted = \$false'
        $script:Source | Should -Match 'raw_power_scheme_text_emitted = \$false'
    }

    It 'keeps remaining-domain semantics explicitly unpromoted' {
        $script:Source | Should -Match 'network_connection_semantics = \$false'
        $script:Source | Should -Match 'network_latency_semantics = \$false'
        $script:Source | Should -Match 'device_lifecycle_semantics = \$false'
        $script:Source | Should -Match 'power_thermal_representative = \$false'
        $script:Source | Should -Match 'firmware_security_effect_semantics = \$false'
        $script:Source | Should -Match "trace_completeness = 'not_claimed'"
    }

    It 'returns a property-addressable domains object and refuses overwrite' {
        $script:Source | Should -Match 'domains = \[pscustomobject\]\[ordered\]@\{'
        $script:Source | Should -Match 'OutputPath already exists'
        $script:Source | Should -Match 'Get-FileHash'
        $script:Source | Should -Match 'capability_sha256'
        $script:Source | Should -Match 'WriteAllText'

        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('nxb-capability-adapter-test-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
        $capabilityPath = Join-Path $tempRoot 'system-capabilities.json'
        $outputPath = Join-Path $tempRoot 'adapter.json'

        try {
            $fixture = [pscustomobject][ordered]@{
                schema_version = 1
                captured_utc = '2026-08-09T00:00:00.0000000Z'
                machine_id = 'fixture-machine'
                domains = [pscustomobject][ordered]@{
                    network = [pscustomobject][ordered]@{
                        status = 'available'
                        data = [pscustomobject][ordered]@{
                            adapters = @([pscustomobject]@{ name = 'fixture-adapter' })
                            configurations = @()
                        }
                    }
                    bus_and_devices = [pscustomobject][ordered]@{
                        status = 'available'
                        data = [pscustomobject][ordered]@{
                            device_class_counts = @([pscustomobject]@{ class = 'fixture'; count = 1 })
                            signed_drivers = @(
                                [pscustomobject]@{ is_signed = $true },
                                [pscustomobject]@{ is_signed = $false },
                                [pscustomobject]@{ is_signed = $null }
                            )
                        }
                    }
                    firmware = [pscustomobject][ordered]@{
                        status = 'available'
                        data = [pscustomobject][ordered]@{
                            bios = [pscustomobject]@{ present = $true }
                            baseboard = [pscustomobject]@{ present = $true }
                        }
                    }
                    security = [pscustomobject][ordered]@{
                        status = 'available'
                        data = [pscustomobject][ordered]@{
                            secure_boot = $true
                            tpm = [pscustomobject]@{ present = $true }
                            device_guard = [pscustomobject]@{ present = $true }
                        }
                    }
                    power = [pscustomobject][ordered]@{
                        status = 'available'
                        data = [pscustomobject][ordered]@{
                            active_power_scheme = 'fixture-scheme'
                            batteries = @()
                        }
                    }
                }
                collection_errors = @()
            }

            [IO.File]::WriteAllText(
                $capabilityPath,
                (($fixture | ConvertTo-Json -Depth 12) + [Environment]::NewLine),
                [Text.UTF8Encoding]::new($false)
            )

            $result = & $script:AdapterPath -CapabilityPath $capabilityPath -OutputPath $outputPath -PassThru
            [string]$result.status | Should -Be 'passed'
            ($null -eq $result.domains.PSObject.Properties['network']) | Should -Be $false
            ($null -eq $result.domains.PSObject.Properties['device_driver']) | Should -Be $false
            [int]$result.domains.network.adapter_count | Should -Be 1
            [int]$result.domains.device_driver.signed_driver_count | Should -Be 3

            $serialized = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
            ($null -eq $serialized.domains.PSObject.Properties['network']) | Should -Be $false
            [int]$serialized.domains.network.adapter_count | Should -Be 1

            { & $script:AdapterPath -CapabilityPath $capabilityPath -OutputPath $outputPath -PassThru } |
                Should -Throw '*OutputPath already exists*'
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }
}
