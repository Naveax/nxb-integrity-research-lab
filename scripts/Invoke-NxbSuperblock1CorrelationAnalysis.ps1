[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$InputPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RecordsOutputPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SummaryOutputPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$SourceHead,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$NormalizerHead,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExperimentId,

    [Parameter(Mandatory)]
    [ValidateRange(1,[int]::MaxValue)]
    [int]$TargetProcessId,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$toolPath = Join-Path $repositoryRoot 'tools\analyze_superblock1_correlations.py'
if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
    throw "SUPERBLOCK correlation analyzer missing: $toolPath"
}

$inputFull = [IO.Path]::GetFullPath($InputPath)
$recordsFull = [IO.Path]::GetFullPath($RecordsOutputPath)
$summaryFull = [IO.Path]::GetFullPath($SummaryOutputPath)
if ($inputFull -ceq $recordsFull -or $inputFull -ceq $summaryFull -or $recordsFull -ceq $summaryFull) {
    throw 'Correlation input and output paths must be distinct.'
}
foreach ($outputPath in @($recordsFull,$summaryFull)) {
    if (Test-Path -LiteralPath $outputPath) {
        throw "Correlation output already exists: $outputPath"
    }
    $parent = Split-Path -Parent $outputPath
    [IO.Directory]::CreateDirectory($parent) | Out-Null
}

$python = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $python) {
    $python = Get-Command python -ErrorAction Stop
}

$output = @(
    & $python.Source $toolPath `
        --input $inputFull `
        --records-output $recordsFull `
        --summary-output $summaryFull `
        --source-head $SourceHead.ToLowerInvariant() `
        --normalizer-head $NormalizerHead.ToLowerInvariant() `
        --experiment-id $ExperimentId `
        --target-pid $TargetProcessId 2>&1
)
$exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
foreach ($line in $output) {
    Write-Verbose ([string]$line)
}
if ($exitCode -ne 0) {
    throw "SUPERBLOCK correlation analyzer failed: exit=$exitCode output=$($output -join ' ')"
}
if (-not (Test-Path -LiteralPath $recordsFull -PathType Leaf) -or
    -not (Test-Path -LiteralPath $summaryFull -PathType Leaf)) {
    throw 'SUPERBLOCK correlation analyzer did not produce both outputs.'
}

$summary = Get-Content -LiteralPath $summaryFull -Raw | ConvertFrom-Json
if ([string]$summary.status -cne 'passed') {
    throw "SUPERBLOCK correlation summary status is not passed: $($summary.status)"
}
$result = [pscustomobject][ordered]@{
    status = 'passed'
    records_output_path = $recordsFull
    records_output_sha256 = (Get-FileHash -LiteralPath $recordsFull -Algorithm SHA256).Hash.ToLowerInvariant()
    summary_output_path = $summaryFull
    summary_output_sha256 = (Get-FileHash -LiteralPath $summaryFull -Algorithm SHA256).Hash.ToLowerInvariant()
    normalized_event_rows = [int64]$summary.source.normalized_event_rows
    pair_record_count = [int64]$summary.local_pair_record_count
    target_pid_rows = [int64]$summary.target_pid.row_count
    semantic_claims_enabled = $false
    trace_completeness = 'not_claimed'
}
Write-Information -MessageData "SUPERBLOCK correlation analysis passed: rows=$($result.normalized_event_rows) pairs=$($result.pair_record_count)" -InformationAction Continue
if ($PassThru) { return $result }
