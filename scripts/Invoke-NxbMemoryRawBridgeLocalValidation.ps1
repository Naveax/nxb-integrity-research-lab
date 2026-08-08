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

function Test-NxbRawBridgeAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Resolve-NxbRawBridgePython {
    [CmdletBinding()]
    param()

    foreach ($candidate in @('python.exe', 'python', 'py.exe', 'py')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return [string]$command.Source
        }
    }
    return $null
}

if ($env:OS -cne 'Windows_NT') {
    throw 'Raw memory bridge validation requires real Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Raw memory bridge validation must run in PowerShell 7.'
}
if (-not (Test-NxbRawBridgeAdministrator)) {
    throw 'Raw memory bridge validation requires elevated PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or
    $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}
$workingTree = @(
    & $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all
)
if ($LASTEXITCODE -ne 0 -or $workingTree.Count -gt 0) {
    throw 'Raw memory bridge validation requires a clean working tree.'
}

$etlRunner = Join-Path `
    $PSScriptRoot `
    'Invoke-NxbMemoryEtlAdapterLocalValidationV3.ps1'
$bridgePath = Join-Path `
    $PSScriptRoot `
    'ConvertFrom-NxbXperfMemoryDumper.ps1'
$exportPath = Join-Path `
    $PSScriptRoot `
    'Export-NxbMemoryEtlWithXperf.ps1'
$adapterPath = Join-Path `
    $PSScriptRoot `
    'ConvertFrom-NxbMemoryEventExport.ps1'
$normalizerPath = Join-Path `
    $repositoryRoot `
    'tools\normalize_xperf_memory_dumper.py'
$fixturePath = Join-Path `
    $repositoryRoot `
    'tests\fixtures\xperf-memory-dumper.valid.txt'
$testPath = Join-Path `
    $repositoryRoot `
    'tests\XperfMemoryDumperBridge.Tests.ps1'
$settingsPath = Join-Path `
    $repositoryRoot `
    '.github\PSScriptAnalyzerSettings.psd1'
foreach ($requiredPath in @(
    $etlRunner,
    $bridgePath,
    $exportPath,
    $adapterPath,
    $normalizerPath,
    $fixturePath,
    $testPath,
    $settingsPath,
    $PSCommandPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Raw bridge validation input not found: $requiredPath"
    }
}

$pythonPath = Resolve-NxbRawBridgePython
if ([string]::IsNullOrWhiteSpace($pythonPath)) {
    throw 'Python not found.'
}

if ([string]::IsNullOrWhiteSpace($ResultsRoot)) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $ResultsRoot = Join-Path `
        ([IO.Path]::GetTempPath()) `
        "nxb-memory-raw-bridge-$($currentHead.Substring(0, 12))-$stamp"
}
$resultsFull = [IO.Path]::GetFullPath($ResultsRoot)
if (Test-Path -LiteralPath $resultsFull) {
    throw "Validation results directory already exists: $resultsFull"
}
[IO.Directory]::CreateDirectory($resultsFull) | Out-Null
$startedUtc = [DateTime]::UtcNow
$gates = [Collections.Generic.List[object]]::new()

$etlResults = Join-Path $resultsFull 'etl-validation'
$etlSummary = & $etlRunner `
    -ExpectedHead $currentHead `
    -ResultsRoot $etlResults `
    -BootstrapDependencies:$BootstrapDependencies `
    -PassThru
if ([string]$etlSummary.status -cne 'passed') {
    throw 'Nested ETL adapter V3 validation did not pass.'
}
$gates.Add([pscustomobject][ordered]@{
    name = 'memory-etl-adapter-v3'
    status = 'passed'
    exit_code = 0
    evidence = Join-Path `
        $etlResults `
        'memory-etl-adapter-v3-validation-summary.json'
})

$pythonCheck = @'
import ast
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
'@
$pythonOutput = @(& $pythonPath -c $pythonCheck $normalizerPath 2>&1)
$pythonExitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
if ($pythonExitCode -ne 0) {
    throw (
        'Raw bridge Python parse failed: ' +
        (@($pythonOutput | ForEach-Object { [string]$_ }) -join ' ')
    )
}
$gates.Add([pscustomobject][ordered]@{
    name = 'memory-raw-bridge-python-parse'
    status = 'passed'
    exit_code = 0
    evidence = $normalizerPath
})

$parseFailures = [Collections.Generic.List[string]]::new()
foreach ($parsePath in @($bridgePath, $exportPath, $testPath, $PSCommandPath)) {
    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $parsePath,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null
    foreach ($parseError in @($parseErrors)) {
        $parseFailures.Add(
            "${parsePath}:$($parseError.Extent.StartLineNumber): " +
            $parseError.Message
        )
    }
}
if ($parseFailures.Count -gt 0) {
    throw (
        'Raw bridge PowerShell parser failures: ' +
        ($parseFailures -join '; ')
    )
}
$gates.Add([pscustomobject][ordered]@{
    name = 'memory-raw-bridge-powershell-parser'
    status = 'passed'
    exit_code = 0
    evidence = 'bridge/export/tests/runner'
})

Import-Module PSScriptAnalyzer -Force
$analyzerFindings = [Collections.Generic.List[object]]::new()
foreach ($analyzerPath in @($bridgePath, $exportPath, $PSCommandPath)) {
    foreach ($finding in @(
        Invoke-ScriptAnalyzer -Path $analyzerPath -Settings $settingsPath
    )) {
        $analyzerFindings.Add($finding)
    }
}
if ($analyzerFindings.Count -gt 0) {
    throw (
        'Raw bridge PSScriptAnalyzer findings: ' +
        ($analyzerFindings |
            Select-Object Severity, ScriptName, Line, RuleName, Message |
            ConvertTo-Json -Compress)
    )
}
$gates.Add([pscustomobject][ordered]@{
    name = 'memory-raw-bridge-psscriptanalyzer'
    status = 'passed'
    exit_code = 0
    evidence = 'zero findings'
})

$contractOutput = Join-Path $resultsFull 'canonical-bridge'
$bridgeResult = & $bridgePath `
    -InputPath $fixturePath `
    -OutputDirectory $contractOutput `
    -PassThru
$coverage = [string[]]@($bridgeResult.covered_event_types)
if ($coverage.Count -ne 8 -or
    $coverage -contains 'hard_fault' -or
    [int]$bridgeResult.manifest.unmapped_event_counts.hard_fault -ne 1) {
    throw 'Canonical raw bridge coverage boundary mismatch.'
}

$summaryPath = Join-Path $resultsFull 'canonical-memory-etl-summary.json'
& $adapterPath `
    -ExperimentId 'raw-bridge-fixture-001' `
    -InputPath ([string]$bridgeResult.event_export_path) `
    -OutputPath $summaryPath `
    -MachineId 'raw-bridge-fixture-machine' `
    -BootId ('1' * 64) `
    -TraceSha256 ('2' * 64) `
    -ProfileSha256 ('3' * 64) `
    -TraceStartUtc ([datetime]'2026-08-07T09:00:00Z') `
    -TraceEndUtc ([datetime]'2026-08-07T09:00:10Z') `
    -TargetProcessId 4242 `
    -TargetProcessStartUtc ([datetime]'2026-08-07T08:59:00Z') `
    -TargetImageSha256 ('4' * 64) `
    -CoveredEventType $coverage `
    -TraceLoss none `
    -CircularOverwrite none
$contractSummary = Get-Content -LiteralPath $summaryPath -Raw |
    ConvertFrom-Json
if ([string]$contractSummary.events.hard_fault.status -cne 'not_assessed' -or
    [string]$contractSummary.events.soft_fault_total.status -cne 'measured' -or
    [int]$contractSummary.events.soft_fault_total.count -ne 4 -or
    [string]$contractSummary.summary.evidence_completeness -cne 'partial') {
    throw 'Canonical dumper-to-summary contract validation failed.'
}
$gates.Add([pscustomobject][ordered]@{
    name = 'memory-raw-bridge-contract'
    status = 'passed'
    exit_code = 0
    evidence = $summaryPath
})

Import-Module Pester -MinimumVersion 6.0.0 -Force
$ps7Xml = Join-Path $resultsFull 'pester-memory-raw-bridge-pwsh.xml'
$ps7Config = New-PesterConfiguration
$ps7Config.Run.Path = $testPath
$ps7Config.Run.PassThru = $true
$ps7Config.Output.Verbosity = 'Detailed'
$ps7Config.TestResult.Enabled = $true
$ps7Config.TestResult.OutputPath = $ps7Xml
$ps7Config.TestResult.OutputFormat = 'NUnitXml'
$ps7Result = Invoke-Pester -Configuration $ps7Config
if ([int]$ps7Result.TotalCount -ne 9 -or
    [int]$ps7Result.FailedCount -ne 0 -or
    [int]$ps7Result.SkippedCount -ne 0 -or
    [int]$ps7Result.NotRunCount -ne 0) {
    throw (
        'PowerShell 7 raw bridge Pester failed: ' +
        "total=$($ps7Result.TotalCount) failed=$($ps7Result.FailedCount) " +
        "skipped=$($ps7Result.SkippedCount) notrun=$($ps7Result.NotRunCount)"
    )
}
$gates.Add([pscustomobject][ordered]@{
    name = 'pester-memory-raw-bridge-pwsh'
    status = 'passed'
    exit_code = 0
    evidence = $ps7Xml
})

$windowsPowerShell = Join-Path `
    $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
    throw "Windows PowerShell 5.1 not found: $windowsPowerShell"
}
$escapedTestPath = $testPath.Replace("'", "''")
$escapedXmlPath = (Join-Path `
    $resultsFull `
    'pester-memory-raw-bridge-ps51.xml').Replace("'", "''")
$ps51Script = @"
`$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 5.0.0 -Force
`$configuration = New-PesterConfiguration
`$configuration.Run.Path = '$escapedTestPath'
`$configuration.Run.PassThru = `$true
`$configuration.Output.Verbosity = 'Detailed'
`$configuration.TestResult.Enabled = `$true
`$configuration.TestResult.OutputPath = '$escapedXmlPath'
`$configuration.TestResult.OutputFormat = 'NUnitXml'
`$result = Invoke-Pester -Configuration `$configuration
if ([int]`$result.TotalCount -ne 9 -or
    [int]`$result.FailedCount -ne 0 -or
    [int]`$result.SkippedCount -ne 0 -or
    [int]`$result.NotRunCount -ne 0) {
    exit 1
}
exit 0
"@
$encodedPs51 = [Convert]::ToBase64String(
    [Text.Encoding]::Unicode.GetBytes($ps51Script)
)
& $windowsPowerShell `
    -NoLogo `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -EncodedCommand $encodedPs51
$ps51ExitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
if ($ps51ExitCode -ne 0) {
    throw "Windows PowerShell 5.1 raw bridge Pester failed: $ps51ExitCode"
}
$ps51Xml = Join-Path $resultsFull 'pester-memory-raw-bridge-ps51.xml'
if (-not (Test-Path -LiteralPath $ps51Xml -PathType Leaf)) {
    throw "Windows PowerShell 5.1 NUnit evidence not found: $ps51Xml"
}
[xml]$ps51NUnit = Get-Content -LiteralPath $ps51Xml -Raw
$ps51Root = $ps51NUnit.'test-results'
if ([int]$ps51Root.total -ne 9 -or
    [int]$ps51Root.failures -ne 0 -or
    [int]$ps51Root.errors -ne 0 -or
    [int]$ps51Root.'not-run' -ne 0) {
    throw 'Windows PowerShell 5.1 NUnit evidence is not clean.'
}
$gates.Add([pscustomobject][ordered]@{
    name = 'pester-memory-raw-bridge-ps51'
    status = 'passed'
    exit_code = 0
    evidence = $ps51Xml
})

$summary = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    head_sha = $currentHead
    expected_head_sha = $ExpectedHead.ToLowerInvariant()
    validation_started_utc = $startedUtc.ToString('o')
    validation_stopped_utc = [DateTime]::UtcNow.ToString('o')
    gates = @($gates)
}
$validationSummaryPath = Join-Path `
    $resultsFull `
    'memory-raw-bridge-validation-summary.json'
[IO.File]::WriteAllText(
    $validationSummaryPath,
    ($summary | ConvertTo-Json -Depth 32),
    [Text.UTF8Encoding]::new($false)
)

$reviewName = (
    'nxb-memory-raw-bridge-' +
    $currentHead.Substring(0, 12) + '-' +
    [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') +
    '-review.zip'
)
$reviewZip = Join-Path (Join-Path $HOME 'Downloads') $reviewName
Compress-Archive -Path (Join-Path $resultsFull '*') -DestinationPath $reviewZip

Write-Host "Memory raw bridge validation summary: $validationSummaryPath"
Write-Host "Review ZIP: $reviewZip"
Write-Host 'Memory raw bridge exact-head validation completed.'

if ($PassThru) {
    return $summary
}
