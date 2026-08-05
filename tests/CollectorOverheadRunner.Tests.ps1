BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsRoot = Join-Path $script:RepositoryRoot 'scripts'
    $script:Runner = Join-Path `
        $script:ScriptsRoot `
        'Invoke-CollectorOverheadCalibration.ps1'

    function New-NxbFakePowerCfg {
        [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
        param(
            [Parameter(Mandatory)]
            [ValidateNotNullOrEmpty()]
            [string]$Path
        )

        $content = @'
@echo off
echo Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)
exit /b 0
'@
        if ($PSCmdlet.ShouldProcess($Path, 'Write fake powercfg command')) {
            Set-Content -LiteralPath $Path -Value $content -Encoding Ascii
        }
        return $Path
    }

    function New-NxbFakeCalibrationWpr {
        [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
        param(
            [Parameter(Mandatory)]
            [ValidateNotNullOrEmpty()]
            [string]$Path,

            [Parameter(Mandatory)]
            [ValidateNotNullOrEmpty()]
            [string]$ArgumentLogPath,

            [Parameter()]
            [int]$StopExitCode = 0
        )

        $quote = [char]34
        $lines = [Collections.Generic.List[string]]::new()
        $lines.Add('@echo off')
        $lines.Add("echo %*>>$quote$ArgumentLogPath$quote")
        $lines.Add("if /I $quote%~1$quote==$quote-start$quote (")
        $lines.Add('  echo synthetic-start')
        $lines.Add('  exit /b 0')
        $lines.Add(')')
        $lines.Add("if /I $quote%~1$quote==$quote-stop$quote (")
        if ($StopExitCode -eq 0) {
            $lines.Add("  > $quote%~2$quote echo synthetic-etl")
            $lines.Add('  echo synthetic-stop')
            $lines.Add('  exit /b 0')
        }
        else {
            $lines.Add('  echo synthetic-stop-failure')
            $lines.Add("  exit /b $StopExitCode")
        }
        $lines.Add(')')
        $lines.Add("if /I $quote%~1$quote==$quote-cancel$quote (")
        $lines.Add('  echo synthetic-cancel')
        $lines.Add('  exit /b 0')
        $lines.Add(')')
        $lines.Add('exit /b 99')

        if ($PSCmdlet.ShouldProcess($Path, 'Write fake WPR command')) {
            Set-Content -LiteralPath $Path -Value @($lines) -Encoding Ascii
        }
        return $Path
    }
}

Describe 'NXB paired collector overhead runner' {
    BeforeEach {
        $script:TempRoot = Join-Path `
            ([IO.Path]::GetTempPath()) `
            ("nxb-overhead-runner-{0}" -f [guid]::NewGuid())
        & (Join-Path $script:ScriptsRoot 'Initialize-Lab.ps1') `
            -Root $script:TempRoot `
            -Role Target | Out-Null
        $script:ParentPath = & (Join-Path $script:ScriptsRoot 'New-Experiment.ps1') `
            -Root $script:TempRoot `
            -Name 'Overhead-Calibration-Test' `
            -Hypothesis 'Paired control and capture evidence remains bound and deterministic'
        $script:ArgumentLog = Join-Path $script:TempRoot 'wpr-arguments.txt'
        $script:FakePowerCfg = New-NxbFakePowerCfg `
            -Path (Join-Path $script:TempRoot 'powercfg.cmd') `
            -Confirm:$false
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force
        }
    }

    It 'completes one deterministic paired trial with bounded WPR evidence' {
        $fakeWpr = New-NxbFakeCalibrationWpr `
            -Path (Join-Path $script:TempRoot 'wpr-success.cmd') `
            -ArgumentLogPath $script:ArgumentLog `
            -Confirm:$false

        $result = & $script:Runner `
            -ExperimentPath $script:ParentPath `
            -RepetitionCount 1 `
            -WarmupCount 0 `
            -Ordering control_then_capture `
            -Iterations 32 `
            -TimeoutSeconds 30 `
            -SampleIntervalMilliseconds 10 `
            -WprExecutablePath $fakeWpr `
            -PowerCfgExecutablePath $script:FakePowerCfg `
            -Confirm:$false `
            -PassThru

        $result.schema_version | Should -Be 1
        $result.protocol.repetition_count | Should -Be 1
        $result.protocol.ordering | Should -Be 'control_then_capture'
        $result.summary.pair_count | Should -Be 1
        $result.summary.successful_pair_count | Should -Be 1
        $result.summary.failed_pair_count | Should -Be 0
        $result.summary.threshold_policy.status | Should -Be 'not_declared'
        $result.pairs[0].first_arm | Should -Be 'control'
        $result.pairs[0].control.status | Should -Be 'measured'
        $result.pairs[0].capture.status | Should -Be 'measured'
        $result.pairs[0].capture.etl.status | Should -Be 'measured'
        $result.pairs[0].control.result.value |
            Should -Be $result.pairs[0].capture.result.value
        $result.pairs[0].control.experiment_id |
            Should -Not -Be $result.pairs[0].capture.experiment_id

        $parentManifest = Get-Content -LiteralPath (
            Join-Path $script:ParentPath 'manifest.json'
        ) -Raw | ConvertFrom-Json
        $parentManifest.status | Should -Be 'finalized'

        foreach ($armName in @('control', 'capture')) {
            $relativePath = [string]$result.pairs[0].$armName.experiment_relative_path
            $childPath = Join-Path `
                $script:TempRoot `
                $relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
            $childManifest = Get-Content -LiteralPath (
                Join-Path $childPath 'manifest.json'
            ) -Raw | ConvertFrom-Json
            $childManifest.status | Should -Be 'finalized'
        }

        $arguments = Get-Content -LiteralPath $script:ArgumentLog -Raw
        $arguments | Should -Match '(?m)^-start '
        $arguments | Should -Match '(?m)^-stop '
        $arguments | Should -Not -Match '(?m)^-cancel\r?$'

        $resultPath = Join-Path `
            $script:ParentPath `
            'analysis\collector-overhead-calibration.json'
        {
            & (Join-Path $script:ScriptsRoot 'Test-CollectorOverheadCalibration.ps1') `
                -Path $resultPath
        } | Should -Not -Throw
    }

    It 'preserves failed-pair evidence and cancels WPR after stop failure' {
        $fakeWpr = New-NxbFakeCalibrationWpr `
            -Path (Join-Path $script:TempRoot 'wpr-stop-failure.cmd') `
            -ArgumentLogPath $script:ArgumentLog `
            -StopExitCode 23 `
            -Confirm:$false

        {
            & $script:Runner `
                -ExperimentPath $script:ParentPath `
                -RepetitionCount 1 `
                -WarmupCount 0 `
                -Ordering capture_then_control `
                -Iterations 16 `
                -TimeoutSeconds 30 `
                -SampleIntervalMilliseconds 10 `
                -WprExecutablePath $fakeWpr `
                -PowerCfgExecutablePath $script:FakePowerCfg `
                -Confirm:$false
        } | Should -Throw '*1 pair başarısız*'

        $resultPath = Join-Path `
            $script:ParentPath `
            'analysis\collector-overhead-calibration.json'
        Test-Path -LiteralPath $resultPath -PathType Leaf | Should -BeTrue
        {
            & (Join-Path $script:ScriptsRoot 'Test-CollectorOverheadCalibration.ps1') `
                -Path $resultPath
        } | Should -Not -Throw

        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        $result.summary.successful_pair_count | Should -Be 0
        $result.summary.failed_pair_count | Should -Be 1
        $result.pairs[0].first_arm | Should -Be 'capture'
        $result.pairs[0].capture.status | Should -Be 'failed'
        $result.pairs[0].capture.etl.status | Should -Be 'failed'
        $result.pairs[0].deltas.duration_relative_percent.status |
            Should -Be 'failed'

        $parentManifest = Get-Content -LiteralPath (
            Join-Path $script:ParentPath 'manifest.json'
        ) -Raw | ConvertFrom-Json
        $parentManifest.status | Should -Be 'finalized'

        $captureRelative = [string]$result.pairs[0].capture.experiment_relative_path
        $capturePath = Join-Path `
            $script:TempRoot `
            $captureRelative.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $captureManifest = Get-Content -LiteralPath (
            Join-Path $capturePath 'manifest.json'
        ) -Raw | ConvertFrom-Json
        $captureManifest.status | Should -Be 'failed'

        $arguments = Get-Content -LiteralPath $script:ArgumentLog -Raw
        $arguments | Should -Match '(?m)^-stop '
        $arguments | Should -Match '(?m)^-cancel\r?$'
    }
}
