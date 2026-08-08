[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$SourceSummaryPath,

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
    [string]$ReplayOutputPath,

    [Parameter()]
    [ValidateRange(1, 5000000)]
    [int]$MaxEventCount = 1000000,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-NxbStorageReplayFile {
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
    throw 'Storage downstream replay validation requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Storage downstream replay validation must run in PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}

$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'Storage downstream replay validation requires a clean exact-head worktree.'
}

$sourceSummaryFull = Resolve-NxbStorageReplayFile -Path $SourceSummaryPath -Label 'Source storage summary'
$captureFull = Resolve-NxbStorageReplayFile -Path $CaptureReceiptPath -Label 'Capture receipt'
$bridgeFull = Resolve-NxbStorageReplayFile -Path $BridgeManifestPath -Label 'Bridge manifest'
$eventExportFull = Resolve-NxbStorageReplayFile -Path $EventExportPath -Label 'Storage event export'
$etlFull = Resolve-NxbStorageReplayFile -Path $EtlPath -Label 'Storage ETL'
$replayOutputFull = [IO.Path]::GetFullPath($ReplayOutputPath)

if ($sourceSummaryFull -ceq $replayOutputFull) {
    throw 'SourceSummaryPath and ReplayOutputPath must be different files.'
}
if (Test-Path -LiteralPath $replayOutputFull) {
    throw "ReplayOutputPath already exists: $replayOutputFull"
}

$sourceSummary = Get-Content -LiteralPath $sourceSummaryFull -Raw | ConvertFrom-Json
$capture = Get-Content -LiteralPath $captureFull -Raw | ConvertFrom-Json
$bridge = Get-Content -LiteralPath $bridgeFull -Raw | ConvertFrom-Json

$eventExportSha = (
    Get-FileHash -LiteralPath $eventExportFull -Algorithm SHA256
).Hash.ToLowerInvariant()
$etlSha = (
    Get-FileHash -LiteralPath $etlFull -Algorithm SHA256
).Hash.ToLowerInvariant()
$sourceSummarySha = (
    Get-FileHash -LiteralPath $sourceSummaryFull -Algorithm SHA256
).Hash.ToLowerInvariant()

if ([string]$sourceSummary.event_export_sha256 -cne $eventExportSha) {
    throw 'Source summary normalized event-export SHA-256 does not match the replay input.'
}
if ([string]$sourceSummary.trace_sha256 -cne $etlSha) {
    throw 'Source summary ETL SHA-256 does not match the replay input.'
}
if ([string]$sourceSummary.profile_sha256 -cne [string]$capture.profile.sha256) {
    throw 'Source summary profile provenance does not match the capture receipt.'
}
if ([string]$sourceSummary.quality.trace_loss -cne [string]$capture.trace_quality.trace_loss -or
    [string]$sourceSummary.quality.circular_overwrite -cne [string]$capture.trace_quality.circular_overwrite -or
    [string]$sourceSummary.quality.parser_completeness -cne [string]$bridge.parser_completeness) {
    throw 'Source summary quality provenance does not match preserved capture/bridge evidence.'
}
if ([int]$bridge.normalized_event_count -le 0) {
    throw 'Bridge manifest normalized_event_count must be positive.'
}

$realSummaryRunner = Join-Path $PSScriptRoot 'Invoke-NxbStorageRealSummaryValidation.ps1'
if (-not (Test-Path -LiteralPath $realSummaryRunner -PathType Leaf)) {
    throw "Real storage summary validation runner missing: $realSummaryRunner"
}

$replayValidation = & $realSummaryRunner `
    -ExpectedHead $currentHead `
    -CaptureReceiptPath $captureFull `
    -BridgeManifestPath $bridgeFull `
    -EventExportPath $eventExportFull `
    -EtlPath $etlFull `
    -OutputPath $replayOutputFull `
    -MaxEventCount $MaxEventCount `
    -PassThru

if ([string]$replayValidation.status -cne 'passed' -or
    [int]$replayValidation.normalized_event_count -ne [int]$bridge.normalized_event_count) {
    throw 'Real storage summary replay did not pass cleanly.'
}

$replaySummary = Get-Content -LiteralPath $replayOutputFull -Raw | ConvertFrom-Json
$replaySummarySha = (
    Get-FileHash -LiteralPath $replayOutputFull -Algorithm SHA256
).Hash.ToLowerInvariant()
$byteIdentical = $sourceSummarySha -ceq $replaySummarySha
if (-not $byteIdentical) {
    throw (
        "Storage downstream replay is not byte-identical.`n" +
        "source=$sourceSummarySha`n" +
        "replay=$replaySummarySha"
    )
}

foreach ($propertyName in @(
    'summary_id',
    'experiment_id',
    'machine_id',
    'boot_id',
    'trace_sha256',
    'profile_sha256',
    'event_export_sha256',
    'adapter_sha256',
    'source_format',
    'trace_start_utc',
    'trace_end_utc'
)) {
    if ([string]$sourceSummary.$propertyName -cne [string]$replaySummary.$propertyName) {
        throw "Replay provenance identity mismatch: $propertyName"
    }
}

if ([int]$sourceSummary.summary.process_count -ne [int]$replaySummary.summary.process_count -or
    [int]$sourceSummary.summary.measured_event_class_count -ne [int]$replaySummary.summary.measured_event_class_count -or
    [int]$sourceSummary.summary.measured_metric_count -ne [int]$replaySummary.summary.measured_metric_count -or
    [string]$sourceSummary.summary.evidence_completeness -cne [string]$replaySummary.summary.evidence_completeness) {
    throw 'Replay summary accounting identity mismatch.'
}

if ([int]$replaySummary.summary.measured_metric_count -ne 0 -or
    [string]$replaySummary.events.split_io.status -cne 'not_assessed' -or
    [bool]$replaySummary.claims.queue_depth_semantics -or
    [bool]$replaySummary.claims.queue_latency_semantics -or
    [bool]$replaySummary.claims.service_time_semantics -or
    [bool]$replaySummary.claims.throughput_representativeness -or
    [bool]$replaySummary.claims.iops_representativeness -or
    [string]$replaySummary.claims.trace_completeness -cne 'not_claimed') {
    throw 'Replay promoted a forbidden storage metric/claim.'
}

$postDirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) {
    throw 'Storage downstream replay validation dirtied the exact-head worktree.'
}

$result = [pscustomobject][ordered]@{
    status = 'passed'
    head_sha = $currentHead
    source_summary_path = $sourceSummaryFull
    replay_summary_path = $replayOutputFull
    source_summary_sha256 = $sourceSummarySha
    replay_summary_sha256 = $replaySummarySha
    byte_identical_summary = $byteIdentical
    normalized_event_count = [int]$replayValidation.normalized_event_count
    process_count = [int]$replaySummary.summary.process_count
    measured_event_class_count = [int]$replaySummary.summary.measured_event_class_count
    measured_metric_count = [int]$replaySummary.summary.measured_metric_count
    parser_completeness = [string]$replaySummary.quality.parser_completeness
    evidence_completeness = [string]$replaySummary.summary.evidence_completeness
    trace_loss = [string]$replaySummary.quality.trace_loss
    circular_overwrite = [string]$replaySummary.quality.circular_overwrite
    split_io_status = [string]$replaySummary.events.split_io.status
    claims = $replaySummary.claims
}

Write-Information -MessageData "Storage downstream replay validation passed: $currentHead" -InformationAction Continue
Write-Information -MessageData "Source summary SHA-256: $sourceSummarySha" -InformationAction Continue
Write-Information -MessageData "Replay summary SHA-256: $replaySummarySha" -InformationAction Continue
Write-Information -MessageData "Byte-identical summary: $byteIdentical" -InformationAction Continue
Write-Information -MessageData "Normalized event count: $($result.normalized_event_count)" -InformationAction Continue
Write-Information -MessageData "Measured event classes: $($result.measured_event_class_count)" -InformationAction Continue
Write-Information -MessageData "Measured metrics: $($result.measured_metric_count)" -InformationAction Continue
Write-Information -MessageData "split_io status: $($result.split_io_status)" -InformationAction Continue

if ($PassThru) {
    return $result
}
