[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Semantic control V2 exact-head mismatch. Expected=$ExpectedHead actual=$currentHead"
}
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'Semantic control V2 requires a clean exact-head worktree.'
}

$innerRunner = Join-Path $PSScriptRoot 'Invoke-NxbSuperblock1SemanticControlCertification.ps1'
$testPath = Join-Path $repositoryRoot 'tests\Superblock1SemanticControls.Tests.ps1'
$buildPath = Join-Path $PSScriptRoot 'Invoke-NxbSuperblock1SemanticControlFixtureBuild.ps1'
$analysisPath = Join-Path $PSScriptRoot 'Invoke-NxbSuperblock1SemanticControlAnalysis.ps1'
$analysisTool = Join-Path $repositoryRoot 'tools\analyze_superblock1_semantic_controls.py'
$profilePath = Join-Path $PSScriptRoot 'Test-NxbSuperblock1MultiDomainWprProfile.ps1'
$statisticsPath = Join-Path $PSScriptRoot 'Get-NxbEtlTraceStatistics.ps1'
$inventoryPath = Join-Path $PSScriptRoot 'Get-NxbSuperblock1XperfHeaderInventory.ps1'
$normalizerPath = Join-Path $PSScriptRoot 'ConvertFrom-NxbSuperblock1XperfDumper.ps1'
$analyzerPaths = @(
    $PSCommandPath,$innerRunner,$testPath,$buildPath,$analysisPath,
    $profilePath,$statisticsPath,$inventoryPath,$normalizerPath
)
foreach ($requiredPath in @($analyzerPaths + $analysisTool)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Semantic control V2 component is missing: $requiredPath"
    }
}

foreach ($scriptPath in $analyzerPaths) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        throw (
            "Semantic control V2 parser failed: $scriptPath`n" +
            (@($parseErrors | ForEach-Object { $_.Message }) -join "`n")
        )
    }
}

Import-Module PSScriptAnalyzer -ErrorAction Stop
$preflightFindings = @(
    foreach ($scriptPath in $analyzerPaths) {
        Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error
    }
)
if ($preflightFindings.Count -gt 0) {
    throw (
        "Semantic control V2 preflight PSScriptAnalyzer findings: $($preflightFindings.Count)`n" +
        (@($preflightFindings | ForEach-Object {
            '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message
        }) -join "`n")
    )
}

$python = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $python) { $python = Get-Command python -ErrorAction Stop }
& $python.Source -m py_compile $analysisTool
if ($LASTEXITCODE -ne 0) {
    throw 'Semantic control V2 Python syntax check failed.'
}

$previousRepositoryRoot = [Environment]::GetEnvironmentVariable('NXB_SEMANTIC_REPOSITORY_ROOT','Process')
$env:NXB_SEMANTIC_REPOSITORY_ROOT = [IO.Path]::GetFullPath($repositoryRoot)
try {
    if ([string]::IsNullOrWhiteSpace([string]$env:NXB_SEMANTIC_REPOSITORY_ROOT) -or
        -not (Test-Path -LiteralPath $env:NXB_SEMANTIC_REPOSITORY_ROOT -PathType Container)) {
        throw 'Semantic control V2 failed to establish the Pester repository root.'
    }
    Write-Information -MessageData "Semantic control Pester repository root: $env:NXB_SEMANTIC_REPOSITORY_ROOT" -InformationAction Continue
    Write-Information -MessageData "Semantic control PowerShell preflight analyzer findings: $($preflightFindings.Count)" -InformationAction Continue

    $innerOutput = @(
        & $innerRunner `
            -ExpectedHead $ExpectedHead `
            -OutputDirectory $OutputDirectory `
            -PassThru
    )
    $passedResult = $null
    foreach ($item in $innerOutput) {
        if ($null -eq $item) { continue }
        $statusProperty = $item.PSObject.Properties['status']
        if ($null -ne $statusProperty -and [string]$statusProperty.Value -ceq 'passed') {
            $passedResult = $item
        }
    }
    if ($null -eq $passedResult) {
        throw 'Semantic control V2 inner runner returned no passed result object.'
    }
    if ($PassThru) { return $passedResult }
}
finally {
    if ($null -eq $previousRepositoryRoot) {
        Remove-Item Env:NXB_SEMANTIC_REPOSITORY_ROOT -ErrorAction SilentlyContinue
    }
    else {
        $env:NXB_SEMANTIC_REPOSITORY_ROOT = $previousRepositoryRoot
    }
}
