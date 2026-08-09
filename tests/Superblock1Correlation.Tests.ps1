BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:WrapperPath = Join-Path $script:RepositoryRoot 'scripts\Invoke-NxbSuperblock1CorrelationAnalysis.ps1'
    $script:ToolPath = Join-Path $script:RepositoryRoot 'tools\analyze_superblock1_correlations.py'
    $script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("nxb-superblock-correlation-test-$([guid]::NewGuid().ToString('N'))")
    [IO.Directory]::CreateDirectory($script:TempRoot) | Out-Null
    $script:InputPath = Join-Path $script:TempRoot 'normalized-events.jsonl'
    $script:RecordsPath = Join-Path $script:TempRoot 'correlations.jsonl'
    $script:SummaryPath = Join-Path $script:TempRoot 'summary.json'
    $script:SourceHead = ('a' * 40)
    $script:NormalizerHead = ('b' * 40)
    $script:ExperimentId = 'synthetic-superblock-correlation'

    $rows = @(
        [ordered]@{ sequence_index=0; source_event_name='P-Start'; domain='kernel_lifecycle'; event_family='process'; process_id=42; thread_id=$null; timestamp_raw='1'; fields=[ordered]@{} },
        [ordered]@{ sequence_index=1; source_event_name='T-Start'; domain='kernel_lifecycle'; event_family='thread'; process_id=42; thread_id=7; timestamp_raw='2'; fields=[ordered]@{} },
        [ordered]@{ sequence_index=2; source_event_name='I-Start'; domain='kernel_lifecycle'; event_family='image'; process_id=42; thread_id=7; timestamp_raw='3'; fields=[ordered]@{'File Name'='C:\private\demo.dll'} },
        [ordered]@{ sequence_index=3; source_event_name='Microsoft-Windows-DXGI/Present/win:Start'; domain='gpu'; event_family='dxgi_present'; process_id=42; thread_id=7; timestamp_raw='4'; fields=[ordered]@{'pIDXGISwapChain'='0x123'} },
        [ordered]@{ sequence_index=4; source_event_name='TcpConnect'; domain='network'; event_family='tcp'; process_id=42; thread_id=7; timestamp_raw='5'; fields=[ordered]@{'Remote IPv4 Addr'='10.1.2.3';'Remote IPv4 Port'='443';'Local IPv4 Addr'='127.0.0.1';'Local IPv4 Port'='5000'} },
        [ordered]@{ sequence_index=5; source_event_name='Microsoft-Windows-DNS-Client//win:Info'; domain='network'; event_family='dns'; process_id=42; thread_id=7; timestamp_raw='6'; fields=[ordered]@{'QueryName'='secret.example'} },
        [ordered]@{ sequence_index=6; source_event_name='TcpSend'; domain='network'; event_family='tcp'; process_id=42; thread_id=7; timestamp_raw='7'; fields=[ordered]@{'Remote IPv4 Addr'='10.1.2.3';'Remote IPv4 Port'='443';'Local IPv4 Addr'='127.0.0.1';'Local IPv4 Port'='5000'} },
        [ordered]@{ sequence_index=7; source_event_name='RegOpenKey'; domain='kernel_lifecycle'; event_family='registry'; process_id=42; thread_id=7; timestamp_raw='8'; fields=[ordered]@{'Key Name'='HKCU\Private\Example'} },
        [ordered]@{ sequence_index=8; source_event_name='TcpRecv'; domain='network'; event_family='tcp'; process_id=42; thread_id=7; timestamp_raw='9'; fields=[ordered]@{'Remote IPv4 Addr'='10.1.2.3';'Remote IPv4 Port'='443';'Local IPv4 Addr'='127.0.0.1';'Local IPv4 Port'='5000'} },
        [ordered]@{ sequence_index=9; source_event_name='Microsoft-Windows-DXGI/Present/win:Stop'; domain='gpu'; event_family='dxgi_present'; process_id=42; thread_id=7; timestamp_raw='10'; fields=[ordered]@{'pIDXGISwapChain'='0x123'} },
        [ordered]@{ sequence_index=10; source_event_name='TcpDisconnect'; domain='network'; event_family='tcp'; process_id=42; thread_id=7; timestamp_raw='11'; fields=[ordered]@{'Remote IPv4 Addr'='10.1.2.3';'Remote IPv4 Port'='443';'Local IPv4 Addr'='127.0.0.1';'Local IPv4 Port'='5000'} },
        [ordered]@{ sequence_index=11; source_event_name='I-End'; domain='kernel_lifecycle'; event_family='image'; process_id=42; thread_id=7; timestamp_raw='12'; fields=[ordered]@{'File Name'='C:\private\demo.dll'} },
        [ordered]@{ sequence_index=12; source_event_name='T-End'; domain='kernel_lifecycle'; event_family='thread'; process_id=42; thread_id=7; timestamp_raw='13'; fields=[ordered]@{} },
        [ordered]@{ sequence_index=13; source_event_name='P-End'; domain='kernel_lifecycle'; event_family='process'; process_id=42; thread_id=$null; timestamp_raw='14'; fields=[ordered]@{} }
    )
    $jsonLines = @($rows | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress })
    [IO.File]::WriteAllLines($script:InputPath,$jsonLines,[Text.UTF8Encoding]::new($false))

    $script:Result = & $script:WrapperPath `
        -InputPath $script:InputPath `
        -RecordsOutputPath $script:RecordsPath `
        -SummaryOutputPath $script:SummaryPath `
        -SourceHead $script:SourceHead `
        -NormalizerHead $script:NormalizerHead `
        -ExperimentId $script:ExperimentId `
        -TargetProcessId 42 `
        -PassThru
    $script:Summary = Get-Content -LiteralPath $script:SummaryPath -Raw | ConvertFrom-Json
    $script:SummaryRaw = Get-Content -LiteralPath $script:SummaryPath -Raw
    $script:RecordsRaw = Get-Content -LiteralPath $script:RecordsPath -Raw
}

AfterAll {
    if (Test-Path -LiteralPath $script:TempRoot) {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force
    }
}

Describe 'NXB SUPERBLOCK 1 structural correlation' {
    It 'parses the wrapper and has the Python analyzer' {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($script:WrapperPath,[ref]$tokens,[ref]$errors)
        @($errors).Count | Should -Be 0
        Test-Path -LiteralPath $script:ToolPath -PathType Leaf | Should -BeTrue
    }

    It 'consumes every synthetic normalized row in sequence order' {
        $script:Result.status | Should -BeExactly 'passed'
        $script:Summary.source.normalized_event_rows | Should -Be 14
        $script:Summary.target_pid.row_count | Should -Be 14
    }

    It 'pairs DXGI Present structurally without promoting present semantics' {
        $script:Summary.pairing.dxgi_present.pair_count | Should -Be 1
        $script:Summary.pairing.dxgi_present.unmatched_starts | Should -Be 0
        $script:Summary.pairing.dxgi_present.unmatched_stops | Should -Be 0
        $script:Summary.claims.present_pairing_semantics | Should -BeFalse
        $script:Summary.claims.present_success_semantics | Should -BeFalse
    }

    It 'pairs process thread and image lifecycle rows structurally' {
        $script:Summary.pairing.process_lifecycle.pair_count | Should -Be 1
        $script:Summary.pairing.thread_lifecycle.pair_count | Should -Be 1
        $script:Summary.pairing.image_lifecycle.pair_count | Should -Be 1
        $script:Summary.claims.kernel_lifecycle_semantics | Should -BeFalse
    }

    It 'groups the TCP observations with hashed identifiers only' {
        $script:Summary.network.tcp.row_count | Should -Be 4
        $script:Summary.network.tcp.structural_key_count | Should -Be 1
        $script:Summary.network.tcp.keys_with_connect_and_disconnect | Should -Be 1
        $script:Summary.network.tcp.keys_with_connect_before_disconnect | Should -Be 1
        $script:Summary.network.tcp.keys_with_send_and_recv | Should -Be 1
        $script:Summary.claims.network_connection_semantics | Should -BeFalse
    }

    It 'groups DNS and registry activity without exposing payloads in review summary' {
        $script:Summary.network.dns.row_count | Should -Be 1
        $script:Summary.kernel.registry.row_count | Should -Be 1
        $script:SummaryRaw | Should -Not -Match 'secret\.example'
        $script:SummaryRaw | Should -Not -Match 'HKCU\\Private'
        $script:SummaryRaw | Should -Not -Match '10\.1\.2\.3'
    }

    It 'detects exact three-domain target PID attribution' {
        $script:Summary.cross_domain.three_domain_pid_count | Should -Be 1
        $script:Summary.target_pid.domain_counts.gpu | Should -Be 2
        $script:Summary.target_pid.domain_counts.network | Should -Be 5
        $script:Summary.target_pid.domain_counts.kernel_lifecycle | Should -Be 7
        $script:Summary.target_pid.anchors_with_same_pid_kernel_neighbor | Should -BeGreaterThan 0
    }

    It 'keeps sequence delta explicitly unitless' {
        $script:Summary.pairing.dxgi_present.sequence_delta.unit | Should -BeExactly 'event_sequence_index'
        $script:Summary.pairing.dxgi_present.sequence_delta.time_unit_resolved | Should -BeFalse
        $script:Summary.claims.timestamp_unit_resolved | Should -BeFalse
        $script:Summary.claims.sequence_delta_is_time | Should -BeFalse
    }

    It 'keeps pair identifiers local and review policy bounded' {
        $script:Summary.review_policy.pair_key_hashes_reviewable | Should -BeFalse
        $script:Summary.review_policy.raw_identifier_values_reviewable | Should -BeFalse
        $script:RecordsRaw | Should -Not -Match 'C:\\private\\demo\.dll'
        $script:RecordsRaw | Should -Not -Match '10\.1\.2\.3'
    }

    It 'is byte-deterministic for the same normalized event stream' {
        $recordsReplay = Join-Path $script:TempRoot 'correlations-replay.jsonl'
        $summaryReplay = Join-Path $script:TempRoot 'summary-replay.json'
        $replay = & $script:WrapperPath -InputPath $script:InputPath -RecordsOutputPath $recordsReplay -SummaryOutputPath $summaryReplay -SourceHead $script:SourceHead -NormalizerHead $script:NormalizerHead -ExperimentId $script:ExperimentId -TargetProcessId 42 -PassThru
        $replay.records_output_sha256 | Should -BeExactly $script:Result.records_output_sha256
        $replay.summary_output_sha256 | Should -BeExactly $script:Result.summary_output_sha256
    }
}
