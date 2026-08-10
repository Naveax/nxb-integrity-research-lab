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

$canonicalSourceHead = '57dd8a466509bd390b94ad8426b2af6dd56c1687'
$canonicalDumperSha = 'c86beeec04a04e03cb7e6d683e01db5c3f7efbd1d26fca0cf5669684df19789d'
$canonicalEtlSha = '85c33dace6439b564703a84e96e4497cce7d10e55854e831973e4ed4ffee43ee'
$canonicalHeaderInventorySha = '704e5900a9c0478cccc25748d64f94682949d953b99c3c3dff3789fc2b2628c4'
$canonicalSourceReceiptSha = 'dba79369359d286939348a5d62719f651f7d1c1cf4e71977fe128e39ce420762'
$canonicalExperimentId = 'superblock1-mega-57dd8a466509-20260809T083641Z'
$canonicalTargetProcessId = 26928

function Write-NxbDownstreamJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$InputObject
    )
    [IO.File]::WriteAllText(
        $Path,
        (($InputObject | ConvertTo-Json -Depth 32) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

function Format-NxbCounterProperty {
    [CmdletBinding()]
    param(
        [Parameter()][object]$Object,
        [Parameter()][int]$Limit = 12
    )
    if ($null -eq $Object) { return 'none' }
    $items = @(
        $Object.PSObject.Properties |
            Sort-Object { [int64]$_.Value } -Descending |
            Select-Object -First $Limit |
            ForEach-Object { '{0}={1}' -f $_.Name,$_.Value }
    )
    if ($items.Count -eq 0) { return 'none' }
    return ($items -join ', ')
}

if ($env:OS -cne 'Windows_NT') { throw 'SUPERBLOCK downstream certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'SUPERBLOCK downstream certification requires PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected=$ExpectedHead actual=$currentHead"
}
$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'Downstream certification requires a clean exact-head worktree.'
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

$localValidationPath = Join-Path $PSScriptRoot 'Invoke-NxbSuperblock1DownstreamLocalValidation.ps1'
$normalizerPath = Join-Path $PSScriptRoot 'ConvertFrom-NxbSuperblock1XperfDumper.ps1'
foreach ($path in @($localValidationPath,$normalizerPath,$PSCommandPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required downstream component missing: $path" }
}

Write-Information -MessageData '=== SUPERBLOCK 1 DOWNSTREAM CERTIFICATION ===' -InformationAction Continue
Write-Information -MessageData '[1/6] Exact-head dual-runtime normalizer gate' -InformationAction Continue
$localGate = & $localValidationPath -ExpectedHead $ExpectedHead -PassThru
if ([string]$localGate.status -cne 'passed' -or [int]$localGate.analyzer_findings -ne 0 -or [string]$localGate.python_syntax -cne 'passed') {
    throw 'Downstream local gate did not pass cleanly.'
}

$dumperPath = Join-Path $sourceRoot 'raw-local\superblock1-xperf-dumper.txt'
$etlPath = Join-Path $sourceRoot 'raw-local\multi-domain-capture\traces\performance.etl'
$inventoryPath = Join-Path $sourceRoot 'raw-local\superblock1-xperf-header-inventory.json'
$sourceReceiptPath = Join-Path $sourceRoot 'review\superblock1-multi-domain-certification-receipt.json'
foreach ($path in @($dumperPath,$etlPath,$inventoryPath,$sourceReceiptPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Canonical source evidence missing: $path" }
}

Write-Information -MessageData '[2/6] Canonical source hash and receipt binding' -InformationAction Continue
$dumperSha = (Get-FileHash -LiteralPath $dumperPath -Algorithm SHA256).Hash.ToLowerInvariant()
$etlSha = (Get-FileHash -LiteralPath $etlPath -Algorithm SHA256).Hash.ToLowerInvariant()
$inventorySha = (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
$sourceReceiptSha = (Get-FileHash -LiteralPath $sourceReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($dumperSha -cne $canonicalDumperSha -or $etlSha -cne $canonicalEtlSha -or $inventorySha -cne $canonicalHeaderInventorySha -or $sourceReceiptSha -cne $canonicalSourceReceiptSha) {
    throw "Canonical source hash mismatch. dumper=$dumperSha etl=$etlSha inventory=$inventorySha receipt=$sourceReceiptSha"
}
$sourceReceipt = Get-Content -LiteralPath $sourceReceiptPath -Raw | ConvertFrom-Json
if ([string]$sourceReceipt.status -cne 'passed' -or [string]$sourceReceipt.head_sha -cne $canonicalSourceHead) {
    throw 'Canonical source receipt status/head mismatch.'
}
if ([uint64]$sourceReceipt.trace_quality.events_lost -ne 0 -or [uint64]$sourceReceipt.trace_quality.buffers_lost -ne 0) {
    throw 'Canonical source receipt is not native-loss-free.'
}
if ([int]$sourceReceipt.capture.header_count -ne 126) { throw 'Canonical source header count drifted.' }

$inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
if ([int]$inventory.header_count -ne 126 -or [int]$inventory.candidate_counts.gpu_candidate -ne 8 -or [int]$inventory.candidate_counts.network_candidate -ne 19) {
    throw 'Canonical source header inventory counts drifted.'
}

Write-Information -MessageData '[3/6] Full local dumper normalization' -InformationAction Continue
$eventsPath = Join-Path $localRoot 'superblock1-normalized-events.jsonl'
$coveragePath = Join-Path $reviewRoot 'superblock1-downstream-coverage.json'
$schemaDiagnosticsPath = Join-Path $reviewRoot 'superblock1-downstream-schema-diagnostics.json'
$first = & $normalizerPath -InputPath $dumperPath -EventsOutputPath $eventsPath -CoverageOutputPath $coveragePath -SourceHead $canonicalSourceHead -ExperimentId $canonicalExperimentId -TargetProcessId $canonicalTargetProcessId -PassThru
$coverage = Get-Content -LiteralPath $coveragePath -Raw | ConvertFrom-Json

$diagnosticStatus = if ([int64]$coverage.rows.unresolved_schema_rows -eq 0 -and [int64]$coverage.rows.recognized_malformed_rows -eq 0) { 'passed' } else { 'failed' }
$schemaDiagnostics = [pscustomobject][ordered]@{
    schema_version = 2
    status = $diagnosticStatus
    source_head = $canonicalSourceHead
    dumper_sha256 = $canonicalDumperSha
    normalized_rows = [int64]$coverage.rows.normalized_rows
    unresolved_schema_rows = [int64]$coverage.rows.unresolved_schema_rows
    malformed_rows = [int64]$coverage.rows.malformed_rows
    recognized_malformed_rows = [int64]$coverage.rows.recognized_malformed_rows
    schema_resolution = $coverage.schema_resolution
    raw_values_in_diagnostics = $false
}
Write-NxbDownstreamJson -Path $schemaDiagnosticsPath -InputObject $schemaDiagnostics

if ([int]$coverage.headers.unique_observed_shapes -ne 126) { throw "Normalizer observed unexpected header-shape count: $($coverage.headers.unique_observed_shapes)" }
if ([int]$coverage.headers.recognized_shapes -ne 73) { throw "Expected 73 structurally recognized header shapes; got $($coverage.headers.recognized_shapes)" }
if ([int64]$coverage.rows.normalized_rows -le 0) { throw 'Normalizer produced zero rows.' }
if ([int64]$coverage.rows.unresolved_schema_rows -ne 0) {
    $reasonSummary = Format-NxbCounterProperty -Object $coverage.schema_resolution.unresolved_reason_counts
    $eventSummary = Format-NxbCounterProperty -Object $coverage.schema_resolution.unresolved_event_counts
    $rowLengthSummary = Format-NxbCounterProperty -Object $coverage.schema_resolution.unresolved_row_length_counts
    throw (
        "Normalizer has unresolved schema rows: $($coverage.rows.unresolved_schema_rows); " +
        "reasons: $reasonSummary; events: $eventSummary; row_lengths: $rowLengthSummary"
    )
}
if ([int64]$coverage.rows.recognized_malformed_rows -ne 0) {
    $malformedSummary = Format-NxbCounterProperty -Object $coverage.schema_resolution.recognized_malformed_event_counts
    throw "Normalizer has recognized malformed rows: $($coverage.rows.recognized_malformed_rows); events: $malformedSummary"
}
if ([int64]$coverage.rows.normalized_rows -ne [int64]$coverage.rows.recognized_candidate_rows) {
    throw "Normalized/candidate row mismatch: normalized=$($coverage.rows.normalized_rows) candidate=$($coverage.rows.recognized_candidate_rows)"
}

Write-Information -MessageData '[4/6] Deterministic full-row replay' -InformationAction Continue
$replayEventsPath = Join-Path $localRoot 'superblock1-normalized-events-replay.jsonl'
$replayCoveragePath = Join-Path $localRoot 'superblock1-downstream-coverage-replay.json'
$second = & $normalizerPath -InputPath $dumperPath -EventsOutputPath $replayEventsPath -CoverageOutputPath $replayCoveragePath -SourceHead $canonicalSourceHead -ExperimentId $canonicalExperimentId -TargetProcessId $canonicalTargetProcessId -PassThru
$eventsByteIdentical = [string]$first.events_output_sha256 -ceq [string]$second.events_output_sha256
$coverageByteIdentical = [string]$first.coverage_output_sha256 -ceq [string]$second.coverage_output_sha256
if (-not $eventsByteIdentical -or -not $coverageByteIdentical) {
    throw "Downstream replay mismatch. events=$eventsByteIdentical coverage=$coverageByteIdentical"
}

Write-Information -MessageData '[5/6] Structural semantics-boundary receipt' -InformationAction Continue
$eventNames = @($inventory.headers | ForEach-Object { [string]$_.event_name })
$presentHeadersObserved = @($eventNames | Where-Object { $_ -like 'Microsoft-Windows-DXGI/Present/*' }).Count -ge 2
$tcpHeadersObserved = @($eventNames | Where-Object { $_ -in @('TcpSend','TcpRecv','TcpConnect','TcpDisconnect','TcpRetransmit') }).Count -ge 5
$processHeadersObserved = @($eventNames | Where-Object { $_ -in @('P-Start','P-End') }).Count -eq 2
$threadHeadersObserved = @($eventNames | Where-Object { $_ -in @('T-Start','T-End') }).Count -eq 2
$imageHeadersObserved = @($eventNames | Where-Object { $_ -in @('I-Start','I-End') }).Count -eq 2
$registryHeadersObserved = @($eventNames | Where-Object { $_ -like 'Reg*' }).Count -gt 0
$semanticsPath = Join-Path $reviewRoot 'superblock1-downstream-semantics-boundary.json'
$semantics = [pscustomobject][ordered]@{
    schema_version = 2
    status = 'passed'
    source_head = $canonicalSourceHead
    source_dumper_sha256 = $canonicalDumperSha
    observed_shapes = [ordered]@{
        dxgi_present_headers = $presentHeadersObserved
        tcp_core_headers = $tcpHeadersObserved
        process_start_end_headers = $processHeadersObserved
        thread_start_end_headers = $threadHeadersObserved
        image_start_end_headers = $imageHeadersObserved
        registry_headers = $registryHeadersObserved
    }
    normalization = [ordered]@{
        recognized_header_shapes = [int]$coverage.headers.recognized_shapes
        normalized_rows = [int64]$coverage.rows.normalized_rows
        recognized_candidate_rows = [int64]$coverage.rows.recognized_candidate_rows
        target_pid_rows = $coverage.rows.target_pid_rows
        malformed_source_fragments = [int64]$coverage.rows.malformed_rows
        recognized_malformed_rows = [int64]$coverage.rows.recognized_malformed_rows
        opaque_tail_rows = [int64]$coverage.schema_resolution.opaque_tail_rows
        opaque_tail_field_count = [int64]$coverage.schema_resolution.opaque_tail_field_count
        domain_counts = $coverage.domain_counts
        family_counts = $coverage.family_counts
        schema_resolution = $coverage.schema_resolution
        event_rows_local_only = $true
    }
    claims = [ordered]@{
        structural_event_name_mapping = $true
        active_header_structural_binding = $true
        nonempty_extra_columns_preserved_as_opaque = $true
        opaque_tail_semantics_resolved = $false
        timestamp_unit_resolved = $false
        dxgi_present_pairing_validated = $false
        present_semantics = $false
        gpu_queue_semantics = $false
        tcp_connection_lifecycle_validated = $false
        network_connection_semantics = $false
        network_latency_semantics = $false
        kernel_lifecycle_semantics = $false
        registry_elapsed_time_unit_resolved = $false
        trace_completeness = 'not_claimed'
    }
}
Write-NxbDownstreamJson -Path $semanticsPath -InputObject $semantics

Write-Information -MessageData '[6/6] Bounded downstream receipt and review ZIP' -InformationAction Continue
$receiptPath = Join-Path $reviewRoot 'superblock1-downstream-certification-receipt.json'
$receipt = [pscustomobject][ordered]@{
    schema_version = 3
    status = 'passed'
    implementation_head = $currentHead
    source = [ordered]@{
        head_sha = $canonicalSourceHead
        experiment_id = $canonicalExperimentId
        target_process_id = $canonicalTargetProcessId
        etl_sha256 = $canonicalEtlSha
        dumper_sha256 = $canonicalDumperSha
        header_inventory_sha256 = $canonicalHeaderInventorySha
        source_receipt_sha256 = $canonicalSourceReceiptSha
        events_lost = 0
        buffers_lost = 0
        buffers_written = [uint64]$sourceReceipt.trace_quality.buffers_written
    }
    validation = [ordered]@{
        powershell7 = "$($localGate.powershell7.passed)/$($localGate.powershell7.total)"
        windows_powershell_51 = "$($localGate.windows_powershell_51.passed)/$($localGate.windows_powershell_51.total)"
        analyzer_findings = 0
        python_syntax = 'passed'
    }
    normalization = [ordered]@{
        unique_observed_header_shapes = [int]$coverage.headers.unique_observed_shapes
        recognized_header_shapes = [int]$coverage.headers.recognized_shapes
        source_data_rows = [int64]$coverage.rows.source_data_rows
        recognized_candidate_rows = [int64]$coverage.rows.recognized_candidate_rows
        normalized_rows = [int64]$coverage.rows.normalized_rows
        unresolved_schema_rows = [int64]$coverage.rows.unresolved_schema_rows
        malformed_rows = [int64]$coverage.rows.malformed_rows
        recognized_malformed_rows = [int64]$coverage.rows.recognized_malformed_rows
        target_pid_rows = $coverage.rows.target_pid_rows
        schema_resolution = $coverage.schema_resolution
        domain_counts = $coverage.domain_counts
        family_counts = $coverage.family_counts
        normalized_events_sha256 = [string]$first.events_output_sha256
        coverage_sha256 = [string]$first.coverage_output_sha256
    }
    replay = [ordered]@{
        normalized_events_byte_identical = $eventsByteIdentical
        coverage_byte_identical = $coverageByteIdentical
        replay_events_sha256 = [string]$second.events_output_sha256
        replay_coverage_sha256 = [string]$second.coverage_output_sha256
    }
    review_policy = [ordered]@{
        raw_etl_in_review_zip = $false
        full_xperf_dumper_in_review_zip = $false
        normalized_event_rows_in_review_zip = $false
        raw_field_values_in_review_zip = $false
        coverage_counts_in_review_zip = $true
        schema_diagnostics_in_review_zip = $true
    }
    claims = [ordered]@{
        structural_event_name_mapping = $true
        active_header_structural_binding = $true
        nonempty_extra_columns_preserved_as_opaque = $true
        opaque_tail_semantics_resolved = $false
        event_ids_validated = $false
        keyword_semantics_validated = $false
        timestamp_unit_resolved = $false
        present_semantics = $false
        gpu_queue_semantics = $false
        network_connection_semantics = $false
        network_latency_semantics = $false
        kernel_lifecycle_semantics = $false
        trace_completeness = 'not_claimed'
    }
}
Write-NxbDownstreamJson -Path $receiptPath -InputObject $receipt

$reviewZipPath = Join-Path $outputFull 'superblock1-downstream-certification-review.zip'
Compress-Archive -Path (Join-Path $reviewRoot '*') -DestinationPath $reviewZipPath -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($reviewZipPath)
try {
    foreach ($entry in $archive.Entries) {
        $lower = $entry.FullName.ToLowerInvariant()
        if ($lower.EndsWith('.etl') -or $lower.EndsWith('.jsonl') -or $lower.Contains('xperf-dumper')) {
            throw "Forbidden raw/local evidence entered downstream review ZIP: $($entry.FullName)"
        }
    }
}
finally {
    $archive.Dispose()
}

$postDirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) {
    throw 'Downstream certification dirtied the exact-head worktree.'
}

$result = [pscustomobject][ordered]@{
    status = 'passed'
    head_sha = $currentHead
    source_head = $canonicalSourceHead
    output_directory = $outputFull
    normalized_events_path_local = $eventsPath
    normalized_events_sha256 = [string]$first.events_output_sha256
    coverage_path = $coveragePath
    coverage_sha256 = [string]$first.coverage_output_sha256
    schema_diagnostics_path = $schemaDiagnosticsPath
    normalized_rows = [int64]$coverage.rows.normalized_rows
    recognized_candidate_rows = [int64]$coverage.rows.recognized_candidate_rows
    recognized_header_shapes = [int]$coverage.headers.recognized_shapes
    unresolved_schema_rows = [int64]$coverage.rows.unresolved_schema_rows
    malformed_rows = [int64]$coverage.rows.malformed_rows
    recognized_malformed_rows = [int64]$coverage.rows.recognized_malformed_rows
    opaque_tail_rows = [int64]$coverage.schema_resolution.opaque_tail_rows
    opaque_tail_field_count = [int64]$coverage.schema_resolution.opaque_tail_field_count
    target_pid_rows = $coverage.rows.target_pid_rows
    schema_resolution = $coverage.schema_resolution
    domain_counts = $coverage.domain_counts
    family_counts = $coverage.family_counts
    replay_events_byte_identical = $eventsByteIdentical
    replay_coverage_byte_identical = $coverageByteIdentical
    review_zip_path = $reviewZipPath
    review_zip_sha256 = (Get-FileHash -LiteralPath $reviewZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    semantic_claims_enabled = $false
    trace_completeness = 'not_claimed'
}
Write-Information -MessageData "SUPERBLOCK downstream certification passed: $currentHead" -InformationAction Continue
Write-Information -MessageData "Normalized rows: $($result.normalized_rows)/$($result.recognized_candidate_rows)" -InformationAction Continue
Write-Information -MessageData "Recognized shapes: $($result.recognized_header_shapes)/126" -InformationAction Continue
Write-Information -MessageData "Opaque-tail rows: $($result.opaque_tail_rows); fields: $($result.opaque_tail_field_count)" -InformationAction Continue
Write-Information -MessageData "Source malformed fragments: $($result.malformed_rows); recognized malformed: $($result.recognized_malformed_rows)" -InformationAction Continue
Write-Information -MessageData "Target PID rows: $($result.target_pid_rows)" -InformationAction Continue
Write-Information -MessageData "Replay events byte-identical: $eventsByteIdentical" -InformationAction Continue
Write-Information -MessageData "Replay coverage byte-identical: $coverageByteIdentical" -InformationAction Continue
Write-Information -MessageData "Review ZIP SHA256: $($result.review_zip_sha256)" -InformationAction Continue
if ($PassThru) { return $result }
