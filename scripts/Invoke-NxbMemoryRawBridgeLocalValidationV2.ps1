[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter()]
    [string]$ResultsRoot,

    [Parameter()]
    [switch]$BootstrapDependencies,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$v1Runner = Join-Path $PSScriptRoot 'Invoke-NxbMemoryRawBridgeLocalValidation.ps1'
$settingsPath = Join-Path $repositoryRoot '.github\PSScriptAnalyzerSettings.psd1'
foreach ($requiredPath in @($v1Runner, $settingsPath, $PSCommandPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Raw bridge V2 input not found: $requiredPath"
    }
}

$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or
    $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}

if ([string]::IsNullOrWhiteSpace($ResultsRoot)) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $ResultsRoot = Join-Path `
        ([IO.Path]::GetTempPath()) `
        "nxb-memory-raw-bridge-v2-$($currentHead.Substring(0, 12))-$stamp"
}
$resultsFull = [IO.Path]::GetFullPath($ResultsRoot)

$runnerOutput = @()
$runnerFailure = $null
try {
    $runnerOutput = @(
        & $v1Runner `
            -ExpectedHead $currentHead `
            -ResultsRoot $resultsFull `
            -BootstrapDependencies:$BootstrapDependencies `
            -PassThru 2>&1
    )
}
catch {
    $runnerFailure = $_
}

foreach ($entry in $runnerOutput) {
    Write-Host ([string]$entry)
}
if ($null -ne $runnerFailure) {
    throw $runnerFailure
}

$summaryPath = Join-Path $resultsFull 'memory-raw-bridge-validation-summary.json'
if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
    throw "Raw bridge summary not found: $summaryPath"
}
$summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
if ([string]$summary.status -cne 'passed' -or
    [string]$summary.head_sha -cne $currentHead -or
    [string]$summary.expected_head_sha -cne $currentHead) {
    throw 'Raw bridge V2 summary did not prove a passed exact-head run.'
}

$expectedGates = @(
    'memory-etl-adapter-v3',
    'memory-raw-bridge-python-parse',
    'memory-raw-bridge-powershell-parser',
    'memory-raw-bridge-psscriptanalyzer',
    'memory-raw-bridge-contract',
    'pester-memory-raw-bridge-pwsh',
    'pester-memory-raw-bridge-ps51'
)
if (@($summary.gates).Count -ne $expectedGates.Count) {
    throw 'Raw bridge V2 gate count mismatch.'
}
foreach ($name in $expectedGates) {
    $gateMatches = @($summary.gates | Where-Object name -CEQ $name)
    if ($gateMatches.Count -ne 1 -or
        [string]$gateMatches[0].status -cne 'passed' -or
        [int]$gateMatches[0].exit_code -ne 0) {
        throw "Raw bridge V2 gate did not pass exactly once: $name"
    }
}

Import-Module PSScriptAnalyzer -Force
$selfFindings = @(
    Invoke-ScriptAnalyzer -Path $PSCommandPath -Settings $settingsPath
)
if ($selfFindings.Count -gt 0) {
    throw (
        'Raw bridge V2 PSScriptAnalyzer findings: ' +
        ($selfFindings |
            Select-Object Severity, Line, RuleName, Message |
            ConvertTo-Json -Compress)
    )
}

Write-Host "Memory raw bridge V2 validation summary: $summaryPath"
Write-Host 'Memory raw bridge exact-head validation V2 completed.'

if ($PassThru) {
    return $summary
}
