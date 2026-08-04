BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsRoot = Join-Path $script:RepositoryRoot 'scripts'
    Import-Module (Join-Path $script:ScriptsRoot 'Nxb.EvidenceStore.psm1') -Force

    function Initialize-NxbProvenanceClockExperiment {
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
            experiment_id = 'experiment-provenance-clock'
        } | ConvertTo-Json | Set-Content `
            -LiteralPath (Join-Path $experimentPath 'manifest.json') `
            -Encoding UTF8

        [ordered]@{
            machine_id = 'machine-provenance-clock'
            boot_id = 'boot-provenance-clock'
        } | ConvertTo-Json | Set-Content `
            -LiteralPath (Join-Path $baselinePath 'observation-identity.json') `
            -Encoding UTF8

        return $experimentPath
    }
}

Describe 'NXB tool provenance and clock-offset evidence' {
    BeforeEach {
        $script:TemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
            'nxb-provenance-clock-{0}' -f [guid]::NewGuid()
        )
        New-Item -ItemType Directory -Path $script:TemporaryRoot -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TemporaryRoot) {
            Remove-Item -LiteralPath $script:TemporaryRoot -Recurse -Force
        }
    }

    It 'records verifiable tool metadata without storing a sensitive argument' {
        $experimentPath = Initialize-NxbProvenanceClockExperiment `
            -Root $script:TemporaryRoot `
            -Name 'tool-provenance'
        $toolPath = Join-Path $script:TemporaryRoot 'synthetic-tool.bin'
        [IO.File]::WriteAllBytes($toolPath, [byte[]](1, 2, 3, 4, 5, 6))

        $result = & (Join-Path $script:ScriptsRoot 'New-ToolProvenanceRecord.ps1') `
            -ExperimentPath $experimentPath `
            -ToolPath $toolPath `
            -InvocationName 'synthetic-tool' `
            -ArgumentList @('--token', 'super-secret', '--mode', 'scan') `
            -SensitiveArgumentIndex 1 `
            -CollectorId 'pester-fixture' `
            -SessionId 'session-provenance-clock' `
            -Status succeeded `
            -ExitCode 0 `
            -CapturedUtc ([DateTime]'2026-08-04T20:00:00Z') `
            -MonotonicNs 100

        $rawRecord = Get-Content -LiteralPath $result.RecordPath -Raw
        $rawRecord | Should -Not -Match 'super-secret'

        $record = $rawRecord | ConvertFrom-Json
        $record.record_type | Should -Be 'tool_provenance'
        $record.payload.argument_count | Should -Be 4
        $record.payload.redacted_argument_count | Should -Be 1
        $record.payload.tool_sha256 | Should -Be (
            (Get-FileHash -LiteralPath $toolPath -Algorithm SHA256).Hash.ToLowerInvariant()
        )

        $verified = & (Join-Path $script:ScriptsRoot 'Test-ToolProvenanceRecord.ps1') `
            -RecordPath $result.RecordPath `
            -PassThru
        $verified.IsValid | Should -BeTrue
        $verified.ToolLength | Should -Be 6
    }

    It 'detects a changed tool binary independently of the chain' {
        $experimentPath = Initialize-NxbProvenanceClockExperiment `
            -Root $script:TemporaryRoot `
            -Name 'tool-change'
        $toolPath = Join-Path $script:TemporaryRoot 'synthetic-tool.bin'
        [IO.File]::WriteAllBytes($toolPath, [byte[]](1, 2, 3, 4))

        $result = & (Join-Path $script:ScriptsRoot 'New-ToolProvenanceRecord.ps1') `
            -ExperimentPath $experimentPath `
            -ToolPath $toolPath `
            -InvocationName 'synthetic-tool' `
            -CollectorId 'pester-fixture' `
            -SessionId 'session-provenance-clock' `
            -CapturedUtc ([DateTime]'2026-08-04T20:00:00Z') `
            -MonotonicNs 100

        [IO.File]::WriteAllBytes($toolPath, [byte[]](1, 2, 3, 4, 5))

        {
            & (Join-Path $script:ScriptsRoot 'Test-ToolProvenanceRecord.ps1') `
                -RecordPath $result.RecordPath
        } | Should -Throw '*Tool SHA-256 uyuşmuyor*'
    }

    It 'computes and verifies bounded four-timestamp clock evidence' {
        $experimentPath = Initialize-NxbProvenanceClockExperiment `
            -Root $script:TemporaryRoot `
            -Name 'clock-valid'

        $result = & (Join-Path $script:ScriptsRoot 'New-ClockOffsetRecord.ps1') `
            -ExperimentPath $experimentPath `
            -ControllerSendUtcNs 1000000 `
            -TargetReceiveMonotonicNs 100000 `
            -TargetSendMonotonicNs 100200 `
            -ControllerReceiveUtcNs 1001000 `
            -SessionId 'session-provenance-clock' `
            -CapturedUtc ([DateTime]'2026-08-04T20:00:00Z') `
            -MonotonicNs 200

        $record = Get-Content -LiteralPath $result.RecordPath -Raw |
            ConvertFrom-Json
        $record.record_type | Should -Be 'clock_offset'
        $record.payload.controller_elapsed_ns | Should -Be 1000
        $record.payload.target_elapsed_ns | Should -Be 200
        $record.payload.round_trip_ns | Should -Be 800
        $record.payload.uncertainty_ns | Should -Be 400
        $record.payload.estimated_offset_ns | Should -Be 900400

        $verified = & (Join-Path $script:ScriptsRoot 'Test-ClockOffsetRecord.ps1') `
            -RecordPath $result.RecordPath `
            -PassThru
        $verified.IsValid | Should -BeTrue
        $verified.EstimatedOffsetNs | Should -Be 900400
    }

    It 'rejects a rehashed clock payload with inconsistent arithmetic' {
        $experimentPath = Initialize-NxbProvenanceClockExperiment `
            -Root $script:TemporaryRoot `
            -Name 'clock-tamper'

        $result = & (Join-Path $script:ScriptsRoot 'New-ClockOffsetRecord.ps1') `
            -ExperimentPath $experimentPath `
            -ControllerSendUtcNs 1000000 `
            -TargetReceiveMonotonicNs 100000 `
            -TargetSendMonotonicNs 100200 `
            -ControllerReceiveUtcNs 1001000 `
            -SessionId 'session-provenance-clock' `
            -CapturedUtc ([DateTime]'2026-08-04T20:00:00Z') `
            -MonotonicNs 200

        $record = Get-Content -LiteralPath $result.RecordPath -Raw |
            ConvertFrom-Json
        $record.payload.estimated_offset_ns = [int64]900401
        $record.payload_sha256 = Get-NxbCanonicalJsonHash -InputObject $record.payload
        $record.record_sha256 = Get-NxbCanonicalJsonHash `
            -InputObject $record `
            -ExcludeRootProperty record_sha256
        Write-NxbCanonicalJsonAtomic `
            -Path $result.RecordPath `
            -InputObject $record `
            -Confirm:$false

        {
            & (Join-Path $script:ScriptsRoot 'Test-ClockOffsetRecord.ps1') `
                -RecordPath $result.RecordPath
        } | Should -Throw '*Clock-offset arithmetic uyuşmuyor: estimated_offset_ns*'
    }

    It 'rejects a clock sample whose target processing exceeds controller elapsed time' {
        $experimentPath = Initialize-NxbProvenanceClockExperiment `
            -Root $script:TemporaryRoot `
            -Name 'clock-invalid'

        {
            & (Join-Path $script:ScriptsRoot 'New-ClockOffsetRecord.ps1') `
                -ExperimentPath $experimentPath `
                -ControllerSendUtcNs 1000000 `
                -TargetReceiveMonotonicNs 100000 `
                -TargetSendMonotonicNs 101500 `
                -ControllerReceiveUtcNs 1001000 `
                -SessionId 'session-provenance-clock' `
                -MonotonicNs 200
        } | Should -Throw '*clock measurement geçersiz*'
    }
}
