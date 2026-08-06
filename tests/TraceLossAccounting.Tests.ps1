BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:Validator = Join-Path $script:RepositoryRoot 'scripts\Test-TraceLossAccounting.ps1'
    $script:Fixture = Join-Path `
        $script:RepositoryRoot `
        'tests\fixtures\trace-loss-accounting.valid.json'
}

Describe 'NXB trace-loss and circular-overwrite accounting validation' {
    BeforeEach {
        $script:TempRoot = Join-Path `
            ([IO.Path]::GetTempPath()) `
            ("nxb-trace-loss-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        $script:DocumentPath = Join-Path $script:TempRoot 'trace-loss-accounting.json'
        Copy-Item -LiteralPath $script:Fixture -Destination $script:DocumentPath
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force
        }
    }

    It 'accepts the deterministic valid fixture' {
        { & $script:Validator -Path $script:DocumentPath } | Should -Not -Throw
    }

    It 'accepts hash-bound ETL header snapshot sources' {
        $document = Get-Content -LiteralPath $script:DocumentPath -Raw | ConvertFrom-Json
        $hash = '6' * 64
        $document.native_counters.events_lost.source =
            "etl_header_snapshot:$hash;field=events_lost"
        $document.native_counters.buffers_lost.source =
            "etl_header_snapshot:$hash;field=buffers_lost"
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $script:DocumentPath -Encoding UTF8

        { & $script:Validator -Path $script:DocumentPath } | Should -Not -Throw
    }

    It 'rejects an experiment relative-path substitution' {
        $document = Get-Content -LiteralPath $script:DocumentPath -Raw | ConvertFrom-Json
        $document.experiment_relative_path = 'experiments/Other-Experiment'
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $script:DocumentPath -Encoding UTF8

        { & $script:Validator -Path $script:DocumentPath } |
            Should -Throw '*experiment_relative_path*'
    }

    It 'rejects a measured counter source without a native-output hash' {
        $document = Get-Content -LiteralPath $script:DocumentPath -Raw | ConvertFrom-Json
        $document.native_counters.events_lost.source = 'synthetic-fixture'
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $script:DocumentPath -Encoding UTF8

        { & $script:Validator -Path $script:DocumentPath } |
            Should -Throw '*source*'
    }

    It 'rejects a counter source field assigned to the wrong counter' {
        $document = Get-Content -LiteralPath $script:DocumentPath -Raw | ConvertFrom-Json
        $document.native_counters.buffers_lost.source = `
            'xperf_tracestats:5555555555555555555555555555555555555555555555555555555555555555;field=events_lost'
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $script:DocumentPath -Encoding UTF8

        { & $script:Validator -Path $script:DocumentPath } |
            Should -Throw '*inconsistent*'
    }

    It 'requires native loss classification when a measured counter is nonzero' {
        $document = Get-Content -LiteralPath $script:DocumentPath -Raw | ConvertFrom-Json
        $document.native_counters.events_lost.value = 2
        $document.trace_loss.total_reported_loss = 2
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $script:DocumentPath -Encoding UTF8

        { & $script:Validator -Path $script:DocumentPath } |
            Should -Throw '*native_loss_observed*'
    }

    It 'does not allow no-native-loss classification with an unsupported applicable counter' {
        $document = Get-Content -LiteralPath $script:DocumentPath -Raw | ConvertFrom-Json
        $counter = $document.native_counters.buffers_lost
        $counter.status = 'unsupported'
        $counter.value = $null
        $counter.source = $null
        $counter.reason = 'Counter is not exposed by this source.'
        $document.trace_loss.measured_counter_count = 1
        $document.trace_loss.total_reported_loss = $null
        $document.trace_loss.reason = 'One applicable counter is unsupported.'
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $script:DocumentPath -Encoding UTF8

        { & $script:Validator -Path $script:DocumentPath } |
            Should -Throw '*not_assessed*'
    }

    It 'rejects not-applicable status on Events Lost' {
        $document = Get-Content -LiteralPath $script:DocumentPath -Raw | ConvertFrom-Json
        $counter = $document.native_counters.events_lost
        $counter.status = 'not_applicable'
        $counter.value = $null
        $counter.source = $null
        $counter.reason = 'Synthetic invalid status.'
        $document.trace_loss.measured_counter_count = 1
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $script:DocumentPath -Encoding UTF8

        { & $script:Validator -Path $script:DocumentPath } |
            Should -Throw '*cannot be not_applicable*'
    }

    It 'rejects a real-time counter marked not applicable outside File logging mode' {
        $document = Get-Content -LiteralPath $script:DocumentPath -Raw | ConvertFrom-Json
        $document.capture.profile.logging_mode = 'Memory'
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $script:DocumentPath -Encoding UTF8

        { & $script:Validator -Path $script:DocumentPath } |
            Should -Throw '*only for File logging mode*'
    }

    It 'rejects circular utilization math that does not match ETL provenance' {
        $document = Get-Content -LiteralPath $script:DocumentPath -Raw | ConvertFrom-Json
        $document.circular_overwrite.utilization_ratio = 0.25
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $script:DocumentPath -Encoding UTF8

        { & $script:Validator -Path $script:DocumentPath } |
            Should -Throw '*utilization_ratio*'
    }

    It 'requires risk classification when the circular capacity threshold is reached' {
        $document = Get-Content -LiteralPath $script:DocumentPath -Raw | ConvertFrom-Json
        $document.capture.etl.length = 500000000
        $document.circular_overwrite.final_etl_length = 500000000
        $document.circular_overwrite.utilization_ratio = 500000000 / 536870912
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $script:DocumentPath -Encoding UTF8

        { & $script:Validator -Path $script:DocumentPath } |
            Should -Throw '*risk_reasons*'
    }

    It 'rejects an overwrite risk reason without a represented native evidence field' {
        $document = Get-Content -LiteralPath $script:DocumentPath -Raw | ConvertFrom-Json
        $document.circular_overwrite.classification = 'risk_observed'
        $document.circular_overwrite.risk_reasons = @('native_overwrite_reported')
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $script:DocumentPath -Encoding UTF8

        { & $script:Validator -Path $script:DocumentPath } |
            Should -Throw '*native_overwrite_reported*'
    }

    It 'rejects a trace-loss absence claim even when native counters are zero' {
        $document = Get-Content -LiteralPath $script:DocumentPath -Raw | ConvertFrom-Json
        $document.claims.trace_loss_absence = $true
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $script:DocumentPath -Encoding UTF8

        { & $script:Validator -Path $script:DocumentPath } |
            Should -Throw '*trace_loss_absence*'
    }

    It 'rejects a circular-overwrite absence claim below the risk threshold' {
        $document = Get-Content -LiteralPath $script:DocumentPath -Raw | ConvertFrom-Json
        $document.claims.circular_overwrite_absence = $true
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $script:DocumentPath -Encoding UTF8

        { & $script:Validator -Path $script:DocumentPath } |
            Should -Throw '*circular_overwrite_absence*'
    }

    It 'requires unbounded captures to classify circular overwrite as not applicable' {
        $document = Get-Content -LiteralPath $script:DocumentPath -Raw | ConvertFrom-Json
        $captureProfile = $document.capture.profile
        $captureProfile.bounded = $false
        $captureProfile.file_mode = 'Unbounded'
        $captureProfile.maximum_file_size_mib = $null
        $document.circular_overwrite.capacity_bytes = $null
        $document.circular_overwrite.final_etl_length = $null
        $document.circular_overwrite.utilization_ratio = $null
        $document | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $script:DocumentPath -Encoding UTF8

        { & $script:Validator -Path $script:DocumentPath } |
            Should -Throw '*not_applicable*'
    }
}
