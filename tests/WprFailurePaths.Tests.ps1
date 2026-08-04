BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsRoot = Join-Path $script:RepositoryRoot 'scripts'
}

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
        [switch]$CreateEtl
    )

    $etlCommand = if ($CreateEtl) {
        '> "%~2" echo synthetic-etl'
    }
    else {
        'rem synthetic stop intentionally creates no ETL'
    }

    $content = @"
@echo off
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

    It 'completes a synthetic start and stop lifecycle deterministically' {
        $fakeWpr = New-NxbFakeWprCommand `
            -Path (Join-Path $script:TempRoot 'success.cmd') `
            -CreateEtl `
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

        $manifest.status | Should -Be 'stopped'
        $session.status | Should -Be 'stopped'
        $metadata.length | Should -BeGreaterThan 0
        $metadata.sha256 | Should -Match '^[0-9A-F]{64}$'
    }
}
