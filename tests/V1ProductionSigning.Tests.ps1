$ErrorActionPreference = 'Stop'

Describe 'NXB v1 production signing contract' {
    BeforeAll {
        function Get-NxbV1SigningTestContext {
            $root = [string]$env:NXB_V1_SIGNING_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_V1_SIGNING_REPOSITORY_ROOT is required.' }
            $fullRoot = [IO.Path]::GetFullPath($root)
            [pscustomobject][ordered]@{
                policy = Join-Path $fullRoot 'config\nxb-v1-production-signing-policy.json'
                integration_policy = Join-Path $fullRoot 'config\nxb-v1-release-integration-policy.json'
                signature_schema = Join-Path $fullRoot 'schemas\nxb-v1-release-signature-envelope.schema.json'
                receipt_schema = Join-Path $fullRoot 'schemas\nxb-v1-production-signing-certification-receipt.schema.json'
                common = Join-Path $fullRoot 'scripts\NxbV1ProductionSigning.Common.ps1'
                operator = Join-Path $fullRoot 'scripts\Invoke-NxbV1ReleaseManifestSigning.ps1'
                authority = Join-Path $fullRoot 'scripts\Invoke-NxbV1ProductionSigningCertification.ps1'
                validator = Join-Path $fullRoot 'tools\validate_v1_production_signing.py'
                release_errors = Join-Path $fullRoot 'config\nxb-v1-release-known-error-signatures.json'
                signing_errors = Join-Path $fullRoot 'config\nxb-v1-signing-known-error-signatures.json'
                docs = Join-Path $fullRoot 'docs\NXB-V1-PRODUCTION-SIGNING.md'
            }
        }
    }

    It 'keeps every production signing authority component repo-owned' {
        $c = Get-NxbV1SigningTestContext
        foreach ($p in @($c.policy,$c.integration_policy,$c.signature_schema,$c.receipt_schema,$c.common,$c.operator,$c.authority,$c.validator,$c.release_errors,$c.signing_errors,$c.docs)) { Test-Path -LiteralPath $p -PathType Leaf | Should -BeTrue }
    }

    It 'binds production signing to the native-certified release integration predecessor' {
        $p = Get-Content -LiteralPath (Get-NxbV1SigningTestContext).policy -Raw | ConvertFrom-Json
        [int]$p.schema_version | Should -Be 1
        [string]$p.contract_id | Should -BeExactly 'nxb-v1-production-signing-v1'
        [string]$p.predecessor_release_integration_head | Should -BeExactly '9371399bab4fbb921ad94198aa148c597c7b6261'
        [string]$p.certified_implementation_head | Should -BeExactly 'a10535b294c4d7ba8a4c3683154609087bf50c4b'
        [string]$p.target_version | Should -BeExactly '1.0.1'
    }

    It 'locks signing to RSA PKCS1 SHA256 with at least 3072 bits' {
        $p = Get-Content -LiteralPath (Get-NxbV1SigningTestContext).policy -Raw | ConvertFrom-Json
        [string]$p.algorithm | Should -BeExactly 'RSA-PKCS1-SHA256'
        [int]$p.minimum_rsa_bits | Should -Be 3072
        [string]$p.canonical_contract_id | Should -BeExactly 'nxb-v1-release-signature-canonical-v1'
        [string]$p.canonical_artifact_order | Should -BeExactly 'ordinal-path'
    }

    It 'keeps certification signing ephemeral and unable to claim production authority' {
        $p = Get-Content -LiteralPath (Get-NxbV1SigningTestContext).policy -Raw | ConvertFrom-Json
        [string]$p.certification.signer_mode | Should -BeExactly 'ephemeral-rsa'
        [bool]$p.certification.private_key_persisted | Should -BeFalse
        [bool]$p.certification.production_signer_claimed | Should -BeFalse
        [int]$p.certification.minimum_rsa_bits | Should -Be 3072
    }

    It 'requires production signing to use protected Windows certificate-store key references only' {
        $p = Get-Content -LiteralPath (Get-NxbV1SigningTestContext).policy -Raw | ConvertFrom-Json
        [string]$p.production.signer_mode | Should -BeExactly 'windows-certificate-store'
        @($p.production.allowed_store_locations).Count | Should -Be 2
        @($p.production.allowed_store_names) | Should -Contain 'My'
        [bool]$p.production.require_private_key | Should -BeTrue
        [bool]$p.production.require_protected_private_key | Should -BeTrue
        [bool]$p.production.allow_pfx_path | Should -BeFalse
        [bool]$p.production.allow_pem_path | Should -BeFalse
        [bool]$p.production.allow_raw_private_key_bytes | Should -BeFalse
    }

    It 'defines a strict signed release envelope with no unknown fields' {
        $s = Get-Content -LiteralPath (Get-NxbV1SigningTestContext).signature_schema -Raw | ConvertFrom-Json
        [bool]$s.additionalProperties | Should -BeFalse
        @($s.required).Count | Should -Be 19
        [string]$s.properties.canonical_contract_id.const | Should -BeExactly 'nxb-v1-release-signature-canonical-v1'
        @($s.properties.release_version.enum) | Should -Contain '1.0.0'
        @($s.properties.release_version.enum) | Should -Contain '1.0.1'
        [string]$s.properties.signing_algorithm.const | Should -BeExactly 'RSA-PKCS1-SHA256'
        [int]$s.properties.key_size_bits.minimum | Should -Be 3072
        [int]$s.properties.artifacts.maxItems | Should -Be 256
    }

    It 'defines a strict production signing certification receipt' {
        $s = Get-Content -LiteralPath (Get-NxbV1SigningTestContext).receipt_schema -Raw | ConvertFrom-Json
        [bool]$s.additionalProperties | Should -BeFalse
        [string]$s.properties.authority.const | Should -BeExactly 'nxb-v1-production-signing-certification-v1'
        [string]$s.properties.release_integration_predecessor_head.const | Should -BeExactly '9371399bab4fbb921ad94198aa148c597c7b6261'
        [int]$s.properties.release_known_error_rules.const | Should -Be 1
        [int]$s.properties.signing_known_error_rules.const | Should -Be 2
        [bool]$s.properties.production_signer_claimed.const | Should -BeFalse
        [bool]$s.properties.actual_production_release_signed.const | Should -BeFalse
        [bool]$s.properties.production_signing_pipeline_certified.const | Should -BeTrue
    }

    It 'constructs canonical material with fixed field ordering and ordinal artifact ordering' {
        $source = Get-Content -LiteralPath (Get-NxbV1SigningTestContext).common -Raw
        $source | Should -Match ([regex]::Escape('[Array]::Sort($paths,[StringComparer]::Ordinal)'))
        $source | Should -Match ([regex]::Escape("[ValidateSet('1.0.0','1.0.1')]"))
        foreach ($token in @('nxb-v1-release-signature-canonical-v1','schema_version=1','release_version={0}','release_head={0}','certified_implementation_head={0}','package_manifest_sha256={0}','release_notes_sha256={0}','artifact_count={0}','signer_mode={0}','signer_key_id={0}','public_fingerprint={0}','artifact={0}|{1}|{2}')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'rejects unsafe duplicate or non-ASCII artifact paths before canonicalization' {
        $source = Get-Content -LiteralPath (Get-NxbV1SigningTestContext).common -Raw
        $source | Should -Match ([regex]::Escape('Test-NxbV1SigningArtifactPath'))
        $source | Should -Match ([regex]::Escape('$Path.IndexOf(''|'',[StringComparison]::Ordinal)'))
        $source | Should -Match ([regex]::Escape('$artifactMap.ContainsKey($path)'))
        $source | Should -Match ([regex]::Escape('[int][char]$character -gt 126'))
    }

    It 'uses exact certificate thumbprint lookup validity checks and a protected private key gate in production mode' {
        $source = Get-Content -LiteralPath (Get-NxbV1SigningTestContext).common -Raw
        foreach ($token in @('$normalizedThumbprint = $Thumbprint.Replace('' '','''').ToUpperInvariant()','$certificateMatches.Count -ne 1','$certificate.HasPrivateKey','$certificate.NotBefore.ToUniversalTime()','Test-NxbV1SigningRsaProtected','[Security.Cryptography.CngExportPolicies]::None')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'never accepts a raw private-key path or PFX parameter in the signing command' {
        $source = Get-Content -LiteralPath (Get-NxbV1SigningTestContext).operator -Raw
        $source | Should -Not -Match '(?im)\[(?:Parameter[^\]]*)\][^\r\n]*(?:Pfx|Pem|PrivateKey)(?:Path|Bytes)'
        $source | Should -Match ([regex]::Escape("[ValidateSet('CertificationEphemeral','ProductionWindowsCertificateStore')]"))
        $source | Should -Match ([regex]::Escape("[ValidateSet('CurrentUser','LocalMachine')]"))
        $source | Should -Match ([regex]::Escape("[ValidateSet('My')]"))
        $source | Should -Match ([regex]::Escape("if ([string]`$policy.target_version -cne '1.0.1')"))
        $source | Should -Match ([regex]::Escape('-ReleaseVersion ([string]$policy.target_version)'))
    }

    It 'hashes real package notes and artifact files and performs a post-signing TOCTOU recheck' {
        $source = Get-Content -LiteralPath (Get-NxbV1SigningTestContext).operator -Raw
        foreach ($token in @('Get-NxbV1ReleaseSigningFileSha256','Package manifest changed during signing.','Release notes changed during signing.','Artifact changed during signing: {0}','[IO.FileAttributes]::ReparsePoint','$trimChars = [char[]]@(')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'creates certification RSA without persistence or production signer claims' {
        $source = Get-Content -LiteralPath (Get-NxbV1SigningTestContext).common -Raw
        foreach ($token in @('function Get-NxbV1CertificationSigner','function ConvertTo-NxbV1SignedReleaseEnvelope',"mode='certification-ephemeral'",'private_key_persisted=$false','production_signer_claimed=$false','key_id=(''cert-ephemeral:{0}'' -f $publicKey.fingerprint)')) { $source | Should -Match ([regex]::Escape($token)) }
        $oldSignerFunction = 'function New-NxbV1' + 'CertificationSigner'
        $oldEnvelopeFunction = 'function New-NxbV1' + 'SignedReleaseEnvelope'
        $source | Should -Not -Match ([regex]::Escape($oldSignerFunction))
        $source | Should -Not -Match ([regex]::Escape($oldEnvelopeFunction))
    }

    It 'signs and verifies canonical bytes with RSA PKCS1 SHA256' {
        $source = Get-Content -LiteralPath (Get-NxbV1SigningTestContext).common -Raw
        foreach ($token in @('$Signer.rsa.SignData','[Security.Cryptography.HashAlgorithmName]::SHA256','[Security.Cryptography.RSASignaturePadding]::Pkcs1','$rsa.VerifyData','canonical_sha256')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'gives the independent validator twelve requirements and all eight adversarial controls' {
        $source = Get-Content -LiteralPath (Get-NxbV1SigningTestContext).validator -Raw
        $source | Should -Match ([regex]::Escape('requirement_count": 12'.Replace('\','')))
        $source | Should -Match ([regex]::Escape('negative_count": 8'.Replace('\','')))
        $source | Should -Match ([regex]::Escape('== "1.0.1"'))
        foreach ($token in @('tampered_release_head','tampered_package_manifest_sha256','tampered_artifact_sha256','tampered_signer_fingerprint','malformed_signature','weak_key_metadata','wrong_signer_key_id','duplicate_artifact_path','pow(signature_int, exponent, modulus)','hmac.compare_digest')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'extends successor known-error regression coverage over the signing authority surface' {
        $c = Get-NxbV1SigningTestContext
        $release = Get-Content -LiteralPath $c.release_errors -Raw | ConvertFrom-Json
        @($release.rules).Count | Should -Be 1
        [string]$release.rules[0].id | Should -BeExactly 'NXB-ERR-036'
        $include = @($release.rules[0].include | ForEach-Object { [string]$_ })
        foreach ($required in @('scripts/NxbV1ProductionSigning.Common.ps1','scripts/Invoke-NxbV1ReleaseManifestSigning.ps1','scripts/Invoke-NxbV1ProductionSigningCertification.ps1','tests/V1ProductionSigning.Tests.ps1')) { $include | Should -Contain $required }

        $signing = Get-Content -LiteralPath $c.signing_errors -Raw | ConvertFrom-Json
        @($signing.rules).Count | Should -Be 2
        @($signing.rules | ForEach-Object { [string]$_.id }) | Should -Contain 'NXB-ERR-007'
        @($signing.rules | ForEach-Object { [string]$_.id }) | Should -Contain 'NXB-ERR-014'

        $authoritySource = Get-Content -LiteralPath $c.authority -Raw
        $authoritySource | Should -Match ([regex]::Escape('$ps7Summary = (''{0}/{1}'' -f [int]$ps7Contract.passed,[int]$ps7Contract.total)'))
        $authoritySource | Should -Match ([regex]::Escape('$ps51Summary = (''{0}/{1}'' -f [int]$ps51Contract.passed,[int]$ps51Contract.total)'))
        $authoritySource | Should -Not -Match "(?im)\\bps(?:7|51)\\s*=\\s*(?:\\(\\s*'18/18'\\s*\\)|'18/18')"
    }

    It 'keeps signing authority incapable of merge tag push or release creation' {
        $c = Get-NxbV1SigningTestContext
        foreach ($path in @($c.operator,$c.authority)) {
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
