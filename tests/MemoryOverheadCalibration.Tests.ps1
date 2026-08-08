BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:MeasuredPath = Join-Path `
        $script:RepositoryRoot `
        'scripts\Invoke-NxbMeasuredMemoryWorkload.ps1'
    $script:CalibrationPath = Join-Path `
        $script:RepositoryRoot `
        'scripts\Invoke-NxbMemoryOverheadCalibration.ps1'
    $script:MeasuredText = Get-Content -LiteralPath $script:MeasuredPath -Raw
    $script:CalibrationText = Get-Content -LiteralPath $script:CalibrationPath -Raw

    function Get-MemoryCalibrationTestExperimentFixture {
        param(
            [Parameter(Mandatory)]
            [string]$Path,

            [Parameter(Mandatory)]
            [string]$Id
        )

        [IO.Directory]::CreateDirectory($Path) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $Path 'logs')) | Out-Null
        $manifest = [ordered]@{
            schema_version = 1
            experiment_id = $Id
            name = 'memory-calibration-test'
            hypothesis = 'bounded test'
            created_utc = [DateTime]::UtcNow.ToString('o')
            completed_utc = $null
            status = 'prepared'
            machine = [ordered]@{}
            target_version = $null
            notes = @()
        }
        [IO.File]::WriteAllText(
            (Join-Path $Path 'manifest.json'),
            ($manifest | ConvertTo-Json -Depth 8),
            [Text.UTF8Encoding]::new($false)
        )
    }
}

Describe 'NXB paired memory overhead calibration' {
    It 'parses the measured workload and calibration runner' {
        foreach ($path in @($script:MeasuredPath, $script:CalibrationPath)) {
            $tokens = $null
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile(
                $path,
                [ref]$tokens,
                [ref]$errors
            )
            $errors.Count | Should -Be 0
        }
    }

    It 'keeps the validated bounded memory workload defaults' {
        $script:MeasuredText | Should -Match '\[int\]\$PrivateMemoryMiB = 32'
        $script:MeasuredText | Should -Match '\[int\]\$MappedFileMiB = 8'
        $script:MeasuredText | Should -Match '\[int\]\$HoldMilliseconds = 1000'
        $script:MeasuredText | Should -Match 'Invoke-NxbMemoryProbeWorkload\.ps1'
        $script:MeasuredText | Should -Match 'page_stride_bytes -ne 4096'
    }

    It 'uses one warmup and three paired repetitions by default' {
        $script:CalibrationText | Should -Match '\[int\]\$RepetitionCount = 3'
        $script:CalibrationText | Should -Match '\[int\]\$WarmupCount = 1'
        $script:CalibrationText | Should -Match '\$Ordering = ''alternating_control_first'''
    }

    It 'binds calibration to an exact clean repository head' {
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

    It 'reuses the validated overhead evidence schema and semantic validator' {
        $script:CalibrationText | Should -Match 'collector-overhead-calibration\.json'
        $script:CalibrationText | Should -Match 'Test-CollectorOverheadCalibration\.ps1'
        $script:CalibrationText | Should -Match "status = 'not_declared'"
        $script:CalibrationText | Should -Match 'require_same_machine = \$true'
        $script:CalibrationText | Should -Match 'require_same_boot = \$true'
        $script:CalibrationText | Should -Match 'require_same_power_policy = \$true'
        $script:CalibrationText | Should -Match 'require_same_workload = \$true'
    }

    It 'keeps raw calibration ETL outside the review ZIP' {
        $script:CalibrationText | Should -Match 'Calibration ETL files remain local'
        $script:CalibrationText | Should -Not -Match 'Copy-Item[^\r\n]*memory-overhead\.etl'
    }

    It 'measures deterministic bounded memory workload checksums on Windows' -Skip:($env:OS -cne 'Windows_NT') {
        $first = Join-Path $TestDrive 'measured-first'
        $second = Join-Path $TestDrive 'measured-second'
        Get-MemoryCalibrationTestExperimentFixture -Path $first -Id 'memory-test-first'
        Get-MemoryCalibrationTestExperimentFixture -Path $second -Id 'memory-test-second'

        $firstResult = & $script:MeasuredPath `
            -ExperimentPath $first `
            -PrivateMemoryMiB 4 `
            -MappedFileMiB 1 `
            -HoldMilliseconds 200 `
            -TimeoutSeconds 10 `
            -SampleIntervalMilliseconds 20 `
            -PassThru
        $secondResult = & $script:MeasuredPath `
            -ExperimentPath $second `
            -PrivateMemoryMiB 4 `
            -MappedFileMiB 1 `
            -HoldMilliseconds 200 `
            -TimeoutSeconds 10 `
            -SampleIntervalMilliseconds 20 `
            -PassThru

        $firstResult.status | Should -Be 'measured'
        $secondResult.status | Should -Be 'measured'
        $firstResult.result.status | Should -Be 'measured'
        $secondResult.result.status | Should -Be 'measured'
        $firstResult.result.unit | Should -Be 'checksum'
        $secondResult.result.value | Should -Be $firstResult.result.value
        $firstResult.process_metrics.peak_working_set_bytes.status |
            Should -Be 'measured'
        $firstResult.process_metrics.peak_private_bytes.status |
            Should -Be 'measured'
    }
}
