BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:Accounting = Join-Path `
        $script:RepositoryRoot `
        'scripts\Invoke-NxbStorageEtlHeaderAccounting.ps1'
    $script:Head = (& git.exe -C $script:RepositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()

    function Write-NxbStorageAccountingFixture {
        param(
            [Parameter(Mandatory)]
            [string]$Root,

            [Parameter()]
            [int64]$Length = 4096,

            [Parameter()]
            [int64]$MaximumFileSizeMiB = 512,

            [Parameter()]
            [string]$FileMode = 'Circular',

            [Parameter()]
            [switch]$WrongHash
        )

        [IO.Directory]::CreateDirectory($Root) | Out-Null
        $etlPath = Join-Path $Root 'fixture.etl'
        $stream = [IO.File]::Open($etlPath, [IO.FileMode]::Create, [IO.FileAccess]::Write)
        try {
            $stream.SetLength($Length)
        }
        finally {
            $stream.Dispose()
        }

        $etlSha = (Get-FileHash -LiteralPath $etlPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $receiptPath = Join-Path $Root 'receipt.json'
        [pscustomobject][ordered]@{
            schema_version = 1
            status = 'passed'
            head_sha = 'a' * 40
            profile = [ordered]@{
                sha256 = 'b' * 64
                file_mode = $FileMode
                maximum_file_size_mib = $MaximumFileSizeMiB
            }
            evidence = [ordered]@{
                etl_sha256 = if ($WrongHash) { 'c' * 64 } else { $etlSha }
            }
        } | ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath $receiptPath -Encoding UTF8

        return [pscustomobject]@{
            EtlPath = $etlPath
            ReceiptPath = $receiptPath
            OutputPath = Join-Path $Root 'accounting.json'
        }
    }

    function Invoke-NxbStorageAccountingFixture {
        param(
            [Parameter(Mandatory)]
            [object]$Fixture,

            [Parameter()]
            [uint64]$EventsLost = 0,

            [Parameter()]
            [uint64]$BuffersLost = 0,

            [Parameter()]
            [uint64]$BuffersWritten = 10
        )

        $eventsLostValue = [uint64]$EventsLost
        $buffersLostValue = [uint64]$BuffersLost
        $buffersWrittenValue = [uint64]$BuffersWritten

        $provider = {
            param($Path)
            $null = $Path
            [pscustomobject]@{
                BufferSize = [uint64]1024
                NumberOfProcessors = [uint64]16
                MaximumFileSize = [uint64]512
                LogFileMode = [uint64]0
                BuffersWritten = $buffersWrittenValue
                PointerSize = [uint64]8
                EventsLost = $eventsLostValue
                BuffersLost = $buffersLostValue
            }
        }.GetNewClosure()

        & $script:Accounting `
            -ExpectedHead $script:Head `
            -CaptureReceiptPath $Fixture.ReceiptPath `
            -EtlPath $Fixture.EtlPath `
            -OutputPath $Fixture.OutputPath `
            -HeaderProvider $provider `
            -PassThru
    }
}

Describe 'NXB storage ETL native header accounting' {
    It 'classifies measured zero loss counters conservatively without claiming absence' {
        $fixture = Write-NxbStorageAccountingFixture -Root (Join-Path $TestDrive 'zero-loss')
        $result = Invoke-NxbStorageAccountingFixture -Fixture $fixture -BuffersWritten 123

        $result.status | Should -Be 'passed'
        $result.native_header.events_lost | Should -Be 0
        $result.native_header.buffers_lost | Should -Be 0
        $result.native_header.buffers_written | Should -Be 123
        $result.trace_loss.state | Should -Be 'none'
        $result.trace_loss.classification | Should -Be 'no_native_loss_reported'
        $result.circular.risk_classification | Should -Be 'no_risk_observed'
        $result.circular.overwrite_state | Should -Be 'unknown'
        $result.claims.trace_loss_absence | Should -BeFalse
        $result.claims.circular_overwrite_absence | Should -BeFalse
        $result.claims.capture_completeness | Should -Be 'not_claimed'
    }

    It 'classifies positive EventsLost as native loss observed' {
        $fixture = Write-NxbStorageAccountingFixture -Root (Join-Path $TestDrive 'events-lost')
        $result = Invoke-NxbStorageAccountingFixture -Fixture $fixture -EventsLost 3

        $result.trace_loss.state | Should -Be 'present'
        $result.trace_loss.classification | Should -Be 'native_loss_observed'
        $result.trace_loss.total_reported_loss | Should -Be 3
    }

    It 'classifies positive BuffersLost as native loss observed' {
        $fixture = Write-NxbStorageAccountingFixture -Root (Join-Path $TestDrive 'buffers-lost')
        $result = Invoke-NxbStorageAccountingFixture -Fixture $fixture -BuffersLost 2

        $result.trace_loss.state | Should -Be 'present'
        $result.trace_loss.classification | Should -Be 'native_loss_observed'
        $result.trace_loss.total_reported_loss | Should -Be 2
    }

    It 'raises circular risk at the fixed 0.9 capacity threshold without claiming overwrite' {
        $fixture = Write-NxbStorageAccountingFixture `
            -Root (Join-Path $TestDrive 'capacity-risk') `
            -Length 950000 `
            -MaximumFileSizeMiB 1
        $result = Invoke-NxbStorageAccountingFixture -Fixture $fixture

        $result.circular.utilization_ratio | Should -BeGreaterOrEqual 0.9
        $result.circular.risk_classification | Should -Be 'risk_observed'
        @($result.circular.risk_reasons) | Should -Contain 'capacity_threshold_reached'
        $result.circular.overwrite_state | Should -Be 'unknown'
        $result.claims.circular_overwrite_absence | Should -BeFalse
    }

    It 'rejects a capture that is not bounded Circular file mode' {
        $fixture = Write-NxbStorageAccountingFixture `
            -Root (Join-Path $TestDrive 'not-circular') `
            -FileMode 'Sequential'

        {
            Invoke-NxbStorageAccountingFixture -Fixture $fixture
        } | Should -Throw '*not Circular file mode*'
    }

    It 'rejects ETL bytes that do not match capture-receipt provenance' {
        $fixture = Write-NxbStorageAccountingFixture `
            -Root (Join-Path $TestDrive 'hash-mismatch') `
            -WrongHash

        {
            Invoke-NxbStorageAccountingFixture -Fixture $fixture
        } | Should -Throw '*ETL SHA-256 does not match*'
    }

    It 'refuses to overwrite an existing accounting output' {
        $fixture = Write-NxbStorageAccountingFixture -Root (Join-Path $TestDrive 'output-exists')
        Set-Content -LiteralPath $fixture.OutputPath -Value '{}'

        {
            Invoke-NxbStorageAccountingFixture -Fixture $fixture
        } | Should -Throw '*OutputPath already exists*'
    }
}
