BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:CapturePath = Join-Path $script:RepositoryRoot 'scripts\Invoke-NxbSuperblock1MultiDomainCertification.ps1'
    $script:WorkloadPath = Join-Path $script:RepositoryRoot 'scripts\Invoke-NxbSuperblock1BoundedWorkload.ps1'
    $script:InventoryPath = Join-Path $script:RepositoryRoot 'scripts\Get-NxbSuperblock1XperfHeaderInventory.ps1'
    $script:ProfilePath = Join-Path $script:RepositoryRoot 'profiles\Nxb.Superblock1MultiDomain.wprp'
    $script:CaptureSource = Get-Content -LiteralPath $script:CapturePath -Raw
    $script:WorkloadSource = Get-Content -LiteralPath $script:WorkloadPath -Raw
    $script:InventorySource = Get-Content -LiteralPath $script:InventoryPath -Raw
}

Describe 'NXB SUPERBLOCK 1 real multi-domain certification contract' {
    It 'parses every new capture-layer PowerShell source' {
        foreach ($path in @($script:CapturePath,$script:WorkloadPath,$script:InventoryPath)) {
            $tokens = $null
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
            @($errors).Count | Should -Be 0
        }
    }

    It 'chains the existing metadata adapter gate and the native multi-domain profile gate' {
        $script:CaptureSource | Should -Match 'Invoke-NxbSuperblock1CaptureAdapterCertification\.ps1'
        $script:CaptureSource | Should -Match 'Invoke-NxbSuperblock1MultiDomainProfileLocalValidation\.ps1'
    }

    It 'uses the repository trace-loss accounting adapter after the ETL stops' {
        $script:CaptureSource | Should -Match 'Get-NxbEtlTraceStatistics\.ps1'
        $script:CaptureSource | Should -Match 'events_lost'
        $script:CaptureSource | Should -Match 'buffers_lost'
    }

    It 'never opts into cancelling a pre-existing WPR session' {
        $script:CaptureSource | Should -Not -Match 'CancelExistingSession'
        $script:CaptureSource | Should -Match 'sessionOwned'
        $script:CaptureSource | Should -Match 'Existing WPR sessions are never auto-cancelled'
    }

    It 'keeps the bounded workload local-only and external-network free' {
        $script:WorkloadSource | Should -Match "external_network_used = \$false"
        $script:WorkloadSource | Should -Match "query = 'localhost'"
        $script:WorkloadSource | Should -Match 'controlled_gpu_workload_executed = \$false'
    }

    It 'keeps raw ETL and full dumper outside the review ZIP' {
        $script:CaptureSource | Should -Match 'raw_etl_in_review_zip = \$false'
        $script:CaptureSource | Should -Match 'full_xperf_dumper_in_review_zip = \$false'
        $script:CaptureSource | Should -Match 'Forbidden raw evidence entered SUPERBLOCK review ZIP'
    }

    It 'keeps event-header classification explicitly non-semantic' {
        $script:InventorySource | Should -Match 'event_name_implies_semantics = \$false'
        $script:InventorySource | Should -Match 'domain_hint_implies_semantics = \$false'
        $script:InventorySource | Should -Match "parser_completeness = 'not_claimed'"
    }

    It 'keeps all real-capture semantic promotions disabled' {
        foreach ($claim in @(
            'present_semantics',
            'gpu_queue_semantics',
            'network_connection_semantics',
            'network_latency_semantics',
            'kernel_lifecycle_semantics',
            'device_lifecycle_semantics'
        )) {
            $script:CaptureSource | Should -Match ($claim + ' = \$false')
        }
        $script:CaptureSource | Should -Match "trace_completeness = 'not_claimed'"
    }
}
