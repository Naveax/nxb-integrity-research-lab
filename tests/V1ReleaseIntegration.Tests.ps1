$ErrorActionPreference = 'Stop'

Describe 'NXB v1 release integration contract' {
    BeforeAll {
        function Get-NxbV1ReleaseTestContext {
            $root = [string]$env:NXB_V1_RELEASE_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_V1_RELEASE_REPOSITORY_ROOT is required.' }
            $fullRoot = [IO.Path]::GetFullPath($root)
            return [pscustomobject][ordered]@{
                root = $fullRoot
                policy = Join-Path $fullRoot 'config\nxb-v1-release-integration-policy.json'
                schema = Join-Path $fullRoot 'schemas\nxb-v1-release-integration-receipt.schema.json'
                release_signatures = Join-Path $fullRoot 'config\nxb-v1-release-known-error-signatures.json'
                release_known_errors = Join-Path $fullRoot 'docs\NXB-V1-RELEASE-KNOWN-ERRORS.md'
                script = Join-Path $fullRoot 'scripts\Test-NxbV1ReleaseIntegration.ps1'
                authority = Join-Path $fullRoot 'scripts\Invoke-NxbV1ReleaseIntegrationCertification.ps1'
                python = Join-Path $fullRoot 'tools\validate_v1_release_integration.py'
                docs = Join-Path $fullRoot 'docs\NXB-V1-RELEASE-INTEGRATION.md'
                candidate_policy = Join-Path $fullRoot 'config\nxb-production-finalization-policy.json'
            }
        }
    }

    It 'keeps every v1 release integration component repo-owned' {
        $context = Get-NxbV1ReleaseTestContext
        foreach ($path in @(
            $context.policy,$context.schema,$context.release_signatures,$context.release_known_errors,
            $context.script,$context.authority,$context.python,$context.docs,$context.candidate_policy
        )) {
            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        }
    }

    It 'binds the release integration policy to one stable contract' {
        $context = Get-NxbV1ReleaseTestContext
        $policy = Get-Content -LiteralPath $context.policy -Raw | ConvertFrom-Json
        [int]$policy.schema_version | Should -Be 1
        [string]$policy.contract_id | Should -BeExactly 'nxb-v1-release-integration-v1'
        [string]$policy.main_branch | Should -BeExactly 'main'
        [string]$policy.release_branch | Should -BeExactly 'release/nxb-v1.0.1-prep'
    }

    It 'binds the successor release layer to the frozen production predecessor and version boundary' {
        $context = Get-NxbV1ReleaseTestContext
        $policy = Get-Content -LiteralPath $context.policy -Raw | ConvertFrom-Json
        [string]$policy.certified_implementation_head | Should -BeExactly 'a4f1b242c003333b1f34b1cd54ca37cab33fbf4f'
        [string]$policy.certified_main_ancestor | Should -BeExactly 'b55fed4e4c960f8fea73b959f29dd57649c6bd65'
        [string]$policy.candidate_version | Should -BeExactly '1.0.1-candidate'
        [string]$policy.target_version | Should -BeExactly '1.0.1'
    }

    It 'allows only explicit additive successor surfaces after certification' {
        $context = Get-NxbV1ReleaseTestContext
        $policy = Get-Content -LiteralPath $context.policy -Raw | ConvertFrom-Json
        $prefixes = @($policy.integration.allowed_successor_paths | ForEach-Object { [string]$_ })
        $prefixes.Count | Should -Be 9
        $prefixes | Should -Contain '.github/workflows/nxb-v1-'
        $prefixes | Should -Contain 'config/nxb-v1-'
        $prefixes | Should -Contain 'docs/NXB-V1-'
        $prefixes | Should -Contain 'schemas/nxb-v1-'
        $prefixes | Should -Contain 'scripts/Invoke-NxbV1'
        $prefixes | Should -Contain 'scripts/NxbV1'
        $prefixes | Should -Contain 'scripts/Test-NxbV1'
        $prefixes | Should -Contain 'tests/V1'
        $prefixes | Should -Contain 'tools/validate_v1_'
        $prefixes | Should -Not -Contain 'scripts/'
        $prefixes | Should -Not -Contain 'config/'
    }

    It 'rejects generated evidence artifacts and private-key marker classes in release preparation' {
        $context = Get-NxbV1ReleaseTestContext
        $policy = Get-Content -LiteralPath $context.policy -Raw | ConvertFrom-Json
        @($policy.integration.forbidden_artifact_suffixes).Count | Should -Be 6
        @($policy.integration.forbidden_artifact_suffixes) | Should -Contain '.etl'
        @($policy.integration.forbidden_artifact_suffixes) | Should -Contain '.zip'
        @($policy.integration.forbidden_artifact_suffixes) | Should -Contain '.pfx'
        @($policy.integration.forbidden_private_key_marker_ids).Count | Should -Be 4
        @($policy.integration.forbidden_private_key_marker_ids) | Should -Contain 'pkcs8'
        @($policy.integration.forbidden_private_key_marker_ids) | Should -Contain 'rsa'
        @($policy.integration.forbidden_private_key_marker_ids) | Should -Contain 'ec'
        @($policy.integration.forbidden_private_key_marker_ids) | Should -Contain 'openssh'
        [bool]$policy.integration.allow_generated_evidence_in_tree | Should -BeFalse
    }

    It 'keeps the production signer separate from certification-only ephemeral signing' {
        $context = Get-NxbV1ReleaseTestContext
        $policy = Get-Content -LiteralPath $context.policy -Raw | ConvertFrom-Json
        [bool]$policy.signing.certification_signer_reuse_allowed | Should -BeFalse
        [bool]$policy.signing.production_signer_required_for_release | Should -BeTrue
        [bool]$policy.signing.private_key_in_repository_allowed | Should -BeFalse
        [bool]$policy.signing.key_rotation_policy_required | Should -BeTrue
        [bool]$policy.signing.revocation_policy_required | Should -BeTrue
    }

    It 'requires signed release packaging smoke validation and a release receipt' {
        $context = Get-NxbV1ReleaseTestContext
        $policy = Get-Content -LiteralPath $context.policy -Raw | ConvertFrom-Json
        [bool]$policy.release.production_merge_required_before_v1_tag | Should -BeTrue
        [bool]$policy.release.signed_release_manifest_required | Should -BeTrue
        [bool]$policy.release.installer_or_package_hashes_required | Should -BeTrue
        [bool]$policy.release.post_integration_smoke_required | Should -BeTrue
        [bool]$policy.release.release_receipt_required | Should -BeTrue
    }

    It 'defines a strict JSON receipt shape for release preflight evidence' {
        $context = Get-NxbV1ReleaseTestContext
        $schema = Get-Content -LiteralPath $context.schema -Raw | ConvertFrom-Json
        [bool]$schema.additionalProperties | Should -BeFalse
        @($schema.required).Count | Should -Be 12
        @($schema.required) | Should -Contain 'certified_implementation_head'
        @($schema.required) | Should -Contain 'release_head'
        @($schema.required) | Should -Contain 'main_head'
        @($schema.required) | Should -Contain 'checks'
        @($schema.required) | Should -Contain 'failure_count'
        [string]$schema.properties.authority.const | Should -BeExactly 'nxb-v1-release-integration-preflight-v1'
        [string]$schema.properties.candidate_version.const | Should -BeExactly '1.0.1-candidate'
        [string]$schema.properties.target_version.const | Should -BeExactly '1.0.1'
    }

    It 'uses the inherited safe native-process preference guard around git calls' {
        $context = Get-NxbV1ReleaseTestContext
        foreach ($sourcePath in @($context.script,$context.authority)) {
            $source = Get-Content -LiteralPath $sourcePath -Raw
            $source | Should -Match ([regex]::Escape('$previousErrorActionPreference = $ErrorActionPreference'))
            $source | Should -Match ([regex]::Escape('$ErrorActionPreference = ''Continue'''))
            $source | Should -Match ([regex]::Escape('$nativeExitCode = if ($null -eq $LASTEXITCODE)'))
            $source | Should -Match ([regex]::Escape('$ErrorActionPreference = $previousErrorActionPreference'))
        }
    }

    It 'requires both certified-head and live-main ancestry before release integration' {
        $context = Get-NxbV1ReleaseTestContext
        $source = Get-Content -LiteralPath $context.script -Raw
        $source | Should -Match ([regex]::Escape('$certifiedAncestorRun = Invoke-NxbV1Native -Executable $git -ArgumentList @(''-C'',$RepositoryRoot,''merge-base'',''--is-ancestor'',$certifiedHead,$releaseHead)'))
        $source | Should -Match ([regex]::Escape('$mainAncestorRun = Invoke-NxbV1Native -Executable $git -ArgumentList @(''-C'',$RepositoryRoot,''merge-base'',''--is-ancestor'',$mainHead,$releaseHead)'))
        $source | Should -Match ([regex]::Escape('$certifiedMainRun = Invoke-NxbV1Native -Executable $git -ArgumentList @(''-C'',$RepositoryRoot,''merge-base'',''--is-ancestor'',$certifiedMainAncestor,$certifiedHead)'))
        $source | Should -Match ([regex]::Escape('main_ref_unavailable'))
    }

    It 'requires a clean tree and rejects modifications outside explicit successor paths' {
        $context = Get-NxbV1ReleaseTestContext
        $source = Get-Content -LiteralPath $context.script -Raw
        $source | Should -Match ([regex]::Escape('$statusRun = Invoke-NxbV1Native -Executable $git -ArgumentList @(''-C'',$RepositoryRoot,''status'',''--porcelain=v1'',''--untracked-files=all'')'))
        $source | Should -Match ([regex]::Escape('$diffRun = Invoke-NxbV1Native -Executable $git -ArgumentList @(''-C'',$RepositoryRoot,''diff'',''--name-only'',''--diff-filter=ACMRTUXB'',(''{0}...{1}'' -f $certifiedHead,$releaseHead))'))
        $source | Should -Match ([regex]::Escape('certified_runtime_modified:{0}'))
        $source | Should -Match ([regex]::Escape('Test-NxbV1AllowedSuccessorPath'))
        $source | Should -Match ([regex]::Escape('$Path.Replace(''\'',''/'')'))
    }

    It 'constructs private-key markers without scanner self-match and scans the tracked tree' {
        $context = Get-NxbV1ReleaseTestContext
        $source = Get-Content -LiteralPath $context.script -Raw
        $source | Should -Match ([regex]::Escape('$privateKeyMarkerMap = @{'))
        $source | Should -Match ([regex]::Escape('pkcs8 = (''-----BEGIN '' + ''PRIVATE KEY-----'')'))
        $source | Should -Match ([regex]::Escape('$grepRun = Invoke-NxbV1Native -Executable $git -ArgumentList @(''-C'',$RepositoryRoot,''grep'',''-I'',''-l'',''-F'',''--'',$marker,''HEAD'')'))
        $source | Should -Match ([regex]::Escape('private_key_marker_id_unknown:{0}'))
        $source | Should -Match ([regex]::Escape('private_key_material:{0}'))
        $source | Should -Match ([regex]::Escape('private_key_scan_failed'))
        $pkcs8Marker = '-----BEGIN ' + 'PRIVATE KEY-----'
        $source | Should -Not -Match ([regex]::Escape($pkcs8Marker))
    }

    It 'preserves the certified candidate version instead of rewriting historical evidence' {
        $context = Get-NxbV1ReleaseTestContext
        $candidate = Get-Content -LiteralPath $context.candidate_policy -Raw | ConvertFrom-Json
        [string]$candidate.part10.release_version | Should -BeExactly '1.0.0-candidate'
        $source = Get-Content -LiteralPath $context.script -Raw
        $source | Should -Match ([regex]::Escape('certified_candidate_version_rewritten'))
        $source | Should -Match ([regex]::Escape('$candidateVersionPreserved = ([string]$candidatePolicy.part10.release_version -ceq ''1.0.0-candidate'')'))
    }

    It 'gives the independent validator ten requirements six controls and release ERR-036 regression coverage' {
        $context = Get-NxbV1ReleaseTestContext
        $pythonSource = Get-Content -LiteralPath $context.python -Raw
        $pythonSource | Should -Match ([regex]::Escape('requirement_count == 10'))
        $pythonSource | Should -Match ([regex]::Escape('negative_count == 6'))
        foreach ($token in @('tampered_certified_head','certified_runtime_change','generated_zip_artifact','certification_signer_reuse','private_key_material','version_drift')) {
            $pythonSource | Should -Match ([regex]::Escape($token))
        }
        $pythonSource | Should -Not -Match ([regex]::Escape('pow('))
        $pythonSource | Should -Not -Match ([regex]::Escape('signature_b64'))

        $signatureDocument = Get-Content -LiteralPath $context.release_signatures -Raw | ConvertFrom-Json
        @($signatureDocument.rules).Count | Should -Be 1
        [string]$signatureDocument.rules[0].id | Should -BeExactly 'NXB-ERR-036'
        $authoritySource = Get-Content -LiteralPath $context.authority -Raw
        [regex]::IsMatch($authoritySource,[string]$signatureDocument.rules[0].regex) | Should -BeFalse
        $authoritySource | Should -Match ([regex]::Escape('$entryName = [string]($entry.Key)'))
        $authoritySource | Should -Match ([regex]::Escape('$sourcePath = [string]($entry.Value)'))
        $authoritySource | Should -Match ([regex]::Escape('$destinationPath = Join-Path -Path $reviewRoot -ChildPath $entryName'))
        $history = Get-Content -LiteralPath $context.release_known_errors -Raw
        $history | Should -Match ([regex]::Escape('NXB-ERR-036'))
    }

    It 'documents that release preflight cannot merge tag push or create the production release' {
        $context = Get-NxbV1ReleaseTestContext
        $docs = Get-Content -LiteralPath $context.docs -Raw
        $docs | Should -Match ([regex]::Escape('This preflight does not merge, tag, push, create a GitHub Release, or mutate `main`.'))
        $docs | Should -Match ([regex]::Escape('The certification-only ephemeral RSA authorities are not production release signers.'))
        foreach ($sourcePath in @($context.script,$context.authority)) {
            $source = Get-Content -LiteralPath $sourcePath -Raw
            $source | Should -Not -Match ([regex]::Escape('@(''push'''))
            $source | Should -Not -Match ([regex]::Escape('@(''tag'''))
            $source | Should -Not -Match ([regex]::Escape('@(''update-ref'''))
        }
    }

    It 'locks the v1 release integration contract at exactly sixteen tests' {
        $testSource = Get-Content -LiteralPath $PSCommandPath -Raw
        [regex]::Matches($testSource,"(?m)^\s*It\s+'").Count | Should -Be 16
    }
}
