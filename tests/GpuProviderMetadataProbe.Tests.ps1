BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ProbePath = Join-Path $script:RepositoryRoot 'scripts\Invoke-NxbGpuProviderMetadataProbe.ps1'
    $script:Source = Get-Content -LiteralPath $script:ProbePath -Raw
}

Describe 'NXB GPU provider metadata probe contract' {
    It 'parses without PowerShell syntax errors' {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($script:ProbePath,[ref]$tokens,[ref]$errors)
        @($errors).Count | Should -Be 0
    }

    It 'requires exact clean Windows PowerShell 7 execution' {
        $script:Source | Should -Match 'requires Windows'
        $script:Source | Should -Match 'requires PowerShell 7'
        $script:Source | Should -Match 'rev-parse HEAD'
        $script:Source | Should -Match 'status --porcelain=v1 --untracked-files=all'
    }

    It 'binds the observed DxgKrnl provider identity' {
        $script:Source | Should -Match 'Microsoft-Windows-DxgKrnl'
        $script:Source | Should -Match '802ec45a-1e99-4b83-9920-87c98277ba9d'
    }

    It 'binds the observed DXGI provider identity' {
        $script:Source | Should -Match 'Microsoft-Windows-DXGI'
        $script:Source | Should -Match 'ca11c036-0102-4a2d-a6ad-f03cfed5d3c9'
    }

    It 'uses Windows provider metadata surfaces' {
        $script:Source | Should -Match 'logman\.exe'
        $script:Source | Should -Match 'query providers'
        $script:Source | Should -Match 'wevtutil\.exe'
        $script:Source | Should -Match 'publisher_metadata'
    }

    It 'records observed keyword rows and hashes' {
        $script:Source | Should -Match 'keyword_rows'
        $script:Source | Should -Match 'keyword_row_count'
        $script:Source | Should -Match 'output_sha256'
    }

    It 'fails closed when expected provider identity is absent' {
        $script:Source | Should -Match 'Expected provider GUID was not observed'
        $script:Source | Should -Match 'expected_guid_observed'
    }

    It 'keeps higher-level GPU semantics disabled' {
        $script:Source | Should -Match 'keyword_semantics_validated = \$false'
        $script:Source | Should -Match 'event_ids_validated = \$false'
        $script:Source | Should -Match 'present_semantics = \$false'
        $script:Source | Should -Match 'gpu_execution_duration_semantics = \$false'
        $script:Source | Should -Match "trace_completeness = 'not_claimed'"
    }
}
