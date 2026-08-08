[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$CaptureReceiptPath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$BridgeManifestPath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$EventExportPath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$EtlPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ExperimentId,

    [Parameter()]
    [ValidateRange(1, 5000000)]
    [int]$MaxEventCount = 1000000,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-NxbStorageNormalFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Label
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "$Label not found: $fullPath"
    }
    $item = Get-Item -LiteralPath $fullPath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label cannot be a reparse point: $fullPath"
    }
    return $fullPath
}

if ($env:OS -cne 'Windows_NT') {
    throw 'Real storage summary validation requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Real storage summary validation must run in PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}
$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'Real storage summary validation requires a clean exact-head worktree.'
}

$captureFull = Assert-NxbStorageNormalFile -Path $CaptureReceiptPath -Label 'Capture receipt'
$bridgeFull = Assert-NxbStorageNormalFile -Path $BridgeManifestPath -Label 'Bridge manifest'
$eventExportFull = Assert-NxbStorageNormalFile -Path $EventExportPath -Label 'Storage event export'
$etlFull = Assert-NxbStorageNormalFile -Path $EtlPath -Label 'Storage ETL'
$outputFull = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $outputFull) {
    throw "OutputPath already exists: $outputFull"
}

$capture = Get-Content -LiteralPath $captureFull -Raw | ConvertFrom-Json
$bridge = Get-Content -LiteralPath $bridgeFull -Raw | ConvertFrom-Json
if ([string]$capture.status -cne 'passed') {
    throw "Capture receipt status is not passed: $($capture.status)"
}
if ([int]$bridge.schema_version -ne 1 -or
    [string]$bridge.source_format -cne 'xperf_storage_dumper_text_v1' -or
    [int]$bridge.normalized_event_count -le 0) {
    throw 'Bridge manifest identity/count validation failed.'
}
if ([bool]$bridge.timing.normalized_duration_us_available) {
    throw 'Bridge unexpectedly exposes normalized duration_us.'
}

$eventExportSha = (
    Get-FileHash -LiteralPath $eventExportFull -Algorithm SHA256
).Hash.ToLowerInvariant()
$etlSha = (
    Get-FileHash -LiteralPath $etlFull -Algorithm SHA256
).Hash.ToLowerInvariant()
if ([string]$bridge.normalized_csv_sha256 -cne $eventExportSha) {
    throw 'Bridge manifest normalized CSV SHA-256 mismatch.'
}
if ($null -ne $capture.evidence.etl_sha256 -and
    -not [string]::IsNullOrWhiteSpace([string]$capture.evidence.etl_sha256) -and
    [string]$capture.evidence.etl_sha256 -cne $etlSha) {
    throw 'Capture receipt ETL SHA-256 mismatch.'
}

$adapterValidationPath = Join-Path $PSScriptRoot 'Invoke-NxbStorageSummaryAdapterLocalValidation.ps1'
$adapterPath = Join-Path $PSScriptRoot 'ConvertFrom-NxbStorageEventExport.ps1'
foreach ($requiredPath in @($adapterValidationPath, $adapterPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required real-summary dependency missing: $requiredPath"
    }
}

$adapterValidation = & $adapterValidationPath `
    -ExpectedHead $currentHead `
    -PassThru
if ([string]$adapterValidation.status -cne 'passed' -or
    [int]$adapterValidation.powershell7.Passed -ne 9 -or
    [int]$adapterValidation.powershell7.Failed -ne 0 -or
    [int]$adapterValidation.windows_powershell_51.Passed -ne 9 -or
    [int]$adapterValidation.windows_powershell_51.Failed -ne 0 -or
    [int]$adapterValidation.analyzer_findings -ne 0 -or
    [string]$adapterValidation.python_compile -cne 'passed') {
    throw 'Repository-native storage summary adapter validation did not pass cleanly.'
}

$coveredEventTypes = @(
    $bridge.row_counts.PSObject.Properties |
        ForEach-Object { [string]$_.Name } |
        Sort-Object
)
if ($coveredEventTypes.Count -le 0) {
    throw 'Bridge manifest reported no covered real event classes.'
}

$resolvedExperimentId = if ($PSBoundParameters.ContainsKey('ExperimentId')) {
    $ExperimentId
}
else {
    'storage-real-' + ([string]$capture.head_sha).Substring(0, 12)
}
$summary = & $adapterPath `
    -ExperimentId $resolvedExperimentId `
    -InputPath $eventExportFull `
    -OutputPath $outputFull `
    -MachineId ([string]$capture.machine_id) `
    -BootId ([string]$capture.boot_id) `
    -TraceSha256 $etlSha `
    -ProfileSha256 ([string]$capture.profile.sha256) `
    -TraceStartUtc ([datetime]$capture.trace_started_utc) `
    -TraceEndUtc ([datetime]$capture.trace_stopped_utc) `
    -TargetProcessId ([int]$capture.workload.process_id) `
    -TargetProcessStartUtc ([datetime]$capture.workload.process_start_utc) `
    -TargetImageSha256 ([string]$capture.workload.image_sha256) `
    -CoveredEventType $coveredEventTypes `
    -TraceLoss ([string]$capture.trace_quality.trace_loss) `
    -CircularOverwrite ([string]$capture.trace_quality.circular_overwrite) `
    -ParserCompleteness ([string]$bridge.parser_completeness) `
    -MaxEventCount $MaxEventCount `
    -PassThru

if ([string]$summary.trace_sha256 -cne $etlSha -or
    [string]$summary.event_export_sha256 -cne $eventExportSha -or
    [string]$summary.profile_sha256 -cne [string]$capture.profile.sha256 -or
    [string]$summary.quality.trace_loss -cne [string]$capture.trace_quality.trace_loss -or
    [string]$summary.quality.circular_overwrite -cne [string]$capture.trace_quality.circular_overwrite -or
    [string]$summary.quality.parser_completeness -cne [string]$bridge.parser_completeness) {
    throw 'Real storage summary provenance/quality propagation failed.'
}

$rows = @(Import-Csv -LiteralPath $eventExportFull)
if ($rows.Count -ne [int]$bridge.normalized_event_count) {
    throw 'Real storage CSV row count does not match bridge manifest.'
}

$byteEventTypes = @('disk_read', 'disk_write', 'file_read', 'file_write')
$aggregateRows = [Collections.Generic.List[object]]::new()
foreach ($eventType in $coveredEventTypes) {
    $sourceRows = @($rows | Where-Object { [string]$_.event_type -ceq $eventType })
    $entry = $summary.events.$eventType
    if ([string]$entry.status -cne 'measured' -or
        [int]$entry.count -ne $sourceRows.Count) {
        throw "Aggregate count/status mismatch for $eventType."
    }

    $expectedBytes = $null
    if ($eventType -in $byteEventTypes) {
        $byteRows = @(
            $sourceRows | Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_.transfer_bytes)
            }
        )
        if ($byteRows.Count -eq $sourceRows.Count) {
            [int64]$byteSum = 0
            foreach ($row in $byteRows) {
                $byteSum += [int64]$row.transfer_bytes
            }
            $expectedBytes = $byteSum
        }
    }

    if ($null -eq $expectedBytes) {
        if ($null -ne $entry.bytes) {
            throw "Unexpected byte total for $eventType."
        }
    }
    elseif ([int64]$entry.bytes -ne [int64]$expectedBytes) {
        throw "Aggregate byte total mismatch for $eventType."
    }

    $aggregateRows.Add([pscustomobject][ordered]@{
        event_type = $eventType
        count = [int]$entry.count
        bytes = $entry.bytes
        unattributed = [int]$entry.unattributed_count
        attribution = [string]$entry.attribution
    })
}

$targetPid = [int]$capture.workload.process_id
$targetDocuments = @($summary.processes | Where-Object { [bool]$_.is_target })
if ($targetDocuments.Count -ne 1 -or
    [int]$targetDocuments[0].process_id -ne $targetPid -or
    [string]$targetDocuments[0].identity_status -cne 'complete') {
    throw 'Target process identity validation failed.'
}

$targetRows = [Collections.Generic.List[object]]::new()
foreach ($eventType in $coveredEventTypes) {
    $csvTargetRows = @(
        $rows | Where-Object {
            [string]$_.event_type -ceq $eventType -and
            [string]$_.process_id -ceq [string]$targetPid
        }
    )
    $entry = $targetDocuments[0].events.$eventType
    if ([int]$entry.count -ne $csvTargetRows.Count) {
        throw "Target process count mismatch for $eventType."
    }
    $targetRows.Add([pscustomobject][ordered]@{
        event_type = $eventType
        count = [int]$entry.count
        bytes = $entry.bytes
    })
}

if ($coveredEventTypes -notcontains 'split_io') {
    if ([string]$summary.events.split_io.status -cne 'not_assessed' -or
        $null -ne $summary.events.split_io.count) {
        throw 'Unobserved split_io was promoted to measured/zero evidence.'
    }
}

foreach ($metric in @(
    'queue_depth',
    'queue_latency_us',
    'service_time_us',
    'throughput_bytes_per_second',
    'iops'
)) {
    $metricEntry = $summary.metrics.$metric
    if ([string]$metricEntry.status -cne 'not_assessed' -or
        $null -ne $metricEntry.statistics) {
        throw "Storage metric was prematurely enabled: $metric"
    }
}
if ([bool]$summary.claims.queue_depth_semantics -or
    [bool]$summary.claims.queue_latency_semantics -or
    [bool]$summary.claims.service_time_semantics -or
    [bool]$summary.claims.throughput_representativeness -or
    [bool]$summary.claims.iops_representativeness -or
    [string]$summary.claims.trace_completeness -cne 'not_claimed') {
    throw 'A forbidden storage summary claim was enabled.'
}

$postDirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) {
    throw 'Real storage summary validation dirtied the exact-head worktree.'
}

$result = [pscustomobject][ordered]@{
    status = 'passed'
    head_sha = $currentHead
    adapter_validation = $adapterValidation
    normalized_event_count = $rows.Count
    process_count = [int]$summary.summary.process_count
    measured_event_class_count = [int]$summary.summary.measured_event_class_count
    measured_metric_count = [int]$summary.summary.measured_metric_count
    parser_completeness = [string]$summary.quality.parser_completeness
    evidence_completeness = [string]$summary.summary.evidence_completeness
    trace_loss = [string]$summary.quality.trace_loss
    circular_overwrite = [string]$summary.quality.circular_overwrite
    split_io_status = [string]$summary.events.split_io.status
    event_export_sha256 = $eventExportSha
    trace_sha256 = $etlSha
    summary_path = $outputFull
    aggregate_rows = @($aggregateRows)
    target_rows = @($targetRows)
    claims = $summary.claims
}

Write-Information -MessageData "Real storage summary validation passed: $currentHead" -InformationAction Continue
Write-Information -MessageData "Normalized event count: $($result.normalized_event_count)" -InformationAction Continue
Write-Information -MessageData "Measured event classes: $($result.measured_event_class_count)" -InformationAction Continue
Write-Information -MessageData "Measured metrics: $($result.measured_metric_count)" -InformationAction Continue
Write-Information -MessageData "Parser completeness: $($result.parser_completeness)" -InformationAction Continue
Write-Information -MessageData "Evidence completeness: $($result.evidence_completeness)" -InformationAction Continue
Write-Information -MessageData "Trace loss: $($result.trace_loss)" -InformationAction Continue
Write-Information -MessageData "Circular overwrite: $($result.circular_overwrite)" -InformationAction Continue
Write-Information -MessageData "split_io status: $($result.split_io_status)" -InformationAction Continue

if ($PassThru) {
    return $result
}
