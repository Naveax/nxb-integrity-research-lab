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

function Invoke-NxbStorageHeaderPesterRun {
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

    $tempRoot = Join-Path `
        ([IO.Path]::GetTempPath()) `
        ("nxb-storage-header-pester-$([guid]::NewGuid().ToString('N'))")
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
if ($summary.failed -ne 0 -or $summary.skipped -ne 0 -or $summary.passed -le 0) {
    exit 1
}
'@ | Set-Content -LiteralPath $childPath -Encoding UTF8

    try {
        $childOutput = @(
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
        foreach ($line in $childOutput) {
            Write-Information -MessageData ([string]$line) -InformationAction Continue
        }
        if ($exitCode -ne 0) {
            throw "$Label Pester run failed with exit code $exitCode."
        }

        $summary = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if ([int]$summary.failed -ne 0 -or
            [int]$summary.skipped -ne 0 -or
            [int]$summary.passed -le 0 -or
            [int]$summary.passed -ne [int]$summary.total) {
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
    throw 'Storage header inspection validation requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Storage header inspection validation must run in PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}

$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'Storage header inspection validation requires a clean worktree.'
}

$parserPath = Join-Path $PSScriptRoot 'Get-NxbXperfStorageHeaderInventory.ps1'
$inspectionPath = Join-Path $PSScriptRoot 'Invoke-NxbStorageHeaderInspection.ps1'
$testPath = Join-Path $repositoryRoot 'tests\XperfStorageHeaderInventory.Tests.ps1'
$fixturePath = Join-Path $repositoryRoot 'tests\fixtures\xperf-storage-header-inventory.valid.txt'
$profileValidatorPath = Join-Path $PSScriptRoot 'Test-NxbStorageWprProfile.ps1'
$runnerPath = $PSCommandPath

foreach ($requiredPath in @(
    $parserPath,
    $inspectionPath,
    $testPath,
    $fixturePath,
    $profileValidatorPath,
    $runnerPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required storage header file missing: $requiredPath"
    }
}

foreach ($scriptPath in @(
    $parserPath,
    $inspectionPath,
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
        $parserPath,
        $inspectionPath,
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

$inspectionText = Get-Content -LiteralPath $inspectionPath -Raw
$startMarker = '$wprStarted = $true'
$startMarkerIndex = $inspectionText.IndexOf($startMarker, [StringComparison]::Ordinal)
if ($startMarkerIndex -lt 0) {
    throw 'Storage inspection WPR start ownership marker was not found.'
}
$preStartText = $inspectionText.Substring(0, $startMarkerIndex)
if ($preStartText -match '(?i)\bwpr(?:\.Source)?\s+-cancel\b|&\s+\$wpr\.Source\s+-cancel') {
    throw 'Storage inspection may not cancel a WPR session before owning one.'
}
if ($inspectionText -notmatch [regex]::Escape('[ValidateRange(4, 64)]')) {
    throw 'Storage inspection bounded FileSizeMiB contract is missing.'
}
if ($inspectionText -notmatch "raw_etl_in_review\s*=\s*\$false") {
    throw 'Storage inspection raw-ETL review exclusion claim is missing.'
}
if ($inspectionText -notmatch "queue_semantics\s*=\s*'not_claimed'") {
    throw 'Storage inspection queue-semantics boundary is missing.'
}

$profile = & $profileValidatorPath -PassThru
if ([string]$profile.Name -cne 'NxbStorageIOQueue') {
    throw 'Storage profile validator returned an unexpected profile.'
}
if ([bool]$profile.KernelQueueEnabled) {
    throw 'KernelQueue must remain disabled.'
}

$pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
$windowsPowerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShellPath -PathType Leaf)) {
    throw "Windows PowerShell 5.1 executable missing: $windowsPowerShellPath"
}

$ps7 = Invoke-NxbStorageHeaderPesterRun `
    -Executable $pwshPath `
    -TestPath $testPath `
    -Label 'PowerShell 7'
$ps51 = Invoke-NxbStorageHeaderPesterRun `
    -Executable $windowsPowerShellPath `
    -TestPath $testPath `
    -Label 'Windows PowerShell 5.1'

$postDirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) {
    throw 'Storage header validation left the exact-head worktree dirty.'
}

$result = [pscustomobject]@{
    status = 'passed'
    head_sha = $currentHead
    powershell7 = $ps7
    windows_powershell_51 = $ps51
    analyzer_findings = 0
    pre_start_auto_cancel = $false
    file_size_mib_min = 4
    file_size_mib_max = 64
    raw_etl_in_review = $false
    queue_semantics_claimed = $false
}

Write-Information -MessageData "Storage header inspection validation passed: $currentHead" -InformationAction Continue
Write-Information -MessageData "PowerShell 7 Pester: $($ps7.Passed)/$($ps7.Total)" -InformationAction Continue
Write-Information -MessageData "Windows PowerShell 5.1 Pester: $($ps51.Passed)/$($ps51.Total)" -InformationAction Continue
Write-Information -MessageData 'PSScriptAnalyzer: 0 findings' -InformationAction Continue
Write-Information -MessageData 'Pre-start WPR auto-cancel: False' -InformationAction Continue
Write-Information -MessageData 'Queue semantics claimed: False' -InformationAction Continue

if ($PassThru) {
    return $result
}
