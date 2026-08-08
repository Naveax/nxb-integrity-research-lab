BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:CollectorPath = Join-Path `
        $script:RepositoryRoot `
        'scripts\Invoke-NxbGpuProviderInventory.ps1'
    $script:Source = Get-Content -LiteralPath $script:CollectorPath -Raw
}

Describe 'NXB GPU provider inventory contract' {
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

    It 'requires Windows PowerShell 7 and an exact clean head' {
        $script:Source | Should -Match "Windows_NT"
        $script:Source | Should -Match "PowerShell 7"
        $script:Source | Should -Match 'rev-parse HEAD'
        $script:Source | Should -Match 'status --porcelain=v1 --untracked-files=all'
    }

    It 'discovers ETW providers instead of hard-coding a DXGKRNL provider identity' {
        $script:Source | Should -Match 'logman\.exe'
        $script:Source | Should -Match 'query providers'
        $script:Source | Should -Match 'providerLinePattern'
        $script:Source | Should -Not -Match '\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}'
    }

    It 'limits provider and event-channel candidates to graphics-related names' {
        $script:Source | Should -Match '\(dxg\|directx\|graphics\|dwm\|present\|gpu\)'
        $script:Source | Should -Match 'wevtutil\.exe'
        $script:Source | Should -Match 'candidate_count'
    }

    It 'collects display adapter and driver metadata without event payload capture' {
        $script:Source | Should -Match 'Win32_VideoController'
        $script:Source | Should -Match 'driver_version'
        $script:Source | Should -Match 'pnp_device_id'
        $script:Source | Should -Not -Match 'StartTrace'
        $script:Source | Should -Not -Match 'wpr\.Source -start'
    }

    It 'inventories WPT tooling without requiring every optional binary' {
        $script:Source | Should -Match "wpr\.exe"
        $script:Source | Should -Match "wpa\.exe"
        $script:Source | Should -Match "xperf\.exe"
        $script:Source | Should -Match "GPUView\.exe"
        $script:Source | Should -Match "status = 'unavailable'"
    }

    It 'keeps GPU semantic claims disabled during discovery' {
        $script:Source | Should -Match 'provider_semantics_validated = \$false'
        $script:Source | Should -Match 'keyword_masks_validated = \$false'
        $script:Source | Should -Match 'present_semantics = \$false'
        $script:Source | Should -Match 'queue_wait_semantics = \$false'
        $script:Source | Should -Match "trace_completeness = 'not_claimed'"
    }

    It 'refuses to overwrite an existing inventory output' {
        $script:Source | Should -Match 'OutputPath already exists'
        $script:Source | Should -Match 'WriteAllText'
    }
}
