BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:AdapterPath = Join-Path `
        $script:RepositoryRoot `
        'scripts\ConvertFrom-NxbMemoryEventExport.ps1'
    $script:ValidatorPath = Join-Path `
        $script:RepositoryRoot `
        'scripts\Test-MemoryEtlSummary.ps1'
    $script:FixturePath = Join-Path `
        $script:RepositoryRoot `
        'tests\fixtures\memory-event-export.valid.csv'

    $script:AllCoverage = @(
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

    function Invoke-MemoryEtlAdapter {
        param(
            [Parameter(Mandatory)]
            [string]$InputPath,

            [Parameter(Mandatory)]
            [string]$OutputPath,

            [Parameter()]
            [string[]]$Coverage = $script:AllCoverage,

            [Parameter()]
            [switch]$Force
        )

        & $script:AdapterPath `
            -ExperimentId 'adapter-fixture-001' `
            -InputPath $InputPath `
            -OutputPath $OutputPath `
            -MachineId 'fixture-machine' `
            -BootId ('1' * 64) `
            -TraceSha256 ('2' * 64) `
            -ProfileSha256 ('3' * 64) `
            -TraceStartUtc ([datetime]'2026-08-06T22:00:00Z') `
            -TraceEndUtc ([datetime]'2026-08-06T22:00:10Z') `
            -TargetProcessId 4242 `
            -TargetProcessStartUtc ([datetime]'2026-08-06T21:59:00Z') `
            -TargetImageSha256 ('4' * 64) `
            -CoveredEventType $Coverage `
            -TraceLoss none `
            -CircularOverwrite none `
            -Force:$Force
    }
}

Describe 'NXB memory event export adapter' {
    It 'converts the complete canonical export into valid evidence' {
        $output = Join-Path $TestDrive 'memory-etl-summary.json'

        {
            Invoke-MemoryEtlAdapter `
                -InputPath $script:FixturePath `
                -OutputPath $output
        } | Should -Not -Throw

        Test-Path -LiteralPath $output -PathType Leaf | Should -BeTrue
        { & $script:ValidatorPath -Path $output } | Should -Not -Throw
    }

    It 'derives hard and soft fault totals without inventing classes' {
        $output = Join-Path $TestDrive 'derived-counts.json'
        Invoke-MemoryEtlAdapter `
            -InputPath $script:FixturePath `
            -OutputPath $output

        $document = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json

        $document.events.hard_fault.count | Should -Be 3
        $document.events.soft_fault_total.count | Should -Be 9
        $document.events.virtual_allocation.count | Should -Be 2
        $document.events.virtual_free.count | Should -Be 1
        $document.processes.Count | Should -Be 2
    }

    It 'keeps uncovered classes explicitly not assessed' {
        $output = Join-Path $TestDrive 'partial-coverage.json'
        $coverage = @(
            'hard_fault',
            'virtual_allocation',
            'virtual_free'
        )
        $partialInput = Join-Path $TestDrive 'partial.csv'
        @(
            'event_type,timestamp_us,process_id,thread_id,size_bytes',
            'hard_fault,1000,4242,101,4096',
            'virtual_allocation,2000,4242,101,4096',
            'virtual_free,3000,4242,101,4096'
        ) | Set-Content -LiteralPath $partialInput -Encoding Ascii

        Invoke-MemoryEtlAdapter `
            -InputPath $partialInput `
            -OutputPath $output `
            -Coverage $coverage

        $document = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
        $document.events.hard_fault.status | Should -Be 'measured'
        $document.events.demand_zero_fault.status | Should -Be 'not_assessed'
        $document.events.soft_fault_total.status | Should -Be 'not_assessed'
        $document.summary.evidence_completeness | Should -Be 'partial'
    }

    It 'rejects a row outside the declared coverage' {
        $output = Join-Path $TestDrive 'outside-coverage.json'
        $coverage = @('hard_fault')

        {
            Invoke-MemoryEtlAdapter `
                -InputPath $script:FixturePath `
                -OutputPath $output `
                -Coverage $coverage
        } | Should -Throw '*not declared in CoveredEventType*'
    }

    It 'rejects an unknown event type' {
        $inputPath = Join-Path $TestDrive 'unknown-event.csv'
        @(
            'event_type,timestamp_us,process_id,thread_id,size_bytes',
            'unknown_memory_event,1000,4242,101,'
        ) | Set-Content -LiteralPath $inputPath -Encoding Ascii
        $output = Join-Path $TestDrive 'unknown-event.json'

        {
            Invoke-MemoryEtlAdapter `
                -InputPath $inputPath `
                -OutputPath $output
        } | Should -Throw '*Unsupported memory event_type*'
    }

    It 'rejects an event outside the declared trace range' {
        $inputPath = Join-Path $TestDrive 'bad-time.csv'
        @(
            'event_type,timestamp_us,process_id,thread_id,size_bytes',
            'hard_fault,11000000,4242,101,4096'
        ) | Set-Content -LiteralPath $inputPath -Encoding Ascii
        $output = Join-Path $TestDrive 'bad-time.json'

        {
            Invoke-MemoryEtlAdapter `
                -InputPath $inputPath `
                -OutputPath $output
        } | Should -Throw '*exceeds the declared trace range*'
    }

    It 'refuses to overwrite evidence without Force' {
        $output = Join-Path $TestDrive 'existing.json'
        [IO.File]::WriteAllText(
            $output,
            '{}',
            [Text.UTF8Encoding]::new($false)
        )

        {
            Invoke-MemoryEtlAdapter `
                -InputPath $script:FixturePath `
                -OutputPath $output
        } | Should -Throw '*use -Force to overwrite*'

        Get-Content -LiteralPath $output -Raw | Should -Be '{}'
    }

    It 'binds the export and adapter hashes' {
        $output = Join-Path $TestDrive 'hashes.json'
        Invoke-MemoryEtlAdapter `
            -InputPath $script:FixturePath `
            -OutputPath $output

        $document = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
        $expectedExport = (
            Get-FileHash -LiteralPath $script:FixturePath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        $expectedAdapter = (
            Get-FileHash -LiteralPath $script:AdapterPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()

        $document.event_export_sha256 | Should -Be $expectedExport
        $document.adapter_sha256 | Should -Be $expectedAdapter
        $document.events.hard_fault.source.provenance_sha256 |
            Should -Be $expectedAdapter
    }
}
