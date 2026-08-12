$ErrorActionPreference = 'Stop'

Describe 'NXB v1 production signing contract' {
    BeforeAll {
        function Get-NxbV1SigningTestContext {
            $root = [string]$env:NXB_V1_SIGNING_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_V1_SIGNING_REPOSITORY_ROOT is required.' }
            $fullRoot = [IO.Path]::GetFullPath($root)
            return [pscustomobject][ordered]@{
                root = $fullRoot
                policy = Join-Path $fullRoot 'config\nxb-v1-production-signing-policy.json'
                integration_policy = Join-Path $fullRoot 'config\nxb-v1-release-integration-policy.json'
                signature_schema = Join-Path $fullRoot 'schemas\nxb-v1-release-signature-envelope.schema.json'
                receipt_schema = Join-Path $fullRoot 'schemas\nxb-v1-production-signing-certification-receipt.schema.json'
                common = Join-Path $fullRoot 'scripts\NxbV1ProductionSigning.Common.ps1'
                operator = Join-Path $fullRoot 'scripts\Invoke-NxbV1ReleaseManifestSigning.ps1'
                authority = Join-Path $fullRoot 'scripts\Invoke-NxbV1ProductionSigningCertification.ps1'
                validator = Join-Path $fullRoot 'tools\validate_v1_production_signing.py'
                release_errors = Join-Path $fullRoot 'config\nxb-v1-release-known-error-signatures.json'
                docs = Join-Path $fullRoot 'docs\NXB-V1-PRODUCTION-SIGNING.md'
            }
        }
    }

    It 'keeps every production signing authority component repo-owned' {
        $context = Get-NxbV1SigningTestContext
        foreach ($path in @($context.policy,$context.integration_policy,$context.signature_schema,$context.receipt_schema,$context.common,$context.operator,$context.authority,$context.validator,$context.release_errors,$context.docs)) {
            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        }
    }

    It 'binds production signing to the native-certified release integration predecessor' {
        $context = Get-NxbV1SigningTestContext
        $policy = Get-Content -LiteralPath $context.policy -Raw | ConvertFrom-Json
        [int]$policy.schema_version | Should -Be 1
        [string]$policy.contract_id | Should -BeExactly 'nxb-v1-production-signing-v1'
        [string]$policy.predecessor_release_integration_head | Should -BeExactly '9371399bab4fbb921ad94198aa148c597c7b6261'
        [string]$policy.certified_implementation_head | Should -BeExactly 'a10535b294c4d7ba8a4c3683154609087bf50c4b'
        [string]$policy.target_version | Should -BeExactly '1.0.0'
    }

    It 'locks signing to RSA PKCS1 SHA256 with at least 3072 bits' {
        $context = Get-NxbV1SigningTestContext
        $policy = Get-Content -LiteralPath $context.policy -Raw | ConvertFrom-Json
        [string]$policy.algorithm | Should -BeExactly 'RSA-PKCS1-SHA256'
        [int]$policy.minimum_rsa_bits | Should -Be 3072
        [string]$policy.canonical_contract_id | Should -BeExactly 'nxb-v1-release-signature-canonical-v1'
        [string]$policy.canonical_artifact_order | Should -BeExactly 'ordinal-path'
    }

    It 'keeps certification signing ephemeral and unable to claim production authority' {
        $context = Get-NxbV1SigningTestContext
        $policy = Get-Content -LiteralPath $context.policy -Raw | ConvertFrom-Json
        [string]$policy.certification.signer_mode | Should -BeExactly 'ephemeral-rsa'
        [bool]$policy.certification.private_key_persisted | Should -BeFalse
        [bool]$policy.certification.production_signer_claimed | Should -BeFalse
        [int]$policy.certification.minimum_rsa_bits | Should -Be 3072
    }

    It 'requires production signing to use protected Windows certificate-store key references only' {
        $context = Get-NxbV1SigningTestContext
        $policy = Get-Content -LiteralPath $context.policy -Raw | ConvertFrom-Json
        [string]$policy.production.signer_mode | Should -BeExactly 'windows-certificate-store'
        @($policy.production.allowed_store_locations).Count | Should -Be 2
        @($policy.production.allowed_store_names) | Should -Contain 'My'
        [bool]$policy.production.require_private_key | Should -BeTrue
        [bool]$policy.production.require_protected_private_key | Should -BeTrue
        [bool]$policy.production.allow_pfx_path | Should -BeFalse
        [bool]$policy.production.allow_pem_path | Should -BeFalse
        [bool]$policy.production.allow_raw_private_key_bytes | Should -BeFalse
    }

    It 'defines a strict signed release envelope with no unknown fields' {
        $context = Get-NxbV1SigningTestContext
        $schema = Get-Content -LiteralPath $context.signature_schema -Raw | ConvertFrom-Json
        [bool]$schema.additionalProperties | Should -BeFalse
        @($schema.required).Count | Should -Be 19
        [string]$schema.properties.canonical_contract_id.const | Should -BeExactly 'nxb-v1-release-signature-canonical-v1'
        [string]$schema.properties.signing_algorithm.const | Should -BeExactly 'RSA-PKCS1-SHA256'
        [int]$schema.properties.key_size_bits.minimum | Should -Be 3072
        [int]$schema.properties.artifacts.maxItems | Should -Be 256
    }

    It 'defines a strict production signing certification receipt' {
        $context = Get-NxbV1SigningTestContext
        $schema = Get-Content -LiteralPath $context.receipt_schema -Raw | ConvertFrom-Json
        [bool]$schema.additionalProperties | Should -BeFalse
        [string]$schema.properties.authority.const | Should -BeExactly 'nxb-v1-production-signing-certification-v1'
        [string]$schema.properties.release_integration_predecessor_head.const | Should -BeExactly '9371399bab4fbb921ad94198aa148c597c7b6261'
        [bool]$schema.properties.production_signer_claimed.const | Should -BeFalse
        [bool]$schema.properties.actual_production_release_signed.const | Should -BeFalse
        [bool]$schema.properties.production_signing_pipeline_certified.const | Should -BeTrue
    }

    It 'constructs canonical material with fixed field ordering and ordinal artifact ordering' {
        $context = Get-NxbV1SigningTestContext
        $source = Get-Content -LiteralPath $context.common -Raw
        $source | Should -Match ([regex]::Escape("[Array]::Sort(`$paths,[StringComparer]::Ordinal)"))
        foreach ($token in @('nxb-v1-release-signature-canonical-v1','schema_version=1','release_version={0}','release_head={0}','certified_implementation_head={0}','package_manifest_sha256={0}','release_notes_sha256={0}','artifact_count={0}','signer_mode={0}','signer_key_id={0}','public_fingerprint={0}','artifact={0}|{1}|{2}')) {
            $source | Should -Match ([regex]::Escape($token))
        }
    }

    It 'rejects unsafe duplicate or non-ASCII artifact paths before canonicalization' {
        $context = Get-NxbV1SigningTestContext
        $source = Get-Content -LiteralPath $context.common -Raw
        $source | Should -Match ([regex]::Escape('Test-NxbV1SigningArtifactPath'))
        $source | Should -Match ([regex]::Escape("$Path.IndexOf('|',[StringComparison]::Ordinal)"))
        $source | Should -Match ([regex]::Escape('$artifactMap.ContainsKey($path)'))
        $source | Should -Match ([regex]::Escape('[int][char]$character -gt 126'))
    }

    It 'uses exact certificate thumbprint lookup validity checks and a protected private key gate in production mode' {
        $context = Get-NxbV1SigningTestContext
        $source = Get-Content -LiteralPath $context.common -Raw
        $source | Should -Match ([regex]::Escape('$normalizedThumbprint = $Thumbprint.Replace('' '','''').ToUpperInvariant()'))
        $source | Should -Match ([regex]::Escape('$certificateMatches.Count -ne 1'))
        $source | Should -Match ([regex]::Escape('$certificate.HasPrivateKey'))
        $source | Should -Match ([regex]::Escape('$certificate.NotBefore.ToUniversalTime()'))
        $source | Should -Match ([regex]::Escape('Test-NxbV1SigningRsaProtected'))
        $source | Should -Match ([regex]::Escape('[Security.Cryptography.CngExportPolicies]::None'))
    }

    It 'never accepts a raw private-key path or PFX parameter in the signing command' {
        $context = Get-NxbV1SigningTestContext
        $source = Get-Content -LiteralPath $context.operator -Raw
        $source | Should -Not -Match '(?im)\[(?:Parameter[^\]]*)\][^\r\n]*(?:Pfx|Pem|PrivateKey)(?:Path|Bytes)'
        $source | Should -Match ([regex]::Escape("[ValidateSet('CertificationEphemeral','ProductionWindowsCertificateStore')]"))
        $source | Should -Match ([regex]::Escape("[ValidateSet('CurrentUser','LocalMachine')]"))
        $source | Should -Match ([regex]::Escape("[ValidateSet('My')]"))
    }

    It 'hashes real package notes and artifact files and performs a post-signing TOCTOU recheck' {
        $context = Get-NxbV1SigningTestContext
        $source = Get-Content -LiteralPath $context.operator -Raw
        $source | Should -Match ([regex]::Escape('Get-NxbV1ReleaseSigningFileSha256'))
        $source | Should -Match ([regex]::Escape('Package manifest changed during signing.'))
        $source | Should -Match ([regex]::Escape('Release notes changed during signing.'))
        $source | Should -Match ([regex]::Escape('Artifact changed during signing: {0}'))
        $source | Should -Match ([regex]::Escape('[IO.FileAttributes]::ReparsePoint'))
    }

    It 'creates certification RSA without persistence or production signer claims' {
        $context = Get-NxbV1SigningTestContext
        $source = Get-Content -LiteralPath $context.common -Raw
        $source | Should -Match ([regex]::Escape("mode='certification-ephemeral'"))
        $source | Should -Match ([regex]::Escape('private_key_persisted=$false'))
        $source | Should -Match ([regex]::Escape('production_signer_claimed=$false'))
        $source | Should -Match ([regex]::Escape("key_id=('cert-ephemeral:{0}' -f $publicKey.fingerprint)"))
    }

    It 'signs and verifies canonical bytes with RSA PKCS1 SHA256' {
        $context = Get-NxbV1SigningTestContext
        $source = Get-Content -LiteralPath $context.common -Raw
        $source | Should -Match ([regex]::Escape('$Signer.rsa.SignData'))
        $source | Should -Match ([regex]::Escape('[Security.Cryptography.HashAlgorithmName]::SHA256'))
        $source | Should -Match ([regex]::Escape('[Security.Cryptography.RSASignaturePadding]::Pkcs1'))
        $source | Should -Match ([regex]::Escape('$rsa.VerifyData'))
        $source | Should -Match ([regex]::Escape('canonical_sha256'))
    }

    It 'gives the independent validator twelve requirements and all eight adversarial controls' {
        $context = Get-NxbV1SigningTestContext
        $source = Get-Content -LiteralPath $context.validator -Raw
        $source | Should -Match ([regex]::Escape('requirement_count": 12'))
        $source | Should -Match ([regex]::Escape('negative_count": 8'))
        foreach ($token in @('tampered_release_head','tampered_package_manifest_sha256','tampered_artifact_sha256','tampered_signer_fingerprint','malformed_signature','weak_key_metadata','wrong_signer_key_id','duplicate_artifact_path')) {
            $source | Should -Match ([regex]::Escape($token))
        }
        $source | Should -Match ([regex]::Escape('pow(signature_int, exponent, modulus)'))
        $source | Should -Match ([regex]::Escape('hmac.compare_digest'))
    }

    It 'extends the release known-error rule over the signing PowerShell authority surface' {
        $context = Get-NxbV1SigningTestContext
        $document = Get-Content -LiteralPath $context.release_errors -Raw | ConvertFrom-Json
        @($document.rules).Count | Should -Be 1
        [string]$document.rules[0].id | Should -BeExactly 'NXB-ERR-036'
        $include = @($document.rules[0].include | ForEach-Object { [string]$_ })
        $include | Should -Contain 'scripts/NxbV1ProductionSigning.Common.ps1'
        $include | Should -Contain 'scripts/Invoke-NxbV1ReleaseManifestSigning.ps1'
        $include | Should -Contain 'scripts/Invoke-NxbV1ProductionSigningCertification.ps1'
        $include | Should -Contain 'tests/V1ProductionSigning.Tests.ps1'
    }

    It 'keeps signing authority incapable of merge tag push or release creation' {
        $context = Get-NxbV1SigningTestContext
        foreach ($path in @($context.operator,$context.authority)) {
            $source = Get-Content -LiteralPath $path -Raw
            $source | Should -Not -Match ([regex]::Escape("@('push'"))
            $source | Should -Not -Match ([regex]::Escape("@('tag'"))
            $source | Should -Not -Match ([regex]::Escape("@('update-ref'"))
            $source | Should -Not -Match 'New-.*GitHub.*Release'
        }
    }

    It 'locks the production signing contract at exactly eighteen tests' {
        $testSource = Get-Content -LiteralPath $PSCommandPath -Raw
        [regex]::Matches($testSource,"(?m)^\s*It\s+'").Count | Should -Be 18
    }
}
