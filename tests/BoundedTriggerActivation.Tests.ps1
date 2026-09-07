$ErrorActionPreference = 'Stop'

Describe 'NXB bounded trigger activation publication regression contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:CoordinatorScript = Join-Path $script:RepositoryRoot 'scripts\Invoke-NxbBoundedTriggerCapture.ps1'
        $script:NativeSmokeScript = Join-Path $script:RepositoryRoot 'scripts\Invoke-NxbBoundedTriggerNativeSmoke.ps1'
        $script:StateScript = Join-Path $script:RepositoryRoot 'scripts\Update-NxbBoundedTriggerCaptureState.ps1'
        $script:PolicyPath = Join-Path $script:RepositoryRoot 'config\adaptive-observability-policy.default.json'
    }

    It 'preserves activation instances and atomically publishes the native trigger signal while failing closed on abnormal completion' {
        $coordinator = Get-Content -LiteralPath $script:CoordinatorScript -Raw
        $nativeSmoke = Get-Content -LiteralPath $script:NativeSmokeScript -Raw
        $stateSource = Get-Content -LiteralPath $script:StateScript -Raw

        $coordinator | Should -Match ([regex]::Escape('Get-NxbBoundedActivationKey'))
        $coordinator | Should -Match ([regex]::Escape('last_transition_utc'))
        $coordinator | Should -Match ([regex]::Escape('$targetActivationKey = Get-NxbBoundedActivationKey -TriggerState $targetState[0]'))
        $coordinator | Should -Match ([regex]::Escape('$seenActivation.Add($targetActivationKey)'))
        $coordinator | Should -Match ([regex]::Escape('$activationKey = Get-NxbBoundedActivationKey -TriggerState $triggerState'))
        $coordinator | Should -Match ([regex]::Escape('$seenActivation.Add($activationKey)'))
        $coordinator | Should -Not -Match ([regex]::Escape('$seenActivation.Add($TriggerId)'))
        $coordinator | Should -Not -Match ([regex]::Escape('$seenActivation.Add($id)'))
        $coordinator | Should -Not -Match 'elseif\s*\(\$primarySeen\s+-and'

        $coordinator | Should -Match ([regex]::Escape('$normalTermination -and'))
        $coordinator | Should -Match ([regex]::Escape('-not [bool]$finalState.truncation -and'))
        $coordinator | Should -Match ([regex]::Escape("[string]`$finalState.budget_state -ceq 'normal' -and"))
        $coordinator | Should -Match ([regex]::Escape("[string]`$diskBudgetState -ceq 'within_budget' -and"))
        $coordinator | Should -Not -Match ([regex]::Escape("@('within_budget','pressure_terminated')"))
        $stateSource | Should -Match ([regex]::Escape("[string]`$state.termination_reason -in @('post_window_complete','zero_post_window')"))
        $stateSource | Should -Match ([regex]::Escape('-not $normalTermination -or [bool]$state.truncation'))
        $stateSource | Should -Match ([regex]::Escape("[string]`$state.budget_state -cne 'normal'"))
        $stateSource | Should -Match ([regex]::Escape('Complete requires normal non-truncated finalization with normal budget'))

        $expectedHead = ('1' * 40)
        $sessionId = [Guid]::NewGuid().ToString('D')
        $statePath = Join-Path $TestDrive 'abnormal-complete.json'
        $frequency = 1000L
        $t0 = [DateTime]::Parse('2026-09-07T09:00:00Z').ToUniversalTime()

        [void](& $script:StateScript `
            -PolicyPath $script:PolicyPath `
            -StatePath $statePath `
            -ExpectedHead $expectedHead `
            -SessionId $sessionId `
            -Action Arm `
            -RequestedPreTriggerSeconds 3 `
            -RequestedPostTriggerSeconds 10 `
            -NowUtc $t0 `
            -MonotonicTicks 1000 `
            -MonotonicFrequency $frequency `
            -PassThru)

        [void](& $script:StateScript `
            -PolicyPath $script:PolicyPath `
            -StatePath $statePath `
            -ExpectedHead $expectedHead `
            -SessionId $sessionId `
            -Action Trigger `
            -TriggerId 'frame-spike' `
            -TriggerReason 'test:frame-spike' `
            -TriggerPriority 700 `
            -PlanFingerprintSha256 ('a' * 64) `
            -Domains @('cpu') `
            -NowUtc $t0.AddSeconds(2) `
            -MonotonicTicks 3000 `
            -MonotonicFrequency $frequency `
            -PassThru)

        $emergency = & $script:StateScript `
            -PolicyPath $script:PolicyPath `
            -StatePath $statePath `
            -ExpectedHead $expectedHead `
            -SessionId $sessionId `
            -Action EmergencyStop `
            -NowUtc $t0.AddSeconds(3) `
            -MonotonicTicks 4000 `
            -MonotonicFrequency $frequency `
            -PassThru
        [string]$emergency.state | Should -BeExactly 'finalizing'
        [string]$emergency.termination_reason | Should -BeExactly 'emergency_stop'
        [bool]$emergency.truncation | Should -BeTrue

        {
            & $script:StateScript `
                -PolicyPath $script:PolicyPath `
                -StatePath $statePath `
                -ExpectedHead $expectedHead `
                -SessionId $sessionId `
                -Action Complete `
                -EvidenceSha256 ('c' * 64) `
                -NowUtc $t0.AddSeconds(4) `
                -MonotonicTicks 5000 `
                -MonotonicFrequency $frequency
        } | Should -Throw '*Complete requires normal non-truncated finalization with normal budget*'

        $afterRejectedComplete = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        [string]$afterRejectedComplete.state | Should -BeExactly 'finalizing'
        [string]$afterRejectedComplete.termination_reason | Should -BeExactly 'emergency_stop'
        $null -eq $afterRejectedComplete.evidence_sha256 | Should -BeTrue

        $nativeSmoke | Should -Match ([regex]::Escape('$armedStatePath = Join-Path ([string]$experiment) ''analysis\bounded-trigger-capture-state.json'''))
        $nativeSmoke | Should -Match ([regex]::Escape('$armGateDelayMilliseconds = 1500'))
        $nativeSmoke | Should -Match ([regex]::Escape('$armGateTimeoutSeconds = 60'))
        $nativeSmoke | Should -Match ([regex]::Escape("[string]`$armState.state -ceq 'armed'"))
        $nativeSmoke | Should -Match ([regex]::Escape('[string]$armState.expected_head -ceq $using:expected'))
        $nativeSmoke | Should -Match ([regex]::Escape('Start-Sleep -Milliseconds $using:armGateDelayMilliseconds'))
        $nativeSmoke | Should -Not -Match ([regex]::Escape('Start-Sleep -Milliseconds 1500'))
        $nativeSmoke | Should -Match ([regex]::Escape('$using:signalsPath + ''.'' + [Guid]::NewGuid().ToString(''N'') + ''.tmp'''))
        $nativeSmoke | Should -Match ([regex]::Escape('[IO.File]::Move($tempPath,$using:signalsPath,$true)'))
        $nativeSmoke | Should -Match ([regex]::Escape('Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue'))
        $nativeSmoke | Should -Match ([regex]::Escape('observed_pretrigger_seconds -lt 1.0'))
        $nativeSmoke | Should -Match ([regex]::Escape('arm_gate_observed = $true'))
        $nativeSmoke | Should -Match ([regex]::Escape("arm_gate_state = 'armed'"))
        $nativeSmoke | Should -Match ([regex]::Escape('minimum_observed_pretrigger_seconds = 1.0'))
    }
}
