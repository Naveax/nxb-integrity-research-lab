[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [string]$BundlePath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$CertificatePath,

    [Parameter()]
    [Security.SecureString]$CertificatePassword,

    [Parameter()]
    [switch]$PassThru
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

function ConvertTo-NxbVerifiedSignaturePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if ([IO.Path]::IsPathRooted($Path) -or $Path -match '^[A-Za-z]:') {
        throw "Signature path mutlak olamaz: $Path"
    }
    if ($Path.Contains([string][IO.Path]::DirectorySeparatorChar)) {
        throw "Signature path forward-slash kullanmalıdır: $Path"
    }
    if (-not $Path.StartsWith(
        'evidence-store/signatures/',
        [StringComparison]::Ordinal
    )) {
        throw 'Detached signature evidence-store/signatures altında olmalıdır.'
    }

    foreach ($segment in $Path.Split([char]'/')) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -eq '.' -or $segment -eq '..') {
            throw "Signature path canonical değil: $Path"
        }
    }

    return $Path
}

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
if ([string]::IsNullOrWhiteSpace($BundlePath)) {
    $BundlePath = Join-Path $experimentFull 'evidence-store\bundle-manifest.json'
}
$bundleFull = Get-NxbFullPath -Path $BundlePath
[void](Get-NxbRelativePath -BasePath $experimentFull -ChildPath $bundleFull)
[void](Test-NxbPathSafety -Path $bundleFull -RootPath $experimentFull)

& (Join-Path $PSScriptRoot 'Test-EvidenceStoreSchema.ps1') `
    -Path $bundleFull `
    -DocumentType bundle-manifest

$bundle = Read-NxbJson -Path $bundleFull
if ([string]$bundle.signature_state -eq 'unsigned') {
    throw 'Unsigned bundle detached signature doğrulamasına gönderilemez.'
}
if ($null -eq $bundle.PSObject.Properties['signature']) {
    throw 'İmzalı bundle signature metadata içermiyor.'
}
if ([string]$bundle.signature.algorithm -cne 'rsa-sha256-pkcs1-v1_5') {
    throw "Desteklenmeyen signature algorithm: $($bundle.signature.algorithm)"
}

$bundleIdentity = Get-NxbCanonicalJsonHash `
    -InputObject $bundle `
    -ExcludeRootProperty @('bundle_sha256', 'signature_state', 'signature')
if ($bundleIdentity -cne [string]$bundle.bundle_sha256) {
    throw 'Bundle SHA-256 signature doğrulamasından önce uyuşmuyor.'
}

$signatureRelative = ConvertTo-NxbVerifiedSignaturePath `
    -Path ([string]$bundle.signature.relative_path)
$signatureNative = $signatureRelative.Replace([char]'/', [IO.Path]::DirectorySeparatorChar)
$signatureFull = [IO.Path]::GetFullPath((Join-Path $experimentFull $signatureNative))
[void](Get-NxbRelativePath -BasePath $experimentFull -ChildPath $signatureFull)
if (-not (Test-Path -LiteralPath $signatureFull -PathType Leaf)) {
    throw "Detached signature dosyası bulunamadı: $signatureRelative"
}
[void](Test-NxbPathSafety -Path $signatureFull -RootPath $experimentFull)

$signatureBytes = [IO.File]::ReadAllBytes($signatureFull)
$actualSignatureHash = Get-NxbSha256Hex -InputBytes $signatureBytes
if ($actualSignatureHash -cne [string]$bundle.signature.signature_sha256) {
    throw 'Detached signature file SHA-256 uyuşmuyor.'
}

$certificateFull = Get-NxbFullPath -Path $CertificatePath
$certificate = $null
$publicKey = $null
try {
    if ($null -ne $CertificatePassword) {
        $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $certificateFull,
            $CertificatePassword,
            [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::DefaultKeySet
        )
    }
    else {
        $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $certificateFull
        )
    }

    $certificateHash = Get-NxbSha256Hex -InputBytes $certificate.RawData
    if ($certificateHash -cne [string]$bundle.signature.certificate_sha256) {
        throw 'Certificate SHA-256 signature metadata ile uyuşmuyor.'
    }
    if ($certificateHash -cne [string]$bundle.signature.key_id) {
        throw 'Signature key_id certificate kimliğiyle uyuşmuyor.'
    }

    $publicKey = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey(
        $certificate
    )
    if ($null -eq $publicKey) {
        throw 'Certificate RSA public key içermiyor.'
    }

    $identityBytes = ConvertFrom-NxbSha256Hex -Hex $bundleIdentity
    $isValid = $publicKey.VerifyHash(
        $identityBytes,
        $signatureBytes,
        [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1
    )
    if (-not $isValid) {
        throw 'Detached bundle signature geçersiz.'
    }

    $result = [pscustomobject]@{
        IsValid = $true
        BundlePath = $bundleFull
        BundleSha256 = $bundleIdentity
        SignaturePath = $signatureFull
        SignatureSha256 = $actualSignatureHash
        CertificatePath = $certificateFull
        CertificateSha256 = $certificateHash
        KeyId = [string]$bundle.signature.key_id
        Algorithm = [string]$bundle.signature.algorithm
        SignatureState = 'valid'
    }

    if ($PassThru) {
        Write-Output $result
    }
    else {
        Write-Host "Detached evidence bundle signature geçerli: $signatureFull"
    }
}
finally {
    if ($null -ne $publicKey) {
        $publicKey.Dispose()
    }
    if ($null -ne $certificate) {
        $certificate.Dispose()
    }
}
