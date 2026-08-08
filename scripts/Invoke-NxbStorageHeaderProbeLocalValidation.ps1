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
    throw 'Storage header probe validation requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Storage header probe validation must run in PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}
$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'Storage header probe validation requires a clean exact-head worktree.'
}

$inventoryPath = Join-Path $PSScriptRoot 'Get-NxbXperfStorageHeaderInventory.ps1'
$workloadPath = Join-Path $PSScriptRoot 'Invoke-NxbStorageHeaderProbeWorkload.ps1'
$capturePath = Join-Path $PSScriptRoot 'Invoke-NxbStorageHeaderProbe.ps1'
$profileValidatorPath = Join-Path $PSScriptRoot 'Test-NxbStorageWprProfile.ps1'
$probeTestPath = Join-Path $repositoryRoot 'tests\StorageHeaderProbe.Tests.ps1'
$inventoryTestPath = Join-Path $repositoryRoot 'tests\XperfStorageHeaderInventory.Tests.ps1'
$inventoryFixturePath = Join-Path `
    $repositoryRoot `
    'tests\fixtures\xperf-storage-header-inventory.valid.txt'
$profilePath = Join-Path $repositoryRoot 'profiles\Nxb.StorageIOQueue.wprp'
$runnerPath = $PSCommandPath

foreach ($requiredPath in @(
    $inventoryPath,
    $workloadPath,
    $capturePath,
    $profileValidatorPath,
    $probeTestPath,
    $inventoryTestPath,
    $inventoryFixturePath,
    $profilePath,
    $runnerPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required storage header probe validation file missing: $requiredPath"
    }
}

foreach ($scriptPath in @(
    $inventoryPath,
    $workloadPath,
    $capturePath,
    $probeTestPath,
    $inventoryTestPath,
    $runnerPath
)) {
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
    foreach ($scriptPath in @(
        $inventoryPath,
        $workloadPath,
        $capturePath,
        $probeTestPath,
        $inventoryTestPath,
        $runnerPath
    )) {
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

Import-Module Pester -ErrorAction Stop
$pesterResult = Invoke-Pester -Path @($probeTestPath, $inventoryTestPath) -PassThru
if ([int]$pesterResult.FailedCount -ne 0 -or
    [int]$pesterResult.SkippedCount -ne 0 -or
    [int]$pesterResult.PassedCount -ne [int]$pesterResult.TotalCount -or
    [int]$pesterResult.TotalCount -ne 11) {
    throw (
        'Storage header probe Pester result is not clean: ' +
        "passed=$($pesterResult.PassedCount) failed=$($pesterResult.FailedCount) " +
        "skipped=$($pesterResult.SkippedCount) total=$($pesterResult.TotalCount)"
    )
}

$profileMetadata = & $profileValidatorPath -PassThru
$wpr = Get-Command wpr.exe -ErrorAction Stop
$xperf = Get-Command xperf.exe -ErrorAction Stop
$nativeOutput = @(& $wpr.Source -profiles $profilePath 2>&1)
$nativeExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
if ($nativeExit -ne 0) {
    throw (
        "Native wpr.exe profile parse failed (exit $nativeExit):`n" +
        (@($nativeOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    )
}

$postDirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) {
    throw 'Storage header probe validation left the exact-head worktree dirty.'
}

$result = [pscustomobject][ordered]@{
    status = 'passed'
    head_sha = $currentHead
    pester = [ordered]@{
        passed = [int]$pesterResult.PassedCount
        failed = [int]$pesterResult.FailedCount
        skipped = [int]$pesterResult.SkippedCount
        total = [int]$pesterResult.TotalCount
    }
    analyzer_findings = 0
    native_wpr_profile_parse = 'passed'
    xperf_path = [string]$xperf.Source
    profile_sha256 = [string]$profileMetadata.Sha256
    kernel_queue_enabled = [bool]$profileMetadata.KernelQueueEnabled
    real_capture_executed = $false
}

Write-Information `
    -MessageData "Storage header probe local validation passed: $currentHead" `
    -InformationAction Continue
Write-Information `
    -MessageData "Pester: $($pesterResult.PassedCount)/$($pesterResult.TotalCount)" `
    -InformationAction Continue
Write-Information `
    -MessageData 'PSScriptAnalyzer: 0 findings' `
    -InformationAction Continue
Write-Information `
    -MessageData 'Native wpr.exe profile parse: PASS' `
    -InformationAction Continue
Write-Information `
    -MessageData "xperf.exe: $($xperf.Source)" `
    -InformationAction Continue
Write-Information `
    -MessageData 'Real capture executed: False' `
    -InformationAction Continue

if ($PassThru) {
    return $result
}
