BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsRoot = Join-Path $script:RepositoryRoot 'scripts'
    $script:SnapshotScript = Join-Path $script:ScriptsRoot 'Get-NxbWprStatusSnapshot.ps1'
    Import-Module (Join-Path $script:ScriptsRoot 'Nxb.Lab.Common.psm1') -Force
}

Describe 'NXB pre-stop WPR status snapshot' {
    BeforeEach {
        $script:TempRoot = Join-Path `
            ([IO.Path]::GetTempPath()) `
            ("nxb-wpr-status-{0}" -f [guid]::NewGuid())
        & (Join-Path $script:ScriptsRoot 'Initialize-Lab.ps1') `
            -Root $script:TempRoot `
            -Role Target | Out-Null
        $script:ExperimentPath = & (Join-Path $script:ScriptsRoot 'New-Experiment.ps1') `
            -Root $script:TempRoot `
            -Name 'WPR-Status-Test' `
            -Hypothesis 'Pre-stop WPR status is captured conservatively'

        Set-NxbExperimentState `
            -ExperimentPath $script:ExperimentPath `
            -State recording `
            -Confirm:$false | Out-Null

        $session = [ordered]@{
            started_utc = [DateTime]::UtcNow.AddSeconds(-1).ToString('o')
            profile = 'NxbMinimalCpuScheduler'
            mode = 'filemode'
            profile_provenance = [ordered]@{}
            profile_provenance_sha256 = ('1' * 64)
            status = 'recording'
            wpr_executable = 'fake'
        }
        $session | ConvertTo-Json -Depth 8 |
            Set-Content `
                -LiteralPath (Join-Path $script:ExperimentPath 'trace-session.json') `
                -Encoding UTF8

        $script:FakeWpr = Join-Path $script:TempRoot 'fake-wpr.cmd'
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force
        }
    }

    It 'sums collector Events Lost values and binds them to the raw snapshot hash' {
        @'
@echo off
if /I "%~1"=="-status" (
  echo Dropped event           : 9
  echo Collector Name          : NT Kernel Logger
  echo Events Lost             : 2
  echo Collector Name          : WPR Event Collector
  echo Events Lost             : 3
  exit /b 0
)
exit /b 7
'@ | Set-Content -LiteralPath $script:FakeWpr -Encoding ASCII

        $snapshot = & $script:SnapshotScript `
            -ExperimentPath $script:ExperimentPath `
            -WprExecutablePath $script:FakeWpr `
            -PassThru `
            -Confirm:$false

        $snapshot.status | Should -Be 'measured'
        $snapshot.exit_code | Should -Be 0
        $snapshot.events_lost.status | Should -Be 'measured'
        $snapshot.events_lost.value | Should -Be 5
        $snapshot.events_lost.source |
            Should -Match '^wpr_status_snapshot:[0-9a-f]{64};field=collector_events_lost$'
        $snapshot.buffers_lost.status | Should -Be 'unsupported'
        $snapshot.realtime_buffers_lost.status | Should -Be 'not_applicable'
    }

    It 'uses Dropped event only when collector Events Lost is absent' {
        @'
@echo off
echo Dropped event           : 7
exit /b 0
'@ | Set-Content -LiteralPath $script:FakeWpr -Encoding ASCII

        $snapshot = & $script:SnapshotScript `
            -ExperimentPath $script:ExperimentPath `
            -WprExecutablePath $script:FakeWpr `
            -PassThru `
            -Confirm:$false

        $snapshot.events_lost.value | Should -Be 7
        $snapshot.events_lost.source |
            Should -Match ';field=dropped_event$'
    }

    It 'preserves a failed native status invocation as failed evidence' {
        @'
@echo off
echo synthetic status failure 1>&2
exit /b 9
'@ | Set-Content -LiteralPath $script:FakeWpr -Encoding ASCII

        $snapshot = & $script:SnapshotScript `
            -ExperimentPath $script:ExperimentPath `
            -WprExecutablePath $script:FakeWpr `
            -PassThru `
            -Confirm:$false

        $snapshot.status | Should -Be 'failed'
        $snapshot.exit_code | Should -Be 9
        $snapshot.events_lost.status | Should -Be 'failed'
        $snapshot.raw_output_sha256 | Should -Match '^[0-9a-f]{64}$'
    }
}
