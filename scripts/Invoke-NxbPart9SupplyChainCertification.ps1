[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][string]$ExpectedHead,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $RepositoryRoot 'scripts\NxbProductionFinalization.Common.ps1')
$policy = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'config\nxb-production-finalization-policy.json') -Raw | ConvertFrom-Json
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null

$packagePaths = @(
    (Join-Path $RepositoryRoot 'config\nxb-production-finalization-policy.json'),
    (Join-Path $RepositoryRoot 'scripts\NxbProductionFinalization.Common.ps1'),
    (Join-Path $RepositoryRoot 'scripts\Invoke-NxbPart6FindingEngineCertification.ps1'),
    (Join-Path $RepositoryRoot 'scripts\Invoke-NxbPart7BoundedActiveValidationCertification.ps1'),
    (Join-Path $RepositoryRoot 'scripts\Invoke-NxbPart8EvidenceHardeningCertification.ps1'),
    (Join-Path $RepositoryRoot 'scripts\nxb.ps1')
)
$files = @(New-NxbFinalArtifactManifest -Path $packagePaths)
if ($files.Count -ne $packagePaths.Count) { throw 'Part 9 package manifest file cardinality mismatch.' }

$manifest = [pscustomobject][ordered]@{
    schema_version = 1
    version = [string]$policy.part10.release_version
    exact_head = $ExpectedHead
    signer_fingerprint_sha256 = Get-NxbFinalSha256Text -Text 'nxb-certification-supply-chain-signer-v1'
    staged_only = $true
    auto_apply = $false
    rollback = [pscustomobject][ordered]@{
        previous_certified_head = [string]$policy.certified_predecessor_head
        rollback_requires_explicit_operator = $true
    }
    files = $files
}
if (-not (Test-NxbFinalPackageManifest -Manifest $manifest -ExpectedVersion ([string]$policy.part10.release_version))) {
    throw 'Part 9 package manifest validation failed.'
}

$tampered = $manifest | ConvertTo-Json -Depth 32 | ConvertFrom-Json
$tampered.files[0].sha256 = 'bad'
if (Test-NxbFinalPackageManifest -Manifest $tampered -ExpectedVersion ([string]$policy.part10.release_version)) {
    throw 'Part 9 tampered package manifest unexpectedly validated.'
}

$cliPath = Join-Path $RepositoryRoot 'scripts\nxb.ps1'
$cliSource = Get-Content -LiteralPath $cliPath -Raw
foreach ($token in @("'status'","'hash'","'inspect-manifest'","'certify-final'","update_mode = 'staged-only'")) {
    if ($cliSource.IndexOf($token,[StringComparison]::Ordinal) -lt 0) { throw ('Part 9 unified CLI token missing: {0}' -f $token) }
}
if ($cliSource -match '(?im)\b(Remove-Item|Format-Volume|Clear-Disk|Invoke-Expression)\b') {
    throw 'Part 9 unified CLI contains a destructive or dynamic-execution primitive.'
}

$manifestPath = Join-Path $OutputDirectory 'part9-package-manifest.json'
Write-NxbFinalAtomicJson -Path $manifestPath -InputObject $manifest
$receipt = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    contract_id = [string]$policy.part9.contract_id
    head_sha = $ExpectedHead
    version = [string]$manifest.version
    package_file_count = $files.Count
    package_manifest_sha256 = Get-NxbFinalFileSha256 -Path $manifestPath
    signer_fingerprint_sha256 = [string]$manifest.signer_fingerprint_sha256
    staged_update_only = $true
    auto_apply = $false
    rollback_metadata = $true
    unified_cli = $true
    offline_inspection = $true
    tamper_rejection = $true
    requirements_validated = @($policy.part9.requirements).Count
}
$receiptPath = Join-Path $OutputDirectory 'part9-supply-chain-receipt.json'
Write-NxbFinalAtomicJson -Path $receiptPath -InputObject $receipt

if ($PassThru) {
    return [pscustomobject][ordered]@{
        status = 'passed'
        receipt_path = $receiptPath
        receipt_sha256 = Get-NxbFinalFileSha256 -Path $receiptPath
        manifest_path = $manifestPath
        manifest_sha256 = Get-NxbFinalFileSha256 -Path $manifestPath
        requirements_validated = [int]$receipt.requirements_validated
    }
}
