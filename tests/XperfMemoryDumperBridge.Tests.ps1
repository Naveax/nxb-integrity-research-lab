BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:BridgePath = Join-Path `
        $script:RepositoryRoot `
        'scripts\ConvertFrom-NxbXperfMemoryDumper.ps1'
    $script:NormalizerPath = Join-Path `
        $script:RepositoryRoot `
        'tools\normalize_xperf_memory_dumper.py'
    $script:FixturePath = Join-Path `
        $script:RepositoryRoot `
        'tests\fixtures\xperf-memory-dumper.valid.txt'

    function Invoke-XperfMemoryBridgeFixture {
        param(
            [Parameter(Mandatory)]
            [string]$InputPath,

            [Parameter(Mandatory)]
            [string]$OutputDirectory
        )

        & $script:BridgePath `
            -InputPath $InputPath `
            -OutputDirectory $OutputDirectory `
            -PassThru
    }
}

Describe 'NXB Xperf memory dumper bridge' {
    It 'normalizes the canonical header-driven dumper fixture' {
        $output = Join-Path $TestDrive 'canonical'

        {
            Invoke-XperfMemoryBridgeFixture `
                -InputPath $script:FixturePath `
                -OutputDirectory $output |
                Out-Null
        } | Should -Not -Throw

        Test-Path `
            -LiteralPath (Join-Path $output 'memory-event-export.csv') `
            -PathType Leaf |
            Should -BeTrue
        Test-Path `
            -LiteralPath (Join-Path $output 'memory-xperf-bridge-manifest.json') `
            -PathType Leaf |
            Should -BeTrue
    }

    It 'does not invent hard-fault bytes or zero coverage' {
        $output = Join-Path $TestDrive 'hard-fault-boundary'
        $result = Invoke-XperfMemoryBridgeFixture `
            -InputPath $script:FixturePath `
            -OutputDirectory $output

        $rows = @(
            Import-Csv -LiteralPath $result.event_export_path
        )
        @($rows | Where-Object event_type -CEQ 'hard_fault').Count |
            Should -Be 0
        @($result.covered_event_types) -contains 'hard_fault' |
            Should -BeFalse
        [int]$result.manifest.unmapped_event_counts.hard_fault |
            Should -Be 1
        [string]$result.manifest.hard_fault_bytes_semantics |
            Should -Be 'not_available_from_observed_header'
        [bool]$result.manifest.claims.missing_event_type_means_zero |
            Should -BeFalse
    }

    It 'extracts process identity only when the dumper exposes it' {
        $output = Join-Path $TestDrive 'attribution'
        $result = Invoke-XperfMemoryBridgeFixture `
            -InputPath $script:FixturePath `
            -OutputDirectory $output
        $rows = @(
            Import-Csv -LiteralPath $result.event_export_path
        )

        $virtualAlloc = @(
            $rows | Where-Object event_type -CEQ 'virtual_allocation'
        )[0]
        [int]$virtualAlloc.process_id | Should -Be 4242
        [int]$virtualAlloc.thread_id | Should -Be 101
        [int]$virtualAlloc.size_bytes | Should -Be 4096

        $demandZero = @(
            $rows | Where-Object event_type -CEQ 'demand_zero_fault'
        )[0]
        [int]$demandZero.process_id | Should -Be 0
        [int]$demandZero.thread_id | Should -Be 101
        [string]$result.process_attribution | Should -Be 'partial'
    }

    It 'records only event classes actually normalized from headers' {
        $output = Join-Path $TestDrive 'coverage'
        $result = Invoke-XperfMemoryBridgeFixture `
            -InputPath $script:FixturePath `
            -OutputDirectory $output

        $expected = @(
            'copy_on_write_fault',
            'demand_zero_fault',
            'guard_page_fault',
            'mapped_section_create',
            'mapped_section_delete',
            'transition_fault',
            'virtual_allocation',
            'virtual_free'
        ) -join ','
        (@($result.covered_event_types) -join ',') |
            Should -Be $expected
        [int]$result.normalized_event_count | Should -Be 8
    }

    It 'rejects a memory event row before a parseable header' {
        $inputPath = Join-Path $TestDrive 'missing-header.txt'
        [IO.File]::WriteAllText(
            $inputPath,
            'VirtualAlloc,1000,target.exe (4242),101,0x1000,4096',
            [Text.ASCIIEncoding]::new()
        )
        $output = Join-Path $TestDrive 'missing-header-output'

        {
            Invoke-XperfMemoryBridgeFixture `
                -InputPath $inputPath `
                -OutputDirectory $output |
                Out-Null
        } | Should -Throw '*before a parseable header*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'rejects virtual allocation events without an explicit size field' {
        $inputPath = Join-Path $TestDrive 'missing-size.txt'
        @(
            'VirtualAlloc, TimeStamp, Process Name ( PID), ThreadID, BaseAddress',
            'VirtualAlloc, 1000, target.exe (4242), 101, 0x1000'
        ) | Set-Content -LiteralPath $inputPath -Encoding Ascii
        $output = Join-Path $TestDrive 'missing-size-output'

        {
            Invoke-XperfMemoryBridgeFixture `
                -InputPath $inputPath `
                -OutputDirectory $output |
                Out-Null
        } | Should -Throw '*size field is required*'
    }

    It 'rejects simultaneous HardFault and PagefaultHard streams' {
        $inputPath = Join-Path $TestDrive 'ambiguous-hard-fault.txt'
        @(
            'HardFault, TimeStamp, ThreadID, ByteCount',
            'HardFault, 1000, 101, 4096',
            'PagefaultHard, TimeStamp, ThreadID, ByteCount',
            'PagefaultHard, 2000, 101, 4096'
        ) | Set-Content -LiteralPath $inputPath -Encoding Ascii
        $output = Join-Path $TestDrive 'ambiguous-hard-fault-output'

        {
            Invoke-XperfMemoryBridgeFixture `
                -InputPath $inputPath `
                -OutputDirectory $output |
                Out-Null
        } | Should -Throw '*potentially overlapping hard-fault streams*'
    }

    It 'refuses to overwrite an existing output directory' {
        $output = Join-Path $TestDrive 'existing'
        New-Item -ItemType Directory -Path $output -Force | Out-Null
        [IO.File]::WriteAllText(
            (Join-Path $output 'sentinel.txt'),
            'keep',
            [Text.ASCIIEncoding]::new()
        )

        {
            Invoke-XperfMemoryBridgeFixture `
                -InputPath $script:FixturePath `
                -OutputDirectory $output |
                Out-Null
        } | Should -Throw '*OutputDirectory already exists*'

        Get-Content -LiteralPath (Join-Path $output 'sentinel.txt') -Raw |
            Should -Be 'keep'
    }

    It 'binds input normalizer and normalized CSV hashes' {
        $output = Join-Path $TestDrive 'hashes'
        $result = Invoke-XperfMemoryBridgeFixture `
            -InputPath $script:FixturePath `
            -OutputDirectory $output

        $expectedInput = (
            Get-FileHash -LiteralPath $script:FixturePath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        $expectedNormalizer = (
            Get-FileHash -LiteralPath $script:NormalizerPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        $expectedCsv = (
            Get-FileHash -LiteralPath $result.event_export_path -Algorithm SHA256
        ).Hash.ToLowerInvariant()

        [string]$result.manifest.input_sha256 | Should -Be $expectedInput
        [string]$result.manifest.normalizer_sha256 |
            Should -Be $expectedNormalizer
        [string]$result.manifest.normalized_csv_sha256 |
            Should -Be $expectedCsv
    }
}
