BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsRoot = Join-Path $script:RepositoryRoot 'scripts'
    Import-Module (Join-Path $script:ScriptsRoot 'Nxb.Lab.Common.psm1') -Force
}

Describe 'NXB experiment lifecycle' {
    BeforeEach {
        $script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("nxb-pester-{0}" -f [guid]::NewGuid())
        & (Join-Path $script:ScriptsRoot 'Initialize-Lab.ps1') `
            -Root $script:TempRoot `
            -Role Target | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force
        }
    }

    It 'creates a prepared experiment with a unique identifier' {
        $experiment = & (Join-Path $script:ScriptsRoot 'New-Experiment.ps1') `
            -Root $script:TempRoot `
            -Name 'Lifecycle Test' `
            -Hypothesis 'The manifest is created atomically'

        $manifest = Get-Content -LiteralPath (Join-Path $experiment 'manifest.json') -Raw |
            ConvertFrom-Json

        $manifest.status | Should -Be 'prepared'
        $manifest.experiment_id | Should -Match '^\d{8}-\d{6}-Lifecycle-Test-[0-9a-f]{8}$'
    }

    It 'finalizes an evidence-only experiment and validates integrity' {
        $experiment = & (Join-Path $script:ScriptsRoot 'New-Experiment.ps1') `
            -Root $script:TempRoot `
            -Name 'Evidence Test' `
            -Hypothesis 'Evidence hashes remain stable'

        'synthetic evidence' |
            Set-Content -LiteralPath (Join-Path $experiment 'logs\evidence.txt') -Encoding UTF8

        & (Join-Path $script:ScriptsRoot 'Finalize-Experiment.ps1') `
            -ExperimentPath $experiment

        $result = & (Join-Path $script:ScriptsRoot 'Test-EvidenceIntegrity.ps1') `
            -ExperimentPath $experiment `
            -PassThru

        $result.IsValid | Should -BeTrue
        $result.CheckedEntries | Should -BeGreaterThan 0
    }

    It 'is idempotent when an already-finalized experiment is unchanged' {
        $experiment = & (Join-Path $script:ScriptsRoot 'New-Experiment.ps1') `
            -Root $script:TempRoot `
            -Name 'Idempotency Test' `
            -Hypothesis 'Second finalization changes no evidence state'

        'stable evidence' |
            Set-Content -LiteralPath (Join-Path $experiment 'logs\stable.txt') -Encoding UTF8

        & (Join-Path $script:ScriptsRoot 'Finalize-Experiment.ps1') `
            -ExperimentPath $experiment

        $manifestPath = Join-Path $experiment 'manifest.json'
        $evidencePath = Join-Path $experiment 'evidence.sha256'
        $manifestHashBefore = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        $evidenceHashBefore = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash

        & (Join-Path $script:ScriptsRoot 'Finalize-Experiment.ps1') `
            -ExperimentPath $experiment

        (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash |
            Should -Be $manifestHashBefore
        (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash |
            Should -Be $evidenceHashBefore
    }

    It 'detects a modified evidence file' {
        $experiment = & (Join-Path $script:ScriptsRoot 'New-Experiment.ps1') `
            -Root $script:TempRoot `
            -Name 'Tamper Test' `
            -Hypothesis 'A one-byte change invalidates evidence'

        $evidenceFile = Join-Path $experiment 'logs\tamper.txt'
        'before' | Set-Content -LiteralPath $evidenceFile -Encoding UTF8
        & (Join-Path $script:ScriptsRoot 'Finalize-Experiment.ps1') `
            -ExperimentPath $experiment

        'after' | Set-Content -LiteralPath $evidenceFile -Encoding UTF8

        {
            & (Join-Path $script:ScriptsRoot 'Test-EvidenceIntegrity.ps1') `
                -ExperimentPath $experiment
        } | Should -Throw '*Hash uyuşmazlığı*'
    }

    It 'rejects forbidden state transitions' {
        Test-NxbStateTransition -From prepared -To stopped | Should -BeFalse
        Test-NxbStateTransition -From finalized -To recording | Should -BeFalse
        Test-NxbStateTransition -From recording -To stopped | Should -BeTrue
    }

    It 'reports finalized experiment status' {
        $experiment = & (Join-Path $script:ScriptsRoot 'New-Experiment.ps1') `
            -Root $script:TempRoot `
            -Name 'Status Test' `
            -Hypothesis 'Status includes evidence validation'

        'status evidence' |
            Set-Content -LiteralPath (Join-Path $experiment 'notes\status.txt') -Encoding UTF8
        & (Join-Path $script:ScriptsRoot 'Finalize-Experiment.ps1') `
            -ExperimentPath $experiment

        $status = & (Join-Path $script:ScriptsRoot 'Get-ExperimentStatus.ps1') `
            -ExperimentPath $experiment

        $status.Status | Should -Be 'finalized'
        $status.EvidenceStatus | Should -Be 'valid'
    }
}
