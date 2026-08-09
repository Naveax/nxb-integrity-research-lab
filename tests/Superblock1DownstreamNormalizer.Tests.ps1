BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:WrapperPath = Join-Path $script:RepositoryRoot 'scripts\ConvertFrom-NxbSuperblock1XperfDumper.ps1'
    $script:ToolPath = Join-Path $script:RepositoryRoot 'tools\convert_superblock1_xperf_dumper.py'
    $script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("nxb-superblock-normalizer-test-$([guid]::NewGuid().ToString('N'))")
    [IO.Directory]::CreateDirectory($script:TempRoot) | Out-Null
    $script:InputPath = Join-Path $script:TempRoot 'synthetic-dumper.txt'
    $script:EventsPath = Join-Path $script:TempRoot 'events.jsonl'
    $script:CoveragePath = Join-Path $script:TempRoot 'coverage.json'
    $script:SourceHead = ('a' * 40)
    $script:ExperimentId = 'synthetic-superblock-normalizer'

    @'
Microsoft-Windows-DXGI/Present/win:Start, TimeStamp, Process Name ( PID), ThreadID, CPU, pIDXGISwapChain, Flags, SyncInterval
Microsoft-Windows-DXGI/Present/win:Start, 1.0, demo.exe ( 42), 7, 1, 0x123, 0, 1
TcpSend, TimeStamp, Process Name ( PID), Transfer Size, Remote IPv4 Addr, Remote IPv4 Port, Local IPv4 Addr, Local IPv4 Port
TcpSend, 2.0, demo.exe ( 42), 64, 127.0.0.1, 5000, 127.0.0.1, 5001
P-Start, TimeStamp, Process Name ( PID), ParentPID, SessionID, UniqueKey
P-Start, 3.0, child.exe ( 99), 42, 1, abc
RegOpenKey, TimeStamp, KCB, Process Name ( PID), ThreadID, Status, ElapsedTime, Key Name
RegOpenKey, 4.0, 0x1, demo.exe ( 42), 7, 0, 123, HKLM\Software\NXB
UnknownThing, TimeStamp, Value
UnknownThing, 5.0, abc
'@ | Set-Content -LiteralPath $script:InputPath -Encoding UTF8

    $script:Result = & $script:WrapperPath `
        -InputPath $script:InputPath `
        -EventsOutputPath $script:EventsPath `
        -CoverageOutputPath $script:CoveragePath `
        -SourceHead $script:SourceHead `
        -ExperimentId $script:ExperimentId `
        -TargetProcessId 42 `
        -PassThru
    $script:Coverage = Get-Content -LiteralPath $script:CoveragePath -Raw | ConvertFrom-Json
    $script:Events = @(Get-Content -LiteralPath $script:EventsPath | ForEach-Object { $_ | ConvertFrom-Json })
}

AfterAll {
    if (Test-Path -LiteralPath $script:TempRoot) {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force
    }
}

Describe 'NXB SUPERBLOCK 1 downstream normalizer' {
    It 'parses the PowerShell wrapper and Python tool exists' {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($script:WrapperPath,[ref]$tokens,[ref]$errors)
        @($errors).Count | Should -Be 0
        Test-Path -LiteralPath $script:ToolPath -PathType Leaf | Should -BeTrue
    }

    It 'normalizes GPU network process and registry synthetic rows' {
        $script:Result.status | Should -BeExactly 'passed'
        $script:Coverage.rows.normalized_rows | Should -Be 4
        $script:Events.Count | Should -Be 4
        (@($script:Events.domain | Sort-Object -Unique) -join '|') | Should -BeExactly 'gpu|kernel_lifecycle|network'
    }

    It 'maps DXGI Present structurally without promoting present semantics' {
        $event = @($script:Events | Where-Object { $_.event_family -ceq 'dxgi_present' })[0]
        $event.source_event_name | Should -BeExactly 'Microsoft-Windows-DXGI/Present/win:Start'
        $event.claims.event_name_mapping_only | Should -BeTrue
        $event.claims.present_pairing_semantics | Should -BeFalse
    }

    It 'maps TCP rows while keeping connection and latency semantics false' {
        $script:Coverage.domain_counts.network | Should -Be 1
        $script:Coverage.family_counts.'network:tcp' | Should -Be 1
        $script:Coverage.claims.network_connection_semantics | Should -BeFalse
        $script:Coverage.claims.network_latency_semantics | Should -BeFalse
    }

    It 'incorporates process and registry kernel shapes missed by the first-pass heuristic' {
        $script:Coverage.family_counts.'kernel_lifecycle:process' | Should -Be 1
        $script:Coverage.family_counts.'kernel_lifecycle:registry' | Should -Be 1
        $script:Coverage.claims.kernel_lifecycle_semantics | Should -BeFalse
    }

    It 'records target PID attribution without making it a completeness claim' {
        $script:Coverage.rows.target_pid_rows | Should -Be 3
        $script:Coverage.claims.trace_completeness | Should -BeExactly 'not_claimed'
    }

    It 'does not normalize unknown rows' {
        $script:Coverage.rows.source_data_rows | Should -Be 5
        $script:Coverage.rows.recognized_candidate_rows | Should -Be 4
        $script:Coverage.rows.normalized_rows | Should -Be 4
    }

    It 'keeps timestamp units unresolved' {
        $script:Coverage.claims.timestamp_unit_resolved | Should -BeFalse
        foreach ($event in $script:Events) {
            $event.claims.timestamp_unit_resolved | Should -BeFalse
        }
    }

    It 'keeps event rows local-only by review policy' {
        $script:Coverage.review_policy.normalized_event_rows_reviewable | Should -BeFalse
        $script:Coverage.review_policy.raw_field_values_reviewable | Should -BeFalse
        $script:Coverage.review_policy.coverage_counts_reviewable | Should -BeTrue
    }

    It 'is deterministic for the same input and identity' {
        $events2 = Join-Path $script:TempRoot 'events-replay.jsonl'
        $coverage2 = Join-Path $script:TempRoot 'coverage-replay.json'
        $replay = & $script:WrapperPath -InputPath $script:InputPath -EventsOutputPath $events2 -CoverageOutputPath $coverage2 -SourceHead $script:SourceHead -ExperimentId $script:ExperimentId -TargetProcessId 42 -PassThru
        $replay.events_output_sha256 | Should -BeExactly $script:Result.events_output_sha256
        $replay.coverage_output_sha256 | Should -BeExactly $script:Result.coverage_output_sha256
    }
}
