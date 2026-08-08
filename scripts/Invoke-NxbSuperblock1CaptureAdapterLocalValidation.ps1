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

function Invoke-NxbSuperblockBatchPesterRun {
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

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('nxb-superblock-batch-' + [guid]::NewGuid().ToString('N'))
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
if ($summary.passed -ne 8 -or $summary.total -ne 8 -or $summary.failed -ne 0 -or $summary.skipped -ne 0) {
    exit 1
}
'@ | Set-Content -LiteralPath $childPath -Encoding UTF8

    try {
        $childOutput = @(
            & $Executable -NoLogo -NoProfile -ExecutionPolicy Bypass -File $childPath -TestPath $TestPath -ResultPath $resultPath 2>&1
        )
        $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        foreach ($line in $childOutput) {
            Write-Information -MessageData ([string]$line) -InformationAction Continue
        }
        if ($exitCode -ne 0) {
            throw "$Label Pester run failed with exit code $exitCode."
        }
        $summary = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        return [pscustomobject][ordered]@{
            label = $Label
            passed = [int]$summary.passed
            failed = [int]$summary.failed
            skipped = [int]$summary.skipped
            total = [int]$summary.total
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

if ($env:OS -cne 'Windows_NT') {
    throw 'SUPERBLOCK capture/adapter local validation requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'SUPERBLOCK capture/adapter local validation requires PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}
$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'SUPERBLOCK capture/adapter validation requires a clean exact-head worktree.'
}

$probePath = Join-Path $PSScriptRoot 'Invoke-NxbSelectedProviderMetadataProbe.ps1'
$adapterPath = Join-Path $PSScriptRoot 'ConvertTo-NxbSuperblock1CapabilityAdapter.ps1'
$probeTestPath = Join-Path $repositoryRoot 'tests\SelectedProviderMetadataProbe.Tests.ps1'
$adapterTestPath = Join-Path $repositoryRoot 'tests\Superblock1CapabilityAdapter.Tests.ps1'
$runnerPath = $PSCommandPath

foreach ($requiredPath in @($probePath,$adapterPath,$probeTestPath,$adapterTestPath,$runnerPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required SUPERBLOCK capture/adapter validation file missing: $requiredPath"
    }
}

foreach ($scriptPath in @($probePath,$adapterPath,$probeTestPath,$adapterTestPath,$runnerPath)) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
    if (@($errors).Count -gt 0) {
        throw (
            "PowerShell parser failed: $scriptPath`n" +
            (@($errors | ForEach-Object { $_.Message }) -join "`n")
        )
    }
}

Import-Module PSScriptAnalyzer -ErrorAction Stop
$findings = @(
    foreach ($scriptPath in @($probePath,$adapterPath,$probeTestPath,$adapterTestPath,$runnerPath)) {
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
$windowsPowerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShellPath -PathType Leaf)) {
    throw "Windows PowerShell 5.1 executable missing: $windowsPowerShellPath"
}

$ps7Probe = Invoke-NxbSuperblockBatchPesterRun -Executable $pwshPath -TestPath $probeTestPath -Label 'PowerShell 7 selected provider metadata'
$ps7Adapter = Invoke-NxbSuperblockBatchPesterRun -Executable $pwshPath -TestPath $adapterTestPath -Label 'PowerShell 7 capability adapter'
$ps51Probe = Invoke-NxbSuperblockBatchPesterRun -Executable $windowsPowerShellPath -TestPath $probeTestPath -Label 'Windows PowerShell 5.1 selected provider metadata'
$ps51Adapter = Invoke-NxbSuperblockBatchPesterRun -Executable $windowsPowerShellPath -TestPath $adapterTestPath -Label 'Windows PowerShell 5.1 capability adapter'

$postDirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) {
    throw 'SUPERBLOCK capture/adapter validation dirtied the exact-head worktree.'
}

$result = [pscustomobject][ordered]@{
    status = 'passed'
    head_sha = $currentHead
    powershell7 = [ordered]@{
        selected_provider_metadata = $ps7Probe
        capability_adapter = $ps7Adapter
        passed = 16
        total = 16
    }
    windows_powershell_51 = [ordered]@{
        selected_provider_metadata = $ps51Probe
        capability_adapter = $ps51Adapter
        passed = 16
        total = 16
    }
    analyzer_findings = 0
    real_provider_metadata_executed = $false
    real_capability_adapter_executed = $false
    semantic_claims_enabled = $false
    trace_completeness = 'not_claimed'
}

Write-Information -MessageData "SUPERBLOCK capture/adapter local validation passed: $currentHead" -InformationAction Continue
Write-Information -MessageData 'PowerShell 7 Pester: 16/16' -InformationAction Continue
Write-Information -MessageData 'Windows PowerShell 5.1 Pester: 16/16' -InformationAction Continue
Write-Information -MessageData 'PSScriptAnalyzer: 0 findings' -InformationAction Continue
Write-Information -MessageData 'Real selected-provider metadata executed: False' -InformationAction Continue
Write-Information -MessageData 'Real capability adapter executed: False' -InformationAction Continue

if ($PassThru) { return $result }
