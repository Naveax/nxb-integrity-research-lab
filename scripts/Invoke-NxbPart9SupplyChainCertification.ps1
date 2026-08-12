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

$packageRelativePaths = @(
    'config/nxb-production-finalization-policy.json',
    'config/nxb-production-known-error-extension.json',
    'scripts/NxbProductionFinalization.Common.ps1',
    'scripts/Invoke-NxbPart6FindingEngineCertification.ps1',
    'scripts/Invoke-NxbPart7BoundedActiveValidationCertification.ps1',
    'scripts/Invoke-NxbPart8EvidenceHardeningCertification.ps1',
    'scripts/Invoke-NxbPart9SupplyChainCertification.ps1',
    'scripts/Invoke-NxbPart10ProductionFreezeCertification.ps1',
    'scripts/Invoke-NxbProductionFinalCertification.ps1',
    'scripts/Invoke-NxbProductionFinalCertificationV2.ps1',
    'scripts/Invoke-NxbProductionKnownErrorScan.ps1',
    'scripts/nxb.ps1',
    'tools/validate_production_prefreeze.py',
    'tools/validate_production_finalization.py',
    'tests/ProductionFinalization.Tests.ps1'
)
if (@($packageRelativePaths | Sort-Object -Unique).Count -ne $packageRelativePaths.Count) { throw 'Part 9 package relative paths are not unique.' }
$files = [Collections.Generic.List[object]]::new()
foreach ($relative in @($packageRelativePaths | Sort-Object -CaseSensitive)) {
    if ([string]::IsNullOrWhiteSpace($relative) -or $relative -match '(^/|^[A-Za-z]:|(^|/)\.\.(/|$)|\\)') {
        throw ('Part 9 unsafe package relative path: {0}' -f $relative)
    }
    $fullPath = Join-Path $RepositoryRoot $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw ('Part 9 package source missing: {0}' -f $relative) }
    $item = Get-Item -LiteralPath $fullPath
    $files.Add([pscustomobject][ordered]@{
        path = $relative
        name = $item.Name
        bytes = [int64]$item.Length
        sha256 = Get-NxbFinalFileSha256 -Path $fullPath
    })
}
if ($files.Count -ne $packageRelativePaths.Count) { throw 'Part 9 package manifest file cardinality mismatch.' }

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
    files = @($files)
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
foreach ($token in @("'status'","'hash'","'inspect-manifest'","'stage-update'","'certify-final'","update_mode = 'staged-only'")) {
    if ($cliSource.IndexOf($token,[StringComparison]::Ordinal) -lt 0) { throw ('Part 9 unified CLI token missing: {0}' -f $token) }
}
if ($cliSource -match '(?im)\b(Format-Volume|Clear-Disk|Invoke-Expression)\b') {
    throw 'Part 9 unified CLI contains a destructive or dynamic-execution primitive.'
}

$manifestPath = Join-Path $OutputDirectory 'part9-package-manifest.json'
Write-NxbFinalAtomicJson -Path $manifestPath -InputObject $manifest
$stagingRoot = Join-Path $OutputDirectory 'part9-staged-update'
$stageResult = & $cliPath -Command stage-update -Path $manifestPath -ExpectedVersion ([string]$policy.part10.release_version) -StagingRoot $stagingRoot
if ([string]$stageResult.status -cne 'staged' -or [int]$stageResult.file_count -ne $files.Count -or [bool]$stageResult.auto_apply) {
    throw 'Part 9 staged update certification failed.'
}
foreach ($stagedFile in @($stageResult.files)) {
    $manifestFile = @($manifest.files | Where-Object { [string]$_.path -ceq [string]$stagedFile.path })
    if ($manifestFile.Count -ne 1 -or [string]$manifestFile[0].sha256 -cne [string]$stagedFile.sha256) {
        throw ('Part 9 staged file evidence mismatch: {0}' -f [string]$stagedFile.path)
    }
}

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
    staged_update_executed = $true
    staged_file_count = [int]$stageResult.file_count
    auto_apply = $false
    rollback_metadata = $true
    unified_cli = $true
    autonomous_certification_workflow = $true
    offline_inspection = $true
    deterministic_package_manifest = $true
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
        staging_root = [string]$stageResult.staging_root
        staged_file_count = [int]$stageResult.file_count
        requirements_validated = [int]$receipt.requirements_validated
    }
}
