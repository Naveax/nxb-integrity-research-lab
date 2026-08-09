[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Semantic eligibility V3 exact-head mismatch. Expected=$ExpectedHead actual=$currentHead"
}
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'Semantic eligibility V3 requires a clean exact-head worktree.'
}

$innerRunner = Join-Path $PSScriptRoot 'Invoke-NxbSuperblock1SemanticEligibilityCertificationV2.ps1'
$testPath = Join-Path $repositoryRoot 'tests\Superblock1SemanticFixtureV2.Tests.ps1'
foreach ($requiredPath in @($innerRunner,$testPath,$PSCommandPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Semantic eligibility V3 component is missing: $requiredPath"
    }
}

Import-Module PSScriptAnalyzer -ErrorAction Stop
$selfFindings = @(Invoke-ScriptAnalyzer -Path $PSCommandPath -Severity Warning,Error)
if ($selfFindings.Count -gt 0) {
    throw (
        "Semantic eligibility V3 wrapper PSScriptAnalyzer findings: $($selfFindings.Count)`n" +
        (@($selfFindings | ForEach-Object {
            '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message
        }) -join "`n")
    )
}

$previousRepositoryRoot = [Environment]::GetEnvironmentVariable('NXB_SEMANTIC_REPOSITORY_ROOT','Process')
$env:NXB_SEMANTIC_REPOSITORY_ROOT = [IO.Path]::GetFullPath($repositoryRoot)
try {
    if ([string]::IsNullOrWhiteSpace([string]$env:NXB_SEMANTIC_REPOSITORY_ROOT) -or
        -not (Test-Path -LiteralPath $env:NXB_SEMANTIC_REPOSITORY_ROOT -PathType Container)) {
        throw 'Semantic eligibility V3 failed to establish the explicit Pester repository root.'
    }

    Write-Information -MessageData "Semantic Pester repository root: $env:NXB_SEMANTIC_REPOSITORY_ROOT" -InformationAction Continue
    $innerResult = @(
        & $innerRunner `
            -ExpectedHead $ExpectedHead `
            -OutputDirectory $OutputDirectory `
            -PassThru
    )

    $passedResult = $null
    foreach ($item in $innerResult) {
        if ($null -eq $item) {
            continue
        }
        $statusProperty = $item.PSObject.Properties['status']
        if ($null -ne $statusProperty -and [string]$statusProperty.Value -ceq 'passed') {
            $passedResult = $item
        }
    }
    if ($null -eq $passedResult) {
        throw 'Semantic eligibility V3 inner runner returned no passed result object.'
    }
    if ($PassThru) {
        return $passedResult
    }
}
finally {
    if ($null -eq $previousRepositoryRoot) {
        Remove-Item Env:NXB_SEMANTIC_REPOSITORY_ROOT -ErrorAction SilentlyContinue
    }
    else {
        $env:NXB_SEMANTIC_REPOSITORY_ROOT = $previousRepositoryRoot
    }
}
