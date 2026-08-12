[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('CertificationEphemeral','ProductionWindowsCertificateStore')][string]$SignerMode,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ReleaseHead,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$CertifiedImplementationHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PackageManifestPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ReleaseNotesPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ArtifactRoot,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$ArtifactPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath,
    [Parameter()][ValidateSet('CurrentUser','LocalMachine')][string]$StoreLocation = 'CurrentUser',
    [Parameter()][ValidateSet('My')][string]$StoreName = 'My',
    [Parameter()][string]$Thumbprint,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'NxbV1ProductionSigning.Common.ps1')

function Get-NxbV1ReleaseSigningFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-NxbV1ReleaseSigningRegularFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)
}

$policyPath = Join-Path $repositoryRoot 'config\nxb-v1-production-signing-policy.json'
if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) { throw 'NXB v1 production signing policy is missing.' }
$policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
if ([string]$policy.contract_id -cne 'nxb-v1-production-signing-v1' -or [int]$policy.schema_version -ne 1) { throw 'NXB v1 production signing policy identity drift.' }

$packageFull = [IO.Path]::GetFullPath($PackageManifestPath)
$notesFull = [IO.Path]::GetFullPath($ReleaseNotesPath)
$artifactRootFull = [IO.Path]::GetFullPath($ArtifactRoot)
$outputFull = [IO.Path]::GetFullPath($OutputPath)
if (-not (Test-NxbV1ReleaseSigningRegularFile -Path $packageFull)) { throw 'Package manifest must be a regular non-reparse file.' }
if (-not (Test-NxbV1ReleaseSigningRegularFile -Path $notesFull)) { throw 'Release notes must be a regular non-reparse file.' }
if (-not (Test-Path -LiteralPath $artifactRootFull -PathType Container)) { throw 'ArtifactRoot must exist.' }
if ((Get-Item -LiteralPath $artifactRootFull -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'ArtifactRoot must not be a reparse point.' }
if ($ArtifactPath.Count -lt 1 -or $ArtifactPath.Count -gt [int]$policy.release_manifest.maximum_artifacts) { throw 'ArtifactPath count is outside the production signing policy.' }

$artifactRows = [Collections.Generic.List[object]]::new()
$artifactSourceByPath = @{}
$trimChars = [char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
$rootPrefix = $artifactRootFull.TrimEnd($trimChars) + [IO.Path]::DirectorySeparatorChar
foreach ($relativeObject in $ArtifactPath) {
    $relative = [string]$relativeObject
    if (-not (Test-NxbV1SigningArtifactPath -Path $relative)) { throw ('Unsafe artifact relative path: {0}' -f $relative) }
    if ($artifactSourceByPath.ContainsKey($relative)) { throw ('Duplicate artifact relative path: {0}' -f $relative) }
    $sourceFull = [IO.Path]::GetFullPath((Join-Path -Path $artifactRootFull -ChildPath $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)))
    if (-not $sourceFull.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw ('Artifact escaped ArtifactRoot: {0}' -f $relative) }
    if (-not (Test-NxbV1ReleaseSigningRegularFile -Path $sourceFull)) { throw ('Artifact must be a regular non-reparse file: {0}' -f $relative) }
    $item = Get-Item -LiteralPath $sourceFull -Force
    $sha = Get-NxbV1ReleaseSigningFileSha256 -Path $sourceFull
    $artifactRows.Add([pscustomobject][ordered]@{ path=$relative; bytes=[int64]$item.Length; sha256=$sha })
    $artifactSourceByPath[$relative] = $sourceFull
}

$packageSha = Get-NxbV1ReleaseSigningFileSha256 -Path $packageFull
$notesSha = Get-NxbV1ReleaseSigningFileSha256 -Path $notesFull
$signer = $null
try {
    if ($SignerMode -ceq 'CertificationEphemeral') {
        if (-not [string]::IsNullOrWhiteSpace($Thumbprint)) { throw 'Thumbprint is forbidden in CertificationEphemeral mode.' }
        $signer = New-NxbV1CertificationSigner -KeySizeBits ([int]$policy.certification.minimum_rsa_bits)
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Thumbprint)) { throw 'Thumbprint is required in ProductionWindowsCertificateStore mode.' }
        $signer = Get-NxbV1ProductionCertificateSigner -StoreLocation $StoreLocation -StoreName $StoreName -Thumbprint $Thumbprint
    }

    $envelope = New-NxbV1SignedReleaseEnvelope `
        -Signer $signer `
        -ReleaseHead $ReleaseHead `
        -CertifiedImplementationHead $CertifiedImplementationHead `
        -PackageManifestSha256 $packageSha `
        -ReleaseNotesSha256 $notesSha `
        -Artifacts @($artifactRows)
    if (-not (Test-NxbV1SignedReleaseEnvelope -Envelope $envelope)) { throw 'Release signature self-verification failed.' }

    if ((Get-NxbV1ReleaseSigningFileSha256 -Path $packageFull) -cne $packageSha) { throw 'Package manifest changed during signing.' }
    if ((Get-NxbV1ReleaseSigningFileSha256 -Path $notesFull) -cne $notesSha) { throw 'Release notes changed during signing.' }
    foreach ($artifact in @($artifactRows)) {
        $relative = [string]$artifact.path
        $sourceFull = [string]$artifactSourceByPath[$relative]
        $item = Get-Item -LiteralPath $sourceFull -Force
        if ([int64]$item.Length -ne [int64]$artifact.bytes -or (Get-NxbV1ReleaseSigningFileSha256 -Path $sourceFull) -cne [string]$artifact.sha256) { throw ('Artifact changed during signing: {0}' -f $relative) }
    }

    if ($SignerMode -ceq 'CertificationEphemeral') {
        if ([bool]$envelope.private_key_persisted -or [bool]$envelope.production_signer_claimed) { throw 'Certification mode crossed the production signer boundary.' }
    }
    else {
        if (-not [bool]$envelope.production_signer_claimed -or [string]$envelope.signer_mode -cne 'production-windows-certificate-store') { throw 'Production mode did not produce a production signer claim.' }
    }

    $outputParent = Split-Path -Parent $outputFull
    if (-not [string]::IsNullOrWhiteSpace($outputParent)) { [IO.Directory]::CreateDirectory($outputParent) | Out-Null }
    if (Test-Path -LiteralPath $outputFull) { throw 'Release signature output path already exists.' }
    $json = ($envelope | ConvertTo-Json -Depth 12) + [Environment]::NewLine
    [IO.File]::WriteAllText($outputFull,$json,[Text.UTF8Encoding]::new($false))
    if ($PassThru) { $envelope }
    if (-not $PassThru) { Write-Information ('NXB v1 release manifest signed: mode={0} key={1} artifacts={2} output={3}' -f [string]$envelope.signer_mode,[string]$envelope.signer_key_id,@($envelope.artifacts).Count,$outputFull) }
}
finally { if ($null -ne $signer -and $null -ne $signer.rsa) { $signer.rsa.Dispose() } }
