BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsRoot = Join-Path $script:RepositoryRoot 'scripts'
    Import-Module (Join-Path $script:ScriptsRoot 'Nxb.EvidenceStore.psm1') -Force

    function New-NxbSyntheticEvidenceExperiment {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$Root,

            [Parameter(Mandatory)]
            [string]$Name
        )

        $experimentPath = Join-Path $Root $Name
        $baselinePath = Join-Path $experimentPath 'baseline'
        New-Item -ItemType Directory -Path $baselinePath -Force | Out-Null

        [ordered]@{
            experiment_id = 'experiment-1'
        } | ConvertTo-Json | Set-Content `
            -LiteralPath (Join-Path $experimentPath 'manifest.json') `
            -Encoding UTF8

        [ordered]@{
            machine_id = 'machine-1'
            boot_id = 'boot-1'
        } | ConvertTo-Json | Set-Content `
            -LiteralPath (Join-Path $baselinePath 'observation-identity.json') `
            -Encoding UTF8

        return $experimentPath
    }

    function Add-NxbSyntheticRecord {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ExperimentPath,

            [Parameter(Mandatory)]
            [string]$Value,

            [Parameter(Mandatory)]
            [int64]$MonotonicNs
        )

        return & (Join-Path $script:ScriptsRoot 'New-EvidenceStoreRecord.ps1') `
            -ExperimentPath $ExperimentPath `
            -RecordType manifest_snapshot `
            -Payload ([ordered]@{ value = $Value }) `
            -SessionId 'session-1' `
            -CapturedUtc ([DateTime]'2026-08-04T20:00:00Z') `
            -MonotonicNs $MonotonicNs
    }
}

Describe 'NXB append-only evidence chain' {
    BeforeEach {
        $script:TemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
            'nxb-evidence-chain-{0}' -f [guid]::NewGuid()
        )
        New-Item -ItemType Directory -Path $script:TemporaryRoot -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TemporaryRoot) {
            Remove-Item -LiteralPath $script:TemporaryRoot -Recurse -Force
        }
    }

    It 'creates deterministic linked records and a verified chain head' {
        $firstExperiment = New-NxbSyntheticEvidenceExperiment `
            -Root $script:TemporaryRoot `
            -Name 'first'
        $secondExperiment = New-NxbSyntheticEvidenceExperiment `
            -Root $script:TemporaryRoot `
            -Name 'second'

        $firstA = Add-NxbSyntheticRecord `
            -ExperimentPath $firstExperiment `
            -Value alpha `
            -MonotonicNs 100
        $secondA = Add-NxbSyntheticRecord `
            -ExperimentPath $firstExperiment `
            -Value beta `
            -MonotonicNs 200

        $firstB = Add-NxbSyntheticRecord `
            -ExperimentPath $secondExperiment `
            -Value alpha `
            -MonotonicNs 100
        $secondB = Add-NxbSyntheticRecord `
            -ExperimentPath $secondExperiment `
            -Value beta `
            -MonotonicNs 200

        $firstA.Sequence | Should -Be 0
        $secondA.Sequence | Should -Be 1
        $secondA.RecordCount | Should -Be 2
        $firstA.RecordSha256 | Should -Be $firstB.RecordSha256
        $secondA.RecordSha256 | Should -Be $secondB.RecordSha256
        $secondA.ChainSha256 | Should -Be $secondB.ChainSha256

        $secondRecord = Get-Content -LiteralPath $secondA.RecordPath -Raw |
            ConvertFrom-Json
        $secondRecord.previous_record_sha256 | Should -Be $firstA.RecordSha256

        $verified = & (Join-Path $script:ScriptsRoot 'Test-EvidenceStoreChain.ps1') `
            -ExperimentPath $firstExperiment `
            -PassThru
        $verified.IsValid | Should -BeTrue
        $verified.RecordCount | Should -Be 2
    }

    It 'detects a payload modification without a matching payload hash' {
        $experimentPath = New-NxbSyntheticEvidenceExperiment `
            -Root $script:TemporaryRoot `
            -Name 'payload-tamper'
        $recordResult = Add-NxbSyntheticRecord `
            -ExperimentPath $experimentPath `
            -Value alpha `
            -MonotonicNs 100

        $record = Get-Content -LiteralPath $recordResult.RecordPath -Raw |
            ConvertFrom-Json
        $record.payload.value = 'changed'
        Write-NxbCanonicalJsonAtomic `
            -Path $recordResult.RecordPath `
            -InputObject $record `
            -Confirm:$false

        {
            & (Join-Path $script:ScriptsRoot 'Test-EvidenceStoreChain.ps1') `
                -ExperimentPath $experimentPath
        } | Should -Throw '*Payload SHA-256 uyuşmazlığı*'
    }

    It 'detects record deletion through a sequence discontinuity' {
        $experimentPath = New-NxbSyntheticEvidenceExperiment `
            -Root $script:TemporaryRoot `
            -Name 'deletion'
        $first = Add-NxbSyntheticRecord `
            -ExperimentPath $experimentPath `
            -Value alpha `
            -MonotonicNs 100
        $second = Add-NxbSyntheticRecord `
            -ExperimentPath $experimentPath `
            -Value beta `
            -MonotonicNs 200

        Remove-Item -LiteralPath $first.RecordPath -Force

        {
            & (Join-Path $script:ScriptsRoot 'Test-EvidenceStoreChain.ps1') `
                -ExperimentPath $experimentPath
        } | Should -Throw '*sequence kesintisi*'

        Test-Path -LiteralPath $second.RecordPath | Should -BeTrue
    }

    It 'detects identity substitution even when the modified record hash is recomputed' {
        $experimentPath = New-NxbSyntheticEvidenceExperiment `
            -Root $script:TemporaryRoot `
            -Name 'identity-substitution'
        [void](Add-NxbSyntheticRecord `
            -ExperimentPath $experimentPath `
            -Value alpha `
            -MonotonicNs 100)
        $second = Add-NxbSyntheticRecord `
            -ExperimentPath $experimentPath `
            -Value beta `
            -MonotonicNs 200

        $record = Get-Content -LiteralPath $second.RecordPath -Raw |
            ConvertFrom-Json
        $record.machine_id = 'substituted-machine'
        $record.record_sha256 = Get-NxbCanonicalJsonHash `
            -InputObject $record `
            -ExcludeRootProperty 'record_sha256'
        Write-NxbCanonicalJsonAtomic `
            -Path $second.RecordPath `
            -InputObject $record `
            -Confirm:$false

        {
            & (Join-Path $script:ScriptsRoot 'Test-EvidenceStoreChain.ps1') `
                -ExperimentPath $experimentPath
        } | Should -Throw '*identity değişti: machine_id*'
    }
}
