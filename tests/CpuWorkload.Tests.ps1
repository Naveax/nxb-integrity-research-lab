BeforeAll {
    $script:Workload = Join-Path `
        (Split-Path -Parent $PSScriptRoot) `
        'tools\Invoke-NxbCpuWorkload.ps1'
}

Describe 'NXB deterministic CPU calibration workload' {
    BeforeEach {
        $script:TempRoot = Join-Path `
            ([IO.Path]::GetTempPath()) `
            ("nxb-cpu-workload-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force
        }
    }

    It 'produces the same checksum for the same bounded parameters' {
        $firstPath = Join-Path $script:TempRoot 'first.json'
        $secondPath = Join-Path $script:TempRoot 'second.json'

        & $script:Workload -Iterations 32 -Seed 73 -OutputPath $firstPath -Confirm:$false |
            Out-Null
        & $script:Workload -Iterations 32 -Seed 73 -OutputPath $secondPath -Confirm:$false |
            Out-Null

        $first = Get-Content -LiteralPath $firstPath -Raw | ConvertFrom-Json
        $second = Get-Content -LiteralPath $secondPath -Raw | ConvertFrom-Json

        $first.schema_version | Should -Be 1
        $first.workload_id | Should -Be 'nxb.cpu.sha256-chain.v1'
        $first.iterations | Should -Be 32
        $first.seed | Should -Be 73
        $first.buffer_bytes | Should -Be 4096
        $first.checksum_sha256 | Should -Match '^[0-9a-f]{64}$'
        $first.checksum_sha256 | Should -Be $second.checksum_sha256
        $first.elapsed_ms | Should -BeGreaterOrEqual 0
    }

    It 'changes the checksum when workload parameters change' {
        $firstPath = Join-Path $script:TempRoot 'first.json'
        $secondPath = Join-Path $script:TempRoot 'second.json'

        & $script:Workload -Iterations 16 -Seed 73 -OutputPath $firstPath -Confirm:$false |
            Out-Null
        & $script:Workload -Iterations 17 -Seed 73 -OutputPath $secondPath -Confirm:$false |
            Out-Null

        $first = Get-Content -LiteralPath $firstPath -Raw | ConvertFrom-Json
        $second = Get-Content -LiteralPath $secondPath -Raw | ConvertFrom-Json
        $first.checksum_sha256 | Should -Not -Be $second.checksum_sha256
    }

    It 'refuses to overwrite an existing result file' {
        $outputPath = Join-Path $script:TempRoot 'existing.json'
        'sentinel' | Set-Content -LiteralPath $outputPath -Encoding Ascii

        {
            & $script:Workload `
                -Iterations 4 `
                -OutputPath $outputPath `
                -Confirm:$false
        } | Should -Throw '*zaten var*'

        Get-Content -LiteralPath $outputPath -Raw | Should -Match 'sentinel'
    }
}
