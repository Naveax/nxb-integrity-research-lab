[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][ValidateSet('Stage','Apply','Rollback')][string]$Action,
    [Parameter(Mandatory)][string]$InstallRoot,
    [Parameter(Mandatory)][string]$UpdateRoot,
    [Parameter(Mandatory)][string]$ReceiptPath,
    [Parameter()][string]$PackageRoot,
    [Parameter()][string]$ManifestPath,
    [Parameter()][string]$DescriptorPath,
    [Parameter()][string]$EnvelopePath,
    [Parameter()][string]$TrustPath,
    [Parameter()][switch]$CertificationMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path -Path $PSScriptRoot -ChildPath 'NxbV1Update.Common.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'NxbV1Update.State.ps1')

if ($CertificationMode -and [string]$env:NXB_V1_UPDATE_CERTIFICATION -cne '1') { throw 'CertificationMode requires the repo-owned certification environment marker.' }

$installFull = [IO.Path]::GetFullPath($InstallRoot)
$updateFull = [IO.Path]::GetFullPath($UpdateRoot)
$receiptFull = [IO.Path]::GetFullPath($ReceiptPath)
if (-not (Test-NxbV1InstallerRoot -Path $installFull -RepositoryRoot $repositoryRoot -RequireExisting)) { throw 'Update InstallRoot is unsafe or missing.' }
if (-not (Test-NxbV1InstallerRoot -Path $updateFull -RepositoryRoot $repositoryRoot -RequireExisting)) { throw 'UpdateRoot is unsafe or missing.' }
$trimChars = [char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
$installPrefix = $installFull.TrimEnd($trimChars) + [IO.Path]::DirectorySeparatorChar
$updatePrefix = $updateFull.TrimEnd($trimChars) + [IO.Path]::DirectorySeparatorChar
if ([string]::Equals($installFull,$updateFull,[StringComparison]::OrdinalIgnoreCase) -or
    $installFull.StartsWith($updatePrefix,[StringComparison]::OrdinalIgnoreCase) -or
    $updateFull.StartsWith($installPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'InstallRoot and UpdateRoot must be separate trees.' }
$receiptParent = Split-Path -Parent $receiptFull
if ([string]::IsNullOrWhiteSpace($receiptParent) -or -not (Test-Path -LiteralPath $receiptParent -PathType Container)) { throw 'Update receipt parent must exist.' }
if ($receiptFull.StartsWith($installPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Update receipt must be outside InstallRoot.' }

$currentInstallState = Get-NxbV1InstallerStateObject -InstallRoot $installFull
$currentUpdateState = Get-NxbV1UpdateStateObject -UpdateRoot $updateFull
$currentSequence = 0
$currentEnvelopeSha = 'none'
$currentChannel = 'stable'
if ($null -ne $currentUpdateState) {
    $currentSequence = [int]$currentUpdateState.current_release_sequence
    $currentEnvelopeSha = [string]$currentUpdateState.current_envelope_sha256
    $currentChannel = [string]$currentUpdateState.current_channel
}

$productionMutation = $false
if (-not $CertificationMode -and $Action -ne 'Stage') { $productionMutation = $true }

function Out-NxbV1UpdateOperationReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][int]$Sequence,
        [Parameter(Mandatory)][string]$ReleaseHead,
        [Parameter(Mandatory)][string]$ManifestSha,
        [Parameter(Mandatory)][string]$DescriptorSha,
        [Parameter(Mandatory)][string]$EnvelopeSha,
        [Parameter(Mandatory)][string]$SignerFingerprint,
        [Parameter(Mandatory)][bool]$RollbackUsed
    )
    $receipt = [pscustomobject][ordered]@{
        schema_version=1; status='passed'; authority='nxb-v1-update-operation-v1'; action=$Operation; channel=$Channel; release_sequence=$Sequence;
        release_head=$ReleaseHead; package_manifest_sha256=$ManifestSha; descriptor_sha256=$DescriptorSha; envelope_sha256=$EnvelopeSha;
        trusted_signer_fingerprint=$SignerFingerprint; install_root=$installFull; update_root=$updateFull; rollback_used=$RollbackUsed;
        auto_apply=$false; production_release_updated=$productionMutation; created_utc=[DateTime]::UtcNow.ToString('o')
    }
    Write-NxbV1UpdateJson -Path $receiptFull -Value $receipt
    return $receipt
}

if ($Action -ceq 'Stage') {
    foreach ($requiredValue in @($PackageRoot,$ManifestPath,$DescriptorPath,$EnvelopePath,$TrustPath)) {
        if ([string]::IsNullOrWhiteSpace([string]$requiredValue)) { throw 'Stage requires PackageRoot, ManifestPath, DescriptorPath, EnvelopePath, and TrustPath.' }
    }
    $packageFull = [IO.Path]::GetFullPath($PackageRoot)
    $manifestFull = [IO.Path]::GetFullPath($ManifestPath)
    $descriptorFull = [IO.Path]::GetFullPath($DescriptorPath)
    $envelopeFull = [IO.Path]::GetFullPath($EnvelopePath)
    $trustFull = [IO.Path]::GetFullPath($TrustPath)
    foreach ($path in @($manifestFull,$descriptorFull,$envelopeFull,$trustFull)) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Stage input file missing: {0}' -f $path) } }
    if (-not (Test-Path -LiteralPath $packageFull -PathType Container)) { throw 'Stage PackageRoot is missing.' }
    $manifest = Get-Content -LiteralPath $manifestFull -Raw | ConvertFrom-Json
    $descriptor = Get-Content -LiteralPath $descriptorFull -Raw | ConvertFrom-Json
    $envelope = Get-Content -LiteralPath $envelopeFull -Raw | ConvertFrom-Json
    $trust = Get-Content -LiteralPath $trustFull -Raw | ConvertFrom-Json
    if (-not (Test-NxbV1UpdateBundle -PackageRoot $packageFull -Manifest $manifest -ManifestPath $manifestFull -Descriptor $descriptor -DescriptorPath $descriptorFull -Envelope $envelope -Trust $trust -CurrentReleaseSequence $currentSequence -CertificationMode:$CertificationMode)) { throw 'Signed update bundle failed trust/signature/package validation.' }
    $stageStatePath = Get-NxbV1UpdateStageStatePath -UpdateRoot $updateFull
    $stagePackageRoot = Join-Path -Path $updateFull -ChildPath 'staged-package'
    $metadataRoot = Join-Path -Path $updateFull -ChildPath 'staged-metadata'
    if (Test-Path -LiteralPath $stageStatePath -PathType Leaf) {
        $existingStage = Get-NxbV1UpdateStageStateObject -UpdateRoot $updateFull
        if ([int]$descriptor.release_sequence -le [int]$existingStage.release_sequence) { throw 'Existing staged update sequence is newer or equal.' }
        $existingStageRoot = [IO.Path]::GetFullPath([string]$existingStage.stage_package_root)
        $expectedStageRoot = [IO.Path]::GetFullPath($stagePackageRoot)
        if (-not [string]::Equals($existingStageRoot,$expectedStageRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Existing staged package root binding drift.' }
        if ($PSCmdlet.ShouldProcess($updateFull,('Supersede staged sequence {0} with signed sequence {1}' -f [int]$existingStage.release_sequence,[int]$descriptor.release_sequence))) {
            if (Test-Path -LiteralPath $stagePackageRoot) { Remove-Item -LiteralPath $stagePackageRoot -Recurse -Force }
            if (Test-Path -LiteralPath $metadataRoot) { Remove-Item -LiteralPath $metadataRoot -Recurse -Force }
            Remove-Item -LiteralPath $stageStatePath -Force
        }
        else { return }
    }
    if ((Test-Path -LiteralPath $stagePackageRoot) -or (Test-Path -LiteralPath $metadataRoot) -or (Test-Path -LiteralPath $stageStatePath)) { throw 'Stage package/metadata/state roots must be absent before publication.' }
    if ($PSCmdlet.ShouldProcess($updateFull,('Stage signed release {0} sequence {1}' -f [string]$descriptor.release_head,[int]$descriptor.release_sequence))) {
        Copy-NxbV1UpdatePackageVerified -PackageRoot $packageFull -Manifest $manifest -DestinationRoot $stagePackageRoot
        [IO.Directory]::CreateDirectory($metadataRoot) | Out-Null
        [IO.File]::Copy($manifestFull,(Join-Path -Path $metadataRoot -ChildPath 'package-manifest.json'),$false)
        [IO.File]::Copy($descriptorFull,(Join-Path -Path $metadataRoot -ChildPath 'update-descriptor.json'),$false)
        [IO.File]::Copy($envelopeFull,(Join-Path -Path $metadataRoot -ChildPath 'signature-envelope.json'),$false)
        $manifestSha = Get-NxbV1UpdateSha256 -Path $manifestFull
        $descriptorSha = Get-NxbV1UpdateSha256 -Path $descriptorFull
        $envelopeSha = Get-NxbV1UpdateSha256 -Path $envelopeFull
        $stageState = [pscustomobject][ordered]@{
            schema_version=1; contract_id='nxb-v1-update-stage-state-v1'; status='staged'; channel=[string]$descriptor.channel; release_sequence=[int]$descriptor.release_sequence;
            release_head=[string]$descriptor.release_head; package_manifest_sha256=$manifestSha; descriptor_sha256=$descriptorSha; envelope_sha256=$envelopeSha;
            trusted_signer_fingerprint=[string]$trust.trusted_signer_fingerprint; stage_package_root=$stagePackageRoot; created_utc=[DateTime]::UtcNow.ToString('o')
        }
        Write-NxbV1UpdateJson -Path $stageStatePath -Value $stageState
        $outReceipt = Out-NxbV1UpdateOperationReceipt -Operation 'Stage' -Channel ([string]$descriptor.channel) -Sequence ([int]$descriptor.release_sequence) -ReleaseHead ([string]$descriptor.release_head) -ManifestSha $manifestSha -DescriptorSha $descriptorSha -EnvelopeSha $envelopeSha -SignerFingerprint ([string]$trust.trusted_signer_fingerprint) -RollbackUsed $false
        Write-Information ('NXB v1 update Stage passed: channel={0} sequence={1} head={2}' -f [string]$descriptor.channel,[int]$descriptor.release_sequence,[string]$descriptor.release_head)
        return $outReceipt
    }
    return
}

if ($Action -ceq 'Apply') {
    if ([string]::IsNullOrWhiteSpace($TrustPath)) { throw 'Apply requires TrustPath.' }
    $trustFull = [IO.Path]::GetFullPath($TrustPath)
    if (-not (Test-Path -LiteralPath $trustFull -PathType Leaf)) { throw 'Apply TrustPath is missing.' }
    $stageState = Get-NxbV1UpdateStageStateObject -UpdateRoot $updateFull
    $expectedStagePackageRoot = [IO.Path]::GetFullPath((Join-Path -Path $updateFull -ChildPath 'staged-package'))
    $stagePackageRoot = [IO.Path]::GetFullPath([string]$stageState.stage_package_root)
    if (-not [string]::Equals($stagePackageRoot,$expectedStagePackageRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Stage package root binding drift.' }
    $metadataRoot = Join-Path -Path $updateFull -ChildPath 'staged-metadata'
    $manifestFull = Join-Path -Path $metadataRoot -ChildPath 'package-manifest.json'
    $descriptorFull = Join-Path -Path $metadataRoot -ChildPath 'update-descriptor.json'
    $envelopeFull = Join-Path -Path $metadataRoot -ChildPath 'signature-envelope.json'
    $manifest = Get-Content -LiteralPath $manifestFull -Raw | ConvertFrom-Json
    $descriptor = Get-Content -LiteralPath $descriptorFull -Raw | ConvertFrom-Json
    $envelope = Get-Content -LiteralPath $envelopeFull -Raw | ConvertFrom-Json
    $trust = Get-Content -LiteralPath $trustFull -Raw | ConvertFrom-Json
    $manifestSha = Get-NxbV1UpdateSha256 -Path $manifestFull
    $descriptorSha = Get-NxbV1UpdateSha256 -Path $descriptorFull
    $envelopeSha = Get-NxbV1UpdateSha256 -Path $envelopeFull
    if ($manifestSha -cne [string]$stageState.package_manifest_sha256 -or $descriptorSha -cne [string]$stageState.descriptor_sha256 -or $envelopeSha -cne [string]$stageState.envelope_sha256) { throw 'Staged metadata hash drift.' }
    if ([string]$trust.trusted_signer_fingerprint -cne [string]$stageState.trusted_signer_fingerprint) { throw 'Trust anchor changed after Stage.' }
    if (-not (Test-NxbV1UpdateBundle -PackageRoot $stagePackageRoot -Manifest $manifest -ManifestPath $manifestFull -Descriptor $descriptor -DescriptorPath $descriptorFull -Envelope $envelope -Trust $trust -CurrentReleaseSequence $currentSequence -CertificationMode:$CertificationMode)) { throw 'Staged update failed revalidation before Apply.' }
    $installParent = Split-Path -Parent $installFull
    $candidateRoot = Join-Path -Path $installParent -ChildPath ('.nxb-update-candidate-' + [Guid]::NewGuid().ToString('N'))
    $rollbackRoot = Join-Path -Path $installParent -ChildPath ('.nxb-update-rollback-' + [Guid]::NewGuid().ToString('N'))
    $previousTreeSha = Get-NxbV1UpdateTreeDigest -Root $installFull
    $previousSequence = $currentSequence
    $previousHead = [string]$currentInstallState.source_head
    $previousManifestSha = [string]$currentInstallState.package_manifest_sha256
    $previousEnvelopeSha = $currentEnvelopeSha
    $previousChannel = $currentChannel
    if ($PSCmdlet.ShouldProcess($installFull,('Apply signed release {0} sequence {1}' -f [string]$descriptor.release_head,[int]$descriptor.release_sequence))) {
        Copy-NxbV1UpdatePackageVerified -PackageRoot $stagePackageRoot -Manifest $manifest -DestinationRoot $candidateRoot
        $newInstallState = Get-NxbV1InstallerStateDocument -Manifest $manifest -InstallMode ([string]$currentInstallState.install_mode) -InstallRoot $installFull -ManifestSha256 $manifestSha
        Write-NxbV1UpdateJson -Path (Join-Path -Path $candidateRoot -ChildPath '.nxb-install-state.json') -Value $newInstallState
        if (-not (Test-NxbV1InstalledRootAgainstManifest -InstallRoot $candidateRoot -Manifest $manifest)) { Remove-Item -LiteralPath $candidateRoot -Recurse -Force; throw 'Update candidate failed installed-root verification.' }
        $validation = { param($publishedRoot) return (Test-NxbV1InstalledRootAgainstManifest -InstallRoot $publishedRoot -Manifest $manifest) }
        try {
            $swapResult = Invoke-NxbV1UpdateAtomicSwap -CurrentRoot $installFull -CandidateRoot $candidateRoot -RollbackRoot $rollbackRoot -PostPublishValidation $validation
            $newState = [pscustomobject][ordered]@{
                schema_version=1; contract_id='nxb-v1-update-state-v1'; current_channel=[string]$descriptor.channel; current_release_sequence=[int]$descriptor.release_sequence;
                current_release_head=[string]$descriptor.release_head; current_package_manifest_sha256=$manifestSha; current_envelope_sha256=$envelopeSha;
                rollback_available=$true; rollback_channel=$previousChannel; rollback_release_sequence=$previousSequence; rollback_release_head=$previousHead;
                rollback_package_manifest_sha256=$previousManifestSha; rollback_envelope_sha256=$previousEnvelopeSha; rollback_tree_sha256=$previousTreeSha;
                rollback_root=$rollbackRoot; updated_utc=[DateTime]::UtcNow.ToString('o')
            }
            try { Write-NxbV1UpdateJson -Path (Get-NxbV1UpdateStatePath -UpdateRoot $updateFull) -Value $newState }
            catch {
                $failedPublishedRoot = Join-Path -Path $installParent -ChildPath ('.nxb-update-failed-' + [Guid]::NewGuid().ToString('N'))
                if (Test-Path -LiteralPath $installFull) { [IO.Directory]::Move($installFull,$failedPublishedRoot) }
                if (Test-Path -LiteralPath $rollbackRoot) { [IO.Directory]::Move($rollbackRoot,$installFull) }
                if (Test-Path -LiteralPath $failedPublishedRoot) { Remove-Item -LiteralPath $failedPublishedRoot -Recurse -Force }
                throw
            }
        }
        catch { if (Test-Path -LiteralPath $candidateRoot) { Remove-Item -LiteralPath $candidateRoot -Recurse -Force }; throw }
        $outReceipt = Out-NxbV1UpdateOperationReceipt -Operation 'Apply' -Channel ([string]$descriptor.channel) -Sequence ([int]$descriptor.release_sequence) -ReleaseHead ([string]$descriptor.release_head) -ManifestSha $manifestSha -DescriptorSha $descriptorSha -EnvelopeSha $envelopeSha -SignerFingerprint ([string]$trust.trusted_signer_fingerprint) -RollbackUsed ([bool]$swapResult.rollback_used)
        Write-Information ('NXB v1 update Apply passed: sequence={0} head={1} rollback_snapshot={2}' -f [int]$descriptor.release_sequence,[string]$descriptor.release_head,$rollbackRoot)
        return $outReceipt
    }
    return
}

if ($Action -ceq 'Rollback') {
    $state = Get-NxbV1UpdateStateObject -UpdateRoot $updateFull
    if ($null -eq $state -or -not [bool]$state.rollback_available) { throw 'No verified update rollback snapshot is available.' }
    $rollbackRoot = [IO.Path]::GetFullPath([string]$state.rollback_root)
    if (-not (Test-Path -LiteralPath $rollbackRoot -PathType Container)) { throw 'Recorded rollback root is missing.' }
    if ((Get-NxbV1UpdateTreeDigest -Root $rollbackRoot) -cne [string]$state.rollback_tree_sha256) { throw 'Rollback snapshot tree hash mismatch.' }
    $installParent = Split-Path -Parent $installFull
    $displacedRoot = Join-Path -Path $installParent -ChildPath ('.nxb-update-displaced-' + [Guid]::NewGuid().ToString('N'))
    if ($PSCmdlet.ShouldProcess($installFull,('Rollback to release {0} sequence {1}' -f [string]$state.rollback_release_head,[int]$state.rollback_release_sequence))) {
        [IO.Directory]::Move($installFull,$displacedRoot)
        $restored = $false
        try {
            [IO.Directory]::Move($rollbackRoot,$installFull)
            $restored = $true
            if ((Get-NxbV1UpdateTreeDigest -Root $installFull) -cne [string]$state.rollback_tree_sha256) { throw 'Restored rollback tree hash mismatch.' }
            $rolledState = [pscustomobject][ordered]@{
                schema_version=1; contract_id='nxb-v1-update-state-v1'; current_channel=[string]$state.rollback_channel; current_release_sequence=[int]$state.rollback_release_sequence;
                current_release_head=[string]$state.rollback_release_head; current_package_manifest_sha256=[string]$state.rollback_package_manifest_sha256;
                current_envelope_sha256=[string]$state.rollback_envelope_sha256; rollback_available=$false; rollback_channel=[string]$state.rollback_channel;
                rollback_release_sequence=[int]$state.rollback_release_sequence; rollback_release_head=[string]$state.rollback_release_head;
                rollback_package_manifest_sha256=[string]$state.rollback_package_manifest_sha256; rollback_envelope_sha256=[string]$state.rollback_envelope_sha256;
                rollback_tree_sha256=[string]$state.rollback_tree_sha256; rollback_root=''; updated_utc=[DateTime]::UtcNow.ToString('o')
            }
            try { Write-NxbV1UpdateJson -Path (Get-NxbV1UpdateStatePath -UpdateRoot $updateFull) -Value $rolledState }
            catch {
                if (Test-Path -LiteralPath $installFull) { Remove-Item -LiteralPath $installFull -Recurse -Force }
                if (Test-Path -LiteralPath $displacedRoot -PathType Container) { [IO.Directory]::Move($displacedRoot,$installFull) }
                throw
            }
            if (Test-Path -LiteralPath $displacedRoot) { Remove-Item -LiteralPath $displacedRoot -Recurse -Force }
        }
        catch {
            if ($restored -and (Test-Path -LiteralPath $installFull) -and (Test-Path -LiteralPath $displacedRoot -PathType Container)) {
                Remove-Item -LiteralPath $installFull -Recurse -Force
                [IO.Directory]::Move($displacedRoot,$installFull)
            }
            throw
        }
        $outReceipt = Out-NxbV1UpdateOperationReceipt -Operation 'Rollback' -Channel ([string]$state.rollback_channel) -Sequence ([int]$state.rollback_release_sequence) -ReleaseHead ([string]$state.rollback_release_head) -ManifestSha ([string]$state.rollback_package_manifest_sha256) -DescriptorSha 'none' -EnvelopeSha ([string]$state.rollback_envelope_sha256) -SignerFingerprint 'none' -RollbackUsed $true
        Write-Information ('NXB v1 update Rollback passed: channel={0} sequence={1} head={2}' -f [string]$state.rollback_channel,[int]$state.rollback_release_sequence,[string]$state.rollback_release_head)
        return $outReceipt
    }
}
