[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -cne 'Windows_NT') {
    throw 'Storage raw bridge validation requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Storage raw bridge validation must run in PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}
$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'Storage raw bridge validation requires a clean exact-head worktree.'
}

$bridgePath = Join-Path $PSScriptRoot 'ConvertFrom-NxbXperfStorageDumper.ps1'
$normalizerPath = Join-Path $repositoryRoot 'tools\normalize_xperf_storage_dumper.py'
$testPath = Join-Path $repositoryRoot 'tests\XperfStorageDumperBridge.Tests.ps1'
$fixturePath = Join-Path $repositoryRoot 'tests\fixtures\xperf-storage-dumper.valid.txt'
$runnerPath = $PSCommandPath

foreach ($requiredPath in @(
    $bridgePath,
    $normalizerPath,
    $testPath,
    $fixturePath,
    $runnerPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required storage raw bridge file missing: $requiredPath"
    }
}

foreach ($scriptPath in @($bridgePath, $testPath, $runnerPath)) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $scriptPath,
        [ref]$tokens,
        [ref]$errors
    )
    if (@($errors).Count -gt 0) {
        throw (
            "PowerShell parser failed: $scriptPath`n" +
            (@($errors | ForEach-Object { $_.Message }) -join "`n")
        )
    }
}

Import-Module PSScriptAnalyzer -ErrorAction Stop
$findings = @(
    foreach ($scriptPath in @($bridgePath, $testPath, $runnerPath)) {
        Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error
    }
)
if ($findings.Count -gt 0) {
    throw (
        "PSScriptAnalyzer findings: $($findings.Count)`n" +
        (@($findings | ForEach-Object {
            '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message
        }) -join "`n")
    )
}

$python = Get-Command python.exe -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
if (-not $python) { throw 'Python was not found.' }
$compileOutput = @(& $python.Source -m py_compile $normalizerPath 2>&1)
$compileExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
if ($compileExit -ne 0) {
    throw (
        "Storage normalizer py_compile failed (exit $compileExit):`n" +
        (@($compileOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    )
}

Import-Module Pester -ErrorAction Stop
$pester = Invoke-Pester -Path $testPath -PassThru
if ([int]$pester.FailedCount -ne 0 -or
    [int]$pester.SkippedCount -ne 0 -or
    [int]$pester.PassedCount -ne [int]$pester.TotalCount -or
    [int]$pester.TotalCount -ne 8) {
    throw (
        'Storage raw bridge Pester result is not clean: ' +
        "passed=$($pester.PassedCount) failed=$($pester.FailedCount) " +
        "skipped=$($pester.SkippedCount) total=$($pester.TotalCount)"
    )
}

$tempOutput = Join-Path ([IO.Path]::GetTempPath()) `
    ("nxb-storage-raw-bridge-$([guid]::NewGuid().ToString('N'))")
try {
    $bridgeResult = & $bridgePath `
        -InputPath $fixturePath `
        -OutputDirectory $tempOutput `
        -PassThru
    if ([int]$bridgeResult.normalized_event_count -ne 10 -or
        [string]$bridgeResult.parser_completeness -cne 'partial' -or
        [bool]$bridgeResult.timing.normalized_duration_us_available) {
        throw 'Canonical storage raw bridge fixture result is invalid.'
    }
}
finally {
    if (Test-Path -LiteralPath $tempOutput) {
        Remove-Item -LiteralPath $tempOutput -Recurse -Force
    }
}

$postDirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) {
    throw 'Storage raw bridge validation left exact-head worktree dirty.'
}

$result = [pscustomobject][ordered]@{
    status = 'passed'
    head_sha = $currentHead
    pester = [ordered]@{
        passed = [int]$pester.PassedCount
        failed = [int]$pester.FailedCount
        skipped = [int]$pester.SkippedCount
        total = [int]$pester.TotalCount
    }
    analyzer_findings = 0
    python_compile = 'passed'
    canonical_fixture_normalized_events = 10
    timing_units_resolved = $false
    duration_us_available = $false
}

Write-Information -MessageData "Storage raw bridge validation passed: $currentHead" -InformationAction Continue
Write-Information -MessageData "Pester: $($pester.PassedCount)/$($pester.TotalCount)" -InformationAction Continue
Write-Information -MessageData 'PSScriptAnalyzer: 0 findings' -InformationAction Continue
Write-Information -MessageData 'Python normalizer py_compile: PASS' -InformationAction Continue
Write-Information -MessageData 'Timing units resolved: False' -InformationAction Continue

if ($PassThru) {
    return $result
}
