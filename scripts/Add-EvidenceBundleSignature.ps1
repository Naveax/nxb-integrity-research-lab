[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [string]$BundlePath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$PfxPath,

    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [Security.SecureString]$PfxPassword,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SignatureRelativePath = 'evidence-store/signatures/bundle.sig'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Nxb.EvidenceStore.psm1') -Force

function ConvertFrom-NxbSha256Hex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-f]{64}$')]
        [string]$Hex
    )

    $bytes = [byte[]]::new(32)
    for ($index = 0; $index -lt 32; $index++) {
        $bytes[$index] = [Convert]::ToByte($Hex.Substring($index * 2, 2), 16)
    }
    return $bytes
}

function ConvertTo-NxbSignatureRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if ([IO.Path]::IsPathRooted($Path) -or $Path -match '^[A-Za-z]:') {
        throw "Signature path mutlak olamaz: $Path"
    }

    $normalized = $Path.Replace([IO.Path]::DirectorySeparatorChar, [char]'/')
    if (-not $normalized.StartsWith(
        'evidence-store/signatures/',
        [StringComparison]::Ordinal
    )) {
        throw 'Detached signature evidence-store/signatures altında olmalıdır.'
    }

    foreach ($segment in $normalized.Split([char]'/')) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -eq '.' -or $segment -eq '..') {
            throw "Signature path canonical değil: $Path"
        }
    }

    return $normalized
}

function Test-NxbSignatureOutputPathSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$ExperimentRoot
    )

    $pathFull = Get-NxbFullPath -Path $Path
    [void](Get-NxbRelativePath -BasePath $ExperimentRoot -ChildPath $pathFull)

    $existingAncestor = $pathFull
    while (-not (Test-Path -LiteralPath $existingAncestor)) {
        $parent = Split-Path -Parent $existingAncestor
        if ([string]::IsNullOrWhiteSpace($parent) -or
            $parent.Equals($existingAncestor, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Signature output yolu için mevcut güvenli ancestor bulunamadı: $pathFull"
        }
        $existingAncestor = $parent
    }

    [void](Test-NxbPathSafety -Path $existingAncestor -RootPath $ExperimentRoot)
    return $true
}

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
if ([string]::IsNullOrWhiteSpace($BundlePath)) {
    $BundlePath = Join-Path $experimentFull 'evidence-store\bundle-manifest.json'
}
$bundleFull = Get-NxbFullPath -Path $BundlePath
[void](Get-NxbRelativePath -BasePath $experimentFull -ChildPath $bundleFull)
[void](Test-NxbPathSafety -Path $bundleFull -RootPath $experimentFull)

$pfxFull = Get-NxbFullPath -Path $PfxPath
$signatureRelative = ConvertTo-NxbSignatureRelativePath -Path $SignatureRelativePath
$signatureNative = $signatureRelative.Replace([char]'/', [IO.Path]::DirectorySeparatorChar)
$signatureFull = [IO.Path]::GetFullPath((Join-Path $experimentFull $signatureNative))
[void](Get-NxbRelativePath -BasePath $experimentFull -ChildPath $signatureFull)
[void](Test-NxbSignatureOutputPathSafety -Path $signatureFull -ExperimentRoot $experimentFull)

if ($signatureFull -ceq $bundleFull) {
    throw 'Signature dosyası bundle manifest ile aynı olamaz.'
}
if (Test-Path -LiteralPath $signatureFull) {
    throw "Detached signature zaten mevcut: $signatureFull"
}

$unsignedVerification = & (Join-Path $PSScriptRoot 'Test-EvidenceBundle.ps1') `
    -ExperimentPath $experimentFull `
    -BundlePath $bundleFull `
    -PassThru
if ([string]$unsignedVerification.SignatureState -cne 'unsigned') {
    throw "Yalnız unsigned bundle imzalanabilir: $($unsignedVerification.SignatureState)"
}

$bundle = Read-NxbJson -Path $bundleFull
if ($null -ne $bundle.PSObject.Properties['signature']) {
    throw 'Unsigned bundle beklenmeyen signature metadata içeriyor.'
}

$bundleIdentity = Get-NxbCanonicalJsonHash `
    -InputObject $bundle `
    -ExcludeRootProperty @('bundle_sha256', 'signature_state', 'signature')
if ($bundleIdentity -cne [string]$bundle.bundle_sha256) {
    throw 'Bundle identity signing öncesinde doğrulanamadı.'
}

$certificate = $null
$privateKey = $null
$publicKey = $null
$signatureBytes = $null
try {
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $pfxFull,
        $PfxPassword,
        [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::DefaultKeySet
    )
    if (-not $certificate.HasPrivateKey) {
        throw 'PFX private key içermiyor.'
    }

    $privateKey = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey(
        $certificate
    )
    if ($null -eq $privateKey) {
        throw 'PFX içinde RSA private key bulunamadı.'
    }

    $identityBytes = ConvertFrom-NxbSha256Hex -Hex $bundleIdentity
    $signatureBytes = $privateKey.SignHash(
        $identityBytes,
        [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1
    )

    $publicKey = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey(
        $certificate
    )
    if ($null -eq $publicKey -or -not $publicKey.VerifyHash(
        $identityBytes,
        $signatureBytes,
        [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1
    )) {
        throw 'Üretilen detached signature yerel doğrulamadan geçmedi.'
    }

    $certificateHash = Get-NxbSha256Hex -InputBytes $certificate.RawData
    $signatureHash = Get-NxbSha256Hex -InputBytes $signatureBytes
    $signatureMetadata = [ordered]@{
        algorithm = 'rsa-sha256-pkcs1-v1_5'
        key_id = $certificateHash
        certificate_sha256 = $certificateHash
        relative_path = $signatureRelative
        signature_sha256 = $signatureHash
    }

    $bundle.signature_state = 'present_unverified'
    $bundle | Add-Member `
        -MemberType NoteProperty `
        -Name signature `
        -Value $signatureMetadata `
        -Force

    $identityAfterMetadata = Get-NxbCanonicalJsonHash `
        -InputObject $bundle `
        -ExcludeRootProperty @('bundle_sha256', 'signature_state', 'signature')
    if ($identityAfterMetadata -cne $bundleIdentity) {
        throw 'Signature metadata unsigned bundle identity değerini değiştirdi.'
    }

    $storePath = Join-Path $experimentFull 'evidence-store'
    $signatureDirectory = Split-Path -Parent $signatureFull
    New-Item -ItemType Directory -Path $signatureDirectory -Force | Out-Null
    [void](Test-NxbPathSafety -Path $signatureDirectory -RootPath $experimentFull)

    $pendingManifest = Join-Path $storePath (
        '.bundle-signature-pending-{0}.json' -f [guid]::NewGuid().ToString('N')
    )
    try {
        Write-NxbCanonicalJsonAtomic `
            -Path $pendingManifest `
            -InputObject $bundle `
            -Confirm:$false
        & (Join-Path $PSScriptRoot 'Test-EvidenceStoreSchema.ps1') `
            -Path $pendingManifest `
            -DocumentType bundle-manifest
    }
    finally {
        if (Test-Path -LiteralPath $pendingManifest) {
            Remove-Item -LiteralPath $pendingManifest -Force
        }
    }

    if (-not $PSCmdlet.ShouldProcess($bundleFull, 'Detached RSA signature ekle')) {
        return
    }

    $originalManifestBytes = [IO.File]::ReadAllBytes($bundleFull)
    $signatureTemporary = "$signatureFull.tmp.$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllBytes($signatureTemporary, $signatureBytes)
        Move-Item -LiteralPath $signatureTemporary -Destination $signatureFull

        Write-NxbCanonicalJsonAtomic `
            -Path $bundleFull `
            -InputObject $bundle `
            -Confirm:$false

        $structural = & (Join-Path $PSScriptRoot 'Test-EvidenceBundle.ps1') `
            -ExperimentPath $experimentFull `
            -BundlePath $bundleFull `
            -PassThru
        if ([string]$structural.SignatureState -cne 'present_unverified') {
            throw 'İmzalı bundle beklenen present_unverified durumunda değil.'
        }
    }
    catch {
        [IO.File]::WriteAllBytes($bundleFull, $originalManifestBytes)
        if (Test-Path -LiteralPath $signatureFull) {
            Remove-Item -LiteralPath $signatureFull -Force
        }
        throw
    }
    finally {
        if (Test-Path -LiteralPath $signatureTemporary) {
            Remove-Item -LiteralPath $signatureTemporary -Force
        }
    }

    [pscustomobject]@{
        BundlePath = $bundleFull
        BundleSha256 = $bundleIdentity
        SignaturePath = $signatureFull
        SignatureSha256 = $signatureHash
        CertificateSha256 = $certificateHash
        KeyId = $certificateHash
        SignatureState = 'present_unverified'
        Algorithm = 'rsa-sha256-pkcs1-v1_5'
    }
}
finally {
    if ($null -ne $privateKey) {
        $privateKey.Dispose()
    }
    if ($null -ne $publicKey) {
        $publicKey.Dispose()
    }
    if ($null -ne $certificate) {
        $certificate.Dispose()
    }
}
