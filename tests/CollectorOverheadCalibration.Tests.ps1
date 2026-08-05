BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:Validator = Join-Path `
        $script:RepositoryRoot `
        'scripts\Test-CollectorOverheadCalibration.ps1'
    $script:Fixture = Join-Path `
        $script:RepositoryRoot `
        'tests\fixtures\collector-overhead-calibration.valid.json'

    function Read-NxbCalibrationFixture {
        [CmdletBinding()]
        param()

        return Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
    }

    function Write-NxbCalibrationFixture {
        [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
        param(
            [Parameter(Mandatory)]
            [object]$Document
        )

        if ($PSCmdlet.ShouldProcess($script:ManifestPath, 'Write calibration fixture')) {
            $Document |
                ConvertTo-Json -Depth 32 |
                Set-Content -LiteralPath $script:ManifestPath -Encoding UTF8
        }
    }
}

Describe 'NXB collector overhead calibration validation' {
    BeforeEach {
        $script:TempRoot = Join-Path `
            ([IO.Path]::GetTempPath()) `
            ("nxb-overhead-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        $script:ManifestPath = Join-Path $script:TempRoot 'calibration.json'
        Copy-Item -LiteralPath $script:Fixture -Destination $script:ManifestPath
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force
        }
    }

    It 'accepts the deterministic valid fixture' {
        { & $script:Validator -Path $script:ManifestPath } | Should -Not -Throw
    }

    It 'rejects a canonical power-policy fingerprint mismatch' {
        $document = Read-NxbCalibrationFixture
        $document.power_policy.name = 'Changed policy'
        Write-NxbCalibrationFixture -Document $document -Confirm:$false

        {
            & $script:Validator -Path $script:ManifestPath
        } | Should -Throw '*power_policy_fingerprint does not match*'
    }

    It 'rejects a canonical workload fingerprint mismatch' {
        $document = Read-NxbCalibrationFixture
        $document.workload.parameters.iterations = 2000
        Write-NxbCalibrationFixture -Document $document -Confirm:$false

        {
            & $script:Validator -Path $script:ManifestPath
        } | Should -Throw '*workload_fingerprint does not match*'
    }

    It 'rejects a pair bound to a different boot identity' {
        $document = Read-NxbCalibrationFixture
        $document.pairs[0].boot_id = ('e' * 64)
        Write-NxbCalibrationFixture -Document $document -Confirm:$false

        {
            & $script:Validator -Path $script:ManifestPath
        } | Should -Throw '*boot_id mismatch*'
    }

    It 'rejects a parent experiment relative-path substitution' {
        $document = Read-NxbCalibrationFixture
        $document.experiment_relative_path = 'experiments/another-parent'
        Write-NxbCalibrationFixture -Document $document -Confirm:$false

        {
            & $script:Validator -Path $script:ManifestPath
        } | Should -Throw '*experiment_relative_path must be*'
    }

    It 'rejects a child experiment relative-path substitution' {
        $document = Read-NxbCalibrationFixture
        $document.pairs[0].capture.experiment_relative_path = `
            'experiments/another-capture'
        Write-NxbCalibrationFixture -Document $document -Confirm:$false

        {
            & $script:Validator -Path $script:ManifestPath
        } | Should -Throw '*capture.experiment_relative_path must be*'
    }

    It 'rejects duplicate lifecycle experiment identities across arms' {
        $document = Read-NxbCalibrationFixture
        $document.pairs[0].capture.experiment_id = `
            $document.pairs[0].control.experiment_id
        $document.pairs[0].capture.experiment_relative_path = `
            $document.pairs[0].control.experiment_relative_path
        Write-NxbCalibrationFixture -Document $document -Confirm:$false

        {
            & $script:Validator -Path $script:ManifestPath
        } | Should -Throw '*duplicate lifecycle experiment_id*'
    }

    It 'rejects a pair ordinal gap' {
        $document = Read-NxbCalibrationFixture
        $document.pairs[0].ordinal = 2
        Write-NxbCalibrationFixture -Document $document -Confirm:$false

        {
            & $script:Validator -Path $script:ManifestPath
        } | Should -Throw '*ordinal must be 1*'
    }

    It 'rejects an arm order that violates the deterministic protocol' {
        $document = Read-NxbCalibrationFixture
        $document.pairs[0].first_arm = 'capture'
        Write-NxbCalibrationFixture -Document $document -Confirm:$false

        {
            & $script:Validator -Path $script:ManifestPath
        } | Should -Throw '*first_arm violates deterministic ordering*'
    }

    It 'rejects different measured workload results across paired arms' {
        $document = Read-NxbCalibrationFixture
        $document.pairs[0].capture.result.value = 2000
        Write-NxbCalibrationFixture -Document $document -Confirm:$false

        {
            & $script:Validator -Path $script:ManifestPath
        } | Should -Throw '*control/capture workload results differ*'
    }

    It 'rejects incorrect absolute and relative overhead math' {
        $document = Read-NxbCalibrationFixture
        $document.pairs[0].deltas.duration_absolute_ms.value = 99
        Write-NxbCalibrationFixture -Document $document -Confirm:$false

        {
            & $script:Validator -Path $script:ManifestPath
        } | Should -Throw '*duration.absolute value mismatch*'
    }

    It 'rejects an incorrect ETL effective byte rate' {
        $document = Read-NxbCalibrationFixture
        $document.pairs[0].capture.etl.effective_bytes_per_second = 99999
        Write-NxbCalibrationFixture -Document $document -Confirm:$false

        {
            & $script:Validator -Path $script:ManifestPath
        } | Should -Throw '*effective_bytes_per_second mismatch*'
    }

    It 'rejects summary pair counters that do not match the trial matrix' {
        $document = Read-NxbCalibrationFixture
        $document.summary.successful_pair_count = 0
        $document.summary.failed_pair_count = 1
        Write-NxbCalibrationFixture -Document $document -Confirm:$false

        {
            & $script:Validator -Path $script:ManifestPath
        } | Should -Throw '*successful_pair_count mismatch*'
    }

    It 'rejects a measured distribution with changed statistics' {
        $document = Read-NxbCalibrationFixture
        $document.summary.cpu_time_delta_percent.mean = 9.5
        Write-NxbCalibrationFixture -Document $document -Confirm:$false

        {
            & $script:Validator -Path $script:ManifestPath
        } | Should -Throw '*cpu_time_delta_percent.mean mismatch*'
    }

    It 'rejects an undeclared capture-arm property' {
        $document = Read-NxbCalibrationFixture
        $document.pairs[0].capture |
            Add-Member -MemberType NoteProperty -Name invented_metric -Value 1
        Write-NxbCalibrationFixture -Document $document -Confirm:$false

        {
            & $script:Validator -Path $script:ManifestPath
        } | Should -Throw '*invented_metric*'
    }

    It 'rejects a threshold verdict because thresholds are not declared' {
        $document = Read-NxbCalibrationFixture
        $document.summary.threshold_policy.status = 'passed'
        Write-NxbCalibrationFixture -Document $document -Confirm:$false

        {
            & $script:Validator -Path $script:ManifestPath
        } | Should -Throw '*not_declared*'
    }
}
