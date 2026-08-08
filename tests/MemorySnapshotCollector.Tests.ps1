BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:CollectorPath = Join-Path `
        $script:RepositoryRoot `
        'scripts\New-NxbMemorySnapshot.ps1'
    $script:ValidatorPath = Join-Path `
        $script:RepositoryRoot `
        'scripts\Test-MemorySnapshot.ps1'
}

Describe 'NXB native memory snapshot collector' {
    It 'collects and validates the current PowerShell process' {
        $output = Join-Path $TestDrive 'current-process-memory.json'

        {
            & $script:CollectorPath `
                -ExperimentId 'collector-current-process' `
                -ProcessId $PID `
                -OutputPath $output
        } | Should -Not -Throw

        Test-Path -LiteralPath $output -PathType Leaf | Should -BeTrue
        { & $script:ValidatorPath -Path $output } | Should -Not -Throw
    }

    It 'binds the target to PID start time and image hash' {
        $output = Join-Path $TestDrive 'target-identity.json'
        & $script:CollectorPath `
            -ExperimentId 'collector-target-identity' `
            -ProcessId $PID `
            -OutputPath $output

        $document = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
        $targetProcess = @($document.processes | Where-Object is_target)

        $document.target.process_id | Should -Be $PID
        $targetProcess.Count | Should -Be 1
        $targetProcess[0].process_id | Should -Be $document.target.process_id
        $targetProcess[0].process_start_utc | Should -Be $document.target.process_start_utc
        $targetProcess[0].image_sha256 | Should -Be $document.target.image_sha256
        $document.target.image_sha256 | Should -Match '^[0-9a-f]{64}$'
    }

    It 'records native footprint and total page-fault measurements' {
        $output = Join-Path $TestDrive 'native-measurements.json'
        & $script:CollectorPath `
            -ExperimentId 'collector-native-measurements' `
            -ProcessId $PID `
            -OutputPath $output

        $document = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
        $process = $document.processes[0]

        $document.system.physical_memory_total_bytes.status | Should -Be 'measured'
        $document.system.commit_limit_bytes.status | Should -Be 'measured'
        $process.working_set_bytes.status | Should -Be 'measured'
        $process.private_bytes.status | Should -Be 'measured'
        $process.page_fault_count.status | Should -Be 'measured'
        [long]$process.page_fault_count.value | Should -BeGreaterOrEqual 0
    }

    It 'keeps hard and soft fault attribution explicitly unassessed' {
        $output = Join-Path $TestDrive 'fault-boundary.json'
        & $script:CollectorPath `
            -ExperimentId 'collector-fault-boundary' `
            -ProcessId $PID `
            -OutputPath $output

        $document = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
        $process = $document.processes[0]

        $process.hard_fault_count.status | Should -Be 'not_assessed'
        $process.hard_fault_count.value | Should -BeNullOrEmpty
        $process.soft_fault_count.status | Should -Be 'not_assessed'
        $process.soft_fault_count.value | Should -BeNullOrEmpty
        $document.claims.page_fault_absence | Should -BeFalse
    }

    It 'binds every measured field to the collector hash' {
        $output = Join-Path $TestDrive 'collector-provenance.json'
        & $script:CollectorPath `
            -ExperimentId 'collector-provenance' `
            -ProcessId $PID `
            -OutputPath $output

        $document = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
        $expectedHash = (
            Get-FileHash -LiteralPath $script:CollectorPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()

        $measured = @(
            foreach ($property in $document.system.PSObject.Properties) {
                $measurement = $property.Value
                if ($null -ne $measurement -and
                    $null -ne $measurement.PSObject.Properties['status'] -and
                    [string]$measurement.status -ceq 'measured') {
                    $measurement
                }
            }
            foreach ($property in $document.processes[0].PSObject.Properties) {
                $measurement = $property.Value
                if ($null -ne $measurement -and
                    $null -ne $measurement.PSObject.Properties['status'] -and
                    [string]$measurement.status -ceq 'measured') {
                    $measurement
                }
            }
        )

        $measured.Count | Should -BeGreaterThan 0
        foreach ($measurement in $measured) {
            $measurement.source.collector | Should -Be 'New-NxbMemorySnapshot.ps1'
            $measurement.source.provenance_sha256 | Should -Be $expectedHash
        }
    }

    It 'does not overwrite evidence without Force' {
        $output = Join-Path $TestDrive 'existing.json'
        [IO.File]::WriteAllText($output, '{}', [Text.UTF8Encoding]::new($false))

        {
            & $script:CollectorPath `
                -ExperimentId 'collector-overwrite-denial' `
                -ProcessId $PID `
                -OutputPath $output
        } | Should -Throw '*üzerine yazmak için -Force gerekir*'

        Get-Content -LiteralPath $output -Raw | Should -Be '{}'
    }

    It 'rejects a process that does not exist' {
        $output = Join-Path $TestDrive 'missing-process.json'

        {
            & $script:CollectorPath `
                -ExperimentId 'collector-missing-process' `
                -ProcessId 2147483647 `
                -OutputPath $output
        } | Should -Throw

        Test-Path -LiteralPath $output | Should -BeFalse
    }
}
