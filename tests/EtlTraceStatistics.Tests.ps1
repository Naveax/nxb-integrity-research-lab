BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsRoot = Join-Path $script:RepositoryRoot 'scripts'
    $script:StatisticsScript = Join-Path `
        $script:ScriptsRoot `
        'Get-NxbEtlTraceStatistics.ps1'
}

Describe 'NXB post-stop ETL trace statistics adapter' {
    BeforeEach {
        $script:TempRoot = Join-Path `
            ([IO.Path]::GetTempPath()) `
            ("nxb-etl-stats-{0}" -f [guid]::NewGuid())
        $script:ExperimentPath = Join-Path `
            $script:TempRoot `
            'experiments\Etl-Stats-Test'
        $tracesRoot = Join-Path $script:ExperimentPath 'traces'
        New-Item -ItemType Directory -Path $tracesRoot -Force | Out-Null
        'synthetic-etl' | Set-Content `
            -LiteralPath (Join-Path $tracesRoot 'performance.etl') `
            -Encoding ASCII
        $script:FakeXperf = Join-Path $script:TempRoot 'fake-xperf.cmd'
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force
        }
    }

    It 'parses Events Lost, Buffers Lost and Buffers Written from tracestats' {
        @'
@echo off
if /I "%~1"=="-i" (
  >"%~4" echo Trace Statistics
  >>"%~4" echo Events Lost      : 3
  >>"%~4" echo Buffers Lost     : 2
  >>"%~4" echo Buffers Written  : 41
  exit /b 0
)
exit /b 7
'@ | Set-Content -LiteralPath $script:FakeXperf -Encoding ASCII

        $result = & $script:StatisticsScript `
            -ExperimentPath $script:ExperimentPath `
            -XperfExecutablePath $script:FakeXperf `
            -PassThru `
            -Confirm:$false

        $result.status | Should -Be 'measured'
        $result.events_lost.status | Should -Be 'measured'
        $result.events_lost.value | Should -Be 3
        $result.buffers_lost.value | Should -Be 2
        $result.buffers_written.value | Should -Be 41
        $result.events_lost.source |
            Should -Match '^xperf_tracestats:[0-9a-f]{64};field=events_lost$'
        $result.realtime_buffers_lost.status | Should -Be 'not_applicable'
    }

    It 'preserves and ignores empty xperf report lines while parsing counters' {
        @"
@echo off
if /I "%~1"=="-i" (
  >"%~4" echo.
  >>"%~4" echo Trace Statistics
  >>"%~4" echo.
  >>"%~4" echo Events Lost      : 6
  >>"%~4" echo Buffers Lost     : 1
  >>"%~4" echo Buffers Written  : 52
  >>"%~4" echo.
  exit /b 0
)
exit /b 7
"@ | Set-Content -LiteralPath $script:FakeXperf -Encoding ASCII

        $result = & $script:StatisticsScript `
            -ExperimentPath $script:ExperimentPath `
            -XperfExecutablePath $script:FakeXperf `
            -PassThru `
            -Confirm:$false

        $result.status | Should -Be 'measured'
        $result.events_lost.value | Should -Be 6
        $result.buffers_lost.value | Should -Be 1
        $result.buffers_written.value | Should -Be 52
        $result.statistics_sha256 | Should -Match '^[0-9a-f]{64}$'
    }

    It 'marks absent header fields unavailable without inventing zeroes' {
        @'
@echo off
>"%~4" echo Trace Statistics
>>"%~4" echo Session Name : Synthetic
exit /b 0
'@ | Set-Content -LiteralPath $script:FakeXperf -Encoding ASCII

        $result = & $script:StatisticsScript `
            -ExperimentPath $script:ExperimentPath `
            -XperfExecutablePath $script:FakeXperf `
            -PassThru `
            -Confirm:$false

        $result.status | Should -Be 'unavailable'
        $result.events_lost.status | Should -Be 'unavailable'
        $result.events_lost.value | Should -BeNullOrEmpty
        $result.buffers_lost.status | Should -Be 'unavailable'
        $result.realtime_buffers_lost.status | Should -Be 'not_applicable'
    }

    It 'preserves a nonzero xperf exit as failed evidence' {
        @'
@echo off
echo synthetic xperf failure 1>&2
exit /b 9
'@ | Set-Content -LiteralPath $script:FakeXperf -Encoding ASCII

        $result = & $script:StatisticsScript `
            -ExperimentPath $script:ExperimentPath `
            -XperfExecutablePath $script:FakeXperf `
            -PassThru `
            -Confirm:$false

        $result.status | Should -Be 'failed'
        $result.exit_code | Should -Be 9
        $result.events_lost.status | Should -Be 'failed'
        $result.realtime_buffers_lost.status | Should -Be 'not_applicable'
        $result.statistics_sha256 | Should -Match '^[0-9a-f]{64}$'
    }

    It 'marks an unavailable xperf executable as unsupported evidence' {
        $missingXperf = Join-Path $script:TempRoot 'missing-xperf.exe'

        $result = & $script:StatisticsScript `
            -ExperimentPath $script:ExperimentPath `
            -XperfExecutablePath $missingXperf `
            -PassThru `
            -Confirm:$false

        $result.status | Should -Be 'unsupported'
        $result.events_lost.status | Should -Be 'unsupported'
        $result.realtime_buffers_lost.status | Should -Be 'not_applicable'
        $result.exit_code | Should -BeNullOrEmpty
    }
}
