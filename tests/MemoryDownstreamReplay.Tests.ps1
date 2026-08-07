BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ReplayPath = Join-Path `
        $script:RepositoryRoot `
        'scripts\Invoke-NxbMemoryDownstreamReplay.ps1'
    $script:AdapterPath = Join-Path `
        $script:RepositoryRoot `
        'scripts\ConvertFrom-NxbMemoryEventExport.ps1'
    $script:FixturePath = Join-Path `
        $script:RepositoryRoot `
        'tests\fixtures\memory-event-export.valid.csv'
    $script:ReplayHead = (
        git -C $script:RepositoryRoot rev-parse HEAD
    ).Trim().ToLowerInvariant()
    $script:SourceHead = 'a' * 40
    $script:Coverage = @(
        'hard_fault',
        'demand_zero_fault',
        'copy_on_write_fault',
        'transition_fault',
        'guard_page_fault',
        'virtual_allocation',
        'virtual_free',
        'mapped_section_create',
        'mapped_section_delete'
    )

    function Write-TestJson {
        param(
            [Parameter(Mandatory)]
            [string]$Path,

            [Parameter(Mandatory)]
            [object]$Value
        )

        [IO.File]::WriteAllText(
            $Path,
            ($Value | ConvertTo-Json -Depth 32),
            [Text.UTF8Encoding]::new($false)
        )
    }

    function New-TestMemoryCapture {
        param(
            [Parameter(Mandatory)]
            [string]$Root
        )

        [IO.Directory]::CreateDirectory($Root) | Out-Null
        $bridge = Join-Path $Root 'bridge'
        [IO.Directory]::CreateDirectory($bridge) | Out-Null

        $csv = Join-Path $bridge 'memory-event-export.csv'
        Copy-Item -LiteralPath $script:FixturePath -Destination $csv
        $csvHash = (
            Get-FileHash -LiteralPath $csv -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        $eventCount = @(
            Get-Content -LiteralPath $csv | Select-Object -Skip 1
        ).Count

        $bridgeManifest = [pscustomobject][ordered]@{
            schema_version = 1
            source_format = 'xperf_dumper_text'
            normalized_csv_sha256 = $csvHash
            normalized_event_count = $eventCount
            covered_event_types = $script:Coverage
        }
        Write-TestJson `
            -Path (Join-Path $bridge 'memory-xperf-bridge-manifest.json') `
            -Value $bridgeManifest

        $receipt = [pscustomobject][ordered]@{
            schema_version = 1
            status = 'passed'
            failure = $null
            head_sha = $script:SourceHead
            expected_head_sha = $script:SourceHead
            machine_id = 'fixture-machine'
            boot_id = '1' * 64
            trace_started_utc = '2026-08-06T22:00:00Z'
            trace_stopped_utc = '2026-08-06T22:00:10Z'
            evidence = [pscustomobject][ordered]@{
                etl_sha256 = '2' * 64
            }
            profile = [pscustomobject][ordered]@{
                sha256 = '3' * 64
            }
            workload = [pscustomobject][ordered]@{
                process_id = 4242
                process_start_utc = '2026-08-06T21:59:00Z'
                image_sha256 = '4' * 64
            }
            trace_quality = [pscustomobject][ordered]@{
                trace_loss = 'none'
                circular_overwrite = 'none'
            }
        }
        Write-TestJson `
            -Path (Join-Path $Root 'memory-real-capture-receipt.json') `
            -Value $receipt

        $summary = Join-Path $Root 'memory-etl-summary.json'
        & $script:AdapterPath `
            -ExperimentId ('memory-real-' + $script:SourceHead.Substring(0, 12)) `
            -InputPath $csv `
            -OutputPath $summary `
            -MachineId 'fixture-machine' `
            -BootId ('1' * 64) `
            -TraceSha256 ('2' * 64) `
            -ProfileSha256 ('3' * 64) `
            -TraceStartUtc ([datetime]'2026-08-06T22:00:00Z') `
            -TraceEndUtc ([datetime]'2026-08-06T22:00:10Z') `
            -TargetProcessId 4242 `
            -TargetProcessStartUtc ([datetime]'2026-08-06T21:59:00Z') `
            -TargetImageSha256 ('4' * 64) `
            -CoveredEventType $script:Coverage `
            -TraceLoss none `
            -CircularOverwrite none

        return [pscustomobject]@{
            root = $Root
            csv = $csv
            summary = $summary
            bridge_manifest = Join-Path `
                $bridge `
                'memory-xperf-bridge-manifest.json'
        }
    }
}

Describe 'NXB real memory downstream replay' {
    It 'replays a captured normalized export to a byte-identical summary' {
        $capture = New-TestMemoryCapture -Root (Join-Path $TestDrive 'capture-pass')
        $output = Join-Path $TestDrive 'replay-pass'

        $result = & $script:ReplayPath `
            -ExpectedReplayHead $script:ReplayHead `
            -ExpectedSourceCaptureHead $script:SourceHead `
            -SourceCaptureDirectory $capture.root `
            -OutputDirectory $output `
            -PassThru

        $result.status | Should -Be 'passed'
        $result.byte_identical_summary | Should -BeTrue
        $result.source_summary_sha256 | Should -Be $result.replay_summary_sha256
        $result.raw_etl_included | Should -BeFalse
        $result.raw_dumper_included | Should -BeFalse
        $result.normalized_csv_included | Should -BeFalse
    }

    It 'rejects a source capture head mismatch' {
        $capture = New-TestMemoryCapture -Root (Join-Path $TestDrive 'capture-head')
        $output = Join-Path $TestDrive 'replay-head'

        {
            & $script:ReplayPath `
                -ExpectedReplayHead $script:ReplayHead `
                -ExpectedSourceCaptureHead ('b' * 40) `
                -SourceCaptureDirectory $capture.root `
                -OutputDirectory $output
        } | Should -Throw '*Source capture head binding mismatch*'
    }

    It 'rejects normalized CSV tampering before replay' {
        $capture = New-TestMemoryCapture -Root (Join-Path $TestDrive 'capture-csv')
        Add-Content -LiteralPath $capture.csv -Value '#tamper' -Encoding Ascii
        $output = Join-Path $TestDrive 'replay-csv'

        {
            & $script:ReplayPath `
                -ExpectedReplayHead $script:ReplayHead `
                -ExpectedSourceCaptureHead $script:SourceHead `
                -SourceCaptureDirectory $capture.root `
                -OutputDirectory $output
        } | Should -Throw '*normalized_csv_sha256 does not match*'
    }

    It 'rejects source summary adapter provenance drift' {
        $capture = New-TestMemoryCapture -Root (Join-Path $TestDrive 'capture-adapter')
        $document = Get-Content -LiteralPath $capture.summary -Raw |
            ConvertFrom-Json
        $document.adapter_sha256 = 'f' * 64
        Write-TestJson -Path $capture.summary -Value $document
        $output = Join-Path $TestDrive 'replay-adapter'

        {
            & $script:ReplayPath `
                -ExpectedReplayHead $script:ReplayHead `
                -ExpectedSourceCaptureHead $script:SourceHead `
                -SourceCaptureDirectory $capture.root `
                -OutputDirectory $output
        } | Should -Throw
    }
}
