BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:MeasuredPath = Join-Path `
        $script:RepositoryRoot `
        'scripts\Invoke-NxbMeasuredStorageWorkload.ps1'
    $script:CalibrationPath = Join-Path `
        $script:RepositoryRoot `
        'scripts\Invoke-NxbStorageOverheadCalibration.ps1'
    $script:WorkloadPath = Join-Path `
        $script:RepositoryRoot `
        'scripts\Invoke-NxbStorageHeaderProbeWorkload.ps1'
    $script:MeasuredText = Get-Content -LiteralPath $script:MeasuredPath -Raw
    $script:CalibrationText = Get-Content -LiteralPath $script:CalibrationPath -Raw
    $script:WorkloadText = Get-Content -LiteralPath $script:WorkloadPath -Raw
}

Describe 'NXB paired storage overhead calibration' {
    It 'parses measured and calibration runners' {
        foreach ($path in @($script:MeasuredPath, $script:CalibrationPath)) {
            $tokens = $null
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile(
                $path,
                [ref]$tokens,
                [ref]$errors
            )
            @($errors).Count | Should -Be 0
        }
    }

    It 'keeps the bounded owned storage workload defaults and receipt contract' {
        $script:MeasuredText | Should -Match '\[int\]\$FileSizeMiB = 16'
        $script:MeasuredText | Should -Match '\[int\]\$BlockSizeKiB = 256'
        $script:MeasuredText | Should -Match 'Invoke-NxbStorageHeaderProbeWorkload\.ps1'
        $script:MeasuredText | Should -Match 'bytes_written -ne \$expectedBytes'
        $script:MeasuredText | Should -Match 'bytes_read -ne \$expectedBytes'
        $script:MeasuredText | Should -Match 'flush_count -lt 1'
        $script:MeasuredText | Should -Match 'receipt\.renamed'
        $script:MeasuredText | Should -Match 'receipt\.deleted'
    }

    It 'uses one warmup and three paired repetitions by default' {
        $script:CalibrationText | Should -Match '\[int\]\$RepetitionCount = 3'
        $script:CalibrationText | Should -Match '\[int\]\$WarmupCount = 1'
        $script:CalibrationText | Should -Match '\$Ordering = ''alternating_control_first'''
        $script:CalibrationText | Should -Match '\[int\]\$FileSizeMiB = 16'
        $script:CalibrationText | Should -Match '\[int\]\$BlockSizeKiB = 256'
    }

    It 'binds calibration to an elevated exact clean repository head' {
        $script:CalibrationText | Should -Match 'requires elevated PowerShell 7'
        $script:CalibrationText | Should -Match 'Exact-head mismatch'
        $script:CalibrationText | Should -Match 'status --porcelain=v1 --untracked-files=all'
        $script:CalibrationText | Should -Match 'requires a clean exact-head worktree'
    }

    It 'does not automatically cancel a pre-existing WPR session' {
        $startIndex = $script:CalibrationText.IndexOf('-start $profileReference')
        $cancelIndex = $script:CalibrationText.IndexOf('-cancel 2>&1')
        $startIndex | Should -BeGreaterThan -1
        $cancelIndex | Should -BeGreaterThan $startIndex
        $script:CalibrationText | Should -Not -Match 'CancelExistingSession'
    }

    It 'reuses canonical overhead evidence and keeps thresholds undeclared' {
        $script:CalibrationText | Should -Match 'collector-overhead-calibration\.json'
        $script:CalibrationText | Should -Match 'Test-CollectorOverheadCalibration\.ps1'
        $script:CalibrationText | Should -Match 'require_same_machine = \$true'
        $script:CalibrationText | Should -Match 'require_same_boot = \$true'
        $script:CalibrationText | Should -Match 'require_same_power_policy = \$true'
        $script:CalibrationText | Should -Match 'require_same_workload = \$true'
        $script:CalibrationText | Should -Match "status = 'not_declared'"
    }

    It 'keeps raw calibration ETL local and out of the review ZIP' {
        $script:CalibrationText | Should -Match 'Calibration ETL files remain local'
        $script:CalibrationText | Should -Not -Match 'Copy-Item[^\r\n]*storage-overhead\.etl'
        $script:CalibrationText | Should -Match 'traces/storage-overhead\.etl'
    }

    It 'preserves conservative storage semantics and profile identity' {
        $script:CalibrationText | Should -Match 'Test-NxbStorageWprProfile\.ps1'
        $script:CalibrationText | Should -Match 'kernel_queue_enabled = \[bool\]\$storageProfile\.KernelQueueEnabled'
        $script:CalibrationText | Should -Match 'benchmark = \$false'
        $script:CalibrationText | Should -Match 'representative_throughput = \$false'
        $script:CalibrationText | Should -Match 'representative_iops = \$false'
        $script:MeasuredText | Should -Match 'receipt\.claims\.benchmark'
        $script:MeasuredText | Should -Match 'receipt\.claims\.representative_throughput'
        $script:MeasuredText | Should -Match 'receipt\.claims\.representative_iops'
        $script:WorkloadText | Should -Match 'cache_state_controlled = \$false'
    }
}
