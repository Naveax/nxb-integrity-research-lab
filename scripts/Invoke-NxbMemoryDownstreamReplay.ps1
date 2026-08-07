[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedReplayHead,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedSourceCaptureHead,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$SourceCaptureDirectory,

    [Parameter()]
    [string]$OutputDirectory,

    [Parameter()]
    [ValidateRange(1, 5000000)]
    [int]$MaxEventCount = 1000000,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-NxbMemoryReplayJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object]$InputObject
    )

    [IO.File]::WriteAllText(
        $Path,
        ($InputObject | ConvertTo-Json -Depth 32),
        [Text.UTF8Encoding]::new($false)
    )
}

function Assert-NxbNormalFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label not found: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label cannot be a reparse point: $Path"
    }
}

function Get-NxbCanonicalReplayTimeTicks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [datetime]$Value
    )

    $utcTicks = $Value.ToUniversalTime().Ticks
    return $utcTicks - ($utcTicks % 10)
}

if ($env:OS -cne 'Windows_NT') {
    throw 'Memory downstream replay requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Memory downstream replay must run in PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or
    $currentHead -cne $ExpectedReplayHead.ToLowerInvariant()) {
    throw "Exact replay-head mismatch. Expected: $ExpectedReplayHead; actual: $currentHead"
}
$workingTree = @(
    & $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all
)
if ($LASTEXITCODE -ne 0 -or $workingTree.Count -gt 0) {
    throw 'Memory downstream replay requires a clean exact-head worktree.'
}

$adapterPath = Join-Path $PSScriptRoot 'ConvertFrom-NxbMemoryEventExport.ps1'
$validatorPath = Join-Path $PSScriptRoot 'Test-MemoryEtlSummary.ps1'
foreach ($required in @($adapterPath, $validatorPath, $PSCommandPath)) {
    Assert-NxbNormalFile -Path $required -Label 'Repository replay input'
}

$sourceFull = [IO.Path]::GetFullPath($SourceCaptureDirectory)
$sourceItem = Get-Item -LiteralPath $sourceFull -Force
if (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "SourceCaptureDirectory cannot be a reparse point: $sourceFull"
}

$receiptPath = Join-Path $sourceFull 'memory-real-capture-receipt.json'
$eventExportPath = Join-Path $sourceFull 'bridge\memory-event-export.csv'
$bridgeManifestPath = Join-Path `
    $sourceFull `
    'bridge\memory-xperf-bridge-manifest.json'
$sourceSummaryPath = Join-Path $sourceFull 'memory-etl-summary.json'
foreach ($pair in @(
    @($receiptPath, 'Source receipt'),
    @($eventExportPath, 'Source normalized event export'),
    @($bridgeManifestPath, 'Source bridge manifest'),
    @($sourceSummaryPath, 'Source memory ETL summary')
)) {
    Assert-NxbNormalFile -Path ([string]$pair[0]) -Label ([string]$pair[1])
}

$receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
$bridgeManifest = Get-Content -LiteralPath $bridgeManifestPath -Raw |
    ConvertFrom-Json
$sourceSummary = Get-Content -LiteralPath $sourceSummaryPath -Raw |
    ConvertFrom-Json

& $validatorPath -Path $sourceSummaryPath

$expectedSourceHead = $ExpectedSourceCaptureHead.ToLowerInvariant()
if ([string]$receipt.status -cne 'passed') {
    throw "Source capture status is not passed: $($receipt.status)"
}
if (-not [string]::IsNullOrWhiteSpace([string]$receipt.failure)) {
    throw "Source capture contains a failure: $($receipt.failure)"
}
if ([string]$receipt.head_sha -cne $expectedSourceHead -or
    [string]$receipt.expected_head_sha -cne $expectedSourceHead) {
    throw (
        'Source capture head binding mismatch. expected=' +
        $expectedSourceHead +
        ' actual=' +
        [string]$receipt.head_sha
    )
}

$expectedExperimentId = 'memory-real-' + $expectedSourceHead.Substring(0, 12)
if ([string]$sourceSummary.experiment_id -cne $expectedExperimentId) {
    throw (
        'Source summary experiment_id is not bound to the source capture head. ' +
        "expected=$expectedExperimentId actual=$($sourceSummary.experiment_id)"
    )
}

$eventExportHash = (
    Get-FileHash -LiteralPath $eventExportPath -Algorithm SHA256
).Hash.ToLowerInvariant()
if ([string]$bridgeManifest.normalized_csv_sha256 -cne $eventExportHash) {
    throw 'Bridge manifest normalized_csv_sha256 does not match the source CSV.'
}
if ([string]$sourceSummary.event_export_sha256 -cne $eventExportHash) {
    throw 'Source summary event_export_sha256 does not match the source CSV.'
}
if ([int64]$bridgeManifest.normalized_event_count -le 0) {
    throw 'Source bridge manifest normalized_event_count must be positive.'
}
$coveredEventTypes = [string[]]@($bridgeManifest.covered_event_types)
if ($coveredEventTypes.Count -eq 0) {
    throw 'Source bridge manifest has no covered event types.'
}

$adapterHash = (
    Get-FileHash -LiteralPath $adapterPath -Algorithm SHA256
).Hash.ToLowerInvariant()
if ([string]$sourceSummary.adapter_sha256 -cne $adapterHash) {
    throw (
        'Replay adapter bytes differ from the adapter that produced the source ' +
        'summary; byte-identical replay cannot be claimed.'
    )
}

if ([string]$sourceSummary.machine_id -cne [string]$receipt.machine_id -or
    [string]$sourceSummary.boot_id -cne [string]$receipt.boot_id -or
    [string]$sourceSummary.trace_sha256 -cne [string]$receipt.evidence.etl_sha256 -or
    [string]$sourceSummary.profile_sha256 -cne [string]$receipt.profile.sha256) {
    throw 'Source summary provenance does not match the capture receipt.'
}
if ([int]$sourceSummary.target.process_id -ne [int]$receipt.workload.process_id -or
    [string]$sourceSummary.target.image_sha256 -cne [string]$receipt.workload.image_sha256) {
    throw 'Source summary target identity does not match the capture receipt.'
}

$sourceTraceStartTicks = Get-NxbCanonicalReplayTimeTicks `
    -Value ([datetime]$sourceSummary.trace_start_utc)
$receiptTraceStartTicks = Get-NxbCanonicalReplayTimeTicks `
    -Value ([datetime]$receipt.trace_started_utc)
$sourceTraceEndTicks = Get-NxbCanonicalReplayTimeTicks `
    -Value ([datetime]$sourceSummary.trace_end_utc)
$receiptTraceEndTicks = Get-NxbCanonicalReplayTimeTicks `
    -Value ([datetime]$receipt.trace_stopped_utc)
$sourceTargetStartTicks = Get-NxbCanonicalReplayTimeTicks `
    -Value ([datetime]$sourceSummary.target.process_start_utc)
$receiptTargetStartTicks = Get-NxbCanonicalReplayTimeTicks `
    -Value ([datetime]$receipt.workload.process_start_utc)
if ($sourceTraceStartTicks -ne $receiptTraceStartTicks -or
    $sourceTraceEndTicks -ne $receiptTraceEndTicks) {
    throw 'Source summary trace timing does not match the capture receipt.'
}
if ($sourceTargetStartTicks -ne $receiptTargetStartTicks) {
    throw 'Source summary target start time does not match the capture receipt.'
}

if ([string]$sourceSummary.quality.trace_loss -cne
        [string]$receipt.trace_quality.trace_loss -or
    [string]$sourceSummary.quality.circular_overwrite -cne
        [string]$receipt.trace_quality.circular_overwrite) {
    throw 'Source summary trace-quality state does not match the capture receipt.'
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $OutputDirectory = Join-Path `
        (Join-Path $HOME 'Downloads') `
        "nxb-memory-downstream-replay-$($currentHead.Substring(0, 12))-$stamp"
}
$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputFull) {
    throw "OutputDirectory already exists: $outputFull"
}
[IO.Directory]::CreateDirectory($outputFull) | Out-Null

$replaySummaryPath = Join-Path $outputFull 'memory-etl-summary-replay.json'
$resultPath = Join-Path $outputFull 'memory-downstream-replay-result.json'
$reviewDirectory = Join-Path $outputFull 'review'
[IO.Directory]::CreateDirectory($reviewDirectory) | Out-Null

& $adapterPath `
    -ExperimentId $expectedExperimentId `
    -InputPath $eventExportPath `
    -OutputPath $replaySummaryPath `
    -MachineId ([string]$receipt.machine_id) `
    -BootId ([string]$receipt.boot_id) `
    -TraceSha256 ([string]$receipt.evidence.etl_sha256) `
    -ProfileSha256 ([string]$receipt.profile.sha256) `
    -TraceStartUtc ([datetime]$receipt.trace_started_utc) `
    -TraceEndUtc ([datetime]$receipt.trace_stopped_utc) `
    -TargetProcessId ([int]$receipt.workload.process_id) `
    -TargetProcessStartUtc ([datetime]$receipt.workload.process_start_utc) `
    -TargetImageSha256 ([string]$receipt.workload.image_sha256) `
    -CoveredEventType $coveredEventTypes `
    -TraceLoss ([string]$receipt.trace_quality.trace_loss) `
    -CircularOverwrite ([string]$receipt.trace_quality.circular_overwrite) `
    -MaxEventCount $MaxEventCount

& $validatorPath -Path $replaySummaryPath

$sourceSummaryHash = (
    Get-FileHash -LiteralPath $sourceSummaryPath -Algorithm SHA256
).Hash.ToLowerInvariant()
$replaySummaryHash = (
    Get-FileHash -LiteralPath $replaySummaryPath -Algorithm SHA256
).Hash.ToLowerInvariant()
$sourceSummaryLength = (Get-Item -LiteralPath $sourceSummaryPath).Length
$replaySummaryLength = (Get-Item -LiteralPath $replaySummaryPath).Length
if ($sourceSummaryHash -cne $replaySummaryHash -or
    [int64]$sourceSummaryLength -ne [int64]$replaySummaryLength) {
    throw (
        'Downstream replay summary is not byte-identical to the source capture ' +
        "summary. source_sha256=$sourceSummaryHash replay_sha256=$replaySummaryHash"
    )
}

$replaySummary = Get-Content -LiteralPath $replaySummaryPath -Raw |
    ConvertFrom-Json
$result = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    replay_head_sha = $currentHead
    source_capture_head_sha = $expectedSourceHead
    source_capture_directory = $sourceFull
    source_receipt_sha256 = (
        Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    source_bridge_manifest_sha256 = (
        Get-FileHash -LiteralPath $bridgeManifestPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    event_export_sha256 = $eventExportHash
    normalized_event_count = [int64]$bridgeManifest.normalized_event_count
    source_summary_sha256 = $sourceSummaryHash
    replay_summary_sha256 = $replaySummaryHash
    byte_identical_summary = $true
    trace_loss = [string]$replaySummary.quality.trace_loss
    circular_overwrite = [string]$replaySummary.quality.circular_overwrite
    parser_completeness = [string]$replaySummary.quality.parser_completeness
    evidence_completeness = [string]$replaySummary.summary.evidence_completeness
    measured_event_class_count = [int]$replaySummary.summary.measured_event_class_count
    failed_event_class_count = [int]$replaySummary.summary.failed_event_class_count
    process_count = [int]$replaySummary.summary.process_count
    claims = $replaySummary.claims
    raw_etl_included = $false
    raw_dumper_included = $false
    normalized_csv_included = $false
}
Write-NxbMemoryReplayJson -Path $resultPath -InputObject $result

Copy-Item -LiteralPath $resultPath -Destination $reviewDirectory
Copy-Item -LiteralPath $receiptPath -Destination $reviewDirectory
Copy-Item -LiteralPath $bridgeManifestPath -Destination $reviewDirectory
Copy-Item `
    -LiteralPath $sourceSummaryPath `
    -Destination (Join-Path $reviewDirectory 'memory-etl-summary-source.json')
Copy-Item -LiteralPath $replaySummaryPath -Destination $reviewDirectory

$reviewParent = Split-Path -Parent $outputFull
$reviewZip = Join-Path `
    $reviewParent `
    (
        'nxb-memory-downstream-replay-' +
        $currentHead.Substring(0, 12) +
        '-' +
        [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') +
        '-review.zip'
    )
Compress-Archive `
    -Path (Join-Path $reviewDirectory '*') `
    -DestinationPath $reviewZip `
    -Force

Write-Host "Memory downstream replay source: $sourceFull"
Write-Host "Memory downstream replay summary: $replaySummaryPath"
Write-Host "Memory downstream replay result: $resultPath"
Write-Host "Memory downstream replay review ZIP: $reviewZip"
Write-Host 'Raw ETL, full dumper text and normalized CSV were not copied into the review ZIP.'

if ($PassThru) {
    $result
}
