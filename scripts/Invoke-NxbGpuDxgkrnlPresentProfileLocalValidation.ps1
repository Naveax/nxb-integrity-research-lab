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

function Invoke-NxbGpuProfilePesterRun {
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

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("nxb-gpu-profile-pester-$([guid]::NewGuid().ToString('N'))")
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $childPath = Join-Path $tempRoot 'invoke-pester.ps1'
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
if ($summary.failed -ne 0 -or $summary.skipped -ne 0 -or $summary.passed -le 0) { exit 1 }
'@ | Set-Content -LiteralPath $childPath -Encoding UTF8

    try {
        $childOutput = @(
            & $Executable -NoLogo -NoProfile -ExecutionPolicy Bypass -File $childPath -TestPath $TestPath -ResultPath $resultPath 2>&1
        )
        $exitCode = $LASTEXITCODE
        foreach ($line in $childOutput) {
            Write-Information -MessageData ([string]$line) -InformationAction Continue
        }
        if ($exitCode -ne 0) {
            throw "$Label Pester run failed with exit code $exitCode."
        }
        $summary = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
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
    throw 'GPU profile native validation requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'GPU profile local validation must run in PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}
$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'GPU profile validation requires a clean exact-head worktree.'
}

$profilePath = Join-Path $repositoryRoot 'profiles\Nxb.GpuDxgkrnlPresent.wprp'
$validatorPath = Join-Path $PSScriptRoot 'Test-NxbGpuDxgkrnlPresentWprProfile.ps1'
$testPath = Join-Path $repositoryRoot 'tests\GpuDxgkrnlPresentWprProfile.Tests.ps1'
$runnerPath = $PSCommandPath
foreach ($requiredPath in @($profilePath,$validatorPath,$testPath,$runnerPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required GPU profile validation file missing: $requiredPath"
    }
}

foreach ($scriptPath in @($validatorPath,$testPath,$runnerPath)) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
    if (@($errors).Count -gt 0) {
        throw "PowerShell parser failed: $scriptPath"
    }
}

Import-Module PSScriptAnalyzer -ErrorAction Stop
$findings = @(
    foreach ($scriptPath in @($validatorPath,$testPath,$runnerPath)) {
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

$ps7 = Invoke-NxbGpuProfilePesterRun -Executable $pwshPath -TestPath $testPath -Label 'PowerShell 7 GPU profile'
$ps51 = Invoke-NxbGpuProfilePesterRun -Executable $windowsPowerShellPath -TestPath $testPath -Label 'Windows PowerShell 5.1 GPU profile'

if ($ps7.Passed -ne 8 -or $ps7.Total -ne 8 -or $ps7.Failed -ne 0 -or $ps7.Skipped -ne 0) {
    throw 'PowerShell 7 GPU profile Pester gate is not 8/8 clean.'
}
if ($ps51.Passed -ne 8 -or $ps51.Total -ne 8 -or $ps51.Failed -ne 0 -or $ps51.Skipped -ne 0) {
    throw 'Windows PowerShell 5.1 GPU profile Pester gate is not 8/8 clean.'
}

$wprPath = (Get-Command wpr.exe -ErrorAction Stop).Source
$wprOutput = @(& $wprPath -profiles $profilePath 2>&1)
$wprExitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
if ($wprExitCode -ne 0) {
    throw (
        "Native wpr.exe profile parse failed (exit $wprExitCode):`n" +
        ($wprOutput -join [Environment]::NewLine)
    )
}
$profileListed = (($wprOutput -join [Environment]::NewLine) -match 'NxbGpuDxgkrnlPresent')
if (-not $profileListed) {
    throw 'Native wpr.exe output did not enumerate NxbGpuDxgkrnlPresent.'
}

$postDirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) {
    throw 'GPU profile validation dirtied the exact-head worktree.'
}

$result = [pscustomobject][ordered]@{
    status = 'passed'
    head_sha = $currentHead
    profile = $profile
    powershell7 = $ps7
    windows_powershell_51 = $ps51
    analyzer_findings = 0
    native_wpr_profile_parse = 'passed'
    native_profile_listed = $true
    real_capture_executed = $false
    semantic_claims_enabled = $false
    trace_completeness = 'not_claimed'
}

Write-Information -MessageData "GPU DXGKRNL present profile local validation passed: $currentHead" -InformationAction Continue
Write-Information -MessageData "PowerShell 7 Pester: $($ps7.Passed)/$($ps7.Total)" -InformationAction Continue
Write-Information -MessageData "Windows PowerShell 5.1 Pester: $($ps51.Passed)/$($ps51.Total)" -InformationAction Continue
Write-Information -MessageData 'PSScriptAnalyzer: 0 findings' -InformationAction Continue
Write-Information -MessageData 'Native wpr.exe profile parse: PASS' -InformationAction Continue
Write-Information -MessageData 'Real GPU capture executed: False' -InformationAction Continue

if ($PassThru) { return $result }
