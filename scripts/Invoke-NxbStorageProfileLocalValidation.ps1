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

function Invoke-NxbStoragePesterRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$Executable,

        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$TestPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Label
    )

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("nxb-storage-pester-$([guid]::NewGuid().ToString('N'))")
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $childPath = Join-Path $tempRoot 'invoke-storage-pester.ps1'
    $resultPath = Join-Path $tempRoot 'result.json'

    @'
param(
    [Parameter(Mandatory)]
    [string]$TestPath,

    [Parameter(Mandatory)]
    [string]$ResultPath
)

$ErrorActionPreference = 'Stop'
Import-Module Pester -ErrorAction Stop
$result = Invoke-Pester -Path $TestPath -PassThru
$summary = [pscustomobject]@{
    passed = [int]$result.PassedCount
    failed = [int]$result.FailedCount
    skipped = [int]$result.SkippedCount
    total = [int]$result.TotalCount
}
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
if ($summary.failed -ne 0 -or $summary.skipped -ne 0 -or $summary.passed -le 0) {
    exit 1
}
'@ | Set-Content -LiteralPath $childPath -Encoding UTF8

    try {
        & $Executable `
            -NoLogo `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $childPath `
            -TestPath $TestPath `
            -ResultPath $resultPath
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "$Label Pester run failed with exit code $exitCode."
        }
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            throw "$Label Pester result JSON was not produced."
        }

        $summary = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if ([int]$summary.failed -ne 0 -or
            [int]$summary.skipped -ne 0 -or
            [int]$summary.passed -le 0) {
            throw "$Label Pester result is not clean."
        }

        return [pscustomobject]@{
            Label = $Label
            Passed = [int]$summary.passed
            Failed = [int]$summary.failed
            Skipped = [int]$summary.skipped
            Total = [int]$summary.total
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

if ($env:OS -cne 'Windows_NT') {
    throw 'Storage profile native validation requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Storage profile local validation must run in PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}

$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'Storage profile validation requires a clean exact-head worktree.'
}

$profilePath = Join-Path $repositoryRoot 'profiles\Nxb.StorageIOQueue.wprp'
$validatorPath = Join-Path $PSScriptRoot 'Test-NxbStorageWprProfile.ps1'
$testPath = Join-Path $repositoryRoot 'tests\StorageWprProfile.Tests.ps1'
$runnerPath = $PSCommandPath

foreach ($requiredPath in @($profilePath, $validatorPath, $testPath, $runnerPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required storage validation file missing: $requiredPath"
    }
}

foreach ($scriptPath in @($validatorPath, $testPath, $runnerPath)) {
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
    foreach ($scriptPath in @($validatorPath, $testPath, $runnerPath)) {
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

$profile = & $validatorPath -PassThru

$pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
$windowsPowerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShellPath -PathType Leaf)) {
    throw "Windows PowerShell 5.1 executable missing: $windowsPowerShellPath"
}

$ps7 = Invoke-NxbStoragePesterRun `
    -Executable $pwshPath `
    -TestPath $testPath `
    -Label 'PowerShell 7'
$ps51 = Invoke-NxbStoragePesterRun `
    -Executable $windowsPowerShellPath `
    -TestPath $testPath `
    -Label 'Windows PowerShell 5.1'

$wprPath = (Get-Command wpr.exe -ErrorAction Stop).Source
$wprOutput = @(& $wprPath -profiles $profilePath 2>&1)
$wprExitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
if ($wprExitCode -ne 0) {
    throw (
        "Native wpr.exe profile parse failed (exit $wprExitCode):`n" +
        ($wprOutput -join [Environment]::NewLine)
    )
}

$postDirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) {
    throw 'Storage validation left the exact-head worktree dirty.'
}

$result = [pscustomobject]@{
    status = 'passed'
    head_sha = $currentHead
    profile = $profile
    powershell7 = $ps7
    windows_powershell_51 = $ps51
    native_wpr_profile_parse = 'passed'
    analyzer_findings = 0
}

Write-Information -MessageData "Storage profile exact-head validation passed: $currentHead" -InformationAction Continue
Write-Information -MessageData "PowerShell 7 Pester: $($ps7.Passed)/$($ps7.Total)" -InformationAction Continue
Write-Information -MessageData "Windows PowerShell 5.1 Pester: $($ps51.Passed)/$($ps51.Total)" -InformationAction Continue
Write-Information -MessageData 'PSScriptAnalyzer: 0 findings' -InformationAction Continue
Write-Information -MessageData 'Native wpr.exe profile parse: PASS' -InformationAction Continue

if ($PassThru) {
    return $result
}
