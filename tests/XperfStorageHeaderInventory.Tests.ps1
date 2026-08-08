BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:Parser = Join-Path `
        $script:RepositoryRoot `
        'scripts\Get-NxbXperfStorageHeaderInventory.ps1'
    $script:Fixture = Join-Path `
        $script:RepositoryRoot `
        'tests\fixtures\xperf-storage-header-inventory.valid.txt'
}

Describe 'NXB xperf storage header inventory' {
    BeforeEach {
        $script:OutputPath = Join-Path `
            ([IO.Path]::GetTempPath()) `
            ("nxb-storage-header-$([guid]::NewGuid().ToString('N')).json")
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:OutputPath) {
            Remove-Item -LiteralPath $script:OutputPath -Force
        }
    }

    It 'extracts unique header rows without event rows' {
        $result = & $script:Parser `
            -InputPath $script:Fixture `
            -OutputPath $script:OutputPath `
            -PassThru

        $result.header_count | Should -Be 4
        @($result.headers.event_name) | Should -Contain 'DiskRead'
        @($result.headers.event_name) | Should -Contain 'DiskWrite'
        @($result.headers.event_name) | Should -Contain 'FileIo/Read'
        @($result.headers.event_name) | Should -Contain 'OtherEvent'
    }

    It 'deduplicates repeated identical header text' {
        $result = & $script:Parser `
            -InputPath $script:Fixture `
            -OutputPath $script:OutputPath `
            -PassThru

        @($result.headers | Where-Object event_name -eq 'DiskRead').Count |
            Should -Be 1
    }

    It 'marks disk/file names only as candidates, not semantics' {
        $result = & $script:Parser `
            -InputPath $script:Fixture `
            -OutputPath $script:OutputPath `
            -PassThru

        $result.candidate_storage_header_count | Should -Be 3
        $result.claims.candidate_name_match_implies_semantics | Should -BeFalse
        $result.claims.queue_semantics | Should -Be 'not_claimed'
        $result.claims.latency_semantics | Should -Be 'not_claimed'
    }

    It 'does not include raw ETL or event rows in the inventory claim' {
        $result = & $script:Parser `
            -InputPath $script:Fixture `
            -OutputPath $script:OutputPath `
            -PassThru

        $result.claims.event_rows_included | Should -BeFalse
        $result.claims.raw_etl_included | Should -BeFalse
        $result.claims.parser_completeness | Should -Be 'not_claimed'
    }

    It 'refuses to overwrite an existing inventory file' {
        Set-Content -LiteralPath $script:OutputPath -Value '{}'

        {
            & $script:Parser `
                -InputPath $script:Fixture `
                -OutputPath $script:OutputPath
        } | Should -Throw '*already exists*'
    }
}
