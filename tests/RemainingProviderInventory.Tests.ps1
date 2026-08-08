BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:CollectorPath = Join-Path `
        $script:RepositoryRoot `
        'scripts\Invoke-NxbRemainingProviderInventory.ps1'
    $script:Source = Get-Content -LiteralPath $script:CollectorPath -Raw
}

Describe 'NXB remaining provider inventory contract' {
    It 'parses without PowerShell syntax errors' {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $script:CollectorPath,
            [ref]$tokens,
            [ref]$errors
        )
        @($errors).Count | Should -Be 0
    }

    It 'requires exact clean Windows PowerShell 7 execution' {
        $script:Source | Should -Match 'PowerShell 7'
        $script:Source | Should -Match 'rev-parse HEAD'
        $script:Source |
            Should -Match 'status --porcelain=v1 --untracked-files=all'
    }

    It 'keeps provider and channel inventories bounded' {
        $script:Source | Should -Match '\[ValidateRange\(16, 1024\)\]'
        $script:Source | Should -Match 'RecordLimit = 256'
        $script:Source | Should -Match 'Select-Object -First \$Limit'
        $script:Source | Should -Match 'truncated = '
    }

    It 'discovers network NDIS and connection provider candidates' {
        $script:Source | Should -Match 'ndis\|tcpip\|winsock\|dns'
        $script:Source | Should -Match 'network_connection_semantics = \$false'
        $script:Source | Should -Match 'network_latency_semantics = \$false'
    }

    It 'discovers kernel lifecycle and device driver candidates' {
        $script:Source | Should -Match 'kernel\|process\|thread\|image'
        $script:Source | Should -Match 'pnp\|pci\|device\|driver'
        $script:Source | Should -Match 'kernel_lifecycle_semantics = \$false'
        $script:Source | Should -Match 'device_lifecycle_semantics = \$false'
    }

    It 'discovers power and thermal candidates without representativeness claims' {
        $script:Source | Should -Match 'power\|thermal\|energy\|battery\|acpi'
        $script:Source | Should -Match 'power_thermal_representative = \$false'
    }

    It 'binds to the existing capability collector domains instead of duplicating them' {
        $script:Source | Should -Match 'schemas/system-capabilities\.schema\.json'
        $script:Source | Should -Match 'scripts/Get-SystemCapabilities\.ps1'
        foreach ($domain in @(
            'gpu',
            'network',
            'bus_and_devices',
            'firmware',
            'security',
            'power'
        )) {
            $script:Source | Should -Match ("'" + $domain + "'")
        }
    }

    It 'keeps identity discovery separate from provider/event semantics' {
        $script:Source | Should -Match 'provider_identity_only = \$true'
        $script:Source | Should -Match 'keyword_semantics_validated = \$false'
        $script:Source | Should -Match 'event_ids_validated = \$false'
        $script:Source | Should -Match "trace_completeness = 'not_claimed'"
    }
}
