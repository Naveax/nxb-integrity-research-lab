BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsRoot = Join-Path $script:RepositoryRoot 'scripts'
    Import-Module (Join-Path $script:ScriptsRoot 'Nxb.EvidenceStore.psm1') -Force

    function Initialize-NxbSyntheticEvidenceExperiment {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$Root,

            [Parameter(Mandatory)]
            [string]$Name,

            [Parameter()]
            [string]$ExperimentId = 'experiment-1',

            [Parameter()]
            [string]$MachineId = 'machine-1',

            [Parameter()]
            [string]$BootId = 'boot-1'
        )

        $experimentPath = Join-Path $Root $Name
        $baselinePath = Join-Path $experimentPath 'baseline'
        New-Item -ItemType Directory -Path $baselinePath -Force | Out-Null

        [ordered]@{
            experiment_id = $ExperimentId
        } | ConvertTo-Json | Set-Content `
            -LiteralPath (Join-Path $experimentPath 'manifest.json') `
            -Encoding UTF8

        [ordered]@{
            machine_id = $MachineId
            boot_id = $BootId
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
            [int64]$MonotonicNs,

            [Parameter()]
            [string]$SessionId = 'session-1'
        )

        return & (Join-Path $script:ScriptsRoot 'New-EvidenceStoreRecord.ps1') `
            -ExperimentPath $ExperimentPath `
            -RecordType manifest_snapshot `
            -Payload ([ordered]@{ value = $Value }) `
            -SessionId $SessionId `
            -CapturedUtc ([DateTime]'2026-08-04T20:00:00Z') `
            -MonotonicNs $MonotonicNs
    }

    function Invoke-NxbRecordIdentityMutation {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$RecordPath,

            [Parameter(Mandatory)]
            [ValidateSet('experiment_id', 'machine_id', 'boot_id', 'session_id')]
            [string]$Field,

            [Parameter(Mandatory)]
            [string]$Value
        )

        $record = Get-Content -LiteralPath $RecordPath -Raw |
            ConvertFrom-Json
        $record.$Field = $Value
        $record.record_sha256 = Get-NxbCanonicalJsonHash `
            -InputObject $record `
            -ExcludeRootProperty 'record_sha256'
        Write-NxbCanonicalJsonAtomic `
            -Path $RecordPath `
            -InputObject $record `
            -Confirm:$false
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
        $firstExperiment = Initialize-NxbSyntheticEvidenceExperiment `
            -Root $script:TemporaryRoot `
            -Name 'first'
        $secondExperiment = Initialize-NxbSyntheticEvidenceExperiment `
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

    It 'detects an exact one-byte record modification' {
        $experimentPath = Initialize-NxbSyntheticEvidenceExperiment `
            -Root $script:TemporaryRoot `
            -Name 'one-byte-tamper'
        $recordResult = Add-NxbSyntheticRecord `
            -ExperimentPath $experimentPath `
            -Value alpha `
            -MonotonicNs 100

        $encoding = [Text.UTF8Encoding]::new($false)
        $originalBytes = [IO.File]::ReadAllBytes($recordResult.RecordPath)
        $originalText = $encoding.GetString($originalBytes)
        $tamperedText = $originalText.Replace('"alpha"', '"alpga"')
        $tamperedBytes = $encoding.GetBytes($tamperedText)

        $tamperedBytes.Length | Should -Be $originalBytes.Length
        $differenceCount = 0
        for ($index = 0; $index -lt $originalBytes.Length; $index++) {
            if ($originalBytes[$index] -ne $tamperedBytes[$index]) {
                $differenceCount++
            }
        }
        $differenceCount | Should -Be 1
        [IO.File]::WriteAllBytes($recordResult.RecordPath, $tamperedBytes)

        {
            & (Join-Path $script:ScriptsRoot 'Test-EvidenceStoreChain.ps1') `
                -ExperimentPath $experimentPath
        } | Should -Throw '*Payload SHA-256 uyuşmazlığı*'
    }

    It 'detects record deletion through a sequence discontinuity' {
        $experimentPath = Initialize-NxbSyntheticEvidenceExperiment `
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

    It 'detects record reordering by filename and embedded sequence' {
        $experimentPath = Initialize-NxbSyntheticEvidenceExperiment `
            -Root $script:TemporaryRoot `
            -Name 'reordering'
        $first = Add-NxbSyntheticRecord `
            -ExperimentPath $experimentPath `
            -Value alpha `
            -MonotonicNs 100
        $second = Add-NxbSyntheticRecord `
            -ExperimentPath $experimentPath `
            -Value beta `
            -MonotonicNs 200

        $firstBytes = [IO.File]::ReadAllBytes($first.RecordPath)
        $secondBytes = [IO.File]::ReadAllBytes($second.RecordPath)
        [IO.File]::WriteAllBytes($first.RecordPath, $secondBytes)
        [IO.File]::WriteAllBytes($second.RecordPath, $firstBytes)

        {
            & (Join-Path $script:ScriptsRoot 'Test-EvidenceStoreChain.ps1') `
                -ExperimentPath $experimentPath
        } | Should -Throw '*Record içi sequence dosya adıyla uyuşmuyor*'
    }

    It 'detects a previous-record link mismatch after record rehashing' {
        $experimentPath = Initialize-NxbSyntheticEvidenceExperiment `
            -Root $script:TemporaryRoot `
            -Name 'previous-link'
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
        $record.previous_record_sha256 = ('0' * 64)
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
        } | Should -Throw '*Previous-record hash uyuşmazlığı*'
    }

    It 'detects a record substituted from another experiment' {
        $targetExperiment = Initialize-NxbSyntheticEvidenceExperiment `
            -Root $script:TemporaryRoot `
            -Name 'substitution-target'
        $donorExperiment = Initialize-NxbSyntheticEvidenceExperiment `
            -Root $script:TemporaryRoot `
            -Name 'substitution-donor' `
            -ExperimentId 'experiment-2' `
            -MachineId 'machine-2' `
            -BootId 'boot-2'

        $targetFirst = Add-NxbSyntheticRecord `
            -ExperimentPath $targetExperiment `
            -Value alpha `
            -MonotonicNs 100
        $targetSecond = Add-NxbSyntheticRecord `
            -ExperimentPath $targetExperiment `
            -Value beta `
            -MonotonicNs 200
        [void](Add-NxbSyntheticRecord `
            -ExperimentPath $donorExperiment `
            -Value alpha `
            -MonotonicNs 100 `
            -SessionId 'session-2')
        $donorSecond = Add-NxbSyntheticRecord `
            -ExperimentPath $donorExperiment `
            -Value beta `
            -MonotonicNs 200 `
            -SessionId 'session-2'

        $record = Get-Content -LiteralPath $donorSecond.RecordPath -Raw |
            ConvertFrom-Json
        $record.previous_record_sha256 = $targetFirst.RecordSha256
        $record.record_sha256 = Get-NxbCanonicalJsonHash `
            -InputObject $record `
            -ExcludeRootProperty 'record_sha256'
        Write-NxbCanonicalJsonAtomic `
            -Path $targetSecond.RecordPath `
            -InputObject $record `
            -Confirm:$false

        {
            & (Join-Path $script:ScriptsRoot 'Test-EvidenceStoreChain.ps1') `
                -ExperimentPath $targetExperiment
        } | Should -Throw '*identity değişti: experiment_id*'
    }

    It 'detects machine identity substitution after record rehashing' {
        $experimentPath = Initialize-NxbSyntheticEvidenceExperiment `
            -Root $script:TemporaryRoot `
            -Name 'machine-substitution'
        [void](Add-NxbSyntheticRecord `
            -ExperimentPath $experimentPath `
            -Value alpha `
            -MonotonicNs 100)
        $second = Add-NxbSyntheticRecord `
            -ExperimentPath $experimentPath `
            -Value beta `
            -MonotonicNs 200

        Invoke-NxbRecordIdentityMutation `
            -RecordPath $second.RecordPath `
            -Field machine_id `
            -Value 'substituted-machine'

        {
            & (Join-Path $script:ScriptsRoot 'Test-EvidenceStoreChain.ps1') `
                -ExperimentPath $experimentPath
        } | Should -Throw '*identity değişti: machine_id*'
    }

    It 'detects boot identity substitution after record rehashing' {
        $experimentPath = Initialize-NxbSyntheticEvidenceExperiment `
            -Root $script:TemporaryRoot `
            -Name 'boot-substitution'
        [void](Add-NxbSyntheticRecord `
            -ExperimentPath $experimentPath `
            -Value alpha `
            -MonotonicNs 100)
        $second = Add-NxbSyntheticRecord `
            -ExperimentPath $experimentPath `
            -Value beta `
            -MonotonicNs 200

        Invoke-NxbRecordIdentityMutation `
            -RecordPath $second.RecordPath `
            -Field boot_id `
            -Value 'substituted-boot'

        {
            & (Join-Path $script:ScriptsRoot 'Test-EvidenceStoreChain.ps1') `
                -ExperimentPath $experimentPath
        } | Should -Throw '*identity değişti: boot_id*'
    }

    It 'detects session identity substitution after record rehashing' {
        $experimentPath = Initialize-NxbSyntheticEvidenceExperiment `
            -Root $script:TemporaryRoot `
            -Name 'session-substitution'
        [void](Add-NxbSyntheticRecord `
            -ExperimentPath $experimentPath `
            -Value alpha `
            -MonotonicNs 100)
        $second = Add-NxbSyntheticRecord `
            -ExperimentPath $experimentPath `
            -Value beta `
            -MonotonicNs 200

        Invoke-NxbRecordIdentityMutation `
            -RecordPath $second.RecordPath `
            -Field session_id `
            -Value 'substituted-session'

        {
            & (Join-Path $script:ScriptsRoot 'Test-EvidenceStoreChain.ps1') `
                -ExperimentPath $experimentPath
        } | Should -Throw '*identity değişti: session_id*'
    }
}
