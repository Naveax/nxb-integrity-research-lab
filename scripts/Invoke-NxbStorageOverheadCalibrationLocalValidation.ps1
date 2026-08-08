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

function Invoke-NxbStorageOverheadPesterRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Executable,

        [Parameter(Mandatory)]
        [string]$TestPath,

        [Parameter(Mandatory)]
        [string]$Label
    )

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
        'nxb-storage-overhead-pester-' + [guid]::NewGuid().ToString('N')
    )
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
    throw 'Storage overhead calibration validation requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Storage overhead calibration validation must run from PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}
$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'Storage overhead calibration validation requires a clean exact-head worktree.'
}

$measuredPath = Join-Path $PSScriptRoot 'Invoke-NxbMeasuredStorageWorkload.ps1'
$calibrationPath = Join-Path $PSScriptRoot 'Invoke-NxbStorageOverheadCalibration.ps1'
$testPath = Join-Path $repositoryRoot 'tests\StorageOverheadCalibration.Tests.ps1'
$profilePath = Join-Path $repositoryRoot 'profiles\Nxb.StorageIOQueue.wprp'
$profileValidatorPath = Join-Path $PSScriptRoot 'Test-NxbStorageWprProfile.ps1'
$overheadValidatorPath = Join-Path $PSScriptRoot 'Test-CollectorOverheadCalibration.ps1'
$overheadSchemaPath = Join-Path $repositoryRoot 'schemas\collector-overhead-calibration.schema.json'
$pythonValidatorPath = Join-Path $repositoryRoot 'tools\validate_overhead_calibration.py'
$runnerPath = $PSCommandPath

foreach ($requiredPath in @(
    $measuredPath,
    $calibrationPath,
    $testPath,
    $profilePath,
    $profileValidatorPath,
    $overheadValidatorPath,
    $overheadSchemaPath,
    $pythonValidatorPath,
    $runnerPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required storage overhead calibration file missing: $requiredPath"
    }
}

foreach ($scriptPath in @(
    $measuredPath,
    $calibrationPath,
    $testPath,
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
        $measuredPath,
        $calibrationPath,
        $testPath,
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

$profile = & $profileValidatorPath -PassThru
if ([bool]$profile.KernelQueueEnabled) {
    throw 'Storage overhead validation found KernelQueue enabled.'
}
if ([int]$profile.MaximumFileSizeMiB -ne 512 -or
    [string]$profile.FileMode -cne 'Circular') {
    throw 'Storage overhead validation profile bound mismatch.'
}

$wpr = Get-Command wpr.exe -ErrorAction Stop
$nativeOutput = @(& $wpr.Source -profiles $profilePath 2>&1)
$nativeExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
foreach ($line in $nativeOutput) {
    Write-Information -MessageData ([string]$line) -InformationAction Continue
}
if ($nativeExit -ne 0) {
    throw "Native WPR profile parse failed with exit code $nativeExit."
}

$pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
$windowsPowerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShellPath -PathType Leaf)) {
    throw "Windows PowerShell 5.1 executable missing: $windowsPowerShellPath"
}

$ps7 = Invoke-NxbStorageOverheadPesterRun `
    -Executable $pwshPath `
    -TestPath $testPath `
    -Label 'PowerShell 7 storage overhead calibration'
$ps51 = Invoke-NxbStorageOverheadPesterRun `
    -Executable $windowsPowerShellPath `
    -TestPath $testPath `
    -Label 'Windows PowerShell 5.1 storage overhead calibration'

$postDirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) {
    throw 'Storage overhead calibration validation dirtied the exact-head worktree.'
}

$result = [pscustomobject][ordered]@{
    status = 'passed'
    head_sha = $currentHead
    powershell7 = $ps7
    windows_powershell_51 = $ps51
    analyzer_findings = 0
    native_wpr_profile_parse = 'passed'
    profile_sha256 = [string]$profile.Sha256
    kernel_queue_enabled = [bool]$profile.KernelQueueEnabled
    default_warmup_count = 1
    default_repetition_count = 3
    default_ordering = 'alternating_control_first'
    default_file_size_mib = 16
    default_block_size_kib = 256
    threshold_policy = 'not_declared'
    raw_calibration_etl_in_review_zip = $false
    real_calibration_executed = $false
}

Write-Information -MessageData "Storage overhead calibration local validation passed: $currentHead" -InformationAction Continue
Write-Information -MessageData "PowerShell 7 Pester: $($ps7.Passed)/$($ps7.Total)" -InformationAction Continue
Write-Information -MessageData "Windows PowerShell 5.1 Pester: $($ps51.Passed)/$($ps51.Total)" -InformationAction Continue
Write-Information -MessageData 'PSScriptAnalyzer: 0 findings' -InformationAction Continue
Write-Information -MessageData 'Native WPR profile parse: PASS' -InformationAction Continue
Write-Information -MessageData 'Real calibration executed: False' -InformationAction Continue

if ($PassThru) {
    return $result
}
