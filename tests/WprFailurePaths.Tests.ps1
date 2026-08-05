BeforeAll {
    $script:ScriptsRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'

    function New-NxbFakeWprCommand {
        [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
        param(
            [Parameter(Mandatory)]
            [ValidateNotNullOrEmpty()]
            [string]$Path,

            [Parameter()]
            [int]$StartExitCode = 0,

            [Parameter()]
            [int]$StopExitCode = 0,

            [Parameter()]
            [int]$CancelExitCode = 0,

            [Parameter()]
            [switch]$CreateEtl,

            [Parameter()]
            [string]$ArgumentLogPath
        )

        $etlCommand = if ($CreateEtl) {
            '> "%~2" echo synthetic-etl'
        }
        else {
            'rem synthetic stop intentionally creates no ETL'
        }
        $argumentLogCommand = if ([string]::IsNullOrWhiteSpace($ArgumentLogPath)) {
            'rem argument logging disabled'
        }
        else {
            "echo %*>>`"$ArgumentLogPath`""
        }

        $content = @"
@echo off
$argumentLogCommand
if /I "%~1"=="-start" (
  echo synthetic-start
  exit /b $StartExitCode
)
if /I "%~1"=="-stop" (
  $etlCommand
  echo synthetic-stop
  exit /b $StopExitCode
)
if /I "%~1"=="-cancel" (
  echo synthetic-cancel
  exit /b $CancelExitCode
)
exit /b 99
"@

        if ($PSCmdlet.ShouldProcess($Path, 'Write synthetic WPR command fixture')) {
            Set-Content -LiteralPath $Path -Value $content -Encoding Ascii
        }

        return $Path
    }
}

Describe 'NXB WPR failure paths' {
    BeforeEach {
        $script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("nxb-wpr-{0}" -f [guid]::NewGuid())
        & (Join-Path $script:ScriptsRoot 'Initialize-Lab.ps1') `
            -Root $script:TempRoot `
            -Role Target | Out-Null

        $script:ExperimentPath = & (Join-Path $script:ScriptsRoot 'New-Experiment.ps1') `
            -Root $script:TempRoot `
            -Name 'WPR-Failure-Path' `
            -Hypothesis 'WPR failures do not corrupt lifecycle state'
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force
        }
    }

    It 'fails visibly when the WPR executable is unavailable' {
        $missing = Join-Path $script:TempRoot 'missing-wpr.cmd'

        {
            & (Join-Path $script:ScriptsRoot 'Start-PerformanceTrace.ps1') `
                -ExperimentPath $script:ExperimentPath `
                -WprExecutablePath $missing
        } | Should -Throw '*wpr.exe bulunamadı*'

        $manifest = Get-Content -LiteralPath (Join-Path $script:ExperimentPath 'manifest.json') -Raw |
            ConvertFrom-Json
        $manifest.status | Should -Be 'prepared'
        Test-Path -LiteralPath (Join-Path $script:ExperimentPath 'trace-session.json') |
            Should -BeFalse
    }

    It 'does not start a trace when cancellation of an existing session fails' {
        $fakeWpr = New-NxbFakeWprCommand `
            -Path (Join-Path $script:TempRoot 'cancel-failure.cmd') `
            -CancelExitCode 31 `
            -Confirm:$false

        {
            & (Join-Path $script:ScriptsRoot 'Start-PerformanceTrace.ps1') `
                -ExperimentPath $script:ExperimentPath `
                -WprExecutablePath $fakeWpr `
                -CancelExistingSession
        } | Should -Throw '*iptal edilemedi*exit 31*'

        $manifest = Get-Content -LiteralPath (Join-Path $script:ExperimentPath 'manifest.json') -Raw |
            ConvertFrom-Json
        $manifest.status | Should -Be 'prepared'
        Test-Path -LiteralPath (Join-Path $script:ExperimentPath 'trace-session.json') |
            Should -BeFalse
    }

    It 'preserves prepared state when WPR start returns a failure code' {
        $fakeWpr = New-NxbFakeWprCommand `
            -Path (Join-Path $script:TempRoot 'start-failure.cmd') `
            -StartExitCode 17 `
            -Confirm:$false

        {
            & (Join-Path $script:ScriptsRoot 'Start-PerformanceTrace.ps1') `
                -ExperimentPath $script:ExperimentPath `
                -WprExecutablePath $fakeWpr
        } | Should -Throw '*WPR başlatılamadı*exit 17*'

        $manifest = Get-Content -LiteralPath (Join-Path $script:ExperimentPath 'manifest.json') -Raw |
            ConvertFrom-Json
        $manifest.status | Should -Be 'prepared'
        Test-Path -LiteralPath (Join-Path $script:ExperimentPath 'trace-session.json') |
            Should -BeFalse
    }

    It 'requires explicit opt-in for the unbounded built-in GeneralProfile' {
        $fakeWpr = New-NxbFakeWprCommand `
            -Path (Join-Path $script:TempRoot 'legacy-denied.cmd') `
            -Confirm:$false

        {
            & (Join-Path $script:ScriptsRoot 'Start-PerformanceTrace.ps1') `
                -ExperimentPath $script:ExperimentPath `
                -CaptureProfile GeneralProfile `
                -WprExecutablePath $fakeWpr
        } | Should -Throw '*GeneralProfile*unbounded*AllowUnboundedBuiltInProfile*'

        $manifest = Get-Content -LiteralPath (Join-Path $script:ExperimentPath 'manifest.json') -Raw |
            ConvertFrom-Json
        $manifest.status | Should -Be 'prepared'
        Test-Path -LiteralPath (Join-Path $script:ExperimentPath 'trace-session.json') |
            Should -BeFalse
    }

    It 'preserves recording state when WPR stop returns a failure code' {
        $fakeWpr = New-NxbFakeWprCommand `
            -Path (Join-Path $script:TempRoot 'stop-failure.cmd') `
            -StopExitCode 23 `
            -Confirm:$false

        & (Join-Path $script:ScriptsRoot 'Start-PerformanceTrace.ps1') `
            -ExperimentPath $script:ExperimentPath `
            -WprExecutablePath $fakeWpr

        {
            & (Join-Path $script:ScriptsRoot 'Stop-PerformanceTrace.ps1') `
                -ExperimentPath $script:ExperimentPath `
                -WprExecutablePath $fakeWpr
        } | Should -Throw '*WPR durdurulamadı*exit 23*'

        $manifest = Get-Content -LiteralPath (Join-Path $script:ExperimentPath 'manifest.json') -Raw |
            ConvertFrom-Json
        $session = Get-Content -LiteralPath (Join-Path $script:ExperimentPath 'trace-session.json') -Raw |
            ConvertFrom-Json

        $manifest.status | Should -Be 'recording'
        $session.status | Should -Be 'recording'
        Test-Path -LiteralPath (Join-Path $script:ExperimentPath 'traces\performance.etl.json') |
            Should -BeFalse
    }

    It 'fails closed when a successful stop code did not create an ETL file' {
        $fakeWpr = New-NxbFakeWprCommand `
            -Path (Join-Path $script:TempRoot 'missing-etl.cmd') `
            -Confirm:$false

        & (Join-Path $script:ScriptsRoot 'Start-PerformanceTrace.ps1') `
            -ExperimentPath $script:ExperimentPath `
            -WprExecutablePath $fakeWpr

        {
            & (Join-Path $script:ScriptsRoot 'Stop-PerformanceTrace.ps1') `
                -ExperimentPath $script:ExperimentPath `
                -WprExecutablePath $fakeWpr
        } | Should -Throw '*ETL oluşturulmadı*'

        $manifest = Get-Content -LiteralPath (Join-Path $script:ExperimentPath 'manifest.json') -Raw |
            ConvertFrom-Json
        $session = Get-Content -LiteralPath (Join-Path $script:ExperimentPath 'trace-session.json') -Raw |
            ConvertFrom-Json

        $manifest.status | Should -Be 'failed'
        $session.status | Should -Be 'failed'
        $manifest.failure_reason | Should -Match 'ETL oluşturulmadı'
        $session.failure_reason | Should -Match 'ETL oluşturulmadı'
    }

    It 'starts the bounded repository profile with exact provenance' {
        $argumentLog = Join-Path $script:TempRoot 'bounded-arguments.txt'
        $fakeWpr = New-NxbFakeWprCommand `
            -Path (Join-Path $script:TempRoot 'bounded-success.cmd') `
            -CreateEtl `
            -ArgumentLogPath $argumentLog `
            -Confirm:$false

        & (Join-Path $script:ScriptsRoot 'Start-PerformanceTrace.ps1') `
            -ExperimentPath $script:ExperimentPath `
            -WprExecutablePath $fakeWpr
        & (Join-Path $script:ScriptsRoot 'Stop-PerformanceTrace.ps1') `
            -ExperimentPath $script:ExperimentPath `
            -WprExecutablePath $fakeWpr

        $manifest = Get-Content -LiteralPath (Join-Path $script:ExperimentPath 'manifest.json') -Raw |
            ConvertFrom-Json
        $session = Get-Content -LiteralPath (Join-Path $script:ExperimentPath 'trace-session.json') -Raw |
            ConvertFrom-Json
        $metadata = Get-Content -LiteralPath (Join-Path $script:ExperimentPath 'traces\performance.etl.json') -Raw |
            ConvertFrom-Json
        $arguments = Get-Content -LiteralPath $argumentLog -Raw

        $manifest.status | Should -Be 'stopped'
        $session.status | Should -Be 'stopped'
        $session.profile | Should -Be 'NxbMinimalCpuScheduler'
        $session.mode | Should -Be 'filemode'
        $session.profile_provenance.type | Should -Be 'repository_wprp'
        $session.profile_provenance.relative_path |
            Should -Be 'profiles/Nxb.MinimalCpuScheduler.wprp'
        $session.profile_provenance.sha256 | Should -Match '^[0-9a-f]{64}$'
        $session.profile_provenance.length | Should -BeGreaterThan 0
        $session.profile_provenance.detail_level | Should -Be 'Verbose'
        $session.profile_provenance.logging_mode | Should -Be 'File'
        $session.profile_provenance.bounded | Should -BeTrue
        $session.profile_provenance.buffer_size_kib | Should -Be 1024
        $session.profile_provenance.buffers | Should -Be 64
        $session.profile_provenance.maximum_file_size_mib | Should -Be 512
        $session.profile_provenance.file_mode | Should -Be 'Circular'
        $session.profile_provenance.keywords.Count | Should -Be 10
        $session.profile_provenance.stacks.Count | Should -Be 9
        $metadata.length | Should -BeGreaterThan 0
        $metadata.sha256 | Should -Match '^[0-9A-F]{64}$'
        $arguments | Should -Match '(?m)^-start '
        $arguments | Should -Match 'Nxb\.MinimalCpuScheduler\.wprp!NxbMinimalCpuScheduler\.Verbose'
        $arguments | Should -Match '(?m)-filemode$'
    }

    It 'supports the legacy GeneralProfile only with explicit unbounded provenance' {
        $argumentLog = Join-Path $script:TempRoot 'legacy-arguments.txt'
        $fakeWpr = New-NxbFakeWprCommand `
            -Path (Join-Path $script:TempRoot 'legacy-success.cmd') `
            -CreateEtl `
            -ArgumentLogPath $argumentLog `
            -Confirm:$false

        & (Join-Path $script:ScriptsRoot 'Start-PerformanceTrace.ps1') `
            -ExperimentPath $script:ExperimentPath `
            -CaptureProfile GeneralProfile `
            -AllowUnboundedBuiltInProfile `
            -WprExecutablePath $fakeWpr
        & (Join-Path $script:ScriptsRoot 'Stop-PerformanceTrace.ps1') `
            -ExperimentPath $script:ExperimentPath `
            -WprExecutablePath $fakeWpr

        $session = Get-Content -LiteralPath (Join-Path $script:ExperimentPath 'trace-session.json') -Raw |
            ConvertFrom-Json
        $arguments = Get-Content -LiteralPath $argumentLog -Raw

        $session.status | Should -Be 'stopped'
        $session.profile | Should -Be 'GeneralProfile'
        $session.profile_provenance.type | Should -Be 'builtin'
        $session.profile_provenance.bounded | Should -BeFalse
        $session.profile_provenance.file_mode | Should -Be 'Unbounded'
        $session.profile_provenance.maximum_file_size_mib | Should -BeNullOrEmpty
        $arguments | Should -Match '(?m)^-start GeneralProfile -filemode$'
    }
}
