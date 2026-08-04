BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsRoot = Join-Path $script:RepositoryRoot 'scripts'
}

Describe 'NXB observation identity' {
    BeforeEach {
        $script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("nxb-identity-{0}" -f [guid]::NewGuid())
        & (Join-Path $script:ScriptsRoot 'Initialize-Lab.ps1') `
            -Root $script:TempRoot `
            -Role Target | Out-Null

        $script:ExperimentPath = & (Join-Path $script:ScriptsRoot 'New-Experiment.ps1') `
            -Root $script:TempRoot `
            -Name 'Identity-Test' `
            -Hypothesis 'Every observation shares machine boot and monotonic clock identity'

        & (Join-Path $script:ScriptsRoot 'Get-SystemCapabilities.ps1') `
            -ExperimentPath $script:ExperimentPath | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force
        }
    }

    It 'creates a stable machine and boot identity document' {
        $path = & (Join-Path $script:ScriptsRoot 'Get-ObservationIdentity.ps1') `
            -ExperimentPath $script:ExperimentPath

        $identity = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $manifest = Get-Content -LiteralPath (Join-Path $script:ExperimentPath 'manifest.json') -Raw |
            ConvertFrom-Json

        $identity.experiment_id | Should -Be $manifest.experiment_id
        $identity.machine_id | Should -Not -BeNullOrEmpty
        $identity.boot_id | Should -Match '^[0-9a-f]{64}$'
        $identity.clock.stopwatch_frequency_hz | Should -BeGreaterThan 0
        $identity.clock.sample_ticks | Should -BeGreaterOrEqual 0
        $identity.clock.sample_monotonic_ns | Should -BeGreaterOrEqual 0
    }

    It 'passes the Draft 2020-12 identity schema' {
        & (Join-Path $script:ScriptsRoot 'Get-ObservationIdentity.ps1') `
            -ExperimentPath $script:ExperimentPath | Out-Null

        {
            & (Join-Path $script:ScriptsRoot 'Test-ObservationIdentity.ps1') `
                -ExperimentPath $script:ExperimentPath
        } | Should -Not -Throw
    }

    It 'keeps boot identity stable within one boot session' {
        $firstPath = & (Join-Path $script:ScriptsRoot 'Get-ObservationIdentity.ps1') `
            -ExperimentPath $script:ExperimentPath
        $first = Get-Content -LiteralPath $firstPath -Raw | ConvertFrom-Json

        Start-Sleep -Milliseconds 10

        $secondPath = & (Join-Path $script:ScriptsRoot 'Get-ObservationIdentity.ps1') `
            -ExperimentPath $script:ExperimentPath
        $second = Get-Content -LiteralPath $secondPath -Raw | ConvertFrom-Json

        $second.machine_id | Should -Be $first.machine_id
        $second.boot_id | Should -Be $first.boot_id
        $second.clock.sample_ticks | Should -BeGreaterThan $first.clock.sample_ticks
    }

    It 'anchors identity into finalized evidence' {
        & (Join-Path $script:ScriptsRoot 'Get-ObservationIdentity.ps1') `
            -ExperimentPath $script:ExperimentPath | Out-Null

        & (Join-Path $script:ScriptsRoot 'Finalize-Experiment.ps1') `
            -ExperimentPath $script:ExperimentPath

        $evidence = Get-Content -LiteralPath (Join-Path $script:ExperimentPath 'evidence.sha256') -Raw
        $evidence | Should -Match 'baseline[\\/]observation-identity\.json'
    }
}
