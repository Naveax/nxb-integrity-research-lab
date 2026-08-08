BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:RunnerPath = Join-Path $script:RepositoryRoot 'scripts\Invoke-NxbSuperblock1CaptureAdapterCertification.ps1'
    $script:Source = Get-Content -LiteralPath $script:RunnerPath -Raw
}

Describe 'NXB SUPERBLOCK 1 capture/adapter certification boundary' {
    It 'parses without PowerShell syntax errors' {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $script:RunnerPath,
            [ref]$tokens,
            [ref]$errors
        )
        @($errors).Count | Should -Be 0
    }

    It 'keeps certification output outside the repository' {
        $script:Source | Should -Match 'Certification output must be outside the repository worktree'
        $script:Source | Should -Match 'raw-local'
        $script:Source | Should -Match 'review'
    }

    It 'runs static metadata capability schema and adapter gates in order' {
        $script:Source | Should -Match '\[1/5\] Combined dual-runtime static gate'
        $script:Source | Should -Match '\[2/5\] Real selected network/kernel provider metadata'
        $script:Source | Should -Match '\[3/5\] Fresh full-system capability snapshot'
        $script:Source | Should -Match '\[4/5\] Device/power/firmware capability adapter'
        $script:Source | Should -Match '\[5/5\] Bounded review receipt and evidence-policy gate'
    }

    It 'requires exactly six selected provider identities' {
        $script:Source | Should -Match 'provider_count -ne 6'
        $script:Source | Should -Match 'expected_guid_observed'
        $script:Source | Should -Match 'keyword_contamination_detected'
    }

    It 'keeps raw metadata and capability evidence out of the review ZIP' {
        $script:Source | Should -Match 'raw_provider_metadata_in_review_zip = \$false'
        $script:Source | Should -Match 'raw_capability_json_in_review_zip = \$false'
        $script:Source | Should -Match 'raw_capability_adapter_in_review_zip = \$false'
        $script:Source | Should -Match 'Review ZIP contains unexpected files'
    }

    It 'records hashes for every local evidence component' {
        $script:Source | Should -Match 'selected_provider_metadata = \(Get-FileHash'
        $script:Source | Should -Match 'system_capabilities = \(Get-FileHash'
        $script:Source | Should -Match 'capability_adapter = \(Get-FileHash'
        $script:Source | Should -Match 'receipt_sha256'
        $script:Source | Should -Match 'review_zip_sha256'
    }

    It 'does not execute a real ETL capture' {
        $script:Source | Should -Match 'real_etl_capture_executed = \$false'
        $script:Source | Should -Not -Match 'wpr\.exe.*-start'
        $script:Source | Should -Not -Match 'xperf\.exe.*-start'
    }

    It 'keeps semantic and completeness claims disabled' {
        $script:Source | Should -Match 'keyword_semantics_validated = \$false'
        $script:Source | Should -Match 'event_ids_validated = \$false'
        $script:Source | Should -Match 'network_connection_semantics = \$false'
        $script:Source | Should -Match 'kernel_lifecycle_semantics = \$false'
        $script:Source | Should -Match 'firmware_security_effect_semantics = \$false'
        $script:Source | Should -Match "trace_completeness = 'not_claimed'"
    }
}
