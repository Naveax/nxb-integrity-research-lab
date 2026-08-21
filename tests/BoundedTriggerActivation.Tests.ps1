$ErrorActionPreference = 'Stop'

Describe 'NXB bounded trigger activation publication regression contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:CoordinatorScript = Join-Path $script:RepositoryRoot 'scripts\Invoke-NxbBoundedTriggerCapture.ps1'
        $script:NativeSmokeScript = Join-Path $script:RepositoryRoot 'scripts\Invoke-NxbBoundedTriggerNativeSmoke.ps1'
    }

    It 'preserves activation instances and atomically publishes the native trigger signal' {
        $coordinator = Get-Content -LiteralPath $script:CoordinatorScript -Raw
        $nativeSmoke = Get-Content -LiteralPath $script:NativeSmokeScript -Raw

        $coordinator | Should -Match ([regex]::Escape('Get-NxbBoundedActivationKey'))
        $coordinator | Should -Match ([regex]::Escape('last_transition_utc'))
        $coordinator | Should -Match ([regex]::Escape('$targetActivationKey = Get-NxbBoundedActivationKey -TriggerState $targetState[0]'))
        $coordinator | Should -Match ([regex]::Escape('$seenActivation.Add($targetActivationKey)'))
        $coordinator | Should -Match ([regex]::Escape('$activationKey = Get-NxbBoundedActivationKey -TriggerState $triggerState'))
        $coordinator | Should -Match ([regex]::Escape('$seenActivation.Add($activationKey)'))
        $coordinator | Should -Not -Match ([regex]::Escape('$seenActivation.Add($TriggerId)'))
        $coordinator | Should -Not -Match ([regex]::Escape('$seenActivation.Add($id)'))
        $coordinator | Should -Not -Match 'elseif\s*\(\$primarySeen\s+-and'

        $nativeSmoke | Should -Match ([regex]::Escape('$using:signalsPath + ''.'' + [Guid]::NewGuid().ToString(''N'') + ''.tmp'''))
        $nativeSmoke | Should -Match ([regex]::Escape('[IO.File]::Move($tempPath,$using:signalsPath,$true)'))
        $nativeSmoke | Should -Match ([regex]::Escape('Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue'))
    }
}
