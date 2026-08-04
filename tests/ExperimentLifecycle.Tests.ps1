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

    It 'writes evidence entries in canonical sorted order' {
        $experiment = & (Join-Path $script:ScriptsRoot 'New-Experiment.ps1') `
            -Root $script:TempRoot `
            -Name 'Canonical Order Test' `
            -Hypothesis 'Evidence ordering is deterministic'

        'z' | Set-Content -LiteralPath (Join-Path $experiment 'logs\z.txt') -Encoding UTF8
        'a' | Set-Content -LiteralPath (Join-Path $experiment 'baseline\a.txt') -Encoding UTF8
        & (Join-Path $script:ScriptsRoot 'Finalize-Experiment.ps1') `
            -ExperimentPath $experiment

        $paths = Get-Content -LiteralPath (Join-Path $experiment 'evidence.sha256') |
            ForEach-Object { ($_ -split '  ', 2)[1] }

        ($paths -join '|') | Should -Be (($paths | Sort-Object) -join '|')
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

    It 'rejects forbidden state transitions and unsafe relative paths' {
        Test-NxbStateTransition -From prepared -To stopped | Should -BeFalse
        Test-NxbStateTransition -From finalized -To recording | Should -BeFalse
        Test-NxbStateTransition -From recording -To stopped | Should -BeTrue

        {
            Get-NxbRelativePath `
                -BasePath $script:TempRoot `
                -ChildPath ([IO.Path]::GetTempPath())
        } | Should -Throw '*deney kökünün dışında*'
    }

    It 'marks an interrupted recording as failed through recovery' {
        $experiment = & (Join-Path $script:ScriptsRoot 'New-Experiment.ps1') `
            -Root $script:TempRoot `
            -Name 'Interrupted Recording' `
            -Hypothesis 'Interrupted recording fails closed'

        Set-NxbExperimentState `
            -ExperimentPath $experiment `
            -State recording `
            -Confirm:$false | Out-Null

        $result = & (Join-Path $script:ScriptsRoot 'Repair-Experiment.ps1') `
            -ExperimentPath $experiment `
            -MarkInterruptedRecordingFailed `
            -Confirm:$false

        $result.PreviousState | Should -Be 'recording'
        $result.CurrentState | Should -Be 'failed'

        $manifest = Get-Content -LiteralPath (Join-Path $experiment 'manifest.json') -Raw |
            ConvertFrom-Json
        $manifest.failure_reason | Should -Match 'interrupted'
    }

    It 'removes abandoned atomic temporary files only when requested' {
        $experiment = & (Join-Path $script:ScriptsRoot 'New-Experiment.ps1') `
            -Root $script:TempRoot `
            -Name 'Temporary Recovery' `
            -Hypothesis 'Temporary files are removed explicitly'

        $temporaryFile = Join-Path $experiment 'manifest.json.tmp.0123456789abcdef0123456789abcdef'
        '{}' | Set-Content -LiteralPath $temporaryFile -Encoding UTF8

        & (Join-Path $script:ScriptsRoot 'Repair-Experiment.ps1') `
            -ExperimentPath $experiment `
            -CleanTemporaryFiles `
            -Confirm:$false | Out-Null

        Test-Path -LiteralPath $temporaryFile | Should -BeFalse
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

    It 'passes the public repository content guard for tracked source files' {
        {
            & (Join-Path $script:ScriptsRoot 'Test-PublicRepositoryContent.ps1') `
                -RepositoryRoot $script:RepositoryRoot
        } | Should -Not -Throw
    }
}
