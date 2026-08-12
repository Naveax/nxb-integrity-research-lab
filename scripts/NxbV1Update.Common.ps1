Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'NxbV1ProductionSigning.Common.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'NxbV1Installer.Common.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'NxbV1Installer.State.ps1')

function Get-NxbV1UpdateSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function ConvertFrom-NxbV1UpdateJsonPreservingStrings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)

    $convertCommand = Get-Command ConvertFrom-Json -CommandType Cmdlet -ErrorAction Stop
    if ($convertCommand.Parameters.ContainsKey('DateKind')) {
        return (ConvertFrom-Json -InputObject $Json -DateKind String)
    }

    $value = ConvertFrom-Json -InputObject $Json
    if ($null -ne $value) {
        foreach ($propertyName in @('created_utc','updated_utc')) {
            $property = $value.PSObject.Properties[$propertyName]
            if ($null -ne $property -and $property.Value -is [DateTime]) {
                $property.Value = ([DateTime]$property.Value).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
            }
        }
    }
    return $value
}

function Read-NxbV1UpdateJsonPreservingStrings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw ('Update JSON file is missing: {0}' -f $full) }
    $json = Get-Content -LiteralPath $full -Raw
    return (ConvertFrom-NxbV1UpdateJsonPreservingStrings -Json $json)
}

function Get-NxbV1UpdateTreeDigest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    $fullRoot = [IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath $fullRoot -PathType Container)) { throw 'Update tree root does not exist.' }
    if (-not (Test-NxbV1InstallerPathChainNoReparse -Path $fullRoot)) { throw 'Update tree root contains a reparse point.' }
    $trimChars = [char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $prefix = $fullRoot.TrimEnd($trimChars) + [IO.Path]::DirectorySeparatorChar
    $rowMap = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $fullRoot -File -Recurse -Force)) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw ('Update tree file is a reparse point: {0}' -f $file.FullName) }
        $full = [IO.Path]::GetFullPath($file.FullName)
        if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Update tree file escaped its root.' }
        $relative = $full.Substring($prefix.Length).Replace([IO.Path]::DirectorySeparatorChar,[char]'/')
        if (-not (Test-NxbV1InstallerRelativePath -Path $relative)) { throw ('Unsafe update tree relative path: {0}' -f $relative) }
        if ($rowMap.ContainsKey($relative)) { throw ('Duplicate update tree path: {0}' -f $relative) }
        $rowMap[$relative] = [pscustomobject][ordered]@{ path=$relative; bytes=[int64]$file.Length; sha256=(Get-NxbV1UpdateSha256 -Path $full) }
    }
    $paths = [string[]]@($rowMap.Keys)
    [Array]::Sort($paths,[StringComparer]::Ordinal)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('nxb-v1-update-tree-v1')
    $lines.Add(('file_count={0}' -f $paths.Count))
    foreach ($path in $paths) {
        $row = $rowMap[$path]
        $lines.Add(('file={0}|{1}|{2}' -f $path,[int64]$row.bytes,[string]$row.sha256))
    }
    return (Get-NxbV1SigningSha256Text -Text ($lines -join "`n"))
}

function Test-NxbV1UpdateTrustObject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Trust)
    try {
        if ([int]$Trust.schema_version -ne 1 -or [string]$Trust.contract_id -cne 'nxb-v1-update-trust-v1') { return $false }
        if (@('stable','beta') -cnotcontains [string]$Trust.channel) { return $false }
        if (-not (Test-NxbV1InstallerLowerHex -Text ([string]$Trust.trusted_signer_fingerprint) -Length 64)) { return $false }
        if ([int]$Trust.minimum_release_sequence -lt 1 -or [bool]$Trust.allow_downgrade) { return $false }
        $seen = @{}
        foreach ($headObject in @($Trust.revoked_release_heads)) {
            $head = [string]$headObject
            if (-not (Test-NxbV1InstallerLowerHex -Text $head -Length 40) -or $seen.ContainsKey($head)) { return $false }
            $seen[$head] = $true
        }
        return $true
    }
    catch { return $false }
}

function Test-NxbV1UpdateDescriptorObject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Descriptor)
    try {
        if ([int]$Descriptor.schema_version -ne 1 -or [string]$Descriptor.contract_id -cne 'nxb-v1-update-descriptor-v1') { return $false }
        if (@('stable','beta') -cnotcontains [string]$Descriptor.channel) { return $false }
        if ([string]$Descriptor.release_version -cne '1.0.0' -or [int]$Descriptor.release_sequence -lt 1) { return $false }
        if (-not (Test-NxbV1InstallerLowerHex -Text ([string]$Descriptor.release_head) -Length 40)) { return $false }
        if ([string]$Descriptor.certified_implementation_head -cne 'a10535b294c4d7ba8a4c3683154609087bf50c4b') { return $false }
        if (-not (Test-NxbV1InstallerLowerHex -Text ([string]$Descriptor.package_manifest_sha256) -Length 64)) { return $false }
        if ([string]::IsNullOrWhiteSpace([string]$Descriptor.created_utc)) { return $false }
        return $true
    }
    catch { return $false }
}

function Get-NxbV1UpdateEnvelopeArtifactMap {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Envelope)
    $map = @{}
    foreach ($artifact in @($Envelope.artifacts)) {
        $path = [string]$artifact.path
        if (-not (Test-NxbV1SigningArtifactPath -Path $path) -or $map.ContainsKey($path)) { throw ('Unsafe or duplicate signed update artifact: {0}' -f $path) }
        $map[$path] = $artifact
    }
    return $map
}

function Test-NxbV1UpdateBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][object]$Descriptor,
        [Parameter(Mandatory)][string]$DescriptorPath,
        [Parameter(Mandatory)][object]$Envelope,
        [Parameter(Mandatory)][object]$Trust,
        [Parameter(Mandatory)][int]$CurrentReleaseSequence,
        [Parameter()][switch]$CertificationMode
    )
    try {
        if (-not (Test-NxbV1UpdateTrustObject -Trust $Trust) -or -not (Test-NxbV1UpdateDescriptorObject -Descriptor $Descriptor)) { return $false }
        if (-not (Test-NxbV1SignedReleaseEnvelope -Envelope $Envelope)) { return $false }
        if ([string]$Envelope.public_key.fingerprint -cne [string]$Trust.trusted_signer_fingerprint) { return $false }
        if ([int]$Envelope.key_size_bits -lt 3072) { return $false }
        if ($CertificationMode) {
            if ([string]$Envelope.signer_mode -cne 'certification-ephemeral' -or [bool]$Envelope.production_signer_claimed) { return $false }
        }
        else {
            if ([string]$Envelope.signer_mode -cne 'production-windows-certificate-store' -or -not [bool]$Envelope.production_signer_claimed) { return $false }
        }
        if ([string]$Descriptor.channel -cne [string]$Trust.channel) { return $false }
        if ([int]$Descriptor.release_sequence -lt [int]$Trust.minimum_release_sequence) { return $false }
        if ([int]$Descriptor.release_sequence -le $CurrentReleaseSequence) { return $false }
        foreach ($revokedObject in @($Trust.revoked_release_heads)) { if ([string]$revokedObject -ceq [string]$Descriptor.release_head) { return $false } }
        if ([string]$Descriptor.release_head -cne [string]$Envelope.release_head -or [string]$Manifest.source_head -cne [string]$Envelope.release_head) { return $false }
        if ([string]$Descriptor.certified_implementation_head -cne [string]$Envelope.certified_implementation_head) { return $false }
        $manifestSha = Get-NxbV1UpdateSha256 -Path $ManifestPath
        $descriptorSha = Get-NxbV1UpdateSha256 -Path $DescriptorPath
        if ([string]$Descriptor.package_manifest_sha256 -cne $manifestSha -or [string]$Envelope.package_manifest_sha256 -cne $manifestSha) { return $false }
        if (-not (Test-NxbV1PackageManifestObject -Manifest $Manifest -MaximumFiles 2048 -MaximumBytes 1073741824)) { return $false }
        if (-not (Test-NxbV1PackageAgainstManifest -PackageRoot $PackageRoot -Manifest $Manifest)) { return $false }
        $artifactMap = Get-NxbV1UpdateEnvelopeArtifactMap -Envelope $Envelope
        if (-not $artifactMap.ContainsKey('update/update-descriptor.json')) { return $false }
        $descriptorArtifact = $artifactMap['update/update-descriptor.json']
        if ([int64]$descriptorArtifact.bytes -ne [int64](Get-Item -LiteralPath $DescriptorPath).Length -or [string]$descriptorArtifact.sha256 -cne $descriptorSha) { return $false }
        foreach ($file in @($Manifest.files)) {
            $signedPath = 'package/' + [string]$file.path
            if (-not $artifactMap.ContainsKey($signedPath)) { return $false }
            $signed = $artifactMap[$signedPath]
            if ([int64]$signed.bytes -ne [int64]$file.bytes -or [string]$signed.sha256 -cne [string]$file.sha256) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Copy-NxbV1UpdatePackageVerified {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][object]$Manifest,[Parameter(Mandatory)][string]$DestinationRoot)
    $source = [IO.Path]::GetFullPath($PackageRoot)
    $destination = [IO.Path]::GetFullPath($DestinationRoot)
    if (Test-Path -LiteralPath $destination) { throw 'Update destination root must be absent.' }
    [IO.Directory]::CreateDirectory($destination) | Out-Null
    foreach ($file in @($Manifest.files)) {
        $relative = [string]$file.path
        if (-not (Test-NxbV1InstallerRelativePath -Path $relative)) { throw ('Unsafe update package path: {0}' -f $relative) }
        $nativeRelative = $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
        $sourcePath = Join-Path -Path $source -ChildPath $nativeRelative
        $destinationPath = Join-Path -Path $destination -ChildPath $nativeRelative
        $parent = Split-Path -Parent $destinationPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
        [IO.File]::Copy($sourcePath,$destinationPath,$false)
    }
    if (-not (Test-NxbV1PackageAgainstManifest -PackageRoot $destination -Manifest $Manifest)) { throw 'Copied update package failed byte/hash verification.' }
}

function Invoke-NxbV1UpdateAtomicSwap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CurrentRoot,
        [Parameter(Mandatory)][string]$CandidateRoot,
        [Parameter(Mandatory)][string]$RollbackRoot,
        [Parameter(Mandatory)][scriptblock]$PostPublishValidation
    )
    $current = [IO.Path]::GetFullPath($CurrentRoot)
    $candidate = [IO.Path]::GetFullPath($CandidateRoot)
    $rollback = [IO.Path]::GetFullPath($RollbackRoot)
    if (-not (Test-Path -LiteralPath $current -PathType Container)) { throw 'Atomic update current root is missing.' }
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { throw 'Atomic update candidate root is missing.' }
    if (Test-Path -LiteralPath $rollback) { throw 'Atomic update rollback root must be absent.' }
    [IO.Directory]::Move($current,$rollback)
    $published = $false
    try {
        [IO.Directory]::Move($candidate,$current)
        $published = $true
        $validationPassed = [bool](& $PostPublishValidation $current)
        if (-not $validationPassed) { throw 'Atomic update post-publish validation failed.' }
        return [pscustomobject][ordered]@{ status='passed'; rollback_used=$false; rollback_root=$rollback }
    }
    catch {
        if ($published -and (Test-Path -LiteralPath $current)) { Remove-Item -LiteralPath $current -Recurse -Force }
        if (Test-Path -LiteralPath $rollback -PathType Container) { [IO.Directory]::Move($rollback,$current) }
        throw
    }
}
