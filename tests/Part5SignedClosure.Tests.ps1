$ErrorActionPreference = 'Stop'

Describe 'NXB IRL-006 Part 5 cryptographic authority signed closure contract' {
    BeforeAll {
        function Get-NxbPart5TestContext {
            $root = [string]$env:NXB_PART5_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_PART5_REPOSITORY_ROOT is required.' }
            $fullRoot = [IO.Path]::GetFullPath($root)
            return [pscustomobject][ordered]@{
                root = $fullRoot
                policy = Join-Path $fullRoot 'config\nxb-part5-signed-closure-policy.json'
                schema = Join-Path $fullRoot 'schemas\nxb-part5-signed-closure.schema.json'
                common = Join-Path $fullRoot 'scripts\NxbPart5Crypto.Common.ps1'
                certification = Join-Path $fullRoot 'scripts\Invoke-NxbPart5SignedClosureCertification.ps1'
                validator = Join-Path $fullRoot 'tools\validate_part5_signed_closure.py'
                inherited = Join-Path $fullRoot 'scripts\Invoke-NxbPart4CombinedCertification.ps1'
                ledger = Join-Path $fullRoot 'docs\NXB-KNOWN-ERROR-LEDGER.md'
                signatures = Join-Path $fullRoot 'config\nxb-known-error-signatures.json'
            }
        }
    }

    It 'keeps every Part 5 authority component repo-owned' {
        $context = Get-NxbPart5TestContext
        foreach ($path in @($context.policy,$context.schema,$context.common,$context.certification,$context.validator,$context.inherited,$context.ledger,$context.signatures)) {
            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        }
    }

    It 'locks RSA PKCS1 SHA256 policy key size and certification boundary' {
        $context = Get-NxbPart5TestContext
        $policy = Get-Content -LiteralPath $context.policy -Raw | ConvertFrom-Json
        [int]$policy.schema_version | Should -Be 1
        [string]$policy.contract_id | Should -BeExactly 'nxb-irl006-part5-signed-closure-v1'
        [string]$policy.algorithm | Should -BeExactly 'RSA-PKCS1-SHA256'
        [int]$policy.key_size_bits | Should -BeGreaterOrEqual 3072
        [bool]$policy.private_key_persisted | Should -BeFalse
        [bool]$policy.production_signer_claimed | Should -BeFalse
    }

    It 'locks ten requirements and ten fail-closed mutations' {
        $context = Get-NxbPart5TestContext
        $policy = Get-Content -LiteralPath $context.policy -Raw | ConvertFrom-Json
        @($policy.requirements).Count | Should -Be 10
        @($policy.requirements | Sort-Object -Unique).Count | Should -Be 10
        @($policy.negative_controls).Count | Should -Be 10
        @($policy.negative_controls | Sort-Object -Unique).Count | Should -Be 10
    }

    It 'uses a strict signed closure schema without additional properties' {
        $context = Get-NxbPart5TestContext
        $schema = Get-Content -LiteralPath $context.schema -Raw | ConvertFrom-Json
        [bool]$schema.additionalProperties | Should -BeFalse
        foreach ($name in @('head_sha','closure_sequence','algorithm','public_key','nested_evidence','nonce_b64','canonical_sha256','signature_b64')) {
            @($schema.required) | Should -Contain $name
        }
    }

    It 'orders canonical material across authority head key and all nested evidence hashes' {
        $context = Get-NxbPart5TestContext
        $source = Get-Content -LiteralPath $context.common -Raw
        $source | Should -Match ([regex]::Escape('function Get-NxbPart5CanonicalMaterial'))
        foreach ($token in @(
            'Receipt.authority','Receipt.head_sha','Receipt.closure_sequence','Receipt.algorithm','Receipt.public_key.modulus_b64',
            'Receipt.public_key.fingerprint_sha256','part234_review_zip_sha256','part234_receipt_sha256','part2_review_zip_sha256',
            'part2_receipt_sha256','part3_review_zip_sha256','part3_receipt_sha256','part4_review_zip_sha256','part4_receipt_sha256',
            'Receipt.nonce_b64','Receipt.created_utc'
        )) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'creates an ephemeral RSA authority and exports only public parameters' {
        $context = Get-NxbPart5TestContext
        $source = Get-Content -LiteralPath $context.common -Raw
        $source | Should -Match ([regex]::Escape('[Security.Cryptography.RSA]::Create()'))
        $source | Should -Match ([regex]::Escape('$rsa.KeySize = $KeySizeBits'))
        $source | Should -Match ([regex]::Escape('$rsa.ExportParameters($false)'))
        $source | Should -Not -Match ([regex]::Escape('ExportParameters($true)'))
    }

    It 'signs canonical UTF8 bytes with SHA256 and PKCS1 padding' {
        $context = Get-NxbPart5TestContext
        $source = Get-Content -LiteralPath $context.common -Raw
        $source | Should -Match ([regex]::Escape('function Invoke-NxbPart5RsaSignature'))
        $source | Should -Match ([regex]::Escape('[Security.Cryptography.HashAlgorithmName]::SHA256'))
        $source | Should -Match ([regex]::Escape('[Security.Cryptography.RSASignaturePadding]::Pkcs1'))
        $source | Should -Match ([regex]::Escape('[Text.Encoding]::UTF8.GetBytes($CanonicalMaterial)'))
    }

    It 'binds public key fingerprint to algorithm modulus and exponent' {
        $context = Get-NxbPart5TestContext
        $source = Get-Content -LiteralPath $context.common -Raw
        $source | Should -Match ([regex]::Escape('@(''RSA-PKCS1-SHA256'',$ModulusB64,$ExponentB64) -join'))
        $source | Should -Match ([regex]::Escape('fingerprint_sha256'))
    }

    It 'keeps private key material memory-only and disposes it after signing' {
        $context = Get-NxbPart5TestContext
        $source = Get-Content -LiteralPath $context.certification -Raw
        $source | Should -Match ([regex]::Escape('private_key_persisted = $false'))
        $source | Should -Match ([regex]::Escape('production_signer_claimed = $false'))
        $source | Should -Match ([regex]::Escape('$authority.rsa.Dispose()'))
        $source | Should -Not -Match '(?im)ExportParameters\(\$true\)|ExportPkcs8PrivateKey|ToXmlString\(\$true\)'
    }

    It 'uses a signed sequence nonce and exact head as anti-replay binding material' {
        $context = Get-NxbPart5TestContext
        $source = Get-Content -LiteralPath $context.common -Raw
        $source | Should -Match ([regex]::Escape('Receipt.closure_sequence'))
        $source | Should -Match ([regex]::Escape('Receipt.head_sha'))
        $source | Should -Match ([regex]::Escape('Receipt.nonce_b64'))
        $source | Should -Match ([regex]::Escape('RandomNumberGenerator]::Create()'))
    }

    It 'independently verifies RSA PKCS1 encoding with modular exponentiation' {
        $context = Get-NxbPart5TestContext
        $source = Get-Content -LiteralPath $context.validator -Raw
        foreach ($token in @('pow(signature_value, e, n)','DIGEST_INFO_SHA256','hashlib.sha256','hmac.compare_digest')) {
            $source | Should -Match ([regex]::Escape($token))
        }
    }

    It 'independent validator recomputes canonical material and public fingerprint' {
        $context = Get-NxbPart5TestContext
        $source = Get-Content -LiteralPath $context.validator -Raw
        $source | Should -Match ([regex]::Escape('def canonical_material'))
        $source | Should -Match ([regex]::Escape('def public_key_fingerprint'))
        $source | Should -Match ([regex]::Escape('canonical_hash_mismatch'))
        $source | Should -Match ([regex]::Escape('public_key_fingerprint_mismatch'))
    }

    It 'requires all ten independent fail-closed mutation names' {
        $context = Get-NxbPart5TestContext
        $source = Get-Content -LiteralPath $context.validator -Raw
        foreach ($token in @(
            'tampered_signature','tampered_head','tampered_part234_receipt_hash','tampered_public_key_fingerprint','tampered_modulus',
            'closure_sequence_replay','algorithm_downgrade','production_signer_claimed','private_key_persisted','canonical_hash_mismatch'
        )) { $source | Should -Match ([regex]::Escape($token)) }
        $source | Should -Match ([regex]::Escape('negative_count == 10'))
    }

    It 'chains Part 5 through the exact Part 4 combined authority and inherited Part 2 and Part 3 results' {
        $context = Get-NxbPart5TestContext
        $source = Get-Content -LiteralPath $context.certification -Raw
        $source | Should -Match ([regex]::Escape('Invoke-NxbPart4CombinedCertification.ps1'))
        $source | Should -Match ([regex]::Escape('-ExpectedHead $ExpectedHead'))
        $source | Should -Match ([regex]::Escape('part2_validated'))
        $source | Should -Match ([regex]::Escape('part3_negative_controls'))
        $source | Should -Match ([regex]::Escape('part4_requirements_validated'))
    }

    It 'publishes only seven JSON review files and no private key artifact' {
        $context = Get-NxbPart5TestContext
        $source = Get-Content -LiteralPath $context.certification -Raw
        foreach ($name in @(
            'known-error-scan.json','part234-combined-certification-receipt.json','part2-semantic-hardening-certification-receipt.json',
            'part3-transport-certification-receipt.json','part4-runner-certification-receipt.json','part5-independent-validation.json','part5-signed-closure-receipt.json'
        )) { $source | Should -Match ([regex]::Escape($name)) }
        $source | Should -Match ([regex]::Escape('$entries.Count -ne 7'))
        $source | Should -Not -Match '(?i)private[-_ ]key\.(?:pem|der|json)|pkcs8'
    }

    It 'inherits ERR-029 keeps Part 5 PowerShell ASCII-clean and requires final zero-error scan' {
        $context = Get-NxbPart5TestContext
        $ledger = Get-Content -LiteralPath $context.ledger -Raw
        $ledger | Should -Match ([regex]::Escape('NXB-ERR-029'))
        foreach ($path in @($context.common,$context.certification)) {
            $nonAscii = 0
            foreach ($byteValue in [IO.File]::ReadAllBytes($path)) { if ([int]$byteValue -gt 0x7F) { $nonAscii++ } }
            $nonAscii | Should -Be 0
            $source = Get-Content -LiteralPath $path -Raw
            $source | Should -Not -Match '(?im)^\s*\$matches\s*='
            $source | Should -Not -Match '(?im)^\s*\$profile\s*='
            $source | Should -Not -Match '(?ims)catch\s*\{\s*\}'
        }
        $certificationSource = Get-Content -LiteralPath $context.certification -Raw
        $certificationSource | Should -Match ([regex]::Escape('$finalScan.rule_count -lt 18'))
        $certificationSource | Should -Match ([regex]::Escape('$finalScan.finding_count -ne 0'))
    }
}
