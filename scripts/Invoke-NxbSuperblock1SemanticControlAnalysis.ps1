[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$InputPath,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$ManifestPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$SourceHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExperimentId,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$toolPath = Join-Path $repositoryRoot 'tools\analyze_superblock1_semantic_controls.py'
if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
    throw "Semantic control analyzer is missing: $toolPath"
}
$inputFull = [IO.Path]::GetFullPath($InputPath)
$manifestFull = [IO.Path]::GetFullPath($ManifestPath)
$outputFull = [IO.Path]::GetFullPath($OutputPath)
if ($inputFull -ceq $outputFull -or $manifestFull -ceq $outputFull) {
    throw 'Semantic control analyzer input/output paths must be distinct.'
}
if (Test-Path -LiteralPath $outputFull) {
    throw "Semantic control analyzer output already exists: $outputFull"
}
[IO.Directory]::CreateDirectory((Split-Path -Parent $outputFull)) | Out-Null

$manifest = Get-Content -LiteralPath $manifestFull -Raw | ConvertFrom-Json
$scenarios = @($manifest.scenarios)
if ($scenarios.Count -ne 10) {
    throw "Semantic control manifest must contain exactly 10 scenarios: actual=$($scenarios.Count)"
}
$pids = @(
    foreach ($scenario in $scenarios) {
        $pidValue = [int]$scenario.pid
        if ($pidValue -le 0) {
            throw "Semantic control manifest contains invalid PID: $pidValue"
        }
        $pidValue
    }
)
$uniquePids = @($pids | Sort-Object -Unique)
if ($uniquePids.Count -ne 10) {
    throw "Semantic control fixture PIDs must be unique: scenarios=10 unique_pids=$($uniquePids.Count)"
}

$python = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $python) { $python = Get-Command python -ErrorAction Stop }
$output = @(
    & $python.Source $toolPath `
        --input $inputFull `
        --manifest $manifestFull `
        --output $outputFull `
        --source-head $SourceHead.ToLowerInvariant() `
        --experiment-id $ExperimentId 2>&1
)
$exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
if ($exitCode -ne 0) {
    throw "Semantic control analyzer failed: exit=$exitCode output=$($output -join ' ')"
}
if (-not (Test-Path -LiteralPath $outputFull -PathType Leaf)) {
    throw 'Semantic control analyzer did not produce output.'
}
$summary = Get-Content -LiteralPath $outputFull -Raw | ConvertFrom-Json
if ([string]$summary.status -cne 'passed') {
    throw "Semantic control summary status is not passed: $($summary.status)"
}
$result = [pscustomobject][ordered]@{
    status = 'passed'
    output_path = $outputFull
    output_sha256 = (Get-FileHash -LiteralPath $outputFull -Algorithm SHA256).Hash.ToLowerInvariant()
    normalized_event_rows = [int64]$summary.source.normalized_event_rows
    controlled_present_count_mapping_validated = [bool]$summary.claims.controlled_present_count_mapping_validated
    controlled_network_activity_mapping_validated = [bool]$summary.claims.controlled_network_activity_mapping_validated
    exact_named_present_pairing_eligible = [bool]$summary.differential.present_pairing_eligibility.exact_named_identifier_pairing_eligible
    trace_completeness = 'not_claimed'
}
Write-Information -MessageData "Semantic control analysis passed: rows=$($result.normalized_event_rows) present_mapping=$($result.controlled_present_count_mapping_validated) network_mapping=$($result.controlled_network_activity_mapping_validated)" -InformationAction Continue
if ($PassThru) { return $result }
