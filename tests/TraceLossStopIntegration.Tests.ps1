BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsRoot = Join-Path $script:RepositoryRoot 'scripts'
    $script:StopWithAccounting = Join-Path `
        $script:ScriptsRoot `
        'Stop-PerformanceTraceWithAccounting.ps1'
    Import-Module (Join-Path $script:ScriptsRoot 'Nxb.Lab.Common.psm1') -Force
    Import-Module (Join-Path $script:ScriptsRoot 'Nxb.EvidenceStore.psm1') -Force

    function Initialize-NxbRecordingFixture {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ExperimentPath
        )

        [void](& (Join-Path $script:ScriptsRoot 'Get-ObservationIdentity.ps1') `
            -ExperimentPath $ExperimentPath)

        $profileMetadata = & (Join-Path $script:ScriptsRoot 'Test-WprProfile.ps1') -PassThru
        $profileProvenance = [ordered]@{
            type = 'repository_wprp'
            relative_path = [string]$profileMetadata.RelativePath
            sha256 = [string]$profileMetadata.Sha256
            length = [int64]$profileMetadata.Length
            name = [string]$profileMetadata.Name
            detail_level = [string]$profileMetadata.DetailLevel
            logging_mode = 'File'
            bounded = $true
            buffer_size_kib = [int]$profileMetadata.BufferSizeKiB
            buffers = [int]$profileMetadata.Buffers
            maximum_file_size_mib = [int]$profileMetadata.MaximumFileSizeMiB
            file_mode = [string]$profileMetadata.FileMode
            keywords = @($profileMetadata.Keywords)
            stacks = @($profileMetadata.Stacks)
        }
        $session = [ordered]@{
            started_utc = [DateTime]::UtcNow.AddSeconds(-1).ToString('o')
            profile = 'NxbMinimalCpuScheduler'
            mode = 'filemode'
            profile_provenance = $profileProvenance
            profile_provenance_sha256 = Get-NxbCanonicalJsonHash `
                -InputObject $profileProvenance
            status = 'recording'
            wpr_executable = 'fake-wpr.cmd'
        }
        Write-NxbJsonAtomic `
            -Path (Join-Path $ExperimentPath 'trace-session.json') `
            -InputObject $session `
            -Depth 16

        Set-NxbExperimentState `
            -ExperimentPath $ExperimentPath `
            -State recording `
            -Confirm:$false | Out-Null
    }
}

Describe 'NXB accounting-aware WPR stop integration' {
    BeforeEach {
        $script:TempRoot = Join-Path `
            ([IO.Path]::GetTempPath()) `
            ("nxb-trace-loss-stop-{0}" -f [guid]::NewGuid())
        & (Join-Path $script:ScriptsRoot 'Initialize-Lab.ps1') `
            -Root $script:TempRoot `
            -Role Target | Out-Null
        $script:ExperimentPath = & (Join-Path $script:ScriptsRoot 'New-Experiment.ps1') `
            -Root $script:TempRoot `
            -Name 'Trace-Loss-Stop-Test' `
            -Hypothesis 'WPR stop preserves explicit trace-loss accounting'
        Initialize-NxbRecordingFixture -ExperimentPath $script:ExperimentPath
        $script:FakeWpr = Join-Path $script:TempRoot 'fake-wpr.cmd'
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force
        }
    }

    It 'stops WPR and persists partial conservative accounting when only Events Lost is exposed' {
        @'
@echo off
if /I "%~1"=="-status" (
  echo Dropped event           : 0
  echo Collector Name          : NT Kernel Logger
  echo Events Lost             : 0
  exit /b 0
)
if /I "%~1"=="-stop" (
  echo synthetic-etl>"%~2"
  exit /b 0
)
exit /b 8
'@ | Set-Content -LiteralPath $script:FakeWpr -Encoding ASCII

        $result = & $script:StopWithAccounting `
            -ExperimentPath $script:ExperimentPath `
            -WprExecutablePath $script:FakeWpr `
            -PassThru `
            -Confirm:$false

        Test-Path -LiteralPath $result.AccountingPath | Should -BeTrue
        $accounting = Get-Content -LiteralPath $result.AccountingPath -Raw |
            ConvertFrom-Json
        $accounting.trace_loss.classification | Should -Be 'not_assessed'
        $accounting.circular_overwrite.classification | Should -Be 'no_risk_observed'
        $accounting.summary.evidence_completeness | Should -Be 'partial'

        $manifest = Get-Content `
            -LiteralPath (Join-Path $script:ExperimentPath 'manifest.json') `
            -Raw | ConvertFrom-Json
        $manifest.status | Should -Be 'stopped'

        $session = Get-Content `
            -LiteralPath (Join-Path $script:ExperimentPath 'trace-session.json') `
            -Raw | ConvertFrom-Json
        $session.status | Should -Be 'stopped'
        $session.trace_loss_accounting | Should -Be 'analysis/trace-loss-accounting.json'
    }

    It 'preserves positive native loss while completing the stop lifecycle' {
        @'
@echo off
if /I "%~1"=="-status" (
  echo Collector Name          : NT Kernel Logger
  echo Events Lost             : 6
  exit /b 0
)
if /I "%~1"=="-stop" (
  echo synthetic-etl>"%~2"
  exit /b 0
)
exit /b 8
'@ | Set-Content -LiteralPath $script:FakeWpr -Encoding ASCII

        $result = & $script:StopWithAccounting `
            -ExperimentPath $script:ExperimentPath `
            -WprExecutablePath $script:FakeWpr `
            -PassThru `
            -Confirm:$false

        $accounting = Get-Content -LiteralPath $result.AccountingPath -Raw |
            ConvertFrom-Json
        $accounting.trace_loss.classification | Should -Be 'native_loss_observed'
        $accounting.trace_loss.total_reported_loss | Should -Be 6
        $accounting.claims.trace_loss_absence | Should -BeFalse
    }

    It 'fails the stopped experiment when the native status source fails' {
        @'
@echo off
if /I "%~1"=="-status" (
  echo synthetic status failure 1>&2
  exit /b 9
)
if /I "%~1"=="-stop" (
  echo synthetic-etl>"%~2"
  exit /b 0
)
exit /b 8
'@ | Set-Content -LiteralPath $script:FakeWpr -Encoding ASCII

        {
            & $script:StopWithAccounting `
                -ExperimentPath $script:ExperimentPath `
                -WprExecutablePath $script:FakeWpr `
                -Confirm:$false
        } | Should -Throw '*accounting finalization başarısız*'

        $manifest = Get-Content `
            -LiteralPath (Join-Path $script:ExperimentPath 'manifest.json') `
            -Raw | ConvertFrom-Json
        $manifest.status | Should -Be 'failed'

        $accountingPath = Join-Path `
            $script:ExperimentPath `
            'analysis\trace-loss-accounting.json'
        Test-Path -LiteralPath $accountingPath | Should -BeTrue
        $accounting = Get-Content -LiteralPath $accountingPath -Raw |
            ConvertFrom-Json
        $accounting.summary.evidence_completeness | Should -Be 'failed'
    }
}
