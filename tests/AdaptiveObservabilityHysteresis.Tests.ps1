$ErrorActionPreference = 'Stop'

Describe 'NXB IRL-005 adaptive observability hysteresis contract' {
    BeforeAll {
        function Get-NxbAdaptiveHysteresisRoot {
            $root = [string]$env:NXB_ADAPTIVE_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_ADAPTIVE_REPOSITORY_ROOT is required.' }
            return [IO.Path]::GetFullPath($root)
        }

        function Write-NxbHysteresisSignalDocument {
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][hashtable]$Signals
            )
            [IO.File]::WriteAllText(
                $Path,
                (($Signals | ConvertTo-Json -Depth 10) + [Environment]::NewLine),
                [Text.UTF8Encoding]::new($false)
            )
        }

        function Get-NxbFrameState {
            param([Parameter(Mandatory)][object]$State)
            $items = @($State.triggers | Where-Object { [string]$_.id -ceq 'frame-spike' })
            if ($items.Count -ne 1) { throw 'frame-spike state missing.' }
            return $items[0]
        }
    }

    It 'keeps hysteresis state repo-owned and connects it to resolver and panel' {
        $root = Get-NxbAdaptiveHysteresisRoot
        $stateScript = Join-Path $root 'scripts\Update-NxbAdaptiveObservabilityState.ps1'
        $testPath = Join-Path $root 'tests\AdaptiveObservabilityHysteresis.Tests.ps1'
        Test-Path -LiteralPath $stateScript -PathType Leaf | Should -BeTrue
        $resolver = Get-Content -LiteralPath (Join-Path $root 'scripts\Resolve-NxbAdaptiveObservabilityPlan.ps1') -Raw
        $panel = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-NxbAdaptiveObservabilityPanel.ps1') -Raw
        $stateSource = Get-Content -LiteralPath $stateScript -Raw
        $tokens = $null
        $parseErrors = $null
        $testAst = [Management.Automation.Language.Parser]::ParseFile($testPath,[ref]$tokens,[ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $functionNames = @(
            $testAst.FindAll(
                { param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] },
                $true
            ) | ForEach-Object { [string]$_.Name }
        )
        $resolver | Should -Match ([regex]::Escape('[string]$TriggerStatePath'))
        $panel | Should -Match ([regex]::Escape('$stateUpdaterPath'))
        $panel | Should -Match ([regex]::Escape('-TriggerStatePath $triggerStatePath'))
        $functionNames | Should -Not -Contain 'Write-NxbHysteresisSignals'
        $functionNames | Should -Contain 'Write-NxbHysteresisSignalDocument'
        $stateSource | Should -Match ([regex]::Escape('if ($Value -is [DateTimeOffset])'))
        $stateSource | Should -Match ([regex]::Escape('if ($Value -is [DateTime])'))
        $stateSource | Should -Match ([regex]::Escape('return ([DateTime]$Value).ToUniversalTime()'))
        $stateSource | Should -Match ([regex]::Escape('Adaptive trigger state is unreadable: {0}'))
        $stateSource | Should -Match ([regex]::Escape('-f $stateFull'))
        $stateSource | Should -Not -Match ([regex]::Escape('starting from empty state'))
    }

    It 'activates a matching trigger and establishes its hold window' {
        $root = Get-NxbAdaptiveHysteresisRoot
        $policy = Join-Path $root 'config\adaptive-observability-policy.default.json'
        $updater = Join-Path $root 'scripts\Update-NxbAdaptiveObservabilityState.ps1'
        $signals = Join-Path $TestDrive 'activate-signals.json'
        $statePath = Join-Path $TestDrive 'activate-state.json'
        Write-NxbHysteresisSignalDocument -Path $signals -Signals @{ frame_time_ms = 40 }
        $t0 = [DateTime]::Parse('2026-08-10T12:00:00Z').ToUniversalTime()
        $state = & $updater -PolicyPath $policy -SignalsPath $signals -StatePath $statePath -NowUtc $t0 -PassThru
        $frame = Get-NxbFrameState -State $state
        [bool]$frame.active | Should -BeTrue
        [string]$frame.transition | Should -BeExactly 'activated'
        [DateTime]::Parse([string]$frame.hold_until_utc).ToUniversalTime() | Should -Be $t0.AddSeconds(10)
    }

    It 'keeps a trigger active when its signal disappears before hold expiry' {
        $root = Get-NxbAdaptiveHysteresisRoot
        $policy = Join-Path $root 'config\adaptive-observability-policy.default.json'
        $updater = Join-Path $root 'scripts\Update-NxbAdaptiveObservabilityState.ps1'
        $signals = Join-Path $TestDrive 'hold-signals.json'
        $statePath = Join-Path $TestDrive 'hold-state.json'
        $t0 = [DateTime]::Parse('2026-08-10T12:00:00Z').ToUniversalTime()
        Write-NxbHysteresisSignalDocument -Path $signals -Signals @{ frame_time_ms = 40 }
        [void](& $updater -PolicyPath $policy -SignalsPath $signals -StatePath $statePath -NowUtc $t0 -PassThru)
        Write-NxbHysteresisSignalDocument -Path $signals -Signals @{}
        $state = & $updater -PolicyPath $policy -SignalsPath $signals -StatePath $statePath -NowUtc $t0.AddSeconds(5) -PassThru
        $frame = Get-NxbFrameState -State $state
        [bool]$frame.active | Should -BeTrue
        [bool]$frame.matched_now | Should -BeFalse
        [string]$frame.transition | Should -BeExactly 'none'
    }

    It 'deactivates after hold expiry and starts cooldown' {
        $root = Get-NxbAdaptiveHysteresisRoot
        $policy = Join-Path $root 'config\adaptive-observability-policy.default.json'
        $updater = Join-Path $root 'scripts\Update-NxbAdaptiveObservabilityState.ps1'
        $signals = Join-Path $TestDrive 'deactivate-signals.json'
        $statePath = Join-Path $TestDrive 'deactivate-state.json'
        $t0 = [DateTime]::Parse('2026-08-10T12:00:00Z').ToUniversalTime()
        Write-NxbHysteresisSignalDocument -Path $signals -Signals @{ frame_time_ms = 40 }
        [void](& $updater -PolicyPath $policy -SignalsPath $signals -StatePath $statePath -NowUtc $t0 -PassThru)
        Write-NxbHysteresisSignalDocument -Path $signals -Signals @{}
        $state = & $updater -PolicyPath $policy -SignalsPath $signals -StatePath $statePath -NowUtc $t0.AddSeconds(11) -PassThru
        $frame = Get-NxbFrameState -State $state
        [bool]$frame.active | Should -BeFalse
        [string]$frame.transition | Should -BeExactly 'deactivated'
        [DateTime]::Parse([string]$frame.cooldown_until_utc).ToUniversalTime() | Should -Be $t0.AddSeconds(41)
    }

    It 'blocks reactivation while cooldown remains active' {
        $root = Get-NxbAdaptiveHysteresisRoot
        $policy = Join-Path $root 'config\adaptive-observability-policy.default.json'
        $updater = Join-Path $root 'scripts\Update-NxbAdaptiveObservabilityState.ps1'
        $signals = Join-Path $TestDrive 'cooldown-signals.json'
        $statePath = Join-Path $TestDrive 'cooldown-state.json'
        $t0 = [DateTime]::Parse('2026-08-10T12:00:00Z').ToUniversalTime()
        Write-NxbHysteresisSignalDocument -Path $signals -Signals @{ frame_time_ms = 40 }
        [void](& $updater -PolicyPath $policy -SignalsPath $signals -StatePath $statePath -NowUtc $t0 -PassThru)
        Write-NxbHysteresisSignalDocument -Path $signals -Signals @{}
        [void](& $updater -PolicyPath $policy -SignalsPath $signals -StatePath $statePath -NowUtc $t0.AddSeconds(11) -PassThru)
        Write-NxbHysteresisSignalDocument -Path $signals -Signals @{ frame_time_ms = 40 }
        $state = & $updater -PolicyPath $policy -SignalsPath $signals -StatePath $statePath -NowUtc $t0.AddSeconds(20) -PassThru
        $frame = Get-NxbFrameState -State $state
        [bool]$frame.matched_now | Should -BeTrue
        [bool]$frame.active | Should -BeFalse
        [string]$frame.transition | Should -BeExactly 'none'
    }

    It 'permits reactivation after cooldown expires' {
        $root = Get-NxbAdaptiveHysteresisRoot
        $policy = Join-Path $root 'config\adaptive-observability-policy.default.json'
        $updater = Join-Path $root 'scripts\Update-NxbAdaptiveObservabilityState.ps1'
        $signals = Join-Path $TestDrive 'reactivate-signals.json'
        $statePath = Join-Path $TestDrive 'reactivate-state.json'
        $t0 = [DateTime]::Parse('2026-08-10T12:00:00Z').ToUniversalTime()
        Write-NxbHysteresisSignalDocument -Path $signals -Signals @{ frame_time_ms = 40 }
        [void](& $updater -PolicyPath $policy -SignalsPath $signals -StatePath $statePath -NowUtc $t0 -PassThru)
        Write-NxbHysteresisSignalDocument -Path $signals -Signals @{}
        [void](& $updater -PolicyPath $policy -SignalsPath $signals -StatePath $statePath -NowUtc $t0.AddSeconds(11) -PassThru)
        Write-NxbHysteresisSignalDocument -Path $signals -Signals @{ frame_time_ms = 40 }
        $state = & $updater -PolicyPath $policy -SignalsPath $signals -StatePath $statePath -NowUtc $t0.AddSeconds(42) -PassThru
        $frame = Get-NxbFrameState -State $state
        [bool]$frame.active | Should -BeTrue
        [string]$frame.transition | Should -BeExactly 'activated'
    }

    It 'lets trigger state preserve deep mode after the raw signal falls' {
        $root = Get-NxbAdaptiveHysteresisRoot
        $policy = Join-Path $root 'config\adaptive-observability-policy.default.json'
        $updater = Join-Path $root 'scripts\Update-NxbAdaptiveObservabilityState.ps1'
        $resolver = Join-Path $root 'scripts\Resolve-NxbAdaptiveObservabilityPlan.ps1'
        $signals = Join-Path $TestDrive 'resolver-signals.json'
        $statePath = Join-Path $TestDrive 'resolver-state.json'
        $t0 = [DateTime]::Parse('2026-08-10T12:00:00Z').ToUniversalTime()
        Write-NxbHysteresisSignalDocument -Path $signals -Signals @{ frame_time_ms = 40 }
        [void](& $updater -PolicyPath $policy -SignalsPath $signals -StatePath $statePath -NowUtc $t0 -PassThru)
        Write-NxbHysteresisSignalDocument -Path $signals -Signals @{}
        [void](& $updater -PolicyPath $policy -SignalsPath $signals -StatePath $statePath -NowUtc $t0.AddSeconds(5) -PassThru)
        $plan = & $resolver -PolicyPath $policy -SignalsPath $signals -TriggerStatePath $statePath -PassThru
        [string]$plan.effective_mode | Should -BeExactly 'deep'
        @($plan.active_trigger_ids) | Should -Contain 'frame-spike'
        @($plan.reasons) | Should -Contain 'trigger_state:authoritative'
    }

    It 'prevents stateless signal evaluation from bypassing state cooldown' {
        $root = Get-NxbAdaptiveHysteresisRoot
        $policy = Join-Path $root 'config\adaptive-observability-policy.default.json'
        $updater = Join-Path $root 'scripts\Update-NxbAdaptiveObservabilityState.ps1'
        $resolver = Join-Path $root 'scripts\Resolve-NxbAdaptiveObservabilityPlan.ps1'
        $signals = Join-Path $TestDrive 'authority-signals.json'
        $statePath = Join-Path $TestDrive 'authority-state.json'
        $t0 = [DateTime]::Parse('2026-08-10T12:00:00Z').ToUniversalTime()
        Write-NxbHysteresisSignalDocument -Path $signals -Signals @{ frame_time_ms = 40 }
        [void](& $updater -PolicyPath $policy -SignalsPath $signals -StatePath $statePath -NowUtc $t0 -PassThru)
        Write-NxbHysteresisSignalDocument -Path $signals -Signals @{}
        [void](& $updater -PolicyPath $policy -SignalsPath $signals -StatePath $statePath -NowUtc $t0.AddSeconds(11) -PassThru)
        Write-NxbHysteresisSignalDocument -Path $signals -Signals @{ frame_time_ms = 40 }
        [void](& $updater -PolicyPath $policy -SignalsPath $signals -StatePath $statePath -NowUtc $t0.AddSeconds(20) -PassThru)
        $plan = & $resolver -PolicyPath $policy -SignalsPath $signals -TriggerStatePath $statePath -PassThru
        [string]$plan.effective_mode | Should -BeExactly 'minimal'
        @($plan.active_trigger_ids).Count | Should -Be 0
        @($plan.reasons) | Should -Contain 'trigger_state:authoritative'
    }
}
