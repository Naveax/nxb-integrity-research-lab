BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsRoot = Join-Path $script:RepositoryRoot 'scripts'
    $script:ToolsRoot = Join-Path $script:RepositoryRoot 'tools'
    $script:Runner = Join-Path $script:ScriptsRoot 'Invoke-NxbMeasuredWorkload.ps1'

    function New-NxbControlledWorkloadFixture {
        [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
        param(
            [Parameter(Mandatory)]
            [ValidateSet('ExitFailure', 'Timeout')]
            [string]$Mode,

            [Parameter(Mandatory)]
            [ValidateNotNullOrEmpty()]
            [string]$Path
        )

        $behavior = if ($Mode -eq 'ExitFailure') {
            'exit 9'
        }
        else {
            'Start-Sleep -Seconds 5'
        }

        $content = @"
[CmdletBinding(SupportsShouldProcess)]
param(
    [int]`$Iterations,
    [int]`$Seed,
    [string]`$OutputPath
)
$behavior
"@

        if ($PSCmdlet.ShouldProcess($Path, "Write $Mode workload fixture")) {
            Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
        }
    }
}

Describe 'NXB independent measured workload runner' {
    BeforeEach {
        $script:TempRoot = Join-Path `
            ([IO.Path]::GetTempPath()) `
            ("nxb-measured-workload-{0}" -f [guid]::NewGuid())
        & (Join-Path $script:ScriptsRoot 'Initialize-Lab.ps1') `
            -Root $script:TempRoot `
            -Role Target | Out-Null
        $script:ExperimentPath = & (Join-Path $script:ScriptsRoot 'New-Experiment.ps1') `
            -Root $script:TempRoot `
            -Name 'Measured-Workload-Test' `
            -Hypothesis 'Controlled workload measurement is bounded and explicit'
        $script:TemporaryTool = Join-Path `
            $script:ToolsRoot `
            ("test-workload-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TemporaryTool) {
            Remove-Item -LiteralPath $script:TemporaryTool -Force
        }
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force
        }
    }

    It 'measures the deterministic CPU fixture in a child PowerShell process' {
        $measurement = & $script:Runner `
            -ExperimentPath $script:ExperimentPath `
            -Iterations 32 `
            -Seed 73 `
            -TimeoutSeconds 30 `
            -SampleIntervalMilliseconds 10 `
            -PassThru

        $measurement.status | Should -Be 'measured'
        $measurement.exit_code | Should -Be 0
        $measurement.timed_out | Should -BeFalse
        $measurement.duration_ms | Should -BeGreaterOrEqual 0
        $measurement.result.status | Should -Be 'measured'
        $measurement.result.value | Should -Match '^[0-9a-f]{64}$'
        $measurement.result.unit | Should -Be 'sha256'
        $measurement.process_metrics.cpu_time_ms.status |
            Should -BeIn @('measured', 'failed')
        $measurement.process_metrics.peak_working_set_bytes.status |
            Should -BeIn @('measured', 'unsupported')
        $measurement.process_metrics.peak_private_bytes.status |
            Should -BeIn @('measured', 'unsupported')
        $measurement.runner_provenance.workload_relative_path |
            Should -Be 'tools/Invoke-NxbCpuWorkload.ps1'
        $measurement.runner_provenance.workload_sha256 |
            Should -Match '^[0-9a-f]{64}$'

        Test-Path -LiteralPath (
            Join-Path $script:ExperimentPath 'logs\cpu-workload-measurement.json'
        ) | Should -BeTrue
    }

    It 'records a nonzero workload exit as an explicit failed arm' {
        New-NxbControlledWorkloadFixture `
            -Mode ExitFailure `
            -Path $script:TemporaryTool `
            -Confirm:$false

        $measurement = & $script:Runner `
            -ExperimentPath $script:ExperimentPath `
            -WorkloadScriptPath $script:TemporaryTool `
            -Iterations 4 `
            -TimeoutSeconds 30 `
            -SampleIntervalMilliseconds 10 `
            -PassThru

        $measurement.status | Should -Be 'failed'
        $measurement.exit_code | Should -Be 9
        $measurement.timed_out | Should -BeFalse
        $measurement.result.status | Should -Be 'failed'
        $measurement.result.value | Should -BeNullOrEmpty
        $measurement.diagnostics -join ' ' | Should -Match 'result dosyası oluşturulmadı'
    }

    It 'kills and records a workload that exceeds the bounded timeout' {
        New-NxbControlledWorkloadFixture `
            -Mode Timeout `
            -Path $script:TemporaryTool `
            -Confirm:$false

        $measurement = & $script:Runner `
            -ExperimentPath $script:ExperimentPath `
            -WorkloadScriptPath $script:TemporaryTool `
            -Iterations 4 `
            -TimeoutSeconds 1 `
            -SampleIntervalMilliseconds 20 `
            -PassThru

        $measurement.status | Should -Be 'failed'
        $measurement.timed_out | Should -BeTrue
        $measurement.result.status | Should -Be 'failed'
        $measurement.diagnostics -join ' ' | Should -Match 'timeout sınırını aştı'
    }

    It 'rejects a workload script outside the repository tools root' {
        $outsideScript = Join-Path $script:TempRoot 'outside-workload.ps1'
        '[CmdletBinding()] param()' |
            Set-Content -LiteralPath $outsideScript -Encoding UTF8

        {
            & $script:Runner `
                -ExperimentPath $script:ExperimentPath `
                -WorkloadScriptPath $outsideScript `
                -Iterations 1
        } | Should -Throw '*dışında*'
    }
}
