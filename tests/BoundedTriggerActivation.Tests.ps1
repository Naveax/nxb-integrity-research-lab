$ErrorActionPreference = 'Stop'

Describe 'NXB bounded trigger activation publication regression contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:CoordinatorScript = Join-Path $script:RepositoryRoot 'scripts\Invoke-NxbBoundedTriggerCapture.ps1'
        $script:NativeSmokeScript = Join-Path $script:RepositoryRoot 'scripts\Invoke-NxbBoundedTriggerNativeSmoke.ps1'
        $script:StateScript = Join-Path $script:RepositoryRoot 'scripts\Update-NxbBoundedTriggerCaptureState.ps1'
    }

    It 'preserves activation instances atomically publishes signals and fails closed on abnormal completion' {
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
