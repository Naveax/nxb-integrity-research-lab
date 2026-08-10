[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceRunRoot,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$canonicalCaptureHead = '57dd8a466509bd390b94ad8426b2af6dd56c1687'
$canonicalNormalizerHead = '7fd766d15faa9b2ca0197edf342a0f794f4d1f0b'
$canonicalExperimentId = 'superblock1-mega-57dd8a466509-20260809T083641Z'
$canonicalTargetProcessId = 26928
$canonicalNormalizedEventsSha = '269d93e00411d78e15ebfb2c4c5a6568b36addb78238d57d7809184a1a420f89'
$canonicalCoverageSha = '5756530354f42fb0be9741de7bd6119649a02a4a17505e75658663f8e36ce3aa'
$canonicalDownstreamReceiptSha = '8ee3d6c18f2c3d53ce45871a6c06e3fb21f0d4dd243ab4ecceb3ec221f58c9ed'

if ($env:OS -cne 'Windows_NT') { throw 'SUPERBLOCK correlation certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'SUPERBLOCK correlation certification requires PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected=$ExpectedHead actual=$currentHead"
}
$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'SUPERBLOCK correlation certification requires a clean exact-head worktree.'
}

$sourceRoot = [IO.Path]::GetFullPath($SourceRunRoot)
$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { throw "SourceRunRoot not found: $sourceRoot" }
if (Test-Path -LiteralPath $outputFull) { throw "OutputDirectory already exists: $outputFull" }
[IO.Directory]::CreateDirectory($outputFull) | Out-Null
$localRoot = Join-Path $outputFull 'raw-local'
$reviewRoot = Join-Path $outputFull 'review'
[IO.Directory]::CreateDirectory($localRoot) | Out-Null
[IO.Directory]::CreateDirectory($reviewRoot) | Out-Null

$localValidationPath = Join-Path $PSScriptRoot 'Invoke-NxbSuperblock1CorrelationLocalValidation.ps1'
$analysisPath = Join-Path $PSScriptRoot 'Invoke-NxbSuperblock1CorrelationAnalysis.ps1'
foreach ($path in @($localValidationPath,$analysisPath,$PSCommandPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required correlation component missing: $path" }
}

Write-Information -MessageData '=== SUPERBLOCK 1 CORRELATION CERTIFICATION ===' -InformationAction Continue
Write-Information -MessageData '[1/6] Exact-head dual-runtime correlation gate' -InformationAction Continue
$localGate = & $localValidationPath -ExpectedHead $ExpectedHead -PassThru
if ([string]$localGate.status -cne 'passed' -or
    [int]$localGate.powershell7.passed -ne 10 -or
    [int]$localGate.windows_powershell_51.passed -ne 10 -or
    [int]$localGate.analyzer_findings -ne 0 -or
    [string]$localGate.python_syntax -cne 'passed') {
    throw 'Correlation local gate did not pass cleanly.'
}

$eventsPath = Join-Path $sourceRoot 'raw-local\superblock1-normalized-events.jsonl'
$coveragePath = Join-Path $sourceRoot 'review\superblock1-downstream-coverage.json'
$downstreamReceiptPath = Join-Path $sourceRoot 'review\superblock1-downstream-certification-receipt.json'
foreach ($path in @($eventsPath,$coveragePath,$downstreamReceiptPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Canonical downstream evidence missing: $path" }
}

Write-Information -MessageData '[2/6] Canonical downstream hash and receipt binding' -InformationAction Continue
$eventsSha = (Get-FileHash -LiteralPath $eventsPath -Algorithm SHA256).Hash.ToLowerInvariant()
$coverageSha = (Get-FileHash -LiteralPath $coveragePath -Algorithm SHA256).Hash.ToLowerInvariant()
$downstreamReceiptSha = (Get-FileHash -LiteralPath $downstreamReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($eventsSha -cne $canonicalNormalizedEventsSha -or
    $coverageSha -cne $canonicalCoverageSha -or
    $downstreamReceiptSha -cne $canonicalDownstreamReceiptSha) {
    throw "Canonical downstream hash mismatch. events=$eventsSha coverage=$coverageSha receipt=$downstreamReceiptSha"
}
$downstreamReceipt = Get-Content -LiteralPath $downstreamReceiptPath -Raw | ConvertFrom-Json
if ([string]$downstreamReceipt.status -cne 'passed' -or
    [string]$downstreamReceipt.implementation_head -cne $canonicalNormalizerHead -or
    [string]$downstreamReceipt.source.head_sha -cne $canonicalCaptureHead) {
    throw 'Canonical downstream receipt status/head binding mismatch.'
}
if ([int64]$downstreamReceipt.normalization.normalized_rows -ne 188505 -or
    [int64]$downstreamReceipt.normalization.recognized_candidate_rows -ne 188505 -or
    [int64]$downstreamReceipt.normalization.unresolved_schema_rows -ne 0 -or
    [int64]$downstreamReceipt.normalization.recognized_malformed_rows -ne 0 -or
    -not [bool]$downstreamReceipt.replay.normalized_events_byte_identical -or
    -not [bool]$downstreamReceipt.replay.coverage_byte_identical) {
    throw 'Canonical downstream receipt does not satisfy the closed normalization/replay contract.'
}

Write-Information -MessageData '[3/6] Full local structural correlation' -InformationAction Continue
$recordsPath = Join-Path $localRoot 'superblock1-correlation-records.jsonl'
$summaryPath = Join-Path $reviewRoot 'superblock1-correlation-summary.json'
$first = & $analysisPath `
    -InputPath $eventsPath `
    -RecordsOutputPath $recordsPath `
    -SummaryOutputPath $summaryPath `
    -SourceHead $canonicalCaptureHead `
    -NormalizerHead $canonicalNormalizerHead `
    -ExperimentId $canonicalExperimentId `
    -TargetProcessId $canonicalTargetProcessId `
    -PassThru
$summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
if ([int64]$summary.source.normalized_event_rows -ne 188505) { throw 'Correlation source row count drifted.' }
if ([int64]$summary.target_pid.row_count -ne 6395) { throw "Target PID row count drifted: $($summary.target_pid.row_count)" }
if ([int64]$summary.observed.domain_counts.gpu -ne 575 -or
    [int64]$summary.observed.domain_counts.network -ne 203 -or
    [int64]$summary.observed.domain_counts.kernel_lifecycle -ne 187727) {
    throw 'Correlation input domain counts drifted from canonical downstream evidence.'
}
if ([int64]$summary.local_pair_record_count -le 0) { throw 'Correlation analyzer produced zero structural pairs.' }
if ([bool]$summary.claims.timestamp_unit_resolved -or
    [bool]$summary.claims.present_pairing_semantics -or
    [bool]$summary.claims.network_connection_semantics -or
    [bool]$summary.claims.kernel_lifecycle_semantics -or
    [bool]$summary.claims.causal_relationship_validated -or
    [bool]$summary.claims.root_cause_validated -or
    [string]$summary.claims.trace_completeness -cne 'not_claimed') {
    throw 'Correlation summary promoted a forbidden semantic claim.'
}

Write-Information -MessageData '[4/6] Deterministic correlation replay' -InformationAction Continue
$replayRecordsPath = Join-Path $localRoot 'superblock1-correlation-records-replay.jsonl'
$replaySummaryPath = Join-Path $localRoot 'superblock1-correlation-summary-replay.json'
$second = & $analysisPath `
    -InputPath $eventsPath `
    -RecordsOutputPath $replayRecordsPath `
    -SummaryOutputPath $replaySummaryPath `
    -SourceHead $canonicalCaptureHead `
    -NormalizerHead $canonicalNormalizerHead `
    -ExperimentId $canonicalExperimentId `
    -TargetProcessId $canonicalTargetProcessId `
    -PassThru
$recordsByteIdentical = [string]$first.records_output_sha256 -ceq [string]$second.records_output_sha256
$summaryByteIdentical = [string]$first.summary_output_sha256 -ceq [string]$second.summary_output_sha256
if (-not $recordsByteIdentical -or -not $summaryByteIdentical) {
    throw "Correlation replay mismatch. records=$recordsByteIdentical summary=$summaryByteIdentical"
}

Write-Information -MessageData '[5/6] Bounded correlation receipt' -InformationAction Continue
$receiptPath = Join-Path $reviewRoot 'superblock1-correlation-certification-receipt.json'
$receipt = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    implementation_head = $currentHead
    source = [ordered]@{
        capture_head = $canonicalCaptureHead
        normalizer_head = $canonicalNormalizerHead
        experiment_id = $canonicalExperimentId
        target_process_id = $canonicalTargetProcessId
        normalized_events_sha256 = $canonicalNormalizedEventsSha
        coverage_sha256 = $canonicalCoverageSha
        downstream_receipt_sha256 = $canonicalDownstreamReceiptSha
        normalized_event_rows = 188505
    }
    validation = [ordered]@{
        powershell7 = "$($localGate.powershell7.passed)/$($localGate.powershell7.total)"
        windows_powershell_51 = "$($localGate.windows_powershell_51.passed)/$($localGate.windows_powershell_51.total)"
        analyzer_findings = 0
        python_syntax = 'passed'
    }
    correlation = [ordered]@{
        local_pair_record_count = [int64]$summary.local_pair_record_count
        local_pair_records_sha256 = [string]$first.records_output_sha256
        summary_sha256 = [string]$first.summary_output_sha256
        target_pid_rows = [int64]$summary.target_pid.row_count
        target_pid_domain_counts = $summary.target_pid.domain_counts
        target_pid_family_counts = $summary.target_pid.family_counts
        three_domain_pid_count = [int64]$summary.cross_domain.three_domain_pid_count
        multi_domain_pid_count = [int64]$summary.cross_domain.multi_domain_pid_count
        pairing = $summary.pairing
        tcp = $summary.network.tcp
        dns = $summary.network.dns
        registry = $summary.kernel.registry
    }
    replay = [ordered]@{
        records_byte_identical = $recordsByteIdentical
        summary_byte_identical = $summaryByteIdentical
        replay_records_sha256 = [string]$second.records_output_sha256
        replay_summary_sha256 = [string]$second.summary_output_sha256
    }
    review_policy = [ordered]@{
        normalized_event_rows_in_review_zip = $false
        correlation_record_rows_in_review_zip = $false
        raw_identifier_values_in_review_zip = $false
        pair_key_hashes_in_review_zip = $false
        aggregate_correlation_summary_in_review_zip = $true
    }
    claims = [ordered]@{
        sequence_order_correlation = $true
        exact_pid_attribution = $true
        exact_tid_attribution_when_present = $true
        hashed_identifier_grouping = $true
        structural_start_stop_pairing = $true
        timestamp_unit_resolved = $false
        sequence_delta_is_time = $false
        present_pairing_semantics = $false
        present_success_semantics = $false
        gpu_queue_semantics = $false
        tcp_connection_lifecycle_validated = $false
        network_connection_semantics = $false
        network_latency_semantics = $false
        kernel_lifecycle_semantics = $false
        causal_relationship_validated = $false
        root_cause_validated = $false
        trace_completeness = 'not_claimed'
    }
}
[IO.File]::WriteAllText($receiptPath,(($receipt | ConvertTo-Json -Depth 32) + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))

Write-Information -MessageData '[6/6] Bounded correlation review ZIP' -InformationAction Continue
$reviewZipPath = Join-Path $outputFull 'superblock1-correlation-certification-review.zip'
Compress-Archive -Path (Join-Path $reviewRoot '*') -DestinationPath $reviewZipPath -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($reviewZipPath)
try {
    foreach ($entry in $archive.Entries) {
        $lower = $entry.FullName.ToLowerInvariant()
        if ($lower.EndsWith('.jsonl') -or $lower.Contains('normalized-events') -or $lower.Contains('correlation-records')) {
            throw "Forbidden local correlation evidence entered review ZIP: $($entry.FullName)"
        }
    }
}
finally { $archive.Dispose() }

$postDirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) { throw 'Correlation certification dirtied the exact-head worktree.' }

$result = [pscustomobject][ordered]@{
    status = 'passed'
    head_sha = $currentHead
    source_capture_head = $canonicalCaptureHead
    source_normalizer_head = $canonicalNormalizerHead
    output_directory = $outputFull
    records_path_local = $recordsPath
    records_sha256 = [string]$first.records_output_sha256
    summary_path = $summaryPath
    summary_sha256 = [string]$first.summary_output_sha256
    pair_record_count = [int64]$summary.local_pair_record_count
    target_pid_rows = [int64]$summary.target_pid.row_count
    target_pid_domain_counts = $summary.target_pid.domain_counts
    target_pid_family_counts = $summary.target_pid.family_counts
    cross_domain = $summary.cross_domain
    pairing = $summary.pairing
    tcp = $summary.network.tcp
    dns = $summary.network.dns
    registry = $summary.kernel.registry
    replay_records_byte_identical = $recordsByteIdentical
    replay_summary_byte_identical = $summaryByteIdentical
    review_zip_path = $reviewZipPath
    review_zip_sha256 = (Get-FileHash -LiteralPath $reviewZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    semantic_claims_enabled = $false
    trace_completeness = 'not_claimed'
}
Write-Information -MessageData "SUPERBLOCK correlation certification passed: $currentHead" -InformationAction Continue
Write-Information -MessageData "Structural pairs: $($result.pair_record_count)" -InformationAction Continue
Write-Information -MessageData "Target PID rows: $($result.target_pid_rows)" -InformationAction Continue
Write-Information -MessageData "Three-domain PID count: $($result.cross_domain.three_domain_pid_count)" -InformationAction Continue
Write-Information -MessageData "Replay records byte-identical: $recordsByteIdentical" -InformationAction Continue
Write-Information -MessageData "Replay summary byte-identical: $summaryByteIdentical" -InformationAction Continue
Write-Information -MessageData "Review ZIP SHA256: $($result.review_zip_sha256)" -InformationAction Continue
if ($PassThru) { return $result }
