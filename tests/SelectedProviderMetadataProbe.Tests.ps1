BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ProbePath = Join-Path $script:RepositoryRoot 'scripts\Invoke-NxbSelectedProviderMetadataProbe.ps1'
    $script:Source = Get-Content -LiteralPath $script:ProbePath -Raw
}

Describe 'NXB selected network/kernel provider metadata contract' {
    It 'parses without PowerShell syntax errors' {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $script:ProbePath,
            [ref]$tokens,
            [ref]$errors
        )
        @($errors).Count | Should -Be 0
    }

    It 'requires exact clean native Windows PowerShell 7 execution' {
        $script:Source | Should -Match 'requires Windows'
        $script:Source | Should -Match 'requires PowerShell 7'
        $script:Source | Should -Match 'rev-parse HEAD'
        $script:Source | Should -Match 'status --porcelain=v1 --untracked-files=all'
    }

    It 'binds exactly three observed network provider identities' {
        foreach ($name in @(
            'Microsoft-Windows-Kernel-Network',
            'Microsoft-Windows-Winsock-AFD',
            'Microsoft-Windows-DNS-Client'
        )) {
            $script:Source | Should -Match ([regex]::Escape($name))
        }
        $script:Source | Should -Match '7dd42a49-5329-4832-8dfd-43d979153a88'
        $script:Source | Should -Match 'e53c6823-7bb8-44bb-90dc-3f86090d48a6'
        $script:Source | Should -Match '1c95126e-7eea-49a9-a3fe-a378b03ddb4d'
    }

    It 'binds exactly three observed kernel lifecycle provider identities' {
        foreach ($name in @(
            'Microsoft-Windows-Kernel-Process',
            'Microsoft-Windows-Kernel-Registry',
            'Microsoft-Windows-Kernel-PnP'
        )) {
            $script:Source | Should -Match ([regex]::Escape($name))
        }
        $script:Source | Should -Match '22fb2cd6-0e7b-422b-a0c7-2fad1fd0e716'
        $script:Source | Should -Match '70eb4f03-c1de-4f73-a051-33d13d5413bd'
        $script:Source | Should -Match '9c205a39-1250-487d-abd7-e831c6290539'
    }

    It 'uses bounded native metadata surfaces without starting a trace session' {
        $script:Source | Should -Match 'logman\.exe'
        $script:Source | Should -Match 'query providers -n'
        $script:Source | Should -Match 'wevtutil\.exe'
        $script:Source | Should -Match 'publisher_metadata'
        $script:Source | Should -Not -Match 'wpr\.exe.*-start'
        $script:Source | Should -Not -Match 'StartTrace'
    }

    It 'tolerates blank native rows and section-bounds keyword parsing' {
        $script:Source | Should -Match 'Get-NxbSelectedKeywordRow'
        $script:Source | Should -Match 'AllowEmptyCollection'
        $script:Source | Should -Match 'AllowEmptyString'
        $script:Source | Should -Match '\\bValue\\b'
        $script:Source | Should -Match '\\bKeyword\\b'
        $script:Source | Should -Match "keyword_parser = 'section-v1'"
        $script:Source | Should -Match 'Keyword metadata contamination detected'
    }

    It 'represents absent keyword metadata as unavailable rather than zero evidence' {
        $script:Source | Should -Match "keyword_status = if"
        $script:Source | Should -Match "'unavailable'"
        $script:Source | Should -Match 'keyword_section_detected'
        $script:Source | Should -Match 'keyword_row_count'
    }

    It 'keeps network and kernel semantics explicitly unpromoted' {
        $script:Source | Should -Match 'keyword_semantics_validated = \$false'
        $script:Source | Should -Match 'event_ids_validated = \$false'
        $script:Source | Should -Match 'network_connection_semantics = \$false'
        $script:Source | Should -Match 'network_latency_semantics = \$false'
        $script:Source | Should -Match 'kernel_lifecycle_semantics = \$false'
        $script:Source | Should -Match "trace_completeness = 'not_claimed'"
    }

    It 'refuses to overwrite output and preserves exact-head cleanliness' {
        $script:Source | Should -Match 'OutputPath already exists'
        $script:Source | Should -Match 'WriteAllText'
        $script:Source | Should -Match 'dirtied the exact-head worktree'
    }
}
