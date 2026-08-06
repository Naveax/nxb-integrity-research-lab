BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsRoot = Join-Path $script:RepositoryRoot 'scripts'
    $script:FixturePath = Join-Path `
        $script:RepositoryRoot `
        'tests\fixtures\memory-snapshot.valid.json'

    function Write-MemorySnapshotFixture {
        param(
            [Parameter(Mandatory)]
            [object]$Document,

            [Parameter(Mandatory)]
            [string]$Path
        )

        $json = $Document | ConvertTo-Json -Depth 64
        [IO.File]::WriteAllText(
            $Path,
            $json,
            [Text.UTF8Encoding]::new($false)
        )
    }
}

Describe 'NXB memory snapshot evidence contract' {
    BeforeEach {
        $script:TestRoot = Join-Path `
            ([IO.Path]::GetTempPath()) `
            ("nxb-memory-snapshot-{0}" -f [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($script:TestRoot) | Out-Null
        $script:TestManifest = Join-Path $script:TestRoot 'memory-snapshot.json'
        $script:Document = Get-Content -LiteralPath $script:FixturePath -Raw |
            ConvertFrom-Json
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TestRoot) {
            Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
        }
    }

    It 'validates the committed partial-evidence fixture' {
        {
            & (Join-Path $script:ScriptsRoot 'Test-MemorySnapshot.ps1') `
                -Path $script:FixturePath
        } | Should -Not -Throw
    }

    It 'rejects available physical memory greater than total physical memory' {
        $script:Document.system.physical_memory_available_bytes.value =
            $script:Document.system.physical_memory_total_bytes.value + 1
        Write-MemorySnapshotFixture `
            -Document $script:Document `
            -Path $script:TestManifest

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemorySnapshot.ps1') `
                -Path $script:TestManifest
        } | Should -Throw '*physical_memory_available_bytes cannot exceed*'
    }

    It 'rejects commit use greater than the commit limit' {
        $script:Document.system.commit_used_bytes.value =
            $script:Document.system.commit_limit_bytes.value + 1
        Write-MemorySnapshotFixture `
            -Document $script:Document `
            -Path $script:TestManifest

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemorySnapshot.ps1') `
                -Path $script:TestManifest
        } | Should -Throw '*commit_used_bytes cannot exceed commit_limit_bytes*'
    }

    It 'rejects current working set greater than peak working set' {
        $script:Document.processes[0].working_set_bytes.value =
            $script:Document.processes[0].peak_working_set_bytes.value + 1
        Write-MemorySnapshotFixture `
            -Document $script:Document `
            -Path $script:TestManifest

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemorySnapshot.ps1') `
                -Path $script:TestManifest
        } | Should -Throw '*working_set_bytes cannot exceed peak_working_set_bytes*'
    }

    It 'rejects duplicate process identities' {
        $duplicate = $script:Document.processes[0] |
            ConvertTo-Json -Depth 64 |
            ConvertFrom-Json
        $duplicate.is_target = $false
        $script:Document.processes = @($script:Document.processes[0], $duplicate)
        Write-MemorySnapshotFixture `
            -Document $script:Document `
            -Path $script:TestManifest

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemorySnapshot.ps1') `
                -Path $script:TestManifest
        } | Should -Throw '*duplicate process identity*'
    }

    It 'rejects target identity with a false is_target flag' {
        $script:Document.processes[0].is_target = $false
        Write-MemorySnapshotFixture `
            -Document $script:Document `
            -Path $script:TestManifest

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemorySnapshot.ps1') `
                -Path $script:TestManifest
        } | Should -Throw '*is_target is inconsistent with target identity*'
    }

    It 'rejects summary counts that do not match measured evidence' {
        $script:Document.summary.process_measurement_count = 8
        Write-MemorySnapshotFixture `
            -Document $script:Document `
            -Path $script:TestManifest

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemorySnapshot.ps1') `
                -Path $script:TestManifest
        } | Should -Throw '*summary.process_measurement_count mismatch*'
    }

    It 'rejects an unmeasured value that still carries a numeric result' {
        $script:Document.system.compression_store_bytes.value = 1
        Write-MemorySnapshotFixture `
            -Document $script:Document `
            -Path $script:TestManifest

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemorySnapshot.ps1') `
                -Path $script:TestManifest
        } | Should -Throw '*Schema validation failed*'
    }

    It 'rejects a claim that working set equals total memory cost' {
        $script:Document.claims.working_set_equals_total_memory_cost = $true
        Write-MemorySnapshotFixture `
            -Document $script:Document `
            -Path $script:TestManifest

        {
            & (Join-Path $script:ScriptsRoot 'Test-MemorySnapshot.ps1') `
                -Path $script:TestManifest
        } | Should -Throw '*Schema validation failed*'
    }
}
