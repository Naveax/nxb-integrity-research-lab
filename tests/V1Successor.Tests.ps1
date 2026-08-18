Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'NXB v1.0.1 successor version transition' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
        $script:PolicyPath = Join-Path $script:RepositoryRoot 'config\nxb-v1-successor-policy.json'
        $script:ProductionReleasePolicyPath = Join-Path $script:RepositoryRoot 'config\nxb-v1-production-release-policy.json'
        $script:ProductionReleaseScriptPath = Join-Path $script:RepositoryRoot 'scripts\Invoke-NxbV1ProductionRelease.ps1'
        $script:ProductionReleaseDocPath = Join-Path $script:RepositoryRoot 'docs\NXB-V1-PRODUCTION-RELEASE.md'
        $script:FinalPolicyPath = Join-Path $script:RepositoryRoot 'config\nxb-production-finalization-policy.json'
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'tools\validate_v1_successor.py'
        $script:PackageSchemaPath = Join-Path $script:RepositoryRoot 'schemas\nxb-v1-package-manifest.schema.json'
        $script:UpdateDescriptorSchemaPath = Join-Path $script:RepositoryRoot 'schemas\nxb-v1-update-descriptor.schema.json'
        $script:PredecessorHead = 'a4f1b242c003333b1f34b1cd54ca37cab33fbf4f'
        $script:PredecessorTree = '34779176d9e15cd4d700d46132785c0b25f19604'
    }

    It 'binds the frozen v1.0.0 predecessor and enters v1.0.1 version-transition' {
        $p = Get-Content -LiteralPath $script:PolicyPath -Raw | ConvertFrom-Json
        [string]$p.contract_id | Should -BeExactly 'nxb-v1-successor-v1'
        [string]$p.phase | Should -BeExactly 'version-transition'
        [string]$p.predecessor.version | Should -BeExactly '1.0.0'
        [string]$p.predecessor.head | Should -BeExactly $script:PredecessorHead
        [string]$p.predecessor.tree | Should -BeExactly $script:PredecessorTree
        [string]$p.successor.target_version | Should -BeExactly '1.0.1'
        [string]$p.successor.candidate_version | Should -BeExactly '1.0.1-candidate'
        foreach ($name in @('cli','installer','update','production_signing','ci','release_integration')) {
            [string]$p.version_transition.components.$name.status | Should -BeExactly 'migrated'
        }
    }

    It 'preserves the v1.0.0 Production Final candidate authority' {
        $f = Get-Content -LiteralPath $script:FinalPolicyPath -Raw | ConvertFrom-Json
        [string]$f.part10.release_version | Should -BeExactly '1.0.0-candidate'
    }

    It 'migrates every release-facing component and binds the production release authority to v1.0.1' {
        $p = Get-Content -LiteralPath $script:PolicyPath -Raw | ConvertFrom-Json
        foreach ($name in @('cli','installer','update','production_signing','ci','release_integration')) {
            $row = $p.version_transition.components.$name
            $path = Join-Path $script:RepositoryRoot ([string]$row.policy_path).Replace('/',[IO.Path]::DirectorySeparatorChar)
            $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            [string]$doc.target_version | Should -BeExactly '1.0.1'
            [string]$row.status | Should -BeExactly 'migrated'
            [string]$row.expected_target_version | Should -BeExactly '1.0.1'
        }
        $releasePolicyPath = Join-Path $script:RepositoryRoot 'config\nxb-v1-release-integration-policy.json'
        $releasePolicy = Get-Content -LiteralPath $releasePolicyPath -Raw | ConvertFrom-Json
        [string]$releasePolicy.candidate_version | Should -BeExactly '1.0.1-candidate'
        [string]$releasePolicy.release_branch | Should -BeExactly 'release/nxb-v1.0.1-prep'
        foreach ($requiredPath in @($script:ProductionReleasePolicyPath,$script:ProductionReleaseScriptPath,$script:ProductionReleaseDocPath)) {
            Test-Path -LiteralPath $requiredPath -PathType Leaf | Should -BeTrue
        }
        $production = Get-Content -LiteralPath $script:ProductionReleasePolicyPath -Raw | ConvertFrom-Json
        [string]$production.contract_id | Should -BeExactly 'nxb-v1-production-release-v1'
        [string]$production.target_version | Should -BeExactly '1.0.1'
        [string]$production.tag | Should -BeExactly 'v1.0.1'
        [int]$production.release_sequence | Should -Be 2
        [string]$production.predecessor.head | Should -BeExactly $script:PredecessorHead
        [string]$production.predecessor.production_signer_fingerprint | Should -BeExactly '1d72e76225854e09af2552639436a508f050042e5e1c635bd7e11cc3feae4373'
        [bool]$production.safety.require_merge_tree_identity | Should -BeTrue
        [bool]$production.safety.allow_signer_rotation | Should -BeFalse
        [bool]$production.safety.allow_production_private_key_export | Should -BeFalse
        [bool]$production.safety.allow_auto_apply | Should -BeFalse
    }

    It 'keeps historical v1.0.0 package compatibility while admitting v1.0.1 package identity' {
        $schema = Get-Content -LiteralPath $script:PackageSchemaPath -Raw | ConvertFrom-Json
        @($schema.properties.release_version.enum).Count | Should -Be 2
        @($schema.properties.release_version.enum) | Should -Contain '1.0.0'
        @($schema.properties.release_version.enum) | Should -Contain '1.0.1'
        $updateSchema = Get-Content -LiteralPath $script:UpdateDescriptorSchemaPath -Raw | ConvertFrom-Json
        @($updateSchema.properties.release_version.enum).Count | Should -Be 2
        @($updateSchema.properties.release_version.enum) | Should -Contain '1.0.0'
        @($updateSchema.properties.release_version.enum) | Should -Contain '1.0.1'
    }

    It 'keeps successor ancestry rooted at the exact production predecessor' {
        $gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
        if ($null -eq $gitCommand) { $gitCommand = Get-Command git -ErrorAction Stop }
        $git = [string]$gitCommand.Source
        $tree = (& $git -C $script:RepositoryRoot rev-parse ($script:PredecessorHead + '^{tree}') 2>$null).Trim()
        $LASTEXITCODE | Should -Be 0
        $tree | Should -BeExactly $script:PredecessorTree
        & $git -C $script:RepositoryRoot merge-base --is-ancestor $script:PredecessorHead HEAD 2>$null
        $LASTEXITCODE | Should -Be 0
    }

    It 'passes the successor independent validator with production authority and six negative controls' {
        $pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
        if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
        $python = [string]$pythonCommand.Source
        $output = @(& $python $script:ValidatorPath --repository-root $script:RepositoryRoot 2>&1)
        $exitCode = $LASTEXITCODE
        $exitCode | Should -Be 0
        $result = ([string]($output | Select-Object -Last 1)) | ConvertFrom-Json
        [string]$result.status | Should -BeExactly 'passed'
        [string]$result.authority | Should -BeExactly 'nxb-v1-successor-independent-v11'
        [bool]$result.checks.package_release_versions | Should -BeTrue
        [bool]$result.checks.update_release_versions | Should -BeTrue
        [bool]$result.checks.production_release_policy | Should -BeTrue
        [bool]$result.checks.required_documents_present | Should -BeTrue
        [bool]$result.checks.transition_paths_allowed | Should -BeTrue
        [int]$result.negative_controls_validated | Should -Be 6
        [int]$result.negative_control_count | Should -Be 6
        @($result.failures).Count | Should -Be 0
    }
}
