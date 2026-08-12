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
. (Join-Path $RepositoryRoot 'scripts\NxbPart5Crypto.Common.ps1')
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

$freezeBase = [ordered]@{
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
    private_key_persisted = $false
    production_signer_claimed = $false
    signing_algorithm = 'RSA-PKCS1-SHA256'
    nonce_b64 = Get-NxbPart5Nonce
    created_utc = [DateTime]::UtcNow.ToString('o')
}

$signingAuthority = Get-NxbPart5EphemeralAuthority -KeySizeBits 3072
try {
    if ([int]$signingAuthority.actual_key_size_bits -lt 3072 -or [bool]$signingAuthority.private_key_persisted) {
        throw 'Part 10 ephemeral RSA authority boundary failed.'
    }
    $orderedReceipts = @($partReceipts | Sort-Object name)
    $receiptMaterial = @($orderedReceipts | ForEach-Object {
        @([string]$_.name,[string]$_.sha256,[string]$_.contract_id,[string][int]$_.requirements_validated) -join '|'
    }) -join "`n"
    $canonicalMaterial = @(
        'nxb-irl006-part10-v1-freeze-signed-v1',
        [string][int]$freezeBase.schema_version,
        [string]$freezeBase.status,
        [string]$freezeBase.contract_id,
        [string]$freezeBase.release_version,
        [string]$freezeBase.head_sha,
        [string]$freezeBase.predecessor_part5_signed_receipt_sha256,
        [string]$freezeBase.predecessor_part5_review_zip_sha256,
        [string]$freezeBase.evidence_index_sha256,
        [string]$freezeBase.report_sha256,
        [string][int]$freezeBase.known_error_rules,
        [string][int]$freezeBase.known_error_findings,
        [string][int]$freezeBase.analyzer_findings,
        ([string][bool]$freezeBase.independent_validation).ToLowerInvariant(),
        ([string][bool]$freezeBase.production_safety_gate).ToLowerInvariant(),
        ([string][bool]$freezeBase.production_merge_performed).ToLowerInvariant(),
        ([string][bool]$freezeBase.v1_freeze_candidate).ToLowerInvariant(),
        [string][int]$freezeBase.requirements_validated,
        ([string][bool]$freezeBase.private_key_persisted).ToLowerInvariant(),
        ([string][bool]$freezeBase.production_signer_claimed).ToLowerInvariant(),
        [string]$freezeBase.signing_algorithm,
        [string]$signingAuthority.modulus_b64,
        [string]$signingAuthority.exponent_b64,
        [string]$signingAuthority.fingerprint_sha256,
        [string]$freezeBase.nonce_b64,
        [string]$freezeBase.created_utc,
        $receiptMaterial
    ) -join "`n"
    $canonicalSha = Get-NxbFinalSha256Text -Text $canonicalMaterial
    $signatureB64 = Invoke-NxbPart5RsaSignature -Rsa $signingAuthority.rsa -CanonicalMaterial $canonicalMaterial
    $freezeReceipt = [pscustomobject][ordered]@{
        schema_version = [int]$freezeBase.schema_version
        status = [string]$freezeBase.status
        contract_id = [string]$freezeBase.contract_id
        release_version = [string]$freezeBase.release_version
        head_sha = [string]$freezeBase.head_sha
        predecessor_part5_signed_receipt_sha256 = [string]$freezeBase.predecessor_part5_signed_receipt_sha256
        predecessor_part5_review_zip_sha256 = [string]$freezeBase.predecessor_part5_review_zip_sha256
        evidence_index_sha256 = [string]$freezeBase.evidence_index_sha256
        report_sha256 = [string]$freezeBase.report_sha256
        known_error_rules = [int]$freezeBase.known_error_rules
        known_error_findings = [int]$freezeBase.known_error_findings
        analyzer_findings = [int]$freezeBase.analyzer_findings
        independent_validation = [bool]$freezeBase.independent_validation
        production_safety_gate = [bool]$freezeBase.production_safety_gate
        production_merge_performed = [bool]$freezeBase.production_merge_performed
        v1_freeze_candidate = [bool]$freezeBase.v1_freeze_candidate
        requirements_validated = [int]$freezeBase.requirements_validated
        private_key_persisted = $false
        production_signer_claimed = $false
        signing_algorithm = [string]$freezeBase.signing_algorithm
        public_key = [pscustomobject][ordered]@{
            modulus_b64 = [string]$signingAuthority.modulus_b64
            exponent_b64 = [string]$signingAuthority.exponent_b64
            fingerprint_sha256 = [string]$signingAuthority.fingerprint_sha256
        }
        nonce_b64 = [string]$freezeBase.nonce_b64
        created_utc = [string]$freezeBase.created_utc
        part6_to_9 = $orderedReceipts
        canonical_sha256 = $canonicalSha
        signature_b64 = $signatureB64
    }
}
finally {
    $signingAuthority.rsa.Dispose()
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
        rsa_signature_created = $true
        requirements_validated = [int]$freezeReceipt.requirements_validated
    }
}
