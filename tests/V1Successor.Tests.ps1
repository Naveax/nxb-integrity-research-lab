Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'NXB v1.0.1 successor version transition' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
        $script:PolicyPath = Join-Path $script:RepositoryRoot 'config\nxb-v1-successor-policy.json'
        $script:FinalPolicyPath = Join-Path $script:RepositoryRoot 'config\nxb-production-finalization-policy.json'
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'tools\validate_v1_successor.py'
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
        [string]$p.version_transition.components.cli.status | Should -BeExactly 'migrated'
    }

    It 'preserves the v1.0.0 Production Final candidate authority' {
        $f = Get-Content -LiteralPath $script:FinalPolicyPath -Raw | ConvertFrom-Json
        [string]$f.part10.release_version | Should -BeExactly '1.0.0-candidate'
    }

    It 'migrates only the CLI target version in the first component transition' {
        $p = Get-Content -LiteralPath $script:PolicyPath -Raw | ConvertFrom-Json
        foreach ($name in @('cli','installer','update','production_signing','ci','release_integration')) {
            $row = $p.version_transition.components.$name
            $path = Join-Path $script:RepositoryRoot ([string]$row.policy_path).Replace('/',[IO.Path]::DirectorySeparatorChar)
            $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            [string]$doc.target_version | Should -BeExactly ([string]$row.expected_target_version)
        }
        [string]$p.version_transition.components.cli.expected_target_version | Should -BeExactly '1.0.1'
        foreach ($name in @('installer','update','production_signing','ci','release_integration')) {
            $row = $p.version_transition.components.$name
            [string]$row.status | Should -BeExactly 'pending'
            [string]$row.expected_target_version | Should -BeExactly '1.0.0'
        }
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

    It 'passes the successor independent validator with six negative controls' {
        $pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
        if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
        $python = [string]$pythonCommand.Source
        $output = @(& $python $script:ValidatorPath --repository-root $script:RepositoryRoot 2>&1)
        $exitCode = $LASTEXITCODE
        $exitCode | Should -Be 0
        $result = ([string]($output | Select-Object -Last 1)) | ConvertFrom-Json
        [string]$result.status | Should -BeExactly 'passed'
        [string]$result.authority | Should -BeExactly 'nxb-v1-successor-independent-v2'
        [int]$result.negative_controls_validated | Should -Be 6
        [int]$result.negative_control_count | Should -Be 6
        @($result.failures).Count | Should -Be 0
    }
}
