Set-StrictMode -Version Latest

function Get-NxbPart5Sha256Text {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Get-NxbPart5FileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-NxbPart5AtomicJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$InputObject)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $tempPath = $fullPath + '.tmp-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($tempPath,(($InputObject | ConvertTo-Json -Depth 64) + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tempPath -Destination $fullPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) { Remove-Item -LiteralPath $tempPath -Force }
    }
}

function Get-NxbPart5PublicKeyFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ModulusB64,
        [Parameter(Mandatory)][string]$ExponentB64
    )
    $material = @('RSA-PKCS1-SHA256',$ModulusB64,$ExponentB64) -join "`n"
    return Get-NxbPart5Sha256Text -Text $material
}

function Get-NxbPart5CanonicalMaterial {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Receipt)
    return @(
        [string]$Receipt.authority,
        [string][int]$Receipt.schema_version,
        [string]$Receipt.status,
        [string]$Receipt.head_sha,
        [string][int]$Receipt.closure_sequence,
        [string]$Receipt.algorithm,
        [string][int]$Receipt.key_size_bits,
        ([string][bool]$Receipt.private_key_persisted).ToLowerInvariant(),
        ([string][bool]$Receipt.production_signer_claimed).ToLowerInvariant(),
        [string]$Receipt.public_key.modulus_b64,
        [string]$Receipt.public_key.exponent_b64,
        [string]$Receipt.public_key.fingerprint_sha256,
        [string]$Receipt.nested_evidence.part234_review_zip_sha256,
        [string]$Receipt.nested_evidence.part234_receipt_sha256,
        [string]$Receipt.nested_evidence.part2_review_zip_sha256,
        [string]$Receipt.nested_evidence.part2_receipt_sha256,
        [string]$Receipt.nested_evidence.part3_review_zip_sha256,
        [string]$Receipt.nested_evidence.part3_receipt_sha256,
        [string]$Receipt.nested_evidence.part4_review_zip_sha256,
        [string]$Receipt.nested_evidence.part4_receipt_sha256,
        [string]$Receipt.nonce_b64,
        [string]$Receipt.created_utc
    ) -join "`n"
}

function Get-NxbPart5Nonce {
    [CmdletBinding()]
    param()
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) }
    finally { $rng.Dispose() }
    return [Convert]::ToBase64String($bytes)
}

function Get-NxbPart5EphemeralAuthority {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateRange(3072,8192)][int]$KeySizeBits)
    $rsa = [Security.Cryptography.RSA]::Create()
    $rsa.KeySize = $KeySizeBits
    $public = $rsa.ExportParameters($false)
    $modulusB64 = [Convert]::ToBase64String($public.Modulus)
    $exponentB64 = [Convert]::ToBase64String($public.Exponent)
    return [pscustomobject][ordered]@{
        rsa = $rsa
        modulus_b64 = $modulusB64
        exponent_b64 = $exponentB64
        fingerprint_sha256 = Get-NxbPart5PublicKeyFingerprint -ModulusB64 $modulusB64 -ExponentB64 $exponentB64
        actual_key_size_bits = [int]$rsa.KeySize
        private_key_persisted = $false
    }
}

function Invoke-NxbPart5RsaSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Security.Cryptography.RSA]$Rsa,
        [Parameter(Mandatory)][string]$CanonicalMaterial
    )
    $signature = $Rsa.SignData(
        [Text.Encoding]::UTF8.GetBytes($CanonicalMaterial),
        [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1
    )
    return [Convert]::ToBase64String($signature)
}
