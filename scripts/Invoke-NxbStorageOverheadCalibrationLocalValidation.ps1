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

function Invoke-NxbStorageCalibrationPesterRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Executable,

        [Parameter(Mandatory)]
        [string]$TestPath,

        [Parameter(Mandatory)]
        [string]$Label
    )

    $tempRoot = Join-Path `
        ([IO.Path]::GetTempPath()) `
        ('nxb-storage-calibration-pester-' + [guid]::NewGuid().ToString('N'))
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
if ($summary.passed -ne 8 -or $summary.total -ne 8 -or
    $summary.failed -ne 0 -or $summary.skipped -ne 0) {
    exit 1
}
'@ | Set-Content -LiteralPath $childPath -Encoding UTF8

    try {
        $output = @(
            & $Executable `
                -NoLogo `
                -NoProfile `
                -ExecutionPolicy Bypass `
                -File $childPath `
                -TestPath $TestPath `
                -ResultPath $resultPath `
                2>&1
        )
        $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        foreach ($line in $output) {
            Write-Information -MessageData ([string]$line) -InformationAction Continue
        }
        if ($exitCode -ne 0) {
            throw "$Label Pester run failed with exit code $exitCode."
        }
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            throw "$Label Pester result JSON was not produced."
        }
        $summary = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if ([int]$summary.passed -ne 8 -or [int]$summary.total -ne 8 -or
            [int]$summary.failed -ne 0 -or [int]$summary.skipped -ne 0) {
            throw "$Label Pester result is not clean 8/8."
        }
        return [pscustomobject][ordered]@{
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
    throw 'Storage overhead calibration local validation requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Storage overhead calibration local validation requires PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}
$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'Storage overhead calibration local validation requires a clean exact-head worktree.'
}

$calibrationPath = Join-Path $PSScriptRoot 'Invoke-NxbStorageOverheadCalibration.ps1'
$testPath = Join-Path $repositoryRoot 'tests\StorageOverheadCalibration.Tests.ps1'
$runnerPath = $PSCommandPath
foreach ($required in @($calibrationPath,$testPath,$runnerPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required storage calibration validation file missing: $required"
    }
}

foreach ($scriptPath in @($calibrationPath,$testPath,$runnerPath)) {
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
    foreach ($scriptPath in @($calibrationPath,$testPath,$runnerPath)) {
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

$pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
$windowsPowerShellPath = Join-Path `
    $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShellPath -PathType Leaf)) {
    throw "Windows PowerShell 5.1 executable missing: $windowsPowerShellPath"
}

$ps7 = Invoke-NxbStorageCalibrationPesterRun `
    -Executable $pwshPath `
    -TestPath $testPath `
    -Label 'PowerShell 7 storage overhead calibration'
$ps51 = Invoke-NxbStorageCalibrationPesterRun `
    -Executable $windowsPowerShellPath `
    -TestPath $testPath `
    -Label 'Windows PowerShell 5.1 storage overhead calibration'

$postDirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) {
    throw 'Storage overhead calibration local validation dirtied the exact-head worktree.'
}

$result = [pscustomobject][ordered]@{
    status = 'passed'
    head_sha = $currentHead
    powershell7 = $ps7
    windows_powershell_51 = $ps51
    analyzer_findings = 0
    warmup_required = $true
    alternating_pair_order = $true
    production_threshold_policy = 'not_declared'
    representative_benchmark = $false
    trace_completeness = 'not_claimed'
}

Write-Information -MessageData "Storage overhead calibration local validation passed: $currentHead" -InformationAction Continue
Write-Information -MessageData "PowerShell 7 Pester: $($ps7.Passed)/$($ps7.Total)" -InformationAction Continue
Write-Information -MessageData "Windows PowerShell 5.1 Pester: $($ps51.Passed)/$($ps51.Total)" -InformationAction Continue
Write-Information -MessageData 'PSScriptAnalyzer: 0 findings' -InformationAction Continue
Write-Information -MessageData 'Production threshold policy: not_declared' -InformationAction Continue

if ($PassThru) { return $result }
