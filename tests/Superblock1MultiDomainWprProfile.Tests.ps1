BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ProfilePath = Join-Path $script:RepositoryRoot 'profiles\Nxb.Superblock1MultiDomain.wprp'
    $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts\Test-NxbSuperblock1MultiDomainWprProfile.ps1'
    $script:ProfileText = Get-Content -LiteralPath $script:ProfilePath -Raw
    $script:ProfileXml = [xml]$script:ProfileText
}

Describe 'NXB SUPERBLOCK 1 multi-domain WPR profile' {
    It 'parses the profile and validator source' {
        { [xml]$script:ProfileText } | Should -Not -Throw
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $script:ValidatorPath,
            [ref]$tokens,
            [ref]$errors
        )
        @($errors).Count | Should -Be 0
    }

    It 'validates the committed conservative profile contract' {
        $result = & $script:ValidatorPath -PassThru
        $result.status | Should -BeExactly 'passed'
        $result.name | Should -BeExactly 'NxbSuperblock1MultiDomain'
        $result.semantic_claims_enabled | Should -BeFalse
        $result.trace_completeness | Should -BeExactly 'not_claimed'
    }

    It 'keeps the exact system-provider foundation keyword set' {
        $values = @(
            $script:ProfileXml.SelectNodes('//SystemProvider/Keywords/Keyword') |
                ForEach-Object { [string]$_.Value } |
                Sort-Object
        )
        $values | Should -Be @('Loader','NetworkTrace','ProcessThread','Registry')
    }

    It 'binds the exact eight certified event-provider identities' {
        $names = @(
            $script:ProfileXml.SelectNodes('//EventProvider') |
                ForEach-Object { [string]$_.Name } |
                Sort-Object
        )
        $names | Should -Be @(
            'Microsoft-Windows-DNS-Client',
            'Microsoft-Windows-DXGI',
            'Microsoft-Windows-DxgKrnl',
            'Microsoft-Windows-Kernel-Network',
            'Microsoft-Windows-Kernel-PnP',
            'Microsoft-Windows-Kernel-Process',
            'Microsoft-Windows-Kernel-Registry',
            'Microsoft-Windows-Winsock-AFD'
        )
    }

    It 'preserves the native-certified GPU keyword identities' {
        $dxg = $script:ProfileXml.SelectSingleNode("//EventProvider[@Name='Microsoft-Windows-DxgKrnl']")
        $dxgi = $script:ProfileXml.SelectSingleNode("//EventProvider[@Name='Microsoft-Windows-DXGI']")
        @($dxg.Keywords.Keyword | ForEach-Object { [string]$_.Value } | Sort-Object) |
            Should -Be @(
                '0x0000000000008000',
                '0x0000000000010000',
                '0x0000000008000000'
            )
        @($dxgi.Keywords.Keyword | ForEach-Object { [string]$_.Value }) |
            Should -Be @('0x0000000000000002')
    }

    It 'does not invent network or kernel manifest-provider keyword filters' {
        $providers = @(
            $script:ProfileXml.SelectNodes('//EventProvider') |
                Where-Object { $_.Name -notin @('Microsoft-Windows-DxgKrnl','Microsoft-Windows-DXGI') }
        )
        $providers.Count | Should -Be 6
        foreach ($provider in $providers) {
            @($provider.SelectNodes('./Keywords/Keyword')).Count | Should -Be 0
        }
    }

    It 'bounds both file collectors to 128 MiB circular mode' {
        $fileCollectors = @(
            $script:ProfileXml.SelectNodes('//SystemCollector|//EventCollector') |
                Where-Object { $_.Id -like '*File' }
        )
        $fileCollectors.Count | Should -Be 2
        foreach ($collector in $fileCollectors) {
            [string]$collector.BufferSize.Value | Should -BeExactly '256'
            [string]$collector.Buffers.Value | Should -BeExactly '64'
            [string]$collector.MaximumFileSize.Value | Should -BeExactly '128'
            [string]$collector.MaximumFileSize.FileMode | Should -BeExactly 'Circular'
        }
    }

    It 'keeps one file and one memory profile variant with both collector classes' {
        $profiles = @($script:ProfileXml.SelectNodes('//Profile'))
        $profiles.Count | Should -Be 2
        foreach ($mode in @('File','Memory')) {
            $variant = @($profiles | Where-Object { $_.LoggingMode -ceq $mode })
            $variant.Count | Should -Be 1
            $variant[0].Collectors.SystemCollectorId | Should -Not -BeNullOrEmpty
            $variant[0].Collectors.EventCollectorId | Should -Not -BeNullOrEmpty
        }
    }

    It 'keeps foundation stack capture disabled' {
        @($script:ProfileXml.SelectNodes('//Stacks/Stack')).Count | Should -Be 0
    }

    It 'documents the unpromoted semantic boundary in source' {
        $script:ProfileText | Should -Match 'event and timing semantics remain unpromoted'
        $script:ProfileText | Should -Match 'without promoting individual keyword/event semantics'
    }
}
