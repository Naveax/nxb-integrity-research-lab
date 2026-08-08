BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:Bridge = Join-Path `
        $script:RepositoryRoot `
        'scripts\ConvertFrom-NxbXperfStorageDumper.ps1'
    $script:Fixture = Join-Path `
        $script:RepositoryRoot `
        'tests\fixtures\xperf-storage-dumper.valid.txt'
}

Describe 'NXB xperf storage dumper bridge' {
    It 'normalizes the observed supported storage rows' {
        $outputDirectory = Join-Path $TestDrive 'normalized'
        $result = & $script:Bridge `
            -InputPath $script:Fixture `
            -OutputDirectory $outputDirectory `
            -PassThru

        $result.normalized_event_count | Should -Be 10
        $rows = @(Import-Csv -LiteralPath $result.event_export_path)
        $rows.Count | Should -Be 10
        @($rows.event_type) | Should -Contain 'disk_read'
        @($rows.event_type) | Should -Contain 'disk_write'
        @($rows.event_type) | Should -Contain 'disk_flush'
        @($rows.event_type) | Should -Contain 'file_read'
        @($rows.event_type) | Should -Contain 'file_write'
        @($rows.event_type) | Should -Contain 'file_rename'
    }

    It 'maps observed DiskRead identity size offset and disk fields' {
        $outputDirectory = Join-Path $TestDrive 'disk-read'
        $result = & $script:Bridge `
            -InputPath $script:Fixture `
            -OutputDirectory $outputDirectory `
            -PassThru
        $row = Import-Csv -LiteralPath $result.event_export_path |
            Where-Object event_type -eq 'disk_read' |
            Select-Object -First 1

        [int]$row.process_id | Should -Be 4242
        [int]$row.thread_id | Should -Be 99
        [int]$row.disk_number | Should -Be 0
        [int64]$row.offset_bytes | Should -Be 4096
        [int64]$row.transfer_bytes | Should -Be 8192
        $row.file_key | Should -Be '0x1000'
        $row.path | Should -Be 'C:\fixture.bin'
    }

    It 'preserves quoted file paths and FileIo Size fields' {
        $outputDirectory = Join-Path $TestDrive 'file-write'
        $result = & $script:Bridge `
            -InputPath $script:Fixture `
            -OutputDirectory $outputDirectory `
            -PassThru
        $row = Import-Csv -LiteralPath $result.event_export_path |
            Where-Object event_type -eq 'file_write' |
            Select-Object -First 1

        [int64]$row.offset_bytes | Should -Be 4096
        [int64]$row.transfer_bytes | Should -Be 8192
        $row.file_key | Should -Be '0x1000'
        $row.path | Should -Be 'C:\fixture,owned.bin'
    }

    It 'keeps native timing values raw and unit-unresolved' {
        $outputDirectory = Join-Path $TestDrive 'timing'
        $result = & $script:Bridge `
            -InputPath $script:Fixture `
            -OutputDirectory $outputDirectory `
            -PassThru
        $row = Import-Csv -LiteralPath $result.event_export_path |
            Where-Object event_type -eq 'disk_read' |
            Select-Object -First 1

        $row.timestamp_raw | Should -Be '100.125000'
        $row.duration_raw | Should -Be '0.250000'
        $row.disk_service_time_raw | Should -Be '0.200000'
        $result.timing.timestamp_raw_unit | Should -Be 'unresolved'
        $result.timing.elapsed_time_raw_unit | Should -Be 'unresolved'
        $result.timing.disk_service_time_raw_unit | Should -Be 'unresolved'
        [bool]$result.timing.normalized_duration_us_available | Should -BeFalse
    }

    It 'records observed storage candidate headers that v1 does not map' {
        $outputDirectory = Join-Path $TestDrive 'unsupported'
        $result = & $script:Bridge `
            -InputPath $script:Fixture `
            -OutputDirectory $outputDirectory `
            -PassThru

        @($result.manifest.observed_unmapped_storage_candidate_headers) |
            Should -Contain 'FileIoOpEnd'
        $result.parser_completeness | Should -Be 'partial'
        $result.manifest.claims.queue_depth_semantics | Should -BeFalse
        $result.manifest.claims.service_time_semantics | Should -BeFalse
    }

    It 'fails closed when a supported row appears before its header' {
        $badInputPath = Join-Path $TestDrive 'row-before-header.txt'
        $outputDirectory = Join-Path $TestDrive 'row-before-header-output'
        'DiskRead, 1.0, pwsh.exe ( 4242), 99, 0, 0x1, 0, 4096, 0.1, 0' |
            Set-Content -LiteralPath $badInputPath -Encoding UTF8

        {
            & $script:Bridge `
                -InputPath $badInputPath `
                -OutputDirectory $outputDirectory
        } | Should -Throw '*before a parseable header*'
    }

    It 'enforces the maximum normalized event count' {
        $outputDirectory = Join-Path $TestDrive 'max-events'
        {
            & $script:Bridge `
                -InputPath $script:Fixture `
                -OutputDirectory $outputDirectory `
                -MaxEventCount 2
        } | Should -Throw '*exceeds max-event-count=2*'
    }

    It 'refuses to overwrite an existing output directory' {
        $outputDirectory = Join-Path $TestDrive 'existing'
        [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null

        {
            & $script:Bridge `
                -InputPath $script:Fixture `
                -OutputDirectory $outputDirectory
        } | Should -Throw '*already exists*'
    }
}
