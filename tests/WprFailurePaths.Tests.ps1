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
    It 'treats an already-idle WPR cancellation as idempotent cleanup' {
        $argumentLog = Join-Path $script:TempRoot 'idle-cancel-arguments.txt'
        $fakeWpr = New-NxbFakeWprCommand `
            -Path (Join-Path $script:TempRoot 'idle-cancel.cmd') `
            -CancelExitCode -984076288 `
            -ArgumentLogPath $argumentLog `
            -Confirm:$false

        & (Join-Path $script:ScriptsRoot 'Start-PerformanceTrace.ps1') `
            -ExperimentPath $script:ExperimentPath `
            -WprExecutablePath $fakeWpr `
            -CancelExistingSession

        $manifest = Get-Content -LiteralPath (Join-Path $script:ExperimentPath 'manifest.json') -Raw |
            ConvertFrom-Json
        $session = Get-Content -LiteralPath (Join-Path $script:ExperimentPath 'trace-session.json') -Raw |
            ConvertFrom-Json
        $arguments = Get-Content -LiteralPath $argumentLog -Raw

        $manifest.status | Should -Be 'recording'
        $session.status | Should -Be 'recording'
        $arguments | Should -Match '(?m)^-cancel\r?$'
        $arguments | Should -Match '(?m)^-start '
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
        $session.profile_provenance_sha256 | Should -Match '^[0-9a-f]{64}$'
        $session.profile_integrity.status | Should -Be 'valid'
        $session.profile_integrity.expected_provenance_sha256 |
            Should -Be $session.profile_provenance_sha256
        $session.profile_integrity.actual_provenance_sha256 |
            Should -Be $session.profile_provenance_sha256
        $session.profile_integrity.current_profile_sha256 |
            Should -Be $session.profile_provenance.sha256
        $session.profile_integrity.current_profile_length |
            Should -Be $session.profile_provenance.length

        $metadata.length | Should -BeGreaterThan 0
        $metadata.sha256 | Should -Match '^[0-9A-F]{64}$'
        $metadata.profile | Should -Be $session.profile
        $metadata.profile_provenance_sha256 | Should -Be $session.profile_provenance_sha256
        $metadata.profile_provenance.sha256 | Should -Be $session.profile_provenance.sha256
        $metadata.profile_integrity.status | Should -Be 'valid'
        $arguments | Should -Match '(?m)^-start '
        $arguments | Should -Match 'Nxb\.MinimalCpuScheduler\.wprp!NxbMinimalCpuScheduler\.Verbose'
        $arguments | Should -Match '(?m)-filemode\r?$'
    }

    It 'tears down and fails closed when sealed profile provenance is modified' {
        $fakeWpr = New-NxbFakeWprCommand `
            -Path (Join-Path $script:TempRoot 'provenance-tamper.cmd') `
            -CreateEtl `
            -Confirm:$false

        & (Join-Path $script:ScriptsRoot 'Start-PerformanceTrace.ps1') `
            -ExperimentPath $script:ExperimentPath `
            -WprExecutablePath $fakeWpr

        $sessionPath = Join-Path $script:ExperimentPath 'trace-session.json'
        $session = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
        $session.profile_provenance.maximum_file_size_mib = 513
        $session | ConvertTo-Json -Depth 16 |
            Set-Content -LiteralPath $sessionPath -Encoding UTF8

        {
            & (Join-Path $script:ScriptsRoot 'Stop-PerformanceTrace.ps1') `
                -ExperimentPath $script:ExperimentPath `
                -WprExecutablePath $fakeWpr
        } | Should -Throw '*profile provenance doğrulaması başarısız*'

        $manifest = Get-Content -LiteralPath (Join-Path $script:ExperimentPath 'manifest.json') -Raw |
            ConvertFrom-Json
        $failedSession = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
        $metadataPath = Join-Path $script:ExperimentPath 'traces\performance.etl.json'
        $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json

        $manifest.status | Should -Be 'failed'
        $failedSession.status | Should -Be 'failed'
        $failedSession.failure_reason | Should -Match 'profile provenance doğrulaması başarısız'
        $failedSession.profile_integrity.status | Should -Be 'invalid'
        $failedSession.profile_integrity.reason | Should -Match 'canonical SHA-256'
        $failedSession.profile_integrity.expected_provenance_sha256 |
            Should -Not -Be $failedSession.profile_integrity.actual_provenance_sha256
        Test-Path -LiteralPath (Join-Path $script:ExperimentPath 'traces\performance.etl') |
            Should -BeTrue
        Test-Path -LiteralPath $metadataPath | Should -BeTrue
        $metadata.profile_integrity.status | Should -Be 'invalid'
        $metadata.profile_provenance.maximum_file_size_mib | Should -Be 513
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
        $metadata = Get-Content -LiteralPath (Join-Path $script:ExperimentPath 'traces\performance.etl.json') -Raw |
            ConvertFrom-Json
        $arguments = Get-Content -LiteralPath $argumentLog -Raw

        $session.status | Should -Be 'stopped'
        $session.profile | Should -Be 'GeneralProfile'
        $session.profile_provenance.type | Should -Be 'builtin'
        $session.profile_provenance.bounded | Should -BeFalse
        $session.profile_provenance.file_mode | Should -Be 'Unbounded'
        $session.profile_provenance.maximum_file_size_mib | Should -BeNullOrEmpty
        $session.profile_provenance_sha256 | Should -Match '^[0-9a-f]{64}$'
        $session.profile_integrity.status | Should -Be 'valid'
        $metadata.profile | Should -Be 'GeneralProfile'
        $metadata.profile_provenance_sha256 | Should -Be $session.profile_provenance_sha256
        $metadata.profile_integrity.status | Should -Be 'valid'
        $arguments | Should -Match '(?m)^-start GeneralProfile -filemode\r?$'
    }
}
