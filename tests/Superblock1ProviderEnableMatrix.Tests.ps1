BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:MatrixPath = Join-Path $script:RepositoryRoot 'scripts\Invoke-NxbSuperblock1ProviderEnableMatrix.ps1'
    $script:Source = Get-Content -LiteralPath $script:MatrixPath -Raw
}

Describe 'NXB SUPERBLOCK 1 provider enable matrix contract' {
    It 'parses the matrix source and keeps the analyzer-safe bounded profile writer' {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $script:MatrixPath,
            [ref]$tokens,
            [ref]$errors
        )
        @($errors).Count | Should -Be 0
        $script:Source | Should -Match 'function Write-NxbProviderProbeProfile'
        $script:Source | Should -Not -Match 'function New-NxbProviderProbeProfile'
        $script:Source | Should -Not -Match '\$profileOutput\s*='
    }

    It 'contains the exact eight provider identities' {
        foreach ($name in @(
            'Microsoft-Windows-DxgKrnl',
            'Microsoft-Windows-DXGI',
            'Microsoft-Windows-Kernel-Network',
            'Microsoft-Windows-Winsock-AFD',
            'Microsoft-Windows-DNS-Client',
            'Microsoft-Windows-Kernel-Process',
            'Microsoft-Windows-Kernel-Registry',
            'Microsoft-Windows-Kernel-PnP'
        )) {
            $script:Source | Should -Match ([regex]::Escape("name='$name'"))
        }
    }

    It 'uses strict single-provider probes' {
        $script:Source | Should -Match ([regex]::Escape('Strict="true"'))
        $script:Source | Should -Match ([regex]::Escape('probe_provider_strict = $true'))
    }

    It 'records the combined profile as non-strict' {
        $script:Source | Should -Match ([regex]::Escape('combined_profile_provider_strict = $false'))
    }

    It 'never auto-cancels a pre-existing WPR session' {
        $script:Source | Should -Match ([regex]::Escape('preexisting_session_auto_cancel = $false'))
        $script:Source | Should -Match ([regex]::Escape('successful_probe_sessions_cancelled_only_when_owned = $true'))
        $script:Source | Should -Match 'sessionOwned'
    }

    It 'does not place raw WPR start output in the result' {
        $script:Source | Should -Match ([regex]::Escape('raw_wpr_start_output_in_result = $false'))
        $script:Source | Should -Match 'start_output_sha256'
        $script:Source | Should -Match 'start_output_line_count'
    }

    It 'preserves the certified GPU keyword masks' {
        foreach ($mask in @(
            '0x0000000000008000',
            '0x0000000000010000',
            '0x0000000008000000',
            '0x0000000000000002'
        )) {
            $script:Source | Should -Match ([regex]::Escape($mask))
        }
    }

    It 'keeps enableability distinct from semantics and delivery' {
        foreach ($literal in @(
            'start_failure_implies_provider_absence = $false',
            'start_failure_implies_semantic_absence = $false',
            'event_delivery_validated = $false',
            'event_semantics_validated = $false',
            "trace_completeness = 'not_claimed'"
        )) {
            $script:Source | Should -Match ([regex]::Escape($literal))
        }
    }
}
