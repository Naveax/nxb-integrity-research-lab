BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsRoot = Join-Path $script:RepositoryRoot 'scripts'
    $script:FixturePath = Join-Path `
        $script:RepositoryRoot `
        'tests\fixtures\memory-etl-summary.valid.json'

    function ConvertTo-MemoryEtlSummaryFixture {
        param(
            [Parameter(Mandatory)]
            [object]$Document,

            [Parameter(Mandatory)]
            [string]$Path
        )

        $json = $Document | ConvertTo-Json -Depth 64
        [IO.File]::WriteAllText(
            $Path,
            $json,
            [Text.UTF8Encoding]::new($false)
        )
    }
}

Describe 'NXB memory ETL summary contract' {
    BeforeEach {
        $script:TestRoot = Join-Path `
            ([IO.Path]::GetTempPath()) `
            ("nxb-memory-etl-summary-{0}" -f [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($script:TestRoot) | Out-Null
        $script:TestManifest = Join-Path $script:TestRoot 'memory-etl-summary.json'
        $script:Document = Get-Content -LiteralPath $script:FixturePath -Raw |
            ConvertFrom-Json
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TestRoot) {
            Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
        }
    }

    It 'validates the committed complete synthetic fixture' {
        {
            & (Join-Path $script:ScriptsRoot 'Test-MemoryEtlSummary.ps1') `
                -Path $script:FixturePath
        } | Should -Not -Throw
    }

    It 'rejects an experiment-relative path mismatch' {
        $script:Document.experiment_relative_path = 'experiments/other'
        ConvertTo-MemoryEtlSummaryFixture `
            -Document $script:Document `
            -Path $script:TestManifest

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemoryEtlSummary.ps1') `
                -Path $script:TestManifest
        } | Should -Throw '*experiment_relative_path must be*'
    }

    It 'rejects a trace range with start after end' {
        $script:Document.trace_start_utc = '2026-08-06T22:01:00Z'
        ConvertTo-MemoryEtlSummaryFixture `
            -Document $script:Document `
            -Path $script:TestManifest

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemoryEtlSummary.ps1') `
                -Path $script:TestManifest
        } | Should -Throw '*trace_start_utc is after trace_end_utc*'
    }

    It 'rejects a duplicate process identity' {
        $duplicate = $script:Document.processes[0] |
            ConvertTo-Json -Depth 64 |
            ConvertFrom-Json
        $duplicate.is_target = $false
        $script:Document.processes = @(
            $script:Document.processes[0],
            $duplicate
        )
        $script:Document.summary.process_count = 2
        ConvertTo-MemoryEtlSummaryFixture `
            -Document $script:Document `
            -Path $script:TestManifest

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemoryEtlSummary.ps1') `
                -Path $script:TestManifest
        } | Should -Throw '*duplicate process identity*'
    }

    It 'rejects a partial target identity' {
        $script:Document.processes[0].identity_status = 'partial'
        ConvertTo-MemoryEtlSummaryFixture `
            -Document $script:Document `
            -Path $script:TestManifest

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemoryEtlSummary.ps1') `
                -Path $script:TestManifest
        } | Should -Throw '*target identity cannot be partial*'
    }

    It 'rejects aggregate counts that do not reconcile' {
        $script:Document.events.hard_fault.count = 4
        ConvertTo-MemoryEtlSummaryFixture `
            -Document $script:Document `
            -Path $script:TestManifest

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemoryEtlSummary.ps1') `
                -Path $script:TestManifest
        } | Should -Throw '*count does not reconcile with process attribution*'
    }

    It 'rejects a soft-fault total that does not match components' {
        $script:Document.events.soft_fault_total.count = 10
        $script:Document.events.soft_fault_total.unattributed_count = 1
        $script:Document.events.soft_fault_total.attribution = 'partial'
        ConvertTo-MemoryEtlSummaryFixture `
            -Document $script:Document `
            -Path $script:TestManifest

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemoryEtlSummary.ps1') `
                -Path $script:TestManifest
        } | Should -Throw '*soft_fault_total count mismatch*'
    }

    It 'rejects an event class that is both measured and unsupported' {
        $script:Document.quality.unsupported_event_types = @('hard_fault')
        ConvertTo-MemoryEtlSummaryFixture `
            -Document $script:Document `
            -Path $script:TestManifest

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemoryEtlSummary.ps1') `
                -Path $script:TestManifest
        } | Should -Throw '*cannot be measured and unsupported*'
    }

    It 'rejects summary counts that do not match event states' {
        $script:Document.summary.measured_event_class_count = 9
        ConvertTo-MemoryEtlSummaryFixture `
            -Document $script:Document `
            -Path $script:TestManifest

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemoryEtlSummary.ps1') `
                -Path $script:TestManifest
        } | Should -Throw '*summary.measured_event_class_count mismatch*'
    }

    It 'rejects a claim of hard-fault absence' {
        $script:Document.claims.hard_fault_absence = $true
        ConvertTo-MemoryEtlSummaryFixture `
            -Document $script:Document `
            -Path $script:TestManifest

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemoryEtlSummary.ps1') `
                -Path $script:TestManifest
        } | Should -Throw '*Schema validation failed*'
    }
}
