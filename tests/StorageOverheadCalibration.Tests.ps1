BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:CalibrationPath = Join-Path `
        $script:RepositoryRoot `
        'scripts\Invoke-NxbStorageOverheadCalibration.ps1'
    $script:Source = Get-Content -LiteralPath $script:CalibrationPath -Raw
}

Describe 'NXB storage overhead calibration contract' {
    It 'parses without PowerShell syntax errors' {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $script:CalibrationPath,
            [ref]$tokens,
            [ref]$errors
        )
        @($errors).Count | Should -Be 0
    }

    It 'requires elevated exact clean Windows PowerShell 7 execution' {
        $script:Source | Should -Match "PowerShell 7"
        $script:Source | Should -Match 'Administrator'
        $script:Source | Should -Match 'rev-parse HEAD'
        $script:Source | Should -Match 'status --porcelain=v1 --untracked-files=all'
    }

    It 'uses bounded owned storage workload inputs' {
        $script:Source | Should -Match 'Invoke-NxbStorageHeaderProbeWorkload\.ps1'
        $script:Source | Should -Match '\[ValidateRange\(1, 16\)\]'
        $script:Source | Should -Match '\[ValidateRange\(64, 1024\)\]'
        $script:Source | Should -Match '15 second timeout'
    }

    It 'uses warmup plus alternating paired control and instrumented trials' {
        $script:Source | Should -Match 'WarmupPairs'
        $script:Source | Should -Match 'PairCount'
        $script:Source | Should -Match "@\('control','instrumented'\)"
        $script:Source | Should -Match "@\('instrumented','control'\)"
        $script:Source | Should -Match 'alternating_order = \$true'
    }

    It 'does not auto-cancel a pre-existing WPR session' {
        $script:Source | Should -Match 'pre-existing WPR session is never auto-cancelled'
        $script:Source | Should -Match 'if \(\$script:wprStarted\)'
        $script:Source | Should -Not -Match 'CancelExistingSession'
    }

    It 'requires native ETL loss and circular-risk accounting on instrumented trials' {
        $script:Source | Should -Match 'Invoke-NxbStorageEtlHeaderAccounting\.ps1'
        $script:Source | Should -Match "trace_loss\.state -cne 'none'"
        $script:Source | Should -Match 'events_lost -ne 0'
        $script:Source | Should -Match 'buffers_lost -ne 0'
        $script:Source | Should -Match "circular\.risk_classification -cne 'no_risk_observed'"
    }

    It 'measures overhead without declaring a production threshold' {
        $script:Source | Should -Match 'fixture_duration_overhead_percent'
        $script:Source | Should -Match "production_threshold_policy = 'not_declared'"
        $script:Source | Should -Match 'production_overhead_threshold_declared = \$false'
        $script:Source | Should -Match 'representative_benchmark = \$false'
    }

    It 'keeps unresolved storage semantics and completeness claims disabled' {
        $script:Source | Should -Match 'queue_depth_semantics = \$false'
        $script:Source | Should -Match 'queue_latency_semantics = \$false'
        $script:Source | Should -Match 'service_time_semantics = \$false'
        $script:Source | Should -Match "trace_completeness = 'not_claimed'"
        $script:Source | Should -Match 'representative_throughput = \$false'
        $script:Source | Should -Match 'representative_iops = \$false'
    }
}
