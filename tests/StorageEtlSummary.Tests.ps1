BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:Validator = Join-Path $script:RepositoryRoot 'scripts\Test-StorageEtlSummary.ps1'
    $script:Fixture = Join-Path $script:RepositoryRoot 'tests\fixtures\storage-etl-summary.valid.json'
}

Describe 'NXB storage ETL summary evidence contract' {
    BeforeEach {
        $script:TemporaryManifest = Join-Path `
            ([IO.Path]::GetTempPath()) `
            ("nxb-storage-summary-$([guid]::NewGuid().ToString('N')).json")
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TemporaryManifest) {
            Remove-Item -LiteralPath $script:TemporaryManifest -Force
        }
    }

    It 'accepts the canonical valid fixture' {
        { & $script:Validator -Path $script:Fixture } | Should -Not -Throw
    }

    It 'rejects experiment path identity drift' {
        $document = Get-Content -LiteralPath $script:Fixture -Raw | ConvertFrom-Json
        $document.experiment_relative_path = 'experiments/wrong-id'
        $document | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $script:TemporaryManifest -Encoding UTF8

        { & $script:Validator -Path $script:TemporaryManifest } |
            Should -Throw '*experiment_relative_path*'
    }

    It 'rejects unattributed event counts above the aggregate count' {
        $document = Get-Content -LiteralPath $script:Fixture -Raw | ConvertFrom-Json
        $document.events.disk_read.unattributed_count = 3
        $document | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $script:TemporaryManifest -Encoding UTF8

        { & $script:Validator -Path $script:TemporaryManifest } |
            Should -Throw '*unattributed_count cannot exceed count*'
    }

    It 'rejects unsupported event status without the quality list entry' {
        $document = Get-Content -LiteralPath $script:Fixture -Raw | ConvertFrom-Json
        $document.events.disk_write.status = 'unsupported'
        $document.events.disk_write.reason = 'Fixture mutation.'
        $document | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $script:TemporaryManifest -Encoding UTF8

        { & $script:Validator -Path $script:TemporaryManifest } |
            Should -Throw '*unsupported status/list mismatch*'
    }

    It 'rejects a measured-event summary count mismatch' {
        $document = Get-Content -LiteralPath $script:Fixture -Raw | ConvertFrom-Json
        $document.summary.measured_event_class_count = 2
        $document | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $script:TemporaryManifest -Encoding UTF8

        { & $script:Validator -Path $script:TemporaryManifest } |
            Should -Throw '*measured_event_class_count mismatch*'
    }

    It 'rejects premature storage queue semantics claims' {
        $document = Get-Content -LiteralPath $script:Fixture -Raw | ConvertFrom-Json
        $document.claims.queue_depth_semantics = $true
        $document | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $script:TemporaryManifest -Encoding UTF8

        { & $script:Validator -Path $script:TemporaryManifest } | Should -Throw
    }

    It 'rejects invalid metric distribution ordering' {
        $document = Get-Content -LiteralPath $script:Fixture -Raw | ConvertFrom-Json
        $source = [pscustomobject]@{
            collector = 'ConvertFrom-NxbStorageEventExport.ps1'
            kind = 'synthetic_fixture'
            provenance_sha256 = ('8' * 64)
        }
        $document.metrics.queue_depth = [pscustomobject]@{
            status = 'measured'
            statistics = [pscustomobject]@{
                samples = 3
                min = 4
                median = 3
                mean = 3.5
                max = 5
            }
            source = $source
            reason = $null
        }
        $document.summary.measured_metric_count = 1
        $document | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $script:TemporaryManifest -Encoding UTF8

        { & $script:Validator -Path $script:TemporaryManifest } |
            Should -Throw '*median is outside min/max*'
    }

    It 'rejects a trace interval with end before start' {
        $document = Get-Content -LiteralPath $script:Fixture -Raw | ConvertFrom-Json
        $document.trace_end_utc = '2026-08-08T13:59:00Z'
        $document | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $script:TemporaryManifest -Encoding UTF8

        { & $script:Validator -Path $script:TemporaryManifest } |
            Should -Throw '*trace_start_utc is after trace_end_utc*'
    }
}
