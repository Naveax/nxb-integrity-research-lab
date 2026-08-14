Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'NXB v1.0.1 successor bootstrap' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
        $script:PolicyPath = Join-Path $script:RepositoryRoot 'config\nxb-v1-successor-policy.json'
        $script:FinalPolicyPath = Join-Path $script:RepositoryRoot 'config\nxb-production-finalization-policy.json'
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'tools\validate_v1_successor.py'
        $script:PredecessorHead = 'a4f1b242c003333b1f34b1cd54ca37cab33fbf4f'
        $script:PredecessorTree = '34779176d9e15cd4d700d46132785c0b25f19604'
    }

    It 'binds the exact frozen v1.0.0 predecessor and v1.0.1 target' {
        $policy = Get-Content -LiteralPath $script:PolicyPath -Raw | ConvertFrom-Json
        [string]$policy.contract_id | Should -BeExactly 'nxb-v1-successor-v1'
        [string]$policy.phase | Should -BeExactly 'pre-version-transition'
        [string]$policy.predecessor.version | Should -BeExactly '1.0.0'
        [string]$policy.predecessor.head | Should -BeExactly $script:PredecessorHead
        [string]$policy.predecessor.tree | Should -BeExactly $script:PredecessorTree
        [string]$policy.predecessor.tag | Should -BeExactly 'v1.0.0'
        [string]$policy.successor.target_version | Should -BeExactly '1.0.1'
        [string]$policy.successor.candidate_version | Should -BeExactly '1.0.1-candidate'
        [string]$policy.successor.branch | Should -BeExactly 'release/nxb-v1.0.1-prep'
        [string]$policy.successor.release_class | Should -BeExactly 'patch'
    }

    It 'preserves the v1.0.0 Production Final candidate authority' {
        $finalPolicy = Get-Content -LiteralPath $script:FinalPolicyPath -Raw | ConvertFrom-Json
        [string]$finalPolicy.part10.release_version | Should -BeExactly '1.0.0-candidate'
    }

    It 'keeps release-facing target versions at v1.0.0 before the transition commit' {
        $policy = Get-Content -LiteralPath $script:PolicyPath -Raw | ConvertFrom-Json
        foreach ($relative in @($policy.pre_transition.target_version_policy_paths)) {
            $path = Join-Path $script:RepositoryRoot ([string]$relative).Replace('/',[IO.Path]::DirectorySeparatorChar)
            $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            [string]$document.target_version | Should -BeExactly '1.0.0'
        }
    }

    It 'keeps the successor branch ancestry rooted at the exact production predecessor' {
        $gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
        if ($null -eq $gitCommand) { $gitCommand = Get-Command git -ErrorAction Stop }
        $git = [string]$gitCommand.Source

        $tree = (& $git -C $script:RepositoryRoot rev-parse ($script:PredecessorHead + '^{tree}') 2>$null).Trim()
        $LASTEXITCODE | Should -Be 0
        $tree | Should -BeExactly $script:PredecessorTree

        & $git -C $script:RepositoryRoot merge-base --is-ancestor $script:PredecessorHead HEAD 2>$null
        $LASTEXITCODE | Should -Be 0
    }

    It 'passes the independent successor validator with all negative controls' {
        $pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
        if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
        $python = [string]$pythonCommand.Source

        $output = @(& $python $script:ValidatorPath --repository-root $script:RepositoryRoot 2>&1)
        $exitCode = $LASTEXITCODE
        $exitCode | Should -Be 0

        $jsonLine = [string]($output | Select-Object -Last 1)
        $result = $jsonLine | ConvertFrom-Json
        [string]$result.status | Should -BeExactly 'passed'
        [string]$result.authority | Should -BeExactly 'nxb-v1-successor-independent-v1'
        [int]$result.negative_controls_validated | Should -Be 6
        [int]$result.negative_control_count | Should -Be 6
        @($result.failures).Count | Should -Be 0
    }
}
