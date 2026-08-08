BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:Inventory = Join-Path `
        $script:RepositoryRoot `
        'scripts\Get-NxbXperfStorageHeaderInventory.ps1'
    $script:Workload = Join-Path `
        $script:RepositoryRoot `
        'scripts\Invoke-NxbStorageHeaderProbeWorkload.ps1'
    $script:Capture = Join-Path `
        $script:RepositoryRoot `
        'scripts\Invoke-NxbStorageHeaderProbe.ps1'
}

Describe 'NXB storage xperf header inventory and bounded probe workload' {
    It 'extracts unique headers without treating event rows as headers' {
        $input = Join-Path $TestDrive 'dumper.txt'
        $output = Join-Path $TestDrive 'inventory.json'
        @(
            'DiskRead, TimeStamp, Process Name ( PID), ThreadID, DiskNum, TransferSize',
            'DiskRead, 1.000000, pwsh.exe ( 4242), 99, 0, 4096',
            'FileIoRead, TimeStamp, Process Name ( PID), ThreadID, FileObject, FileName',
            'FileIoRead, 1.100000, pwsh.exe ( 4242), 99, 0x1234, C:\fixture.bin',
            'DiskRead, TimeStamp, Process Name ( PID), ThreadID, DiskNum, TransferSize'
        ) | Set-Content -LiteralPath $input -Encoding UTF8

        $result = & $script:Inventory `
            -InputPath $input `
            -OutputPath $output `
            -PassThru

        $result.header_count | Should -Be 2
        $result.candidate_storage_header_count | Should -Be 2
        @($result.headers.event_name) | Should -Contain 'DiskRead'
        @($result.headers.event_name) | Should -Contain 'FileIoRead'
        $result.claims.event_rows_included | Should -BeFalse
        $result.claims.raw_etl_included | Should -BeFalse
        $result.claims.candidate_name_match_implies_semantics | Should -BeFalse
    }

    It 'keeps queue and performance semantics unclaimed in header inventory' {
        $input = Join-Path $TestDrive 'claims-dumper.txt'
        $output = Join-Path $TestDrive 'claims-inventory.json'
        'DiskWrite, TimeStamp, Process Name ( PID), ThreadID, DiskNum' |
            Set-Content -LiteralPath $input -Encoding UTF8

        $result = & $script:Inventory `
            -InputPath $input `
            -OutputPath $output `
            -PassThru

        $result.claims.queue_semantics | Should -Be 'not_claimed'
        $result.claims.latency_semantics | Should -Be 'not_claimed'
        $result.claims.throughput_semantics | Should -Be 'not_claimed'
        $result.claims.iops_semantics | Should -Be 'not_claimed'
        $result.claims.parser_completeness | Should -Be 'not_claimed'
    }

    It 'runs a bounded owned 1 MiB write-read-flush-rename-delete workload' {
        $output = Join-Path $TestDrive 'workload'
        $receipt = Join-Path $TestDrive 'workload-receipt.json'

        & $script:Workload `
            -OutputDirectory $output `
            -FileSizeMiB 1 `
            -BlockSizeKiB 64 `
            -ReceiptPath $receipt

        $document = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
        $document.status | Should -Be 'passed'
        [int64]$document.bytes_written | Should -Be 1MB
        [int64]$document.bytes_read | Should -Be 1MB
        [int]$document.flush_count | Should -Be 1
        [bool]$document.renamed | Should -BeTrue
        [bool]$document.deleted | Should -BeTrue
        [bool]$document.claims.benchmark | Should -BeFalse
        [bool]$document.claims.representative_throughput | Should -BeFalse
        [bool]$document.claims.representative_iops | Should -BeFalse
        @(Get-ChildItem -LiteralPath $output -File -ErrorAction Stop).Count |
            Should -Be 0
    }

    It 'rejects an existing workload output directory' {
        $output = Join-Path $TestDrive 'existing-workload'
        [IO.Directory]::CreateDirectory($output) | Out-Null

        {
            & $script:Workload `
                -OutputDirectory $output `
                -FileSizeMiB 1 `
                -BlockSizeKiB 64
        } | Should -Throw '*OutputDirectory already exists*'
    }

    It 'requires explicit opt-in before cancelling an existing WPR session' {
        $content = Get-Content -LiteralPath $script:Capture -Raw
        $content | Should -Match '\[switch\]\$CancelExistingSession'
        $content | Should -Match 'if \(\$CancelExistingSession\)'
        $content | Should -Match 'Existing sessions are not cancelled unless'
    }

    It 'keeps raw ETL and full dumper out of the review-copy set' {
        $content = Get-Content -LiteralPath $script:Capture -Raw
        $reviewBlock = [regex]::Match(
            $content,
            '(?s)foreach \(\$reviewPath in @\((.*?)\)\)'
        )
        $reviewBlock.Success | Should -BeTrue
        $reviewBlock.Groups[1].Value | Should -Not -Match '\$etlPath'
        $reviewBlock.Groups[1].Value | Should -Not -Match '\$dumperPath'
        $reviewBlock.Groups[1].Value | Should -Match '\$headerInventoryPath'
        $content | Should -Match 'raw_etl_reviewed = \$false'
        $content | Should -Match 'full_dumper_reviewed = \$false'
    }
}
