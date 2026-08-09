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

function Invoke-NxbCorrelationPesterRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$TestPath,
        [Parameter(Mandatory)][string]$Label
    )
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("nxb-superblock-correlation-pester-$([guid]::NewGuid().ToString('N'))")
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $childPath = Join-Path $tempRoot 'invoke-pester.ps1'
    $resultPath = Join-Path $tempRoot 'result.json'
    @'
param([string]$TestPath,[string]$ResultPath)
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
if ($summary.passed -ne 10 -or $summary.total -ne 10 -or $summary.failed -ne 0 -or $summary.skipped -ne 0) { exit 1 }
'@ | Set-Content -LiteralPath $childPath -Encoding UTF8
    try {
        $childOutput = @(& $Executable -NoLogo -NoProfile -ExecutionPolicy Bypass -File $childPath -TestPath $TestPath -ResultPath $resultPath 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        foreach ($line in $childOutput) {
            Write-Information -MessageData ([string]$line) -InformationAction Continue
        }
        if ($exitCode -ne 0) { throw "$Label Pester run failed: exit=$exitCode" }
        return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}

if ($env:OS -cne 'Windows_NT') { throw 'SUPERBLOCK correlation validation requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'SUPERBLOCK correlation validation requires PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected=$ExpectedHead actual=$currentHead"
}
$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'SUPERBLOCK correlation validation requires a clean exact-head worktree.'
}

$wrapperPath = Join-Path $PSScriptRoot 'Invoke-NxbSuperblock1CorrelationAnalysis.ps1'
$certificationPath = Join-Path $PSScriptRoot 'Invoke-NxbSuperblock1CorrelationCertification.ps1'
$testPath = Join-Path $repositoryRoot 'tests\Superblock1Correlation.Tests.ps1'
$toolPath = Join-Path $repositoryRoot 'tools\analyze_superblock1_correlations.py'
$runnerPath = $PSCommandPath
foreach ($path in @($wrapperPath,$certificationPath,$testPath,$toolPath,$runnerPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required correlation file missing: $path" }
}

foreach ($path in @($wrapperPath,$certificationPath,$testPath,$runnerPath)) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    if (@($errors).Count -gt 0) { throw "PowerShell parser failed: $path" }
}

Import-Module PSScriptAnalyzer -ErrorAction Stop
$findings = @(
    foreach ($path in @($wrapperPath,$certificationPath,$testPath,$runnerPath)) {
        Invoke-ScriptAnalyzer -Path $path -Severity Warning,Error
    }
)
if ($findings.Count -gt 0) {
    throw ("PSScriptAnalyzer findings: $($findings.Count)`n" + (@($findings | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join "`n"))
}

$python = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $python) { $python = Get-Command python -ErrorAction Stop }
$syntaxCode = 'import ast,pathlib,sys; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))'
$syntaxOutput = @(& $python.Source -c $syntaxCode $toolPath 2>&1)
$syntaxExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
if ($syntaxExit -ne 0) { throw "Python syntax validation failed: $($syntaxOutput -join ' ')" }

$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ps7Result = Invoke-NxbCorrelationPesterRun -Executable $pwsh -TestPath $testPath -Label 'PowerShell 7 correlation'
$ps51Result = Invoke-NxbCorrelationPesterRun -Executable $ps51 -TestPath $testPath -Label 'Windows PowerShell 5.1 correlation'

$postDirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) { throw 'Correlation validation dirtied the exact-head worktree.' }

$result = [pscustomobject][ordered]@{
    status = 'passed'
    head_sha = $currentHead
    powershell7 = [pscustomobject][ordered]@{ passed=[int]$ps7Result.passed; total=[int]$ps7Result.total; failed=[int]$ps7Result.failed; skipped=[int]$ps7Result.skipped }
    windows_powershell_51 = [pscustomobject][ordered]@{ passed=[int]$ps51Result.passed; total=[int]$ps51Result.total; failed=[int]$ps51Result.failed; skipped=[int]$ps51Result.skipped }
    analyzer_findings = 0
    python_syntax = 'passed'
    structural_correlation = $true
    semantic_claims_enabled = $false
    trace_completeness = 'not_claimed'
}
Write-Information -MessageData "SUPERBLOCK correlation local validation passed: $currentHead" -InformationAction Continue
Write-Information -MessageData "PowerShell 7: $($result.powershell7.passed)/$($result.powershell7.total)" -InformationAction Continue
Write-Information -MessageData "Windows PowerShell 5.1: $($result.windows_powershell_51.passed)/$($result.windows_powershell_51.total)" -InformationAction Continue
Write-Information -MessageData 'PSScriptAnalyzer: 0 findings' -InformationAction Continue
Write-Information -MessageData 'Python syntax: PASS' -InformationAction Continue
if ($PassThru) { return $result }
