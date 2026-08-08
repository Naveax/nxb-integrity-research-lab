BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ReplayRunner = Join-Path `
        $script:RepositoryRoot `
        'scripts\Invoke-NxbStorageDownstreamReplayValidation.ps1'
    $script:Source = Get-Content -LiteralPath $script:ReplayRunner -Raw
}

Describe 'NXB storage downstream replay validation contract' {
    It 'parses without PowerShell syntax errors' {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $script:ReplayRunner,
            [ref]$tokens,
            [ref]$errors
        )
        @($errors).Count | Should -Be 0
    }

    It 'requires exact clean repository HEAD binding' {
        $script:Source | Should -Match 'rev-parse HEAD'
        $script:Source | Should -Match 'Exact-head mismatch'
        $script:Source | Should -Match 'status --porcelain=v1 --untracked-files=all'
    }

    It 'replays through the validated real-summary runner instead of a second implementation' {
        $script:Source | Should -Match 'Invoke-NxbStorageRealSummaryValidation\.ps1'
        $script:Source | Should -Not -Match 'summarize_storage_event_export\.py'
    }

    It 'requires byte-identical SHA-256 output rather than semantic equivalence' {
        $script:Source | Should -Match 'sourceSummarySha -ceq \$replaySummarySha'
        $script:Source | Should -Match 'Storage downstream replay is not byte-identical'
        $script:Source | Should -Match 'byte_identical_summary = \$byteIdentical'
    }

    It 'rechecks preserved provenance identity fields' {
        foreach ($name in @(
            'summary_id',
            'experiment_id',
            'machine_id',
            'boot_id',
            'trace_sha256',
            'profile_sha256',
            'event_export_sha256',
            'adapter_sha256'
        )) {
            $script:Source | Should -Match ([regex]::Escape("'$name'"))
        }
    }

    It 'keeps timing queue representativeness and trace-completeness claims disabled' {
        $script:Source | Should -Match 'measured_metric_count -ne 0'
        $script:Source | Should -Match "split_io\.status -cne 'not_assessed'"
        $script:Source | Should -Match 'queue_depth_semantics'
        $script:Source | Should -Match 'queue_latency_semantics'
        $script:Source | Should -Match 'service_time_semantics'
        $script:Source | Should -Match 'throughput_representativeness'
        $script:Source | Should -Match 'iops_representativeness'
        $script:Source | Should -Match "trace_completeness -cne 'not_claimed'"
    }
}
