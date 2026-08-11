[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -cne 'Windows_NT') { throw 'Part 2 V2 certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Part 2 V2 certification requires PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw ('Part 2 V2 exact-head mismatch. Expected={0} actual={1}' -f $ExpectedHead,$currentHead)
}
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Part 2 V2 certification requires a clean exact-head worktree.' }

$preflightPath = Join-Path $PSScriptRoot 'Test-NxbSemanticHardeningHostCapability.ps1'
$childPath = Join-Path $PSScriptRoot 'Invoke-NxbSemanticHardeningCertification.ps1'
$scannerPath = Join-Path $PSScriptRoot 'Invoke-NxbKnownErrorScan.ps1'
$signaturePath = Join-Path $repositoryRoot 'config\nxb-known-error-signatures.json'
foreach ($requiredPath in @($preflightPath,$childPath,$scannerPath,$signaturePath,$PSCommandPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw ('Part 2 V2 component missing: {0}' -f $requiredPath) }
}

Write-Information -InformationAction Continue -MessageData '=== NXB IRL-006 PART 2 8/8 SEMANTIC HARDENING CERTIFICATION V2 ==='
Write-Information -InformationAction Continue -MessageData '[preflight 1/3] Parser/analyzer + inherited known-error scan'
foreach ($scriptPath in @($preflightPath,$PSCommandPath)) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        throw ('Part 2 V2 parser failed: {0}`n{1}' -f $scriptPath,(@($parseErrors | ForEach-Object { $_.Message }) -join "`n"))
    }
}
Import-Module PSScriptAnalyzer -ErrorAction Stop
$analyzerFinding = @(foreach ($scriptPath in @($preflightPath,$PSCommandPath)) { Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error })
if ($analyzerFinding.Count -gt 0) {
    throw ('Part 2 V2 PSScriptAnalyzer findings: {0}`n{1}' -f $analyzerFinding.Count,(@($analyzerFinding | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join "`n"))
}
$scan = & $scannerPath -RepositoryRoot $repositoryRoot -SignaturePath $signaturePath -NoThrow -PassThru
if ([string]$scan.status -cne 'passed' -or [int]$scan.finding_count -ne 0) {
    $detail = @($scan.findings | ForEach-Object { '{0} {1}:{2} {3}' -f $_.id,$_.path,$_.line,$_.preview }) -join [Environment]::NewLine
    throw ('Part 2 V2 known-error preflight failed: findings={0}{1}{2}' -f [int]$scan.finding_count,[Environment]::NewLine,$detail)
}

Write-Information -InformationAction Continue -MessageData '[preflight 2/3] Fail-fast native host capability gate'
$hostCapability = & $preflightPath -PassThru
if ([string]$hostCapability.status -cne 'passed') { throw 'Part 2 V2 host capability gate did not pass.' }

Write-Information -InformationAction Continue -MessageData '[preflight 3/3] Run complete Part 2 child authority'
$childPipeline = @(& $childPath -ExpectedHead $ExpectedHead -OutputDirectory $OutputDirectory -PassThru)
$child = $null
foreach ($item in $childPipeline) {
    if ($null -eq $item) { continue }
    $statusProperty = $item.PSObject.Properties['status']
    if ($null -ne $statusProperty -and [string]$statusProperty.Value -ceq 'passed') { $child = $item }
}
if ($null -eq $child) { throw 'Part 2 V2 child authority returned no passed result.' }
if ([string]$child.head_sha -cne $currentHead -or [int]$child.requested -ne 8 -or [int]$child.validated -ne 8) {
    throw 'Part 2 V2 child authority result contract mismatch.'
}

$result = [pscustomobject][ordered]@{
    schema_version = 2
    status = 'passed'
    head_sha = $currentHead
    requested = [int]$child.requested
    validated = [int]$child.validated
    host_capability = 'passed'
    ps7_tests = [string]$child.ps7_tests
    ps51_tests = [string]$child.ps51_tests
    psscriptanalyzer_findings = [int]$child.psscriptanalyzer_findings
    known_error_rule_count = [int]$child.known_error_rule_count
    known_error_finding_count = [int]$child.known_error_finding_count
    independent_validation = [bool]$child.independent_validation
    inherited_part1_status = [string]$child.inherited_part1_status
    inherited_part1_head = [string]$child.inherited_part1_head
    policy_fingerprint_sha256 = [string]$child.policy_fingerprint_sha256
    review_zip_path = [string]$child.review_zip_path
    review_zip_sha256 = [string]$child.review_zip_sha256
    receipt_path = [string]$child.receipt_path
    receipt_sha256 = [string]$child.receipt_sha256
    work_root = [string]$child.work_root
    part1_output = [string]$child.part1_output
    root_trace_output = [string]$child.root_trace_output
}
Write-Information -InformationAction Continue -MessageData ('NXB IRL-006 Part 2 V2 passed: requested={0} validated={1}' -f $result.requested,$result.validated)
if ($PassThru) { return $result }
Write-Output ([string]$result.review_zip_path)
