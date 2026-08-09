[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$InputPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$EventsOutputPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$CoverageOutputPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$SourceHead,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExperimentId,

    [Parameter()]
    [ValidateRange(1,2147483647)]
    [int]$TargetProcessId,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$toolPath = Join-Path $repositoryRoot 'tools\convert_superblock1_xperf_dumper.py'
if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
    throw "SUPERBLOCK normalizer tool missing: $toolPath"
}

$inputFull = [IO.Path]::GetFullPath($InputPath)
$eventsFull = [IO.Path]::GetFullPath($EventsOutputPath)
$coverageFull = [IO.Path]::GetFullPath($CoverageOutputPath)
if ($inputFull -ceq $eventsFull -or $inputFull -ceq $coverageFull -or $eventsFull -ceq $coverageFull) {
    throw 'Input and output paths must be distinct.'
}
foreach ($output in @($eventsFull,$coverageFull)) {
    if (Test-Path -LiteralPath $output) {
        throw "Output already exists: $output"
    }
    $parent = Split-Path -Parent $output
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
}

$python = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $python) {
    $python = Get-Command python -ErrorAction Stop
}

$arguments = @(
    $toolPath,
    '--input', $inputFull,
    '--events-output', $eventsFull,
    '--coverage-output', $coverageFull,
    '--source-head', $SourceHead.ToLowerInvariant(),
    '--experiment-id', $ExperimentId
)
if ($PSBoundParameters.ContainsKey('TargetProcessId')) {
    $arguments += @('--target-pid',[string]$TargetProcessId)
}

$output = @(& $python.Source @arguments 2>&1)
$exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
if ($exitCode -ne 0) {
    throw "SUPERBLOCK xperf normalizer failed: exit=$exitCode output=$($output -join ' ')"
}
if (-not (Test-Path -LiteralPath $eventsFull -PathType Leaf) -or
    -not (Test-Path -LiteralPath $coverageFull -PathType Leaf)) {
    throw 'SUPERBLOCK xperf normalizer did not produce both outputs.'
}

$coverage = Get-Content -LiteralPath $coverageFull -Raw | ConvertFrom-Json
if ([string]$coverage.status -cne 'passed') {
    throw 'SUPERBLOCK coverage receipt is not passed.'
}
if ([string]$coverage.source.head_sha -cne $SourceHead.ToLowerInvariant()) {
    throw 'SUPERBLOCK coverage source head mismatch.'
}
if ([string]$coverage.source.experiment_id -cne $ExperimentId) {
    throw 'SUPERBLOCK coverage experiment ID mismatch.'
}
if ([string]$coverage.claims.trace_completeness -cne 'not_claimed') {
    throw 'SUPERBLOCK normalizer unexpectedly promoted trace completeness.'
}
if ([bool]$coverage.claims.present_semantics -or
    [bool]$coverage.claims.gpu_queue_semantics -or
    [bool]$coverage.claims.network_connection_semantics -or
    [bool]$coverage.claims.network_latency_semantics -or
    [bool]$coverage.claims.kernel_lifecycle_semantics) {
    throw 'SUPERBLOCK normalizer unexpectedly promoted domain semantics.'
}

$result = [pscustomobject][ordered]@{
    status = 'passed'
    source_head = [string]$coverage.source.head_sha
    experiment_id = [string]$coverage.source.experiment_id
    input_sha256 = [string]$coverage.source.dumper_sha256
    events_output_path = $eventsFull
    events_output_sha256 = (Get-FileHash -LiteralPath $eventsFull -Algorithm SHA256).Hash.ToLowerInvariant()
    coverage_output_path = $coverageFull
    coverage_output_sha256 = (Get-FileHash -LiteralPath $coverageFull -Algorithm SHA256).Hash.ToLowerInvariant()
    recognized_header_shapes = [int]$coverage.headers.recognized_shapes
    normalized_rows = [int64]$coverage.rows.normalized_rows
    unresolved_schema_rows = [int64]$coverage.rows.unresolved_schema_rows
    target_pid_rows = $coverage.rows.target_pid_rows
    semantic_claims_enabled = $false
    trace_completeness = 'not_claimed'
}
Write-Information -MessageData "SUPERBLOCK xperf normalization passed: rows=$($result.normalized_rows) unresolved=$($result.unresolved_schema_rows)" -InformationAction Continue
if ($PassThru) { return $result }
