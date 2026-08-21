$ErrorActionPreference = 'Stop'

Describe 'NXB bounded pre-trigger and post-trigger capture contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:StateScript = Join-Path $script:RepositoryRoot 'scripts\Update-NxbBoundedTriggerCaptureState.ps1'
        $script:StartScript = Join-Path $script:RepositoryRoot 'scripts\Start-NxbBoundedMemoryTrace.ps1'
        $script:CoordinatorScript = Join-Path $script:RepositoryRoot 'scripts\Invoke-NxbBoundedTriggerCapture.ps1'
        $script:NativeSmokeScript = Join-Path $script:RepositoryRoot 'scripts\Invoke-NxbBoundedTriggerNativeSmoke.ps1'
        $script:PolicyPath = Join-Path $script:RepositoryRoot 'config\adaptive-observability-policy.default.json'
        $script:ExpectedHead = ('1' * 40)
        $script:PlanA = ('a' * 64)
        $script:PlanB = ('b' * 64)
        $script:T0 = [DateTime]::Parse('2026-08-21T12:00:00Z').ToUniversalTime()
        $script:Frequency = 1000L

        function Invoke-NxbBoundedTestStateSetup {
            param(
                [Parameter(Mandatory)][string]$Name,
                [Parameter()][int]$Pre = 15,
                [Parameter()][int]$Post = 60,
                [Parameter()][int]$MaxCoalesced = 32,
                [Parameter()][int]$MaxHistory = 64,
                [Parameter()][string]$SessionId = ([Guid]::NewGuid().ToString('D')),
                [Parameter()][string]$PolicyPath = $script:PolicyPath
            )
            $path = Join-Path $TestDrive ($Name + '.json')
            $state = & $script:StateScript `
                -PolicyPath $PolicyPath `
                -StatePath $path `
                -ExpectedHead $script:ExpectedHead `
                -SessionId $SessionId `
                -Action Arm `
                -RequestedPreTriggerSeconds $Pre `
                -RequestedPostTriggerSeconds $Post `
                -MaxCoalescedTriggers $MaxCoalesced `
                -MaxTriggerHistory $MaxHistory `
                -NowUtc $script:T0 `
                -MonotonicTicks 1000 `
                -MonotonicFrequency $script:Frequency `
                -PassThru
            return [pscustomobject]@{ Path = $path; State = $state; SessionId = $SessionId; PolicyPath = $PolicyPath }
        }

        function Invoke-NxbBoundedTestTrigger {
            param(
                [Parameter(Mandatory)][object]$Context,
                [Parameter()][string]$Id = 'frame-spike',
                [Parameter()][int]$Priority = 700,
                [Parameter()][string]$Plan = $script:PlanA,
                [Parameter()][string[]]$Domains = @('cpu'),
                [Parameter()][DateTime]$Now = $script:T0.AddSeconds(2),
                [Parameter()][long]$Ticks = 3000
            )
            return & $script:StateScript `
                -PolicyPath $Context.PolicyPath `
                -StatePath $Context.Path `
                -ExpectedHead $script:ExpectedHead `
                -SessionId $Context.SessionId `
                -Action Trigger `
                -TriggerId $Id `
                -TriggerReason ('test:' + $Id) `
                -TriggerPriority $Priority `
                -PlanFingerprintSha256 $Plan `
                -Domains $Domains `
                -NowUtc $Now `
                -MonotonicTicks $Ticks `
                -MonotonicFrequency $script:Frequency `
                -PassThru
        }
    }

    It 'keeps the new runtime surface parser-clean and explicitly bounded' {
        foreach ($path in @($script:StateScript,$script:StartScript,$script:CoordinatorScript,$script:NativeSmokeScript,$PSCommandPath)) {
            $tokens = $null
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
            @($errors).Count | Should -Be 0
        }
        $startSource = Get-Content -LiteralPath $script:StartScript -Raw
        $startSource | Should -Match ([regex]::Escape("logging_mode             = 'Memory'"))
        $startSource | Should -Match ([regex]::Escape('memory_buffer_budget_mib = $memoryBudgetMiB'))
        $startSource | Should -Match ([regex]::Escape('if ($memoryBudgetMiB -ne 64)'))
        $startSource | Should -Match ([regex]::Escape("overwrite_model          = 'bounded-memory-buffer-reuse'"))
        $startSource | Should -Not -Match '(?m)^\s*\$startOutput\s*=.*-filemode'
    }

    It 'clamps oversized requested windows to policy maxima' {
        $c = Invoke-NxbBoundedTestStateSetup -Name 'clamp' -Pre 999 -Post 9999
        [int]$c.State.requested_pretrigger_seconds | Should -Be 999
        [int]$c.State.requested_posttrigger_seconds | Should -Be 9999
        [int]$c.State.effective_pretrigger_seconds | Should -Be 15
        [int]$c.State.effective_posttrigger_seconds | Should -Be 60
        [bool]$c.State.window_clamped | Should -BeTrue
    }

    It 'supports a zero-length post-trigger window without becoming unbounded' {
        $c = Invoke-NxbBoundedTestStateSetup -Name 'zero' -Pre 0 -Post 0
        $state = Invoke-NxbBoundedTestTrigger -Context $c
        [string]$state.state | Should -BeExactly 'finalizing'
        [string]$state.termination_reason | Should -BeExactly 'zero_post_window'
        [double]$state.observed_pretrigger_seconds | Should -Be 0
    }

    It 'binds trigger reason timestamp session policy plan and domains' {
        $sessionId = [Guid]::NewGuid().ToString('D')
        $c = Invoke-NxbBoundedTestStateSetup -Name 'binding' -SessionId $sessionId
        $state = Invoke-NxbBoundedTestTrigger -Context $c -Domains @('cpu','kernel')
        [string]$state.session_id | Should -BeExactly $sessionId
        [string]$state.expected_head | Should -BeExactly $script:ExpectedHead
        [string]$state.primary_trigger.id | Should -BeExactly 'frame-spike'
        [string]$state.primary_trigger.reason | Should -BeExactly 'test:frame-spike'
        [string]$state.primary_trigger.plan_fingerprint_sha256 | Should -BeExactly $script:PlanA
        [string]$state.primary_plan_fingerprint_sha256 | Should -BeExactly $script:PlanA
        [string]$state.plan_fingerprint_sha256 | Should -BeExactly $script:PlanA
        @($state.active_domains) | Should -Contain 'cpu'
        @($state.active_domains) | Should -Contain 'kernel'
        [string]$state.policy_fingerprint_sha256 | Should -Match '^[0-9a-f]{64}$'
        [DateTime]::Parse([string]$state.trigger_utc).ToUniversalTime() | Should -Be $script:T0.AddSeconds(2)
    }

    It 'coalesces an overlapping trigger even when the adaptive plan fingerprint evolves' {
        $c = Invoke-NxbBoundedTestStateSetup -Name 'overlap' -Post 10
        [void](Invoke-NxbBoundedTestTrigger -Context $c -Priority 700 -Plan $script:PlanA -Domains @('cpu') -Now $script:T0.AddSeconds(1) -Ticks 2000)
        $state = Invoke-NxbBoundedTestTrigger `
            -Context $c `
            -Id 'security-state-change' `
            -Priority 950 `
            -Plan $script:PlanB `
            -Domains @('kernel','security') `
            -Now $script:T0.AddSeconds(4) `
            -Ticks 5000
        [int]$state.coalesced_trigger_count | Should -Be 1
        [string]$state.primary_plan_fingerprint_sha256 | Should -BeExactly $script:PlanA
        [string]$state.plan_fingerprint_sha256 | Should -BeExactly $script:PlanB
        [string]$state.selected_trigger.id | Should -BeExactly 'security-state-change'
        @($state.active_domains) | Should -Contain 'cpu'
        @($state.active_domains) | Should -Contain 'kernel'
        @($state.active_domains) | Should -Contain 'security'
        [DateTime]::Parse([string]$state.post_deadline_utc).ToUniversalTime() | Should -Be $script:T0.AddSeconds(14)
    }

    It 'bounds a trigger storm with coalescing and explicit rejection accounting' {
        $c = Invoke-NxbBoundedTestStateSetup -Name 'storm' -Post 10 -MaxCoalesced 1
        [void](Invoke-NxbBoundedTestTrigger -Context $c -Now $script:T0.AddSeconds(1) -Ticks 2000)
        [void](Invoke-NxbBoundedTestTrigger -Context $c -Id 'second' -Priority 1 -Plan $script:PlanB -Now $script:T0.AddSeconds(2) -Ticks 3000)
        $state = Invoke-NxbBoundedTestTrigger -Context $c -Id 'third' -Priority 2 -Plan $script:PlanB -Now $script:T0.AddSeconds(3) -Ticks 4000
        [int]$state.coalesced_trigger_count | Should -Be 1
        [int]$state.rejected_trigger_count | Should -Be 1
        [string]$state.trigger_history[-1].disposition | Should -BeExactly 'rejected_storm_limit'
    }

    It 'rejects backwards monotonic ordering' {
        $c = Invoke-NxbBoundedTestStateSetup -Name 'monotonic'
        [void](Invoke-NxbBoundedTestTrigger -Context $c -Ticks 3000)
        {
            & $script:StateScript `
                -PolicyPath $c.PolicyPath `
                -StatePath $c.Path `
                -ExpectedHead $script:ExpectedHead `
                -SessionId $c.SessionId `
                -Action Tick `
                -NowUtc $script:T0.AddSeconds(3) `
                -MonotonicTicks 2999 `
                -MonotonicFrequency $script:Frequency
        } | Should -Throw '*monotonic timestamp ordering violation*'
    }

    It 'rejects stale exact-head and session bindings' {
        $c = Invoke-NxbBoundedTestStateSetup -Name 'stale-session'
        {
            & $script:StateScript `
                -PolicyPath $c.PolicyPath `
                -StatePath $c.Path `
                -ExpectedHead ('2' * 40) `
                -SessionId $c.SessionId `
                -Action Tick `
                -NowUtc $script:T0.AddSeconds(1) `
                -MonotonicTicks 2000 `
                -MonotonicFrequency $script:Frequency
        } | Should -Throw '*exact-head binding is stale*'
        {
            & $script:StateScript `
                -PolicyPath $c.PolicyPath `
                -StatePath $c.Path `
                -ExpectedHead $script:ExpectedHead `
                -SessionId ([Guid]::NewGuid().ToString('D')) `
                -Action Tick `
                -NowUtc $script:T0.AddSeconds(1) `
                -MonotonicTicks 2000 `
                -MonotonicFrequency $script:Frequency
        } | Should -Throw '*session binding is stale*'
    }

    It 'rejects a policy mutation after the session is armed' {
        $policyCopy = Join-Path $TestDrive 'stale-policy.json'
        Copy-Item -LiteralPath $script:PolicyPath -Destination $policyCopy
        $c = Invoke-NxbBoundedTestStateSetup -Name 'stale-policy-state' -PolicyPath $policyCopy
        $policy = Get-Content -LiteralPath $policyCopy -Raw | ConvertFrom-Json
        $policy.budgets.posttrigger_seconds = 59
        [IO.File]::WriteAllText($policyCopy,(($policy | ConvertTo-Json -Depth 32) + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
        {
            & $script:StateScript `
                -PolicyPath $policyCopy `
                -StatePath $c.Path `
                -ExpectedHead $script:ExpectedHead `
                -SessionId $c.SessionId `
                -Action Tick `
                -NowUtc $script:T0.AddSeconds(1) `
                -MonotonicTicks 2000 `
                -MonotonicFrequency $script:Frequency
        } | Should -Throw '*policy fingerprint is stale*'
    }

    It 'terminates an untriggered session at the hard session deadline' {
        $c = Invoke-NxbBoundedTestStateSetup -Name 'timeout'
        $state = & $script:StateScript `
            -PolicyPath $c.PolicyPath `
            -StatePath $c.Path `
            -ExpectedHead $script:ExpectedHead `
            -SessionId $c.SessionId `
            -Action Tick `
            -NowUtc $script:T0.AddSeconds(1800) `
            -MonotonicTicks 1801000 `
            -MonotonicFrequency $script:Frequency `
            -PassThru
        [string]$state.state | Should -BeExactly 'finalizing'
        [bool]$state.truncation | Should -BeTrue
        [string]$state.budget_state | Should -BeExactly 'session_budget_exhausted'
        [string]$state.termination_reason | Should -BeExactly 'trigger_timeout'
    }

    It 'records emergency-stop termination during post-trigger capture' {
        $c = Invoke-NxbBoundedTestStateSetup -Name 'emergency'
        [void](Invoke-NxbBoundedTestTrigger -Context $c)
        $state = & $script:StateScript `
            -PolicyPath $c.PolicyPath `
            -StatePath $c.Path `
            -ExpectedHead $script:ExpectedHead `
            -SessionId $c.SessionId `
            -Action EmergencyStop `
            -NowUtc $script:T0.AddSeconds(5) `
            -MonotonicTicks 6000 `
            -MonotonicFrequency $script:Frequency `
            -PassThru
        [string]$state.state | Should -BeExactly 'finalizing'
        [bool]$state.truncation | Should -BeTrue
        [string]$state.termination_reason | Should -BeExactly 'emergency_stop'
        [double]$state.observed_posttrigger_seconds | Should -Be 3
    }

    It 'records budget-aware termination during post-trigger capture' {
        $c = Invoke-NxbBoundedTestStateSetup -Name 'budget'
        [void](Invoke-NxbBoundedTestTrigger -Context $c)
        $state = & $script:StateScript `
            -PolicyPath $c.PolicyPath `
            -StatePath $c.Path `
            -ExpectedHead $script:ExpectedHead `
            -SessionId $c.SessionId `
            -Action BudgetExhausted `
            -BudgetReason 'disk_pressure' `
            -NowUtc $script:T0.AddSeconds(4) `
            -MonotonicTicks 5000 `
            -MonotonicFrequency $script:Frequency `
            -PassThru
        [string]$state.state | Should -BeExactly 'finalizing'
        [string]$state.budget_state | Should -BeExactly 'disk_pressure'
        [string]$state.termination_reason | Should -BeExactly 'disk_pressure'
        [bool]$state.truncation | Should -BeTrue
    }

    It 'bounds trigger-history retention independently of storm counters' {
        $c = Invoke-NxbBoundedTestStateSetup -Name 'history' -Post 10 -MaxCoalesced 4 -MaxHistory 1
        [void](Invoke-NxbBoundedTestTrigger -Context $c -Now $script:T0.AddSeconds(1) -Ticks 2000)
        $state = Invoke-NxbBoundedTestTrigger -Context $c -Id 'second' -Plan $script:PlanB -Now $script:T0.AddSeconds(2) -Ticks 3000
        @($state.trigger_history).Count | Should -Be 1
        [int]$state.history_dropped_count | Should -Be 1
        [int]$state.coalesced_trigger_count | Should -Be 1
    }

    It 'binds completion evidence without permitting a completed state rewrite' {
        $c = Invoke-NxbBoundedTestStateSetup -Name 'complete' -Post 0
        [void](Invoke-NxbBoundedTestTrigger -Context $c)
        $state = & $script:StateScript `
            -PolicyPath $c.PolicyPath `
            -StatePath $c.Path `
            -ExpectedHead $script:ExpectedHead `
            -SessionId $c.SessionId `
            -Action Complete `
            -EvidenceSha256 ('c' * 64) `
            -NowUtc $script:T0.AddSeconds(3) `
            -MonotonicTicks 4000 `
            -MonotonicFrequency $script:Frequency `
            -PassThru
        [string]$state.state | Should -BeExactly 'completed'
        [string]$state.evidence_sha256 | Should -BeExactly ('c' * 64)
        {
            & $script:StateScript `
                -PolicyPath $c.PolicyPath `
                -StatePath $c.Path `
                -ExpectedHead $script:ExpectedHead `
                -SessionId $c.SessionId `
                -Action Fail `
                -FailureReason 'should-not-rewrite' `
                -NowUtc $script:T0.AddSeconds(4) `
                -MonotonicTicks 5000 `
                -MonotonicFrequency $script:Frequency
        } | Should -Throw '*cannot rewrite a completed*'
    }

    It 'makes disk pressure partial-domain and overwrite accounting explicit in the coordinator' {
        $source = Get-Content -LiteralPath $script:CoordinatorScript -Raw
        foreach ($token in @(
            'MinimumFreeDiskMiB',
            "BudgetReason = 'disk_pressure'",
            'domain_coverage = $coverageStatus',
            'not_captured_by_minimal_wpr_primitive',
            'estimated_overwritten_buffer_count',
            'max(0,buffers_written-configured_buffer_capacity)',
            'session_binding_valid',
            'primary_plan_fingerprint_sha256',
            'policy_fingerprint_sha256',
            'capture_mode_before_trigger',
            'capture_mode_after_trigger'
        )) {
            $source | Should -Match ([regex]::Escape($token))
        }
        $source | Should -Not -Match ([regex]::Escape('$uncapturedDomainCount -eq 0'))
    }
}
