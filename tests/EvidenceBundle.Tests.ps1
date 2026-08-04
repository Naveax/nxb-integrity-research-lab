BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsRoot = Join-Path $script:RepositoryRoot 'scripts'
    Import-Module (Join-Path $script:ScriptsRoot 'Nxb.Lab.Common.psm1') -Force
    Import-Module (Join-Path $script:ScriptsRoot 'Nxb.EvidenceStore.psm1') -Force

    function New-NxbSyntheticBundleExperiment {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$Name
        )

        $experimentPath = Join-Path $Root $Name
        $baselinePath = Join-Path $experimentPath 'baseline'
        $logsPath = Join-Path $experimentPath 'logs'
        New-Item -ItemType Directory -Path $baselinePath -Force | Out-Null
        New-Item -ItemType Directory -Path $logsPath -Force | Out-Null

        Write-NxbCanonicalJsonAtomic `
            -Path (Join-Path $experimentPath 'manifest.json') `
            -InputObject ([ordered]@{
                experiment_id = 'experiment-1'
                status = 'prepared'
            }) `
            -Confirm:$false

        Write-NxbCanonicalJsonAtomic `
            -Path (Join-Path $baselinePath 'observation-identity.json') `
            -InputObject ([ordered]@{
                machine_id = 'machine-1'
                boot_id = 'boot-1'
            }) `
            -Confirm:$false

        [IO.File]::WriteAllText(
            (Join-Path $logsPath 'evidence.txt'),
            'synthetic evidence',
            [Text.UTF8Encoding]::new($false)
        )

        [void](& (Join-Path $script:ScriptsRoot 'New-EvidenceStoreRecord.ps1') `
            -ExperimentPath $experimentPath `
            -RecordType manifest_snapshot `
            -Payload ([ordered]@{ state = 'prepared' }) `
            -SessionId 'session-1' `
            -CapturedUtc ([DateTime]'2026-08-04T20:00:00Z') `
            -MonotonicNs 100)

        [void](& (Join-Path $script:ScriptsRoot 'New-EvidenceStoreRecord.ps1') `
            -ExperimentPath $experimentPath `
            -RecordType evidence_index_snapshot `
            -Payload ([ordered]@{ count = [int64]1 }) `
            -SessionId 'session-1' `
            -CapturedUtc ([DateTime]'2026-08-04T20:00:01Z') `
            -MonotonicNs 200)

        return $experimentPath
    }

    function New-NxbSyntheticBundle {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$ExperimentPath
        )

        return & (Join-Path $script:ScriptsRoot 'New-EvidenceBundle.ps1') `
            -ExperimentPath $ExperimentPath `
            -IncludeRelativePath @(
                'manifest.json',
                'baseline/observation-identity.json',
                'evidence-store/chain-head.json',
                'logs/evidence.txt'
            ) `
            -Confirm:$false
    }
}

Describe 'NXB deterministic offline evidence bundles' {
    BeforeEach {
        $script:TemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
            'nxb-evidence-bundle-{0}' -f [guid]::NewGuid()
        )
        New-Item -ItemType Directory -Path $script:TemporaryRoot -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TemporaryRoot) {
            Remove-Item -LiteralPath $script:TemporaryRoot -Recurse -Force
        }
    }

    It 'creates the same bundle identity for unchanged inputs' {
        $experiment = New-NxbSyntheticBundleExperiment `
            -Root $script:TemporaryRoot `
            -Name 'deterministic'

        $first = New-NxbSyntheticBundle -ExperimentPath $experiment
        $second = New-NxbSyntheticBundle -ExperimentPath $experiment

        $first.BundleSha256 | Should -Be $second.BundleSha256
        $second.RecordCount | Should -Be 2
        $second.FileCount | Should -Be 4
        $second.SignatureState | Should -Be 'unsigned'

        $verified = & (Join-Path $script:ScriptsRoot 'Test-EvidenceBundle.ps1') `
            -ExperimentPath $experiment `
            -PassThru
        $verified.IsValid | Should -BeTrue
        $verified.BundleSha256 | Should -Be $second.BundleSha256
    }

    It 'detects a changed listed evidence file' {
        $experiment = New-NxbSyntheticBundleExperiment `
            -Root $script:TemporaryRoot `
            -Name 'file-tamper'
        [void](New-NxbSyntheticBundle -ExperimentPath $experiment)

        [IO.File]::WriteAllText(
            (Join-Path $experiment 'logs\evidence.txt'),
            'changed evidence',
            [Text.UTF8Encoding]::new($false)
        )

        {
            & (Join-Path $script:ScriptsRoot 'Test-EvidenceBundle.ps1') `
                -ExperimentPath $experiment
        } | Should -Throw '*Bundle file*SHA-256 uyuşmuyor*'
    }

    It 'detects bundle record inventory truncation even after rehashing' {
        $experiment = New-NxbSyntheticBundleExperiment `
            -Root $script:TemporaryRoot `
            -Name 'truncation'
        $created = New-NxbSyntheticBundle -ExperimentPath $experiment
        $bundle = Read-NxbJson -Path $created.BundlePath
        $bundle.records = @($bundle.records[0])
        $bundle.bundle_sha256 = Get-NxbCanonicalJsonHash `
            -InputObject $bundle `
            -ExcludeRootProperty @('bundle_sha256', 'signature_state', 'signature')
        Write-NxbCanonicalJsonAtomic `
            -Path $created.BundlePath `
            -InputObject $bundle `
            -Confirm:$false

        {
            & (Join-Path $script:ScriptsRoot 'Test-EvidenceBundle.ps1') `
                -ExperimentPath $experiment
        } | Should -Throw '*record sayısı*verified chain*'
    }

    It 'rejects case-colliding inventory paths after a valid rehash' {
        $experiment = New-NxbSyntheticBundleExperiment `
            -Root $script:TemporaryRoot `
            -Name 'case-collision'
        $created = New-NxbSyntheticBundle -ExperimentPath $experiment
        $bundle = Read-NxbJson -Path $created.BundlePath
        $manifestEntry = @($bundle.files | Where-Object {
            $_.relative_path -ceq 'manifest.json'
        })[0]
        $bundle.files = @($bundle.files) + @(
            [ordered]@{
                relative_path = 'MANIFEST.JSON'
                length = [int64]$manifestEntry.length
                sha256 = [string]$manifestEntry.sha256
            }
        )
        $bundle.bundle_sha256 = Get-NxbCanonicalJsonHash `
            -InputObject $bundle `
            -ExcludeRootProperty @('bundle_sha256', 'signature_state', 'signature')
        Write-NxbCanonicalJsonAtomic `
            -Path $created.BundlePath `
            -InputObject $bundle `
            -Confirm:$false

        {
            & (Join-Path $script:ScriptsRoot 'Test-EvidenceBundle.ps1') `
                -ExperimentPath $experiment
        } | Should -Throw '*case-collision*'
    }

    It 'rejects traversal paths through schema validation' {
        $experiment = New-NxbSyntheticBundleExperiment `
            -Root $script:TemporaryRoot `
            -Name 'traversal'
        $created = New-NxbSyntheticBundle -ExperimentPath $experiment
        $bundle = Read-NxbJson -Path $created.BundlePath
        $bundle.files[0].relative_path = '../manifest.json'
        $bundle.bundle_sha256 = Get-NxbCanonicalJsonHash `
            -InputObject $bundle `
            -ExcludeRootProperty @('bundle_sha256', 'signature_state', 'signature')
        Write-NxbCanonicalJsonAtomic `
            -Path $created.BundlePath `
            -InputObject $bundle `
            -Confirm:$false

        {
            & (Join-Path $script:ScriptsRoot 'Test-EvidenceBundle.ps1') `
                -ExperimentPath $experiment
        } | Should -Throw '*schema doğrulaması başarısız*'
    }

    It 'rejects a reparse-point path before adding it to a bundle' {
        $experiment = New-NxbSyntheticBundleExperiment `
            -Root $script:TemporaryRoot `
            -Name 'reparse'
        $outsidePath = Join-Path $script:TemporaryRoot 'outside'
        New-Item -ItemType Directory -Path $outsidePath -Force | Out-Null
        [IO.File]::WriteAllText(
            (Join-Path $outsidePath 'outside.txt'),
            'outside evidence',
            [Text.UTF8Encoding]::new($false)
        )

        $junctionPath = Join-Path $experiment 'logs\linked'
        New-Item `
            -ItemType Junction `
            -Path $junctionPath `
            -Target $outsidePath | Out-Null

        {
            & (Join-Path $script:ScriptsRoot 'New-EvidenceBundle.ps1') `
                -ExperimentPath $experiment `
                -IncludeRelativePath @(
                    'manifest.json',
                    'baseline/observation-identity.json',
                    'evidence-store/chain-head.json',
                    'logs/linked/outside.txt'
                ) `
                -Confirm:$false
        } | Should -Throw '*reparse*'
    }

    It 'compares identical and same-identity changed bundles deterministically' {
        $leftExperiment = New-NxbSyntheticBundleExperiment `
            -Root $script:TemporaryRoot `
            -Name 'left'
        $rightExperiment = New-NxbSyntheticBundleExperiment `
            -Root $script:TemporaryRoot `
            -Name 'right'
        $leftBundle = New-NxbSyntheticBundle -ExperimentPath $leftExperiment
        $rightBundle = New-NxbSyntheticBundle -ExperimentPath $rightExperiment

        $identical = & (Join-Path $script:ScriptsRoot 'Compare-EvidenceBundle.ps1') `
            -LeftBundlePath $leftBundle.BundlePath `
            -RightBundlePath $rightBundle.BundlePath `
            -LeftExperimentPath $leftExperiment `
            -RightExperimentPath $rightExperiment
        $identical.Relationship | Should -Be 'identical_bundle_identity'
        $identical.LeftFullyVerified | Should -BeTrue
        $identical.RightFullyVerified | Should -BeTrue

        [IO.File]::WriteAllText(
            (Join-Path $rightExperiment 'logs\evidence.txt'),
            'different evidence',
            [Text.UTF8Encoding]::new($false)
        )
        $rightBundle = New-NxbSyntheticBundle -ExperimentPath $rightExperiment

        $changed = & (Join-Path $script:ScriptsRoot 'Compare-EvidenceBundle.ps1') `
            -LeftBundlePath $leftBundle.BundlePath `
            -RightBundlePath $rightBundle.BundlePath `
            -LeftExperimentPath $leftExperiment `
            -RightExperimentPath $rightExperiment
        $changed.Relationship | Should -Be 'same_experiment_identity_different_content'
        $changed.FilesChanged | Should -Contain 'logs/evidence.txt'
        $changed.IdentityChanges.Count | Should -Be 0
    }
}
