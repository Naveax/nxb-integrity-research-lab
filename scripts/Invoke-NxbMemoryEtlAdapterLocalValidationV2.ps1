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

function Test-NxbMemoryEtlV2Administrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Test-NxbMemoryEtlV2NUnit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [int]$ExpectedTotal
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "NUnit XML not found: $Path"
    }

    [xml]$xml = Get-Content -LiteralPath $Path -Raw
    $root = $xml.'test-results'
    if ($null -eq $root) {
        throw "NUnit XML root is missing: $Path"
    }

    $actual = [ordered]@{
        total = [int]$root.total
        errors = [int]$root.errors
        failures = [int]$root.failures
        not_run = [int]$root.'not-run'
        inconclusive = [int]$root.inconclusive
        ignored = [int]$root.ignored
        skipped = [int]$root.skipped
        invalid = [int]$root.invalid
    }

    if ($actual.total -ne $ExpectedTotal -or
        $actual.errors -ne 0 -or
        $actual.failures -ne 0 -or
        $actual.not_run -ne 0 -or
        $actual.inconclusive -ne 0 -or
        $actual.ignored -ne 0 -or
        $actual.skipped -ne 0 -or
        $actual.invalid -ne 0) {
        throw (
            "Unexpected NUnit result in $Path: " +
            ($actual | ConvertTo-Json -Compress)
        )
    }

    return [pscustomobject]$actual
}

function Get-NxbMemoryEtlV2Gate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Summary,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $matches = @($Summary.gates | Where-Object name -CEQ $Name)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one gate named '$Name'; found $($matches.Count)."
    }
    return $matches[0]
}

if ($env:OS -cne 'Windows_NT') {
    throw 'Memory ETL adapter V2 validation requires real Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Memory ETL adapter V2 validation must run in PowerShell 7.'
}
if (-not (Test-NxbMemoryEtlV2Administrator)) {
    throw 'Memory ETL adapter V2 validation requires elevated PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}

$workingTree = @(
    & $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all
)
if ($LASTEXITCODE -ne 0 -or $workingTree.Count -gt 0) {
    throw 'Exact-head V2 validation requires a clean working tree.'
}

$v1Runner = Join-Path $PSScriptRoot 'Invoke-NxbMemoryEtlAdapterLocalValidation.ps1'
$settingsPath = Join-Path $repositoryRoot '.github\PSScriptAnalyzerSettings.psd1'
foreach ($requiredPath in @($v1Runner, $settingsPath, $PSCommandPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Memory ETL V2 validation input not found: $requiredPath"
    }
}

if ([string]::IsNullOrWhiteSpace($ResultsRoot)) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $ResultsRoot = Join-Path `
        ([IO.Path]::GetTempPath()) `
        "nxb-memory-etl-adapter-v2-$($currentHead.Substring(0, 12))-$stamp"
}
$resultsFull = [IO.Path]::GetFullPath($ResultsRoot)
if (Test-Path -LiteralPath $resultsFull) {
    throw "Validation results directory already exists: $resultsFull"
}
[IO.Directory]::CreateDirectory($resultsFull) | Out-Null
$rawResults = Join-Path $resultsFull 'raw-validation'
$summaryPath = Join-Path $resultsFull 'memory-etl-adapter-v2-validation-summary.json'
$reviewZip = Join-Path $HOME (
    'Downloads\' + (Split-Path -Leaf $resultsFull) + '-review.zip'
)
$startedUtc = [DateTime]::UtcNow
$v1Failure = $null

try {
    & $v1Runner `
        -ExpectedHead $currentHead `
        -ResultsRoot $rawResults `
        -BootstrapDependencies:$BootstrapDependencies `
        -PassThru | Out-Null
}
catch {
    $v1Failure = $_.Exception.Message
}

$rawSummaryPath = Join-Path $rawResults 'memory-etl-adapter-validation-summary.json'
if (-not (Test-Path -LiteralPath $rawSummaryPath -PathType Leaf)) {
    throw "Raw ETL validation summary not found: $rawSummaryPath"
}
$rawSummary = Get-Content -LiteralPath $rawSummaryPath -Raw | ConvertFrom-Json
if ([string]$rawSummary.head_sha -cne $currentHead -or
    [string]$rawSummary.expected_head_sha -cne $currentHead) {
    throw 'Raw ETL validation summary exact-head binding mismatch.'
}

$requiredPassedGates = @(
    'memory-collector-foundation',
    'memory-etl-python-compile',
    'memory-etl-powershell-parser',
    'memory-etl-psscriptanalyzer',
    'memory-etl-contract'
)
$finalGates = [Collections.Generic.List[object]]::new()
foreach ($name in $requiredPassedGates) {
    $gate = Get-NxbMemoryEtlV2Gate -Summary $rawSummary -Name $name
    if ([string]$gate.status -cne 'passed' -or [int]$gate.exit_code -ne 0) {
        throw "Raw ETL gate did not pass: $name"
    }
    $finalGates.Add([pscustomobject][ordered]@{
        name = $name
        status = 'passed'
        exit_code = 0
        evidence = [string]$gate.log_path
        reason = $null
    })
}

$ps7Xml = Join-Path $rawResults 'pester-memory-etl-pwsh.xml'
$ps51Xml = Join-Path $rawResults 'pester-memory-etl-ps51.xml'
$ps7Result = Test-NxbMemoryEtlV2NUnit -Path $ps7Xml -ExpectedTotal 18
$ps51Result = Test-NxbMemoryEtlV2NUnit -Path $ps51Xml -ExpectedTotal 18

$ps7Gate = Get-NxbMemoryEtlV2Gate -Summary $rawSummary -Name 'pester-memory-etl-pwsh'
$ps51Gate = Get-NxbMemoryEtlV2Gate -Summary $rawSummary -Name 'pester-memory-etl-ps51'
$ps7Log = Get-Content -LiteralPath ([string]$ps7Gate.log_path) -Raw
$ps51Log = Get-Content -LiteralPath ([string]$ps51Gate.log_path) -Raw

if ([string]$ps7Gate.status -ceq 'failed') {
    if ($ps7Log -notmatch "Cannot process the XML from the 'Error' stream" -or
        $ps7Log -notmatch '0x07' -or
        $ps7Log -notmatch 'invalid character') {
        throw 'PowerShell 7 Pester gate failed for an unknown reason.'
    }
}
elseif ([string]$ps7Gate.status -cne 'passed') {
    throw "Unexpected PowerShell 7 Pester gate status: $($ps7Gate.status)"
}

if ([string]$ps51Gate.status -ceq 'failed') {
    if ($ps51Log -notmatch 'Unexpected Pester result: total= failed= skipped= notrun=') {
        throw 'Windows PowerShell 5.1 Pester gate failed for an unknown reason.'
    }
}
elseif ([string]$ps51Gate.status -cne 'passed') {
    throw "Unexpected Windows PowerShell 5.1 Pester gate status: $($ps51Gate.status)"
}

$finalGates.Add([pscustomobject][ordered]@{
    name = 'pester-memory-etl-pwsh'
    status = 'passed'
    exit_code = 0
    evidence = $ps7Xml
    reason = if ([string]$ps7Gate.status -ceq 'failed') {
        'V1 CLIXML false-negative superseded by successful 18-test NUnit evidence.'
    }
    else { $null }
})
$finalGates.Add([pscustomobject][ordered]@{
    name = 'pester-memory-etl-ps51'
    status = 'passed'
    exit_code = 0
    evidence = $ps51Xml
    reason = if ([string]$ps51Gate.status -ceq 'failed') {
        'V1 PassThru false-negative superseded by successful 18-test NUnit evidence.'
    }
    else { $null }
})

Import-Module PSScriptAnalyzer -Force
$selfFindings = @(
    Invoke-ScriptAnalyzer -Path $PSCommandPath -Settings $settingsPath
)
if ($selfFindings.Count -gt 0) {
    throw (
        'Memory ETL V2 runner PSScriptAnalyzer findings: ' +
        ($selfFindings | Select-Object Severity, Line, RuleName, Message |
            ConvertTo-Json -Compress)
    )
}
$finalGates.Add([pscustomobject][ordered]@{
    name = 'memory-etl-v2-runner-psscriptanalyzer'
    status = 'passed'
    exit_code = 0
    evidence = $PSCommandPath
    reason = $null
})

$summary = [pscustomobject][ordered]@{
    schema_version = 1
    runner_version = 2
    status = 'passed'
    head_sha = $currentHead
    expected_head_sha = $ExpectedHead.ToLowerInvariant()
    validation_started_utc = $startedUtc.ToString('o')
    validation_stopped_utc = [DateTime]::UtcNow.ToString('o')
    raw_validation_summary_path = $rawSummaryPath
    raw_validation_status = [string]$rawSummary.status
    superseded_v1_failure = $v1Failure
    pester = [ordered]@{
        pwsh = $ps7Result
        ps51 = $ps51Result
    }
    gates = @($finalGates)
}

[IO.File]::WriteAllText(
    $summaryPath,
    ($summary | ConvertTo-Json -Depth 32),
    [Text.UTF8Encoding]::new($false)
)

if (Test-Path -LiteralPath $reviewZip -PathType Leaf) {
    Remove-Item -LiteralPath $reviewZip -Force
}
Compress-Archive -Path (Join-Path $resultsFull '*') -DestinationPath $reviewZip

Write-Host "Memory ETL adapter V2 validation summary: $summaryPath"
Write-Host "Review ZIP: $reviewZip"
Write-Host 'Memory ETL adapter exact-head validation V2 completed.'

if ($PassThru) {
    return $summary
}
