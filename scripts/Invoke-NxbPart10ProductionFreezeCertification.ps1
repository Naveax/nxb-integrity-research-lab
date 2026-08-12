[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][string]$ExpectedHead,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$Part5SignedReceiptPath,
    [Parameter(Mandatory)][string]$Part5ReviewZipPath,
    [Parameter(Mandatory)][string[]]$Part6To9ReceiptPath,
    [Parameter(Mandatory)][int]$KnownErrorRuleCount,
    [Parameter(Mandatory)][int]$KnownErrorFindingCount,
    [Parameter(Mandatory)][int]$AnalyzerFindingCount,
    [Parameter(Mandatory)][bool]$IndependentValidationPassed,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $RepositoryRoot 'scripts\NxbProductionFinalization.Common.ps1')
$policy = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'config\nxb-production-finalization-policy.json') -Raw | ConvertFrom-Json
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null

if ($KnownErrorRuleCount -lt [int]$policy.known_error_minimum_rules -or $KnownErrorFindingCount -ne 0) {
    throw 'Part 10 known-error production gate failed.'
}
if ($AnalyzerFindingCount -ne 0) { throw 'Part 10 analyzer production gate failed.' }
if (-not $IndependentValidationPassed) { throw 'Part 10 independent validation production gate failed.' }
if (-not (Test-Path -LiteralPath $Part5SignedReceiptPath -PathType Leaf)) { throw 'Part 10 Part 5 signed receipt missing.' }
if (-not (Test-Path -LiteralPath $Part5ReviewZipPath -PathType Leaf)) { throw 'Part 10 Part 5 review ZIP missing.' }

$part5 = Get-Content -LiteralPath $Part5SignedReceiptPath -Raw | ConvertFrom-Json
if ([string]$part5.status -cne 'passed' -or [string]$part5.head_sha -cne $ExpectedHead) {
    throw 'Part 10 Part 5 signed authority binding failed.'
}
if ([bool]$part5.private_key_persisted -or [bool]$part5.production_signer_claimed) {
    throw 'Part 10 Part 5 signer boundary failed.'
}

$partReceipts = [Collections.Generic.List[object]]::new()
foreach ($path in @($Part6To9ReceiptPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Part 10 prior receipt missing: {0}' -f $path) }
    $receipt = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ([string]$receipt.status -cne 'passed' -or [string]$receipt.head_sha -cne $ExpectedHead) {
        throw ('Part 10 prior receipt binding failed: {0}' -f $path)
    }
    $partReceipts.Add([pscustomobject][ordered]@{
        name = [IO.Path]::GetFileName($path)
        sha256 = Get-NxbFinalFileSha256 -Path $path
        contract_id = [string]$receipt.contract_id
        requirements_validated = [int]$receipt.requirements_validated
    })
}
if ($partReceipts.Count -ne 4) { throw 'Part 10 requires exactly four Part 6-9 receipts.' }

$part6Receipt = Get-Content -LiteralPath $Part6To9ReceiptPath[0] -Raw | ConvertFrom-Json
$findings = @($part6Receipt.findings)
$partStatus = [pscustomobject][ordered]@{
    part5 = 'native-certified-predecessor-bound'
    part6 = 'passed'
    part7 = 'passed'
    part8 = 'passed'
    part9 = 'passed'
    part10 = 'passed'
}
$report = Get-NxbFinalReportObject -ExactHead $ExpectedHead -ReleaseVersion ([string]$policy.part10.release_version) -Finding $findings -PartStatus $partStatus
$reportPath = Join-Path $OutputDirectory 'nxb-v1-candidate-report.json'
Write-NxbFinalAtomicJson -Path $reportPath -InputObject $report

$evidenceIndex = [pscustomobject][ordered]@{
    schema_version = 1
    exact_head = $ExpectedHead
    part5_signed_receipt_sha256 = Get-NxbFinalFileSha256 -Path $Part5SignedReceiptPath
    part5_review_zip_sha256 = Get-NxbFinalFileSha256 -Path $Part5ReviewZipPath
    part6_to_9 = @($partReceipts)
    report_sha256 = Get-NxbFinalFileSha256 -Path $reportPath
}
$indexPath = Join-Path $OutputDirectory 'nxb-v1-candidate-evidence-index.json'
Write-NxbFinalAtomicJson -Path $indexPath -InputObject $evidenceIndex

$freezeReceipt = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    contract_id = [string]$policy.part10.contract_id
    release_version = [string]$policy.part10.release_version
    head_sha = $ExpectedHead
    predecessor_part5_signed_receipt_sha256 = [string]$evidenceIndex.part5_signed_receipt_sha256
    predecessor_part5_review_zip_sha256 = [string]$evidenceIndex.part5_review_zip_sha256
    evidence_index_sha256 = Get-NxbFinalFileSha256 -Path $indexPath
    report_sha256 = Get-NxbFinalFileSha256 -Path $reportPath
    known_error_rules = $KnownErrorRuleCount
    known_error_findings = $KnownErrorFindingCount
    analyzer_findings = $AnalyzerFindingCount
    independent_validation = $IndependentValidationPassed
    production_safety_gate = $true
    production_merge_performed = $false
    v1_freeze_candidate = $true
    requirements_validated = @($policy.part10.requirements).Count
}
$freezePath = Join-Path $OutputDirectory 'part10-v1-freeze-receipt.json'
Write-NxbFinalAtomicJson -Path $freezePath -InputObject $freezeReceipt

if ($PassThru) {
    return [pscustomobject][ordered]@{
        status = 'passed'
        receipt_path = $freezePath
        receipt_sha256 = Get-NxbFinalFileSha256 -Path $freezePath
        report_path = $reportPath
        report_sha256 = Get-NxbFinalFileSha256 -Path $reportPath
        evidence_index_path = $indexPath
        evidence_index_sha256 = Get-NxbFinalFileSha256 -Path $indexPath
        requirements_validated = [int]$freezeReceipt.requirements_validated
    }
}
