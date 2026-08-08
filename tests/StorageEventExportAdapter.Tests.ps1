BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:Adapter = Join-Path `
        $script:RepositoryRoot `
        'scripts\ConvertFrom-NxbStorageEventExport.ps1'

    function Write-NxbStorageAdapterFixture {
        param(
            [Parameter(Mandatory)]
            [string]$Path,

            [Parameter(Mandatory)]
            [string[]]$Rows
        )

        @(
            'event_type,timestamp_raw,process_id,thread_id,disk_number,file_key,path,offset_bytes,transfer_bytes,duration_raw,disk_service_time_raw,result_raw'
        ) + $Rows | Set-Content -LiteralPath $Path -Encoding UTF8
    }

    function Invoke-NxbStorageAdapterFixture {
        param(
            [Parameter(Mandatory)]
            [string]$InputPath,

            [Parameter(Mandatory)]
            [string]$OutputPath,

            [Parameter(Mandatory)]
            [string[]]$CoveredEventType
        )

        & $script:Adapter `
            -ExperimentId 'storage-adapter-fixture' `
            -InputPath $InputPath `
            -OutputPath $OutputPath `
            -MachineId 'fixture-machine' `
            -BootId ('1' * 64) `
            -TraceSha256 ('2' * 64) `
            -ProfileSha256 ('3' * 64) `
            -TraceStartUtc ([datetime]'2026-08-08T15:00:00Z') `
            -TraceEndUtc ([datetime]'2026-08-08T15:00:10Z') `
            -TargetProcessId 4242 `
            -TargetProcessStartUtc ([datetime]'2026-08-08T15:00:01Z') `
            -TargetImageSha256 ('4' * 64) `
            -CoveredEventType $CoveredEventType `
            -TraceLoss none `
            -CircularOverwrite unknown `
            -ParserCompleteness partial `
            -PassThru
    }
}

Describe 'NXB storage event export summary adapter' {
    It 'aggregates observed event counts and verified byte totals' {
        $csvPath = Join-Path $TestDrive 'happy.csv'
        $summaryPath = Join-Path $TestDrive 'happy.json'
        Write-NxbStorageAdapterFixture -Path $csvPath -Rows @(
            'disk_read,1.0,4242,10,0,0x1,C:\fixture.bin,0,4096,0.1,0.05,',
            'disk_read,1.1,4242,10,0,0x1,C:\fixture.bin,4096,8192,0.1,0.05,',
            'file_write,1.2,4242,10,,0x1,C:\fixture.bin,0,1024,,,',
            'file_create,1.3,4242,10,,0x1,C:\fixture.bin,,,,,'
        )

        $result = Invoke-NxbStorageAdapterFixture `
            -InputPath $csvPath `
            -OutputPath $summaryPath `
            -CoveredEventType @('disk_read','file_write','file_create')

        $result.events.disk_read.status | Should -Be 'measured'
        $result.events.disk_read.count | Should -Be 2
        $result.events.disk_read.bytes | Should -Be 12288
        $result.events.file_write.count | Should -Be 1
        $result.events.file_write.bytes | Should -Be 1024
        $result.events.file_create.bytes | Should -BeNullOrEmpty
        $result.summary.measured_event_class_count | Should -Be 3
    }

    It 'keeps uncovered event classes not assessed instead of inventing zero' {
        $csvPath = Join-Path $TestDrive 'uncovered.csv'
        $summaryPath = Join-Path $TestDrive 'uncovered.json'
        Write-NxbStorageAdapterFixture -Path $csvPath -Rows @(
            'disk_read,1.0,4242,10,0,0x1,C:\fixture.bin,0,4096,0.1,0.05,'
        )

        $result = Invoke-NxbStorageAdapterFixture `
            -InputPath $csvPath `
            -OutputPath $summaryPath `
            -CoveredEventType @('disk_read')

        $result.events.split_io.status | Should -Be 'not_assessed'
        $result.events.split_io.count | Should -BeNullOrEmpty
        $result.processes[0].events.split_io.status | Should -Be 'not_assessed'
    }

    It 'keeps a covered but unobserved class not assessed instead of inferring zero' {
        $csvPath = Join-Path $TestDrive 'covered-unobserved.csv'
        $summaryPath = Join-Path $TestDrive 'covered-unobserved.json'
        Write-NxbStorageAdapterFixture -Path $csvPath -Rows @(
            'disk_read,1.0,4242,10,0,0x1,C:\fixture.bin,0,4096,0.1,0.05,'
        )

        $result = Invoke-NxbStorageAdapterFixture `
            -InputPath $csvPath `
            -OutputPath $summaryPath `
            -CoveredEventType @('disk_read','disk_flush')

        $result.events.disk_flush.status | Should -Be 'not_assessed'
        $result.events.disk_flush.count | Should -BeNullOrEmpty
        $result.events.disk_flush.bytes | Should -BeNullOrEmpty
        $result.processes[0].events.disk_flush.status | Should -Be 'not_assessed'
        $result.summary.measured_event_class_count | Should -Be 1
    }

    It 'does not synthesize a partial byte total when a byte row lacks transfer size' {
        $csvPath = Join-Path $TestDrive 'missing-bytes.csv'
        $summaryPath = Join-Path $TestDrive 'missing-bytes.json'
        Write-NxbStorageAdapterFixture -Path $csvPath -Rows @(
            'disk_write,1.0,4242,10,0,0x1,C:\fixture.bin,0,4096,0.1,0.05,',
            'disk_write,1.1,4242,10,0,0x1,C:\fixture.bin,4096,,0.1,0.05,'
        )

        $result = Invoke-NxbStorageAdapterFixture `
            -InputPath $csvPath `
            -OutputPath $summaryPath `
            -CoveredEventType @('disk_write')

        $result.events.disk_write.count | Should -Be 2
        $result.events.disk_write.bytes | Should -BeNullOrEmpty
    }

    It 'tracks missing process attribution without creating process zero' {
        $csvPath = Join-Path $TestDrive 'attribution.csv'
        $summaryPath = Join-Path $TestDrive 'attribution.json'
        Write-NxbStorageAdapterFixture -Path $csvPath -Rows @(
            'disk_read,1.0,4242,10,0,0x1,C:\fixture.bin,0,4096,0.1,0.05,',
            'disk_read,1.1,,11,0,0x1,C:\fixture.bin,4096,4096,0.1,0.05,'
        )

        $result = Invoke-NxbStorageAdapterFixture `
            -InputPath $csvPath `
            -OutputPath $summaryPath `
            -CoveredEventType @('disk_read')

        $result.events.disk_read.count | Should -Be 2
        $result.events.disk_read.unattributed_count | Should -Be 1
        $result.events.disk_read.attribution | Should -Be 'partial'
        @($result.processes.process_id) | Should -Not -Contain 0
    }

    It 'keeps only the target process identity complete' {
        $csvPath = Join-Path $TestDrive 'identity.csv'
        $summaryPath = Join-Path $TestDrive 'identity.json'
        Write-NxbStorageAdapterFixture -Path $csvPath -Rows @(
            'file_read,1.0,4242,10,,0x1,C:\fixture.bin,0,4096,,,',
            'file_read,1.1,5252,11,,0x1,C:\fixture.bin,4096,4096,,,'
        )

        $result = Invoke-NxbStorageAdapterFixture `
            -InputPath $csvPath `
            -OutputPath $summaryPath `
            -CoveredEventType @('file_read')

        $target = @($result.processes | Where-Object is_target -eq $true)
        $other = @($result.processes | Where-Object is_target -eq $false)
        $target.Count | Should -Be 1
        $target[0].process_id | Should -Be 4242
        $target[0].identity_status | Should -Be 'complete'
        $other.Count | Should -Be 1
        $other[0].identity_status | Should -Be 'partial'
        $other[0].process_start_utc | Should -BeNullOrEmpty
        $other[0].image_sha256 | Should -BeNullOrEmpty
    }

    It 'keeps latency and all higher-level metrics unassessed' {
        $csvPath = Join-Path $TestDrive 'timing.csv'
        $summaryPath = Join-Path $TestDrive 'timing.json'
        Write-NxbStorageAdapterFixture -Path $csvPath -Rows @(
            'disk_read,123.456,4242,10,0,0x1,C:\fixture.bin,0,4096,7.25,3.50,'
        )

        $result = Invoke-NxbStorageAdapterFixture `
            -InputPath $csvPath `
            -OutputPath $summaryPath `
            -CoveredEventType @('disk_read')

        $result.events.disk_read.latency_us | Should -BeNullOrEmpty
        foreach ($name in @(
            'queue_depth',
            'queue_latency_us',
            'service_time_us',
            'throughput_bytes_per_second',
            'iops'
        )) {
            $result.metrics.$name.status | Should -Be 'not_assessed'
            $result.metrics.$name.statistics | Should -BeNullOrEmpty
        }
        $result.claims.queue_depth_semantics | Should -BeFalse
        $result.claims.queue_latency_semantics | Should -BeFalse
        $result.claims.service_time_semantics | Should -BeFalse
        $result.claims.throughput_representativeness | Should -BeFalse
        $result.claims.iops_representativeness | Should -BeFalse
    }

    It 'rejects an event row not declared in CoveredEventType' {
        $csvPath = Join-Path $TestDrive 'coverage-mismatch.csv'
        $summaryPath = Join-Path $TestDrive 'coverage-mismatch.json'
        Write-NxbStorageAdapterFixture -Path $csvPath -Rows @(
            'disk_read,1.0,4242,10,0,0x1,C:\fixture.bin,0,4096,0.1,0.05,',
            'file_write,1.1,4242,10,,0x1,C:\fixture.bin,0,4096,,,'
        )

        {
            Invoke-NxbStorageAdapterFixture `
                -InputPath $csvPath `
                -OutputPath $summaryPath `
                -CoveredEventType @('disk_read')
        } | Should -Throw '*not declared in CoveredEventType*'
    }

    It 'rejects a non-canonical normalized CSV header' {
        $csvPath = Join-Path $TestDrive 'bad-header.csv'
        $summaryPath = Join-Path $TestDrive 'bad-header.json'
        @(
            'event_type,process_id,transfer_bytes',
            'disk_read,4242,4096'
        ) | Set-Content -LiteralPath $csvPath -Encoding UTF8

        {
            Invoke-NxbStorageAdapterFixture `
                -InputPath $csvPath `
                -OutputPath $summaryPath `
                -CoveredEventType @('disk_read')
        } | Should -Throw '*header mismatch*'
    }
}
