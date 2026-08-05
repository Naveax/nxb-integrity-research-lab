BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsRoot = Join-Path $script:RepositoryRoot 'scripts'
    $script:Collector = Join-Path $script:ScriptsRoot 'New-NxbTraceLossAccounting.ps1'
    Import-Module (Join-Path $script:ScriptsRoot 'Nxb.Lab.Common.psm1') -Force
    Import-Module (Join-Path $script:ScriptsRoot 'Nxb.EvidenceStore.psm1') -Force

    function Initialize-NxbTraceLossFixture {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ExperimentPath,

            [Parameter()]
            [int64]$EventsLost = 0,

            [Parameter()]
            [ValidateRange(1, 10485760)]
            [int64]$EtlLength = 100000,

            [Parameter()]
            [ValidateRange(1, 16)]
            [int64]$MaximumFileSizeMiB = 1,

            [Parameter()]
            [ValidateSet('measured', 'failed')]
            [string]$EventsStatus = 'measured'
        )

        Set-NxbExperimentState `
            -ExperimentPath $ExperimentPath `
            -State recording `
            -Confirm:$false | Out-Null

        [void](& (Join-Path $script:ScriptsRoot 'Get-ObservationIdentity.ps1') `
            -ExperimentPath $ExperimentPath)

        $startedUtc = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
        $stoppedUtc = [DateTime]::UtcNow.ToString('o')
        $profile = [ordered]@{
            type = 'repository_wprp'
            relative_path = 'profiles/Nxb.MinimalCpuScheduler.wprp'
            sha256 = ('2' * 64)
            length = 4096
            name = 'NxbMinimalCpuScheduler'
            detail_level = 'Verbose'
            logging_mode = 'File'
            bounded = $true
            buffer_size_kib = 1024
            buffers = 64
            maximum_file_size_mib = $MaximumFileSizeMiB
            file_mode = 'Circular'
            keywords = @('SampledProfile')
            stacks = @('SampledProfile')
        }
        $profileSeal = Get-NxbCanonicalJsonHash -InputObject $profile
        $session = [ordered]@{
            started_utc = $startedUtc
            stopped_utc = $stoppedUtc
            profile = 'NxbMinimalCpuScheduler'
            mode = 'filemode'
            profile_provenance = $profile
            profile_provenance_sha256 = $profileSeal
            status = 'stopped'
            wpr_executable = 'fake-wpr.exe'
        }
        Write-NxbJsonAtomic `
            -Path (Join-Path $ExperimentPath 'trace-session.json') `
            -InputObject $session `
            -Depth 16

        $tracesRoot = Join-Path $ExperimentPath 'traces'
        New-Item -ItemType Directory -Path $tracesRoot -Force | Out-Null
        $etlPath = Join-Path $tracesRoot 'performance.etl'
        $stream = [IO.File]::Open(
            $etlPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        try {
            $stream.SetLength($EtlLength)
        }
        finally {
            $stream.Dispose()
        }
        $etlSha256 = (Get-FileHash -LiteralPath $etlPath -Algorithm SHA256).Hash
        $etlMetadata = [ordered]@{
            path = $etlPath
            sha256 = $etlSha256
            length = $EtlLength
            stopped_utc = $stoppedUtc
            wpr_executable = 'fake-wpr.exe'
            profile = 'NxbMinimalCpuScheduler'
            profile_provenance = $profile
            profile_provenance_sha256 = $profileSeal
            profile_integrity = [ordered]@{
                status = 'valid'
                reason = $null
            }
        }
        Write-NxbJsonAtomic `
            -Path (Join-Path $tracesRoot 'performance.etl.json') `
            -InputObject $etlMetadata `
            -Depth 16

        $analysisRoot = Join-Path $ExperimentPath 'analysis'
        New-Item -ItemType Directory -Path $analysisRoot -Force | Out-Null
        $eventsCounter = if ($EventsStatus -eq 'measured') {
            [ordered]@{
                status = 'measured'
                value = $EventsLost
                source = ('wpr_status_snapshot:' + ('5' * 64) + ';field=collector_events_lost')
                reason = $null
            }
        }
        else {
            [ordered]@{
                status = 'failed'
                value = $null
                source = $null
                reason = 'Synthetic WPR status failure.'
            }
        }
        $snapshot = [ordered]@{
            schema_version = 1
            captured_utc = $stoppedUtc
            experiment_id = [string](Split-Path -Leaf $ExperimentPath)
            command = [ordered]@{
                executable = 'fake-wpr.exe'
                arguments = @('-status', 'collectors', '-details')
            }
            status = if ($EventsStatus -eq 'measured') { 'measured' } else { 'failed' }
            exit_code = if ($EventsStatus -eq 'measured') { 0 } else { 9 }
            raw_output_sha256 = ('5' * 64)
            raw_output = @('synthetic')
            events_lost = $eventsCounter
            buffers_lost = [ordered]@{
                status = 'unsupported'
                value = $null
                source = $null
                reason = 'Not exposed by WPR status.'
            }
            realtime_buffers_lost = [ordered]@{
                status = 'not_applicable'
                value = $null
                source = $null
                reason = 'File-mode capture has no real-time consumer.'
            }
        }
        Write-NxbJsonAtomic `
            -Path (Join-Path $analysisRoot 'wpr-status-pre-stop.json') `
            -InputObject $snapshot `
            -Depth 16

        Set-NxbExperimentState `
            -ExperimentPath $ExperimentPath `
            -State stopped `
            -Confirm:$false | Out-Null
    }
}

Describe 'NXB trace-loss accounting collector' {
    BeforeEach {
        $script:TempRoot = Join-Path `
            ([IO.Path]::GetTempPath()) `
            ("nxb-trace-loss-collector-{0}" -f [guid]::NewGuid())
        & (Join-Path $script:ScriptsRoot 'Initialize-Lab.ps1') `
            -Root $script:TempRoot `
            -Role Target | Out-Null
        $script:ExperimentPath = & (Join-Path $script:ScriptsRoot 'New-Experiment.ps1') `
            -Root $script:TempRoot `
            -Name 'Trace-Loss-Collector-Test' `
            -Hypothesis 'Trace-loss accounting remains conservative'
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force
        }
    }

    It 'keeps zero partial native counters as not assessed' {
        Initialize-NxbTraceLossFixture -ExperimentPath $script:ExperimentPath

        $result = & $script:Collector `
            -ExperimentPath $script:ExperimentPath `
            -PassThru `
            -Confirm:$false

        $result.trace_loss.classification | Should -Be 'not_assessed'
        $result.trace_loss.measured_counter_count | Should -Be 1
        $result.circular_overwrite.classification | Should -Be 'no_risk_observed'
        $result.summary.evidence_completeness | Should -Be 'partial'
        $result.claims.capture_completeness | Should -Be 'not_claimed'
    }

    It 'classifies a positive measured counter as native loss observed' {
        Initialize-NxbTraceLossFixture `
            -ExperimentPath $script:ExperimentPath `
            -EventsLost 4

        $result = & $script:Collector `
            -ExperimentPath $script:ExperimentPath `
            -PassThru `
            -Confirm:$false

        $result.trace_loss.classification | Should -Be 'native_loss_observed'
        $result.trace_loss.total_reported_loss | Should -Be 4
        $result.summary.trace_loss_assessed | Should -BeTrue
        $result.summary.evidence_completeness | Should -Be 'complete'
    }

    It 'classifies a near-capacity circular ETL as risk observed' {
        Initialize-NxbTraceLossFixture `
            -ExperimentPath $script:ExperimentPath `
            -EtlLength 950000

        $result = & $script:Collector `
            -ExperimentPath $script:ExperimentPath `
            -PassThru `
            -Confirm:$false

        $result.circular_overwrite.classification | Should -Be 'risk_observed'
        $result.circular_overwrite.risk_reasons |
            Should -Contain 'capacity_threshold_reached'
    }

    It 'keeps a missing status snapshot explicitly not assessed' {
        Initialize-NxbTraceLossFixture -ExperimentPath $script:ExperimentPath
        Remove-Item `
            -LiteralPath (Join-Path $script:ExperimentPath 'analysis\wpr-status-pre-stop.json') `
            -Force

        $result = & $script:Collector `
            -ExperimentPath $script:ExperimentPath `
            -PassThru `
            -Confirm:$false

        $result.trace_loss.classification | Should -Be 'not_assessed'
        $result.trace_loss.measured_counter_count | Should -Be 0
        $result.native_counters.events_lost.status | Should -Be 'not_assessed'
    }

    It 'propagates a failed native status source into failed evidence' {
        Initialize-NxbTraceLossFixture `
            -ExperimentPath $script:ExperimentPath `
            -EventsStatus failed

        $result = & $script:Collector `
            -ExperimentPath $script:ExperimentPath `
            -PassThru `
            -Confirm:$false

        $result.trace_loss.classification | Should -Be 'failed'
        $result.summary.evidence_completeness | Should -Be 'failed'
        $result.claims.trace_loss_absence | Should -BeFalse
    }

    It 'rejects ETL metadata that does not match the actual ETL' {
        Initialize-NxbTraceLossFixture -ExperimentPath $script:ExperimentPath
        $metadataPath = Join-Path `
            $script:ExperimentPath `
            'traces\performance.etl.json'
        $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
        $metadata.length = [int64]$metadata.length + 1
        Write-NxbJsonAtomic -Path $metadataPath -InputObject $metadata -Depth 16

        {
            & $script:Collector `
                -ExperimentPath $script:ExperimentPath `
                -Confirm:$false
        } | Should -Throw '*gerçek ETL ile uyuşmuyor*'
    }

    It 'rejects accounting before the experiment reaches stopped state' {
        Initialize-NxbTraceLossFixture -ExperimentPath $script:ExperimentPath
        $manifestPath = Join-Path $script:ExperimentPath 'manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $manifest.status = 'recording'
        Write-NxbJsonAtomic -Path $manifestPath -InputObject $manifest -Depth 16

        {
            & $script:Collector `
                -ExperimentPath $script:ExperimentPath `
                -Confirm:$false
        } | Should -Throw '*yalnız stopped deneyde*'
    }
}
