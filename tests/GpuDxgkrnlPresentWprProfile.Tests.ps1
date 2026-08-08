BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ProfilePath = Join-Path $script:RepositoryRoot 'profiles\Nxb.GpuDxgkrnlPresent.wprp'
    $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts\Test-NxbGpuDxgkrnlPresentWprProfile.ps1'
    $script:ProfileSource = Get-Content -LiteralPath $script:ProfilePath -Raw
    $script:ValidatorSource = Get-Content -LiteralPath $script:ValidatorPath -Raw
    [xml]$script:Xml = $script:ProfileSource
}

Describe 'NXB GPU DXGKRNL present WPR profile contract' {
    It 'parses as XML and exposes exactly two event collectors and variants' {
        $script:Xml.WindowsPerformanceRecorder.Profiles.EventCollector.Count | Should -Be 2
        $script:Xml.WindowsPerformanceRecorder.Profiles.Profile.Count | Should -Be 2
    }

    It 'keeps file capture bounded and circular' {
        $file = @($script:Xml.WindowsPerformanceRecorder.Profiles.EventCollector) |
            Where-Object Id -eq 'NxbGpuDxgkrnlPresentEventCollectorFile'
        $file.BufferSize.Value | Should -Be '256'
        $file.Buffers.Value | Should -Be '64'
        $file.MaximumFileSize.Value | Should -Be '256'
        $file.MaximumFileSize.FileMode | Should -Be 'Circular'
    }

    It 'binds only the two certified GPU provider identities' {
        $providers = @($script:Xml.WindowsPerformanceRecorder.Profiles.EventProvider)
        $providers.Count | Should -Be 2
        @($providers.Name) | Should -Contain 'Microsoft-Windows-DxgKrnl'
        @($providers.Name) | Should -Contain 'Microsoft-Windows-DXGI'
    }

    It 'uses the exact observed bounded keyword identities' {
        $dxg = @($script:Xml.WindowsPerformanceRecorder.Profiles.EventProvider) |
            Where-Object Name -eq 'Microsoft-Windows-DxgKrnl'
        @($dxg.Keywords.Keyword.Value) | Should -Contain '0x0000000000008000'
        @($dxg.Keywords.Keyword.Value) | Should -Contain '0x0000000000010000'
        @($dxg.Keywords.Keyword.Value) | Should -Contain '0x0000000008000000'
        @($dxg.Keywords.Keyword.Value).Count | Should -Be 3

        $dxgi = @($script:Xml.WindowsPerformanceRecorder.Profiles.EventProvider) |
            Where-Object Name -eq 'Microsoft-Windows-DXGI'
        @($dxgi.Keywords.Keyword.Value) | Should -Be @('0x0000000000000002')
    }

    It 'fails closed on provider absence and avoids provider-wide stacks' {
        foreach ($provider in @($script:Xml.WindowsPerformanceRecorder.Profiles.EventProvider)) {
            $provider.Strict | Should -Be 'true'
            [string]$provider.Stack | Should -Not -Be 'true'
        }
    }

    It 'provides matched File and Memory profile variants referencing both providers' {
        foreach ($profile in @($script:Xml.WindowsPerformanceRecorder.Profiles.Profile)) {
            $profile.Name | Should -Be 'NxbGpuDxgkrnlPresent'
            $profile.DetailLevel | Should -Be 'Verbose'
            @($profile.Collectors.EventCollectorId.EventProviders.EventProviderId.Value).Count | Should -Be 2
            @($profile.Collectors.EventCollectorId.EventProviders.EventProviderId.Value) | Should -Contain 'NxbGpuDxgKrnlEventProvider'
            @($profile.Collectors.EventCollectorId.EventProviders.EventProviderId.Value) | Should -Contain 'NxbGpuDxgiEventProvider'
        }
    }

    It 'does not enable unrelated system heap or all-events capture' {
        $script:ProfileSource | Should -Not -Match '<SystemCollector'
        $script:ProfileSource | Should -Not -Match '<SystemProvider'
        $script:ProfileSource | Should -Not -Match '<HeapEventProvider'
        $script:ProfileSource | Should -Not -Match 'Value="0x0"'
        $script:ProfileSource | Should -Not -Match '0xFFFFFFFFFFFFFFFF'
    }

    It 'keeps higher-level GPU semantics explicitly unpromoted' {
        $script:ValidatorSource | Should -Match 'keyword_semantics_validated = \$false'
        $script:ValidatorSource | Should -Match 'event_ids_validated = \$false'
        $script:ValidatorSource | Should -Match 'present_semantics = \$false'
        $script:ValidatorSource | Should -Match 'submission_semantics = \$false'
        $script:ValidatorSource | Should -Match 'gpu_execution_duration_semantics = \$false'
        $script:ValidatorSource | Should -Match "trace_completeness = 'not_claimed'"
    }
}
