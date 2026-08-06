BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsRoot = Join-Path $script:RepositoryRoot 'scripts'
    $script:FixturePath = Join-Path `
        $script:RepositoryRoot `
        'tests\fixtures\memory-working-set-snapshot.valid.json'
    $script:SchemaPath = Join-Path `
        $script:RepositoryRoot `
        'schemas\memory-working-set-snapshot.schema.json'
}

Describe 'NXB memory working-set snapshot evidence' {
    BeforeEach {
        $script:TemporaryPath = Join-Path `
            ([IO.Path]::GetTempPath()) `
            ("nxb-memory-snapshot-{0}.json" -f [guid]::NewGuid().ToString('N'))
        $script:Document = Get-Content `
            -LiteralPath $script:FixturePath `
            -Raw | ConvertFrom-Json
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TemporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $script:TemporaryPath -Force
        }
    }

    function Write-NxbMemorySnapshotTestDocument {
        param(
            [Parameter(Mandatory)]
            [object]$Document
        )

        $Document |
            ConvertTo-Json -Depth 64 |
            Set-Content -LiteralPath $script:TemporaryPath -Encoding UTF8
    }

    It 'validates the committed complete memory snapshot fixture' {
        {
            & (Join-Path $script:ScriptsRoot 'Test-MemoryWorkingSetSnapshot.ps1') `
                -Path $script:FixturePath `
                -SchemaPath $script:SchemaPath
        } | Should -Not -Throw
    }

    It 'rejects an experiment-relative path inconsistent with experiment_id' {
        $script:Document.experiment_relative_path = 'experiments/different-experiment'
        Write-NxbMemorySnapshotTestDocument -Document $script:Document

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemoryWorkingSetSnapshot.ps1') `
                -Path $script:TemporaryPath `
                -SchemaPath $script:SchemaPath
        } | Should -Throw '*experiment_relative_path must be*'
    }

    It 'rejects duplicate process identifiers' {
        $copy = $script:Document.processes[0] |
            ConvertTo-Json -Depth 64 |
            ConvertFrom-Json
        $script:Document.capture.selection_mode = 'system_and_target_process_tree'
        $script:Document.processes = @($script:Document.processes[0], $copy)
        $script:Document.summary.process_count = 2
        $script:Document.summary.measured_process_count = 2
        $script:Document.summary.process_measurement_count = 22
        $script:Document.summary.measured_process_measurement_count = 22
        Write-NxbMemorySnapshotTestDocument -Document $script:Document

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemoryWorkingSetSnapshot.ps1') `
                -Path $script:TemporaryPath `
                -SchemaPath $script:SchemaPath
        } | Should -Throw '*PID values must be unique*'
    }

    It 'rejects available physical memory greater than total physical memory' {
        $script:Document.system.available_physical_bytes.value = 68719476736
        Write-NxbMemorySnapshotTestDocument -Document $script:Document

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemoryWorkingSetSnapshot.ps1') `
                -Path $script:TemporaryPath `
                -SchemaPath $script:SchemaPath
        } | Should -Throw '*cannot exceed total_physical_bytes*'
    }

    It 'rejects current working set greater than peak working set' {
        $script:Document.processes[0].metrics.working_set_bytes.value = 402653184
        Write-NxbMemorySnapshotTestDocument -Document $script:Document

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemoryWorkingSetSnapshot.ps1') `
                -Path $script:TemporaryPath `
                -SchemaPath $script:SchemaPath
        } | Should -Throw '*working_set_bytes cannot exceed peak_working_set_bytes*'
    }

    It 'rejects hard-fault count greater than total page-fault count' {
        $script:Document.processes[0].metrics.hard_fault_count.value = 1001
        Write-NxbMemorySnapshotTestDocument -Document $script:Document

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemoryWorkingSetSnapshot.ps1') `
                -Path $script:TemporaryPath `
                -SchemaPath $script:SchemaPath
        } | Should -Throw '*hard_fault_count cannot exceed page_fault_count*'
    }

    It 'rejects process summary counts inconsistent with process evidence' {
        $script:Document.summary.process_count = 2
        Write-NxbMemorySnapshotTestDocument -Document $script:Document

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemoryWorkingSetSnapshot.ps1') `
                -Path $script:TemporaryPath `
                -SchemaPath $script:SchemaPath
        } | Should -Throw '*summary.process_count mismatch*'
    }

    It 'rejects ReferenceSet activation in minimal memory evidence' {
        $script:Document.profile.reference_set_enabled = $true
        Write-NxbMemorySnapshotTestDocument -Document $script:Document

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemoryWorkingSetSnapshot.ps1') `
                -Path $script:TemporaryPath `
                -SchemaPath $script:SchemaPath
        } | Should -Throw '*reference_set_enabled*False*'
    }

    It 'rejects a system-only capture containing process snapshots' {
        $script:Document.capture.selection_mode = 'system_only'
        $script:Document.capture.requested_process_ids = @()
        Write-NxbMemorySnapshotTestDocument -Document $script:Document

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemoryWorkingSetSnapshot.ps1') `
                -Path $script:TemporaryPath `
                -SchemaPath $script:SchemaPath
        } | Should -Throw '*system_only capture cannot contain process snapshots*'
    }

    It 'rejects a process status inconsistent with metric states' {
        $script:Document.processes[0].status = 'partial'
        $script:Document.processes[0].reason = 'synthetic mismatch'
        Write-NxbMemorySnapshotTestDocument -Document $script:Document

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemoryWorkingSetSnapshot.ps1') `
                -Path $script:TemporaryPath `
                -SchemaPath $script:SchemaPath
        } | Should -Throw "*status must be 'measured'*"
    }
}
