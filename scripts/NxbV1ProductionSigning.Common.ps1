Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NxbV1SigningSha256Text {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Test-NxbV1SigningLowerHex {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text,[Parameter(Mandatory)][int]$Length)
    return ($Text.Length -eq $Length -and $Text -cmatch '^[0-9a-f]+$')
}

function Test-NxbV1SigningArtifactPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path.IndexOf('|',[StringComparison]::Ordinal) -ge 0 -or $Path.IndexOf("`r",[StringComparison]::Ordinal) -ge 0 -or $Path.IndexOf("`n",[StringComparison]::Ordinal) -ge 0 -or $Path.IndexOf('\',[StringComparison]::Ordinal) -ge 0) { return $false }
    if ($Path.StartsWith('/',[StringComparison]::Ordinal) -or $Path -match '^[A-Za-z]:') { return $false }
    if ($Path.StartsWith('../',[StringComparison]::Ordinal) -or $Path.EndsWith('/..',[StringComparison]::Ordinal) -or $Path.Contains('/../')) { return $false }
    foreach ($character in $Path.ToCharArray()) { if ([int][char]$character -lt 32 -or [int][char]$character -gt 126) { return $false } }
    return $true
}

function Get-NxbV1SigningPublicKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Security.Cryptography.RSA]$Rsa)
    $parameters = $Rsa.ExportParameters($false)
    $modulusB64 = [Convert]::ToBase64String($parameters.Modulus)
    $exponentB64 = [Convert]::ToBase64String($parameters.Exponent)
    $fingerprintMaterial = @('nxb-v1-rsa-public-key-v1',('modulus_b64={0}' -f $modulusB64),('exponent_b64={0}' -f $exponentB64)) -join "`n"
    return [pscustomobject][ordered]@{ modulus_b64=$modulusB64; exponent_b64=$exponentB64; fingerprint=(Get-NxbV1SigningSha256Text -Text $fingerprintMaterial) }
}

function Get-NxbV1ReleaseCanonicalMaterial {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Envelope)
    if ([string]$Envelope.canonical_contract_id -cne 'nxb-v1-release-signature-canonical-v1') { throw 'Release signature canonical contract drift.' }
    if ([int]$Envelope.schema_version -ne 1) { throw 'Release signature schema_version must be 1.' }
    if ([string]$Envelope.release_version -cne '1.0.0') { throw 'Release signature release_version must be 1.0.0.' }
    if (-not (Test-NxbV1SigningLowerHex -Text ([string]$Envelope.release_head) -Length 40)) { throw 'release_head must be 40 lowercase hex.' }
    if (-not (Test-NxbV1SigningLowerHex -Text ([string]$Envelope.certified_implementation_head) -Length 40)) { throw 'certified_implementation_head must be 40 lowercase hex.' }
    if (-not (Test-NxbV1SigningLowerHex -Text ([string]$Envelope.package_manifest_sha256) -Length 64)) { throw 'package_manifest_sha256 must be 64 lowercase hex.' }
    if (-not (Test-NxbV1SigningLowerHex -Text ([string]$Envelope.release_notes_sha256) -Length 64)) { throw 'release_notes_sha256 must be 64 lowercase hex.' }
    if ([string]$Envelope.signing_algorithm -cne 'RSA-PKCS1-SHA256') { throw 'Unsupported release signing algorithm.' }
    if ([int]$Envelope.key_size_bits -lt 3072) { throw 'Release signing key is below 3072 bits.' }
    if (-not (Test-NxbV1SigningLowerHex -Text ([string]$Envelope.public_key.fingerprint) -Length 64)) { throw 'public key fingerprint must be 64 lowercase hex.' }
    if ([string]::IsNullOrWhiteSpace([string]$Envelope.signer_key_id)) { throw 'signer_key_id is required.' }
    if ([string]::IsNullOrWhiteSpace([string]$Envelope.created_utc)) { throw 'created_utc is required.' }
    $artifactMap = @{}
    foreach ($artifact in @($Envelope.artifacts)) {
        $path = [string]$artifact.path
        if (-not (Test-NxbV1SigningArtifactPath -Path $path)) { throw ('Unsafe release artifact path: {0}' -f $path) }
        if ($artifactMap.ContainsKey($path)) { throw ('Duplicate release artifact path: {0}' -f $path) }
        if ([int64]$artifact.bytes -lt 0) { throw ('Negative release artifact byte count: {0}' -f $path) }
        if (-not (Test-NxbV1SigningLowerHex -Text ([string]$artifact.sha256) -Length 64)) { throw ('Invalid release artifact SHA-256: {0}' -f $path) }
        $artifactMap[$path] = $artifact
    }
    if ($artifactMap.Count -lt 1 -or $artifactMap.Count -gt 256) { throw 'Release artifact count must be between 1 and 256.' }
    $paths = [string[]]@($artifactMap.Keys)
    [Array]::Sort($paths,[StringComparer]::Ordinal)
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($line in @(
        'nxb-v1-release-signature-canonical-v1','schema_version=1',
        ('release_version={0}' -f [string]$Envelope.release_version),('release_head={0}' -f [string]$Envelope.release_head),
        ('certified_implementation_head={0}' -f [string]$Envelope.certified_implementation_head),('package_manifest_sha256={0}' -f [string]$Envelope.package_manifest_sha256),
        ('release_notes_sha256={0}' -f [string]$Envelope.release_notes_sha256),('artifact_count={0}' -f $paths.Count),
        ('signer_mode={0}' -f [string]$Envelope.signer_mode),('signer_key_id={0}' -f [string]$Envelope.signer_key_id),
        ('signing_algorithm={0}' -f [string]$Envelope.signing_algorithm),('key_size_bits={0}' -f [int]$Envelope.key_size_bits),
        ('public_modulus_b64={0}' -f [string]$Envelope.public_key.modulus_b64),('public_exponent_b64={0}' -f [string]$Envelope.public_key.exponent_b64),
        ('public_fingerprint={0}' -f [string]$Envelope.public_key.fingerprint),('created_utc={0}' -f [string]$Envelope.created_utc)
    )) { $lines.Add($line) }
    foreach ($path in $paths) { $artifact=$artifactMap[$path]; $lines.Add(('artifact={0}|{1}|{2}' -f $path,[int64]$artifact.bytes,[string]$artifact.sha256)) }
    return ($lines -join "`n")
}

function Test-NxbV1SigningRsaProtected {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Security.Cryptography.RSA]$Rsa)
    if ($Rsa -is [Security.Cryptography.RSACng]) { return ($Rsa.Key.ExportPolicy -eq [Security.Cryptography.CngExportPolicies]::None) }
    if ($Rsa -is [Security.Cryptography.RSACryptoServiceProvider]) { return (-not $Rsa.CspKeyContainerInfo.Exportable) }
    return $false
}

function New-NxbV1CertificationSigner {
    [CmdletBinding()]
    param([Parameter()][int]$KeySizeBits = 3072)
    if ($KeySizeBits -lt 3072) { throw 'Certification signer must be at least 3072 bits.' }
    $rsa = [Security.Cryptography.RSA]::Create()
    try {
        $rsa.KeySize = $KeySizeBits
        if ($rsa.KeySize -lt 3072) { throw 'Certification RSA provider did not honor the minimum key size.' }
        $publicKey = Get-NxbV1SigningPublicKey -Rsa $rsa
        return [pscustomobject][ordered]@{ mode='certification-ephemeral'; key_id=('cert-ephemeral:{0}' -f $publicKey.fingerprint); rsa=$rsa; public_key=$publicKey; key_size_bits=[int]$rsa.KeySize; private_key_persisted=$false; production_signer_claimed=$false }
    }
    catch { $rsa.Dispose(); throw }
}

function Get-NxbV1ProductionCertificateSigner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('CurrentUser','LocalMachine')][string]$StoreLocation,
        [Parameter()][ValidateSet('My')][string]$StoreName = 'My',
        [Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{40,128}$')][string]$Thumbprint
    )
    $location = [Security.Cryptography.X509Certificates.StoreLocation][Enum]::Parse([Security.Cryptography.X509Certificates.StoreLocation],$StoreLocation,$true)
    $store = [Security.Cryptography.X509Certificates.X509Store]::new($StoreName,$location)
    $normalizedThumbprint = $Thumbprint.Replace(' ','').ToUpperInvariant()
    try {
        $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
        $certificateMatches = @($store.Certificates | Where-Object { $_.Thumbprint.Replace(' ','').ToUpperInvariant() -ceq $normalizedThumbprint })
        if ($certificateMatches.Count -ne 1) { throw ('Production signer certificate count must be exactly one. actual={0}' -f $certificateMatches.Count) }
        $certificate = $certificateMatches[0]
        if (-not $certificate.HasPrivateKey) { throw 'Production signer certificate has no private key.' }
        $now = [DateTime]::UtcNow
        if ($now -lt $certificate.NotBefore.ToUniversalTime() -or $now -gt $certificate.NotAfter.ToUniversalTime()) { throw 'Production signer certificate is outside its validity window.' }
        $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
        if ($null -eq $rsa) { throw 'Production signer certificate does not expose an RSA private key.' }
        if ($rsa.KeySize -lt 3072) { $rsa.Dispose(); throw 'Production signer RSA key is below 3072 bits.' }
        if (-not (Test-NxbV1SigningRsaProtected -Rsa $rsa)) { $rsa.Dispose(); throw 'Production signer private key is exportable or its protection state is unknown.' }
        $publicKey = Get-NxbV1SigningPublicKey -Rsa $rsa
        return [pscustomobject][ordered]@{ mode='production-windows-certificate-store'; key_id=('win-cert:{0}/{1}/{2}' -f $StoreLocation,$StoreName,$normalizedThumbprint); rsa=$rsa; public_key=$publicKey; key_size_bits=[int]$rsa.KeySize; private_key_persisted=$true; production_signer_claimed=$true; certificate_thumbprint=$normalizedThumbprint }
    }
    finally { $store.Close(); $store.Dispose() }
}

function New-NxbV1SignedReleaseEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Signer,[Parameter(Mandatory)][string]$ReleaseHead,[Parameter(Mandatory)][string]$CertifiedImplementationHead,
        [Parameter(Mandatory)][string]$PackageManifestSha256,[Parameter(Mandatory)][string]$ReleaseNotesSha256,[Parameter(Mandatory)][object[]]$Artifacts,
        [Parameter()][string]$CreatedUtc = ([DateTime]::UtcNow.ToString('o'))
    )
    $envelope = [pscustomobject][ordered]@{
        schema_version=1; status='signed'; canonical_contract_id='nxb-v1-release-signature-canonical-v1'; release_version='1.0.0';
        release_head=$ReleaseHead.ToLowerInvariant(); certified_implementation_head=$CertifiedImplementationHead.ToLowerInvariant();
        package_manifest_sha256=$PackageManifestSha256.ToLowerInvariant(); release_notes_sha256=$ReleaseNotesSha256.ToLowerInvariant(); artifacts=@($Artifacts);
        signer_mode=[string]$Signer.mode; signer_key_id=[string]$Signer.key_id; signing_algorithm='RSA-PKCS1-SHA256'; key_size_bits=[int]$Signer.key_size_bits;
        public_key=$Signer.public_key; created_utc=$CreatedUtc; canonical_sha256=''; signature_b64=''; private_key_persisted=[bool]$Signer.private_key_persisted; production_signer_claimed=[bool]$Signer.production_signer_claimed
    }
    $material = Get-NxbV1ReleaseCanonicalMaterial -Envelope $envelope
    $envelope.canonical_sha256 = Get-NxbV1SigningSha256Text -Text $material
    $signature = $Signer.rsa.SignData([Text.UTF8Encoding]::new($false).GetBytes($material),[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $envelope.signature_b64 = [Convert]::ToBase64String($signature)
    return $envelope
}

function Test-NxbV1SignedReleaseEnvelope {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Envelope)
    try {
        $material = Get-NxbV1ReleaseCanonicalMaterial -Envelope $Envelope
        if ((Get-NxbV1SigningSha256Text -Text $material) -cne [string]$Envelope.canonical_sha256) { return $false }
        $parameters = [Security.Cryptography.RSAParameters]::new()
        $parameters.Modulus = [Convert]::FromBase64String([string]$Envelope.public_key.modulus_b64)
        $parameters.Exponent = [Convert]::FromBase64String([string]$Envelope.public_key.exponent_b64)
        $rsa = [Security.Cryptography.RSA]::Create()
        try {
            $rsa.ImportParameters($parameters)
            if ($rsa.KeySize -lt 3072) { return $false }
            $publicKey = Get-NxbV1SigningPublicKey -Rsa $rsa
            if ([string]$publicKey.fingerprint -cne [string]$Envelope.public_key.fingerprint) { return $false }
            $signature = [Convert]::FromBase64String([string]$Envelope.signature_b64)
            return $rsa.VerifyData([Text.UTF8Encoding]::new($false).GetBytes($material),$signature,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
        }
        finally { $rsa.Dispose() }
    }
    catch { return $false }
}
