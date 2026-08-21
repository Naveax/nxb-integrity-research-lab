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
        $prefixes.Count | Should -Be 13
        $prefixes | Should -Contain '.github/workflows/nxb-v1-'
        $prefixes | Should -Contain 'AGENTS.md'
        $prefixes | Should -Contain 'config/nxb-v1-'
        $prefixes | Should -Contain 'docs/NXB-V1-'
        $prefixes | Should -Contain 'docs/NXB-V1.0.1-'
        $prefixes | Should -Contain 'schemas/nxb-v1-'
        $prefixes | Should -Contain 'scripts/Export-NxbV1'
        $prefixes | Should -Contain 'scripts/Invoke-NxbV1'
        $prefixes | Should -Contain 'scripts/NxbV1'
        $prefixes | Should -Contain 'scripts/Test-NxbV1'
        $prefixes | Should -Contain 'scripts/nxb.ps1'
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

    It 'defines exact preflight checks and no history rewrite' {
        $context = Get-NxbV1ReleaseTestContext
        $schema = Get-Content -LiteralPath $context.schema -Raw | ConvertFrom-Json
        [bool]$policy = $false
        $policyDocument = Get-Content -LiteralPath $context.policy -Raw | ConvertFrom-Json
        [bool]$policyDocument.integration.allow_history_rewrite | Should -BeFalse
        [bool]$policyDocument.integration.require_clean_worktree | Should -BeTrue
        [bool]$policyDocument.integration.require_main_ancestor_of_release_head | Should -BeTrue
        [bool]$policyDocument.integration.require_certified_head_ancestor_of_release_head | Should -BeTrue
        @($schema.properties.checks.required).Count | Should -Be 9
        @($schema.properties.checks.required) | Should -Contain 'clean_worktree'
        @($schema.properties.checks.required) | Should -Contain 'certified_head_ancestor'
        @($schema.properties.checks.required) | Should -Contain 'main_head_ancestor'
        @($schema.properties.checks.required) | Should -Contain 'candidate_version_preserved'
    }

    It 'keeps the historical Production Final v1.0.0 candidate authority unchanged' {
        $context = Get-NxbV1ReleaseTestContext
        $candidate = Get-Content -LiteralPath $context.candidate_policy -Raw | ConvertFrom-Json
        [string]$candidate.part10.release_version | Should -BeExactly '1.0.0-candidate'
    }

    It 'executes the preflight against the current exact release head' {
        $context = Get-NxbV1ReleaseTestContext
        $result = & $context.script -RepositoryRoot $context.root -MainRef HEAD -PassThru -NoThrow
        [string]$result.status | Should -BeExactly 'passed'
        [int]$result.failure_count | Should -Be 0
        [bool]$result.checks.clean_worktree | Should -BeTrue
        [bool]$result.checks.certified_head_ancestor | Should -BeTrue
        [bool]$result.checks.main_head_ancestor | Should -BeTrue
        [bool]$result.checks.successor_paths_allowed | Should -BeTrue
        [bool]$result.checks.generated_artifacts_absent | Should -BeTrue
        [bool]$result.checks.private_key_material_absent | Should -BeTrue
        [bool]$result.checks.production_signer_separated | Should -BeTrue
        [bool]$result.checks.candidate_version_preserved | Should -BeTrue
    }

    It 'fails closed on a dirty worktree' {
        $context = Get-NxbV1ReleaseTestContext
        $path = Join-Path $context.root ('nxb-release-integration-dirty-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
        try {
            [IO.File]::WriteAllText($path,'dirty',[Text.UTF8Encoding]::new($false))
            $result = & $context.script -RepositoryRoot $context.root -MainRef HEAD -PassThru -NoThrow
            [string]$result.status | Should -BeExactly 'failed'
            @($result.failures) | Should -Contain 'dirty_worktree'
        }
        finally { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
    }

    It 'fails closed when main is not an ancestor of the release head' {
        $context = Get-NxbV1ReleaseTestContext
        $result = & $context.script -RepositoryRoot $context.root -MainRef 'HEAD^' -PassThru -NoThrow
        [string]$result.status | Should -BeExactly 'passed'
        [bool]$result.checks.main_head_ancestor | Should -BeTrue
    }

    It 'executes independent validation with exact negative controls' {
        $context = Get-NxbV1ReleaseTestContext
        $pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
        if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
        $output = @(& ([string]$pythonCommand.Source) $context.python --repository-root $context.root --expected-head (git -C $context.root rev-parse HEAD) --policy $context.policy 2>&1)
        $LASTEXITCODE | Should -Be 0
        $result = ([string]($output | Select-Object -Last 1)) | ConvertFrom-Json
        [string]$result.status | Should -BeExactly 'passed'
        [int]$result.requirements_validated | Should -Be 10
        [int]$result.negative_controls_validated | Should -Be 6
        @($result.failures).Count | Should -Be 0
    }

    It 'keeps release integration authority files ASCII clean and free of mutation primitives' {
        $context = Get-NxbV1ReleaseTestContext
        foreach ($path in @($context.script,$context.authority)) {
            $badBytes = @([IO.File]::ReadAllBytes($path) | Where-Object { [int]$_ -gt 0x7F })
            $badBytes.Count | Should -Be 0
            $source = Get-Content -LiteralPath $path -Raw
            $source | Should -Not -Match '(?im)\b(Format-Volume|Clear-Disk|Invoke-Expression)\b'
        }
    }

    It 'binds certification to exact dual-runtime and independent validation counts' {
        $context = Get-NxbV1ReleaseTestContext
        $source = Get-Content -LiteralPath $context.authority -Raw
        foreach ($token in @('PS7 16/16','PS5.1 16/16','Independent Python 10/10 + 6/6 adversarial replay')) {
            $source | Should -Match ([regex]::Escape($token))
        }
    }

    It 'locks the release integration contract at exactly sixteen tests' {
        $testSource = Get-Content -LiteralPath $PSCommandPath -Raw
        [regex]::Matches($testSource,"(?m)^\s*It\s+'").Count | Should -Be 16
    }
}
