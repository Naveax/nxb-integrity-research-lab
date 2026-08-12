[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

if ($env:OS -cne 'Windows_NT') { throw 'Production final V2 certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Production final V2 certification requires PowerShell 7.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Production final V2 requires elevated PowerShell 7 because the inherited native chain is mandatory.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'NxbProductionFinalization.Common.ps1')
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw ('Production final V2 exact-head mismatch: expected={0} actual={1}' -f $ExpectedHead,$currentHead)
}
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Production final V2 requires a clean exact-head worktree.' }

$childPath = Join-Path $PSScriptRoot 'Invoke-NxbProductionFinalCertification.ps1'
$extensionScannerPath = Join-Path $PSScriptRoot 'Invoke-NxbProductionKnownErrorScan.ps1'
$extensionConfigPath = Join-Path $repositoryRoot 'config\nxb-production-known-error-extension.json'
foreach ($requiredPath in @($childPath,$extensionScannerPath,$extensionConfigPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw ('Production final V2 component missing: {0}' -f $requiredPath) }
}

Import-Module PSScriptAnalyzer -ErrorAction Stop
$analyzerFinding = @(
    Invoke-ScriptAnalyzer -Path $PSCommandPath -Severity Warning,Error
    Invoke-ScriptAnalyzer -Path $extensionScannerPath -Severity Warning,Error
)
if ($analyzerFinding.Count -gt 0) {
    $detail = @($analyzerFinding | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join [Environment]::NewLine
    throw ('Production final V2 PSScriptAnalyzer findings: {0}{1}{2}' -f $analyzerFinding.Count,[Environment]::NewLine,$detail)
}

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$preScanPath = $outputFull + '-production-extension-pre.json'
$postScanPath = $outputFull + '-production-extension-post.json'
$topReceiptPath = $outputFull + '-v2-certification-receipt.json'
$topReviewRoot = $outputFull + '-v2-review'
$topReviewZip = $outputFull + '-v2-review.zip'
foreach ($reserved in @($preScanPath,$postScanPath,$topReceiptPath,$topReviewRoot,$topReviewZip)) {
    if (Test-Path -LiteralPath $reserved) { throw ('Production final V2 reserved output already exists: {0}' -f $reserved) }
}

Write-Information '=== NXB IRL-006 PART 6-10 PRODUCTION FINAL CERTIFICATION V2 ==='
Write-Information '[top 1/4] Permanent production known-error extension preflight'
$preScan = & $extensionScannerPath -RepositoryRoot $repositoryRoot -ConfigurationPath $extensionConfigPath -OutputPath $preScanPath -NoThrow -PassThru
if ([string]$preScan.status -cne 'passed' -or [int]$preScan.finding_count -ne 0 -or [int]$preScan.extension_rule_count -ne 9 -or [int]$preScan.guard_contract_count -ne 1) {
    throw ('Production final V2 extension preflight failed: rules={0} guards={1} findings={2}' -f [int]$preScan.extension_rule_count,[int]$preScan.guard_contract_count,[int]$preScan.finding_count)
}

Write-Information '[top 2/4] Run complete Part 5 predecessor plus Part 6-10 child authority'
$pipeline = @(& $childPath -ExpectedHead $ExpectedHead -OutputDirectory $outputFull -PassThru)
$child = $null
foreach ($item in $pipeline) {
    if ($null -eq $item) { continue }
    $property = $item.PSObject.Properties['status']
    if ($null -ne $property -and [string]$property.Value -ceq 'passed') { $child = $item }
}
if ($null -eq $child) { throw 'Production final V2 child returned no passed result.' }
if ([string]$child.head_sha -cne $currentHead) { throw 'Production final V2 child exact-head binding mismatch.' }
if ([string]$child.ps7 -cne '20/20' -or [string]$child.ps51 -cne '20/20') { throw 'Production final V2 child dual-runtime contract failed.' }
if ([int]$child.part6_requirements -ne 8 -or [int]$child.part7_requirements -ne 10 -or [int]$child.part8_requirements -ne 10 -or [int]$child.part9_requirements -ne 10 -or [int]$child.part10_requirements -ne 10) {
    throw 'Production final V2 child Part 6-10 requirement closure failed.'
}
if ([int]$child.independent_requirements -ne 48 -or [int]$child.independent_negative_controls -ne 12) {
    throw 'Production final V2 child independent replay closure failed.'
}
if ([int]$child.known_error_findings -ne 0 -or [int]$child.analyzer_findings -ne 0) { throw 'Production final V2 child zero-error closure failed.' }
if ([bool]$child.production_merge_performed -or -not [bool]$child.v1_freeze_candidate) { throw 'Production final V2 child freeze boundary failed.' }

Write-Information '[top 3/4] Permanent production known-error extension post-scan'
$postScan = & $extensionScannerPath -RepositoryRoot $repositoryRoot -ConfigurationPath $extensionConfigPath -OutputPath $postScanPath -NoThrow -PassThru
if ([string]$postScan.status -cne 'passed' -or [int]$postScan.finding_count -ne 0 -or [int]$postScan.extension_rule_count -ne 9 -or [int]$postScan.guard_contract_count -ne 1) {
    throw ('Production final V2 extension post-scan failed: rules={0} guards={1} findings={2}' -f [int]$postScan.extension_rule_count,[int]$postScan.guard_contract_count,[int]$postScan.finding_count)
}

Write-Information '[top 4/4] Bind child review and extension scans into top production closure'
$topReceipt = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    authority = 'nxb-irl006-part6-10-production-final-v2'
    head_sha = $currentHead
    release_version = [string]$child.release_version
    child_receipt_sha256 = Get-NxbFinalFileSha256 -Path ([string]$child.receipt_path)
    child_review_zip_sha256 = Get-NxbFinalFileSha256 -Path ([string]$child.review_zip_path)
    extension_pre_scan_sha256 = Get-NxbFinalFileSha256 -Path $preScanPath
    extension_post_scan_sha256 = Get-NxbFinalFileSha256 -Path $postScanPath
    base_known_error_rules = [int]$child.known_error_rules
    production_extension_rules = [int]$postScan.extension_rule_count
    production_guard_contracts = [int]$postScan.guard_contract_count
    known_error_findings = 0
    analyzer_findings = 0
    ps7 = [string]$child.ps7
    ps51 = [string]$child.ps51
    part6_requirements = [int]$child.part6_requirements
    part7_requirements = [int]$child.part7_requirements
    part8_requirements = [int]$child.part8_requirements
    part9_requirements = [int]$child.part9_requirements
    part10_requirements = [int]$child.part10_requirements
    independent_requirements = [int]$child.independent_requirements
    independent_negative_controls = [int]$child.independent_negative_controls
    production_merge_performed = $false
    v1_freeze_candidate = $true
}
Write-NxbFinalAtomicJson -Path $topReceiptPath -InputObject $topReceipt

[IO.Directory]::CreateDirectory($topReviewRoot) | Out-Null
$topFiles = @(
    @([string]$child.receipt_path,'production-final-child-receipt.json'),
    @($preScanPath,'production-known-error-extension-pre.json'),
    @($postScanPath,'production-known-error-extension-post.json'),
    @($topReceiptPath,'production-final-v2-certification-receipt.json')
)
foreach ($pair in $topFiles) {
    $destination = Join-Path $topReviewRoot ([string]$pair[1])
    [IO.File]::Copy([IO.Path]::GetFullPath([string]$pair[0]),$destination,$false)
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($topReviewRoot,$topReviewZip,[IO.Compression.CompressionLevel]::Optimal,$false)

Write-Information ('NXB production final V2 candidate passed: head={0} Part6=8/8 Part7=10/10 Part8=10/10 Part9=10/10 Part10=10/10 independent=48/48 negatives=12/12 base_rules={1} extension_rules=9 guards=1 findings=0.' -f $currentHead,[int]$child.known_error_rules)
if ($PassThru) {
    return [pscustomobject][ordered]@{
        status = 'passed'
        head_sha = $currentHead
        release_version = [string]$child.release_version
        ps7 = [string]$child.ps7
        ps51 = [string]$child.ps51
        part6_requirements = 8
        part7_requirements = 10
        part8_requirements = 10
        part9_requirements = 10
        part10_requirements = 10
        independent_requirements = 48
        independent_negative_controls = 12
        base_known_error_rules = [int]$child.known_error_rules
        production_extension_rules = 9
        production_guard_contracts = 1
        known_error_findings = 0
        analyzer_findings = 0
        production_merge_performed = $false
        v1_freeze_candidate = $true
        child_review_zip_path = [string]$child.review_zip_path
        child_review_zip_sha256 = Get-NxbFinalFileSha256 -Path ([string]$child.review_zip_path)
        receipt_path = $topReceiptPath
        receipt_sha256 = Get-NxbFinalFileSha256 -Path $topReceiptPath
        review_zip_path = $topReviewZip
        review_zip_sha256 = Get-NxbFinalFileSha256 -Path $topReviewZip
    }
}
Write-Output $topReviewZip
