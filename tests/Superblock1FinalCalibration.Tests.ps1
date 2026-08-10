$ErrorActionPreference = 'Stop'

Describe 'SUPERBLOCK 1 final calibration and claim-audit contract' {
    BeforeAll {
        function Get-NxbFinalTestRepositoryRoot {
            $root = [string]$env:NXB_SUPERBLOCK1_FINAL_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_SUPERBLOCK1_FINAL_REPOSITORY_ROOT is required.' }
            $full = [IO.Path]::GetFullPath($root)
            if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "Repository root missing: $full" }
            return $full
        }
    }

    It 'keeps the final runner and controlled fixture build repo-owned with analyzer-safe names' {
        $root = Get-NxbFinalTestRepositoryRoot
        foreach ($relative in @(
            'scripts\Invoke-NxbSuperblock1FinalCertification.ps1',
            'scripts\Invoke-NxbSuperblock1SemanticControlFixtureBuild.ps1',
            'fixtures\superblock1-semantic-controls\main.cpp',
            'scripts\Test-NxbSuperblock1MultiDomainWprProfile.ps1',
            'scripts\Get-NxbEtlTraceStatistics.ps1'
        )) {
            Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf | Should -BeTrue
        }
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1FinalCertification.ps1') -Raw
        $source | Should -Match ([regex]::Escape('$zipEntryMatches'))
        $source | Should -Match ([regex]::Escape('$profileContract'))
        $source | Should -Match ([regex]::Escape('function Get-NxbFinalDelta'))
        $source | Should -Not -Match ([regex]::Escape('$matches ='))
        $source | Should -Not -Match ([regex]::Escape('$profile ='))
        $source | Should -Not -Match ([regex]::Escape('function New-NxbFinalDelta'))
    }

    It 'requires exact clean HEAD before native work' {
        $root = Get-NxbFinalTestRepositoryRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1FinalCertification.ps1') -Raw
        $source | Should -Match ([regex]::Escape('rev-parse HEAD'))
        $source | Should -Match ([regex]::Escape('status --porcelain=v1 --untracked-files=all'))
        $source | Should -Match ([regex]::Escape('requires a clean exact-head worktree'))
    }

    It 'binds canonical Round 1 and Round 2 review hashes' {
        $root = Get-NxbFinalTestRepositoryRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1FinalCertification.ps1') -Raw
        $source | Should -Match '97922ba500a0f66d34a8b8cbda54b34aa7e871af3e3d68d81255bcd8bd39a150'
        $source | Should -Match 'c7dc5f723af5ea28903efc04a7f45391d7856f06f3d87f43ddc0627bcfafb98a'
        $source | Should -Match '4f4a55c34469dafcfde14f8fc9ae21efedf6457e19f26674bf25a4ff31eae20c'
    }

    It 'binds canonical capture normalization and correlation lineage' {
        $root = Get-NxbFinalTestRepositoryRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1FinalCertification.ps1') -Raw
        foreach ($sha in @(
            '57dd8a466509bd390b94ad8426b2af6dd56c1687',
            '7fd766d15faa9b2ca0197edf342a0f794f4d1f0b',
            '8bb94d10b4a74629668ddee2ad2fe378f8928999'
        )) { $source | Should -Match $sha }
    }

    It 'uses one warmup and exactly four measured paired trials' {
        $root = Get-NxbFinalTestRepositoryRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1FinalCertification.ps1') -Raw
        $source | Should -Match ([regex]::Escape('warmup_pair_count = 1'))
        $source | Should -Match ([regex]::Escape('measured_pair_count = 4'))
        $source | Should -Match ([regex]::Escape('Expected exactly four measured pairs.'))
    }

    It 'alternates control-first and instrumented-first measured pairs' {
        $root = Get-NxbFinalTestRepositoryRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1FinalCertification.ps1') -Raw
        ([regex]::Matches($source,"warmup=\$false; order='control_then_instrumented'")).Count | Should -Be 2
        ([regex]::Matches($source,"warmup=\$false; order='instrumented_then_control'")).Count | Should -Be 2
        $source | Should -Match ([regex]::Escape("ordering = 'alternating_control_instrumented'"))
    }

    It 'measures the same all_on fixture in both arms' {
        $root = Get-NxbFinalTestRepositoryRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1FinalCertification.ps1') -Raw
        $source | Should -Match ([regex]::Escape("'all_on'"))
        $source | Should -Match ([regex]::Escape('Invoke-NxbFinalMeasuredFixture'))
        $source | Should -Match ([regex]::Escape("workload = 'superblock1-semantic-controls all_on'"))
    }

    It 'requires hardware D3D11 128 Presents and bounded loopback receipts' {
        $root = Get-NxbFinalTestRepositoryRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1FinalCertification.ps1') -Raw
        foreach ($needle in @('gpu.hardware_device_created','gpu.present_calls_attempted','gpu.present_calls_succeeded','network.loopback_completed','network.bytes_sent','network.bytes_received')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
        $source | Should -Match ([regex]::Escape('-ne 128'))
        $source | Should -Match ([regex]::Escape('-ne 65536'))
    }

    It 'forbids external network and registry writes in every measured fixture' {
        $root = Get-NxbFinalTestRepositoryRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1FinalCertification.ps1') -Raw
        $source | Should -Match ([regex]::Escape('network.external_network_used'))
        $source | Should -Match ([regex]::Escape('kernel_stimulus.registry_write_executed'))
        $source | Should -Match ([regex]::Escape('Fixture used external network.'))
        $source | Should -Match ([regex]::Escape('Fixture performed a registry write.'))
    }

    It 'measures duration CPU working set and private bytes' {
        $root = Get-NxbFinalTestRepositoryRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1FinalCertification.ps1') -Raw
        foreach ($needle in @('duration_ms','cpu_time_ms','peak_working_set_bytes','peak_private_bytes','TotalProcessorTime','WorkingSet64','PrivateMemorySize64')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'checks same machine boot and active power policy throughout the protocol' {
        $root = Get-NxbFinalTestRepositoryRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1FinalCertification.ps1') -Raw
        foreach ($needle in @('Win32_OperatingSystem','LastBootUpTime','power_scheme_guid','Get-NxbActivePowerPolicy.ps1','identity changed')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'never auto-cancels a pre-existing WPR session' {
        $root = Get-NxbFinalTestRepositoryRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1FinalCertification.ps1') -Raw
        $source | Should -Match ([regex]::Escape('$sessionOwned = $false'))
        $source | Should -Match ([regex]::Escape('$sessionOwned = $true'))
        $source | Should -Match ([regex]::Escape('if ($sessionOwned)'))
        $source | Should -Match ([regex]::Escape('WPR start failed; pre-existing session untouched.'))
        $source | Should -Match ([regex]::Escape('Pre-existing WPR sessions are never auto-cancelled.'))
    }

    It 'requires every instrumented measured pair to be loss-free' {
        $root = Get-NxbFinalTestRepositoryRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1FinalCertification.ps1') -Raw
        foreach ($needle in @('events_lost','buffers_lost','buffers_written','Instrumented arm trace quality failed','instrumented_loss_free_pairs = 4')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'does not invent an overhead acceptance threshold' {
        $root = Get-NxbFinalTestRepositoryRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1FinalCertification.ps1') -Raw
        $source | Should -Match ([regex]::Escape("status = 'not_declared'"))
        $source | Should -Match ([regex]::Escape('representative_benchmark = $false'))
        $source | Should -Not -Match "threshold_policy\s*=\s*'passed'|threshold_policy\s*=\s*'failed'|acceptable_threshold"
    }

    It 'promotes only bounded controlled observability and replay claims' {
        $root = Get-NxbFinalTestRepositoryRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1FinalCertification.ps1') -Raw
        foreach ($claim in @('controlled_fixture_process','exact_fixture_pid_attribution','exact_pid_three_domain_observability','controlled_present_count_mapping_validated','controlled_network_activity_mapping_validated','bounded_paired_overhead_measured')) {
            $source | Should -Match ([regex]::Escape($claim + ' = $true'))
        }
    }

    It 'keeps pairing success kernel timing causality and root-cause semantics withheld' {
        $root = Get-NxbFinalTestRepositoryRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1FinalCertification.ps1') -Raw
        foreach ($claim in @('present_pairing_semantics','present_success_semantics','kernel_lifecycle_semantics','registry_operation_semantics','timestamp_unit_resolved','causal_relationship_validated','root_cause_validated','circular_overwrite_absence')) {
            $source | Should -Match ([regex]::Escape($claim + ' = $false'))
        }
    }

    It 'retains unknown circular-overwrite and not-claimed trace completeness boundaries' {
        $root = Get-NxbFinalTestRepositoryRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1FinalCertification.ps1') -Raw
        $source | Should -Match ([regex]::Escape("circular_overwrite = 'unknown'"))
        $source | Should -Match ([regex]::Escape("trace_completeness = 'not_claimed'"))
    }

    It 'keeps raw ETL binaries fixture receipts and normalized artifacts out of final review ZIP' {
        $root = Get-NxbFinalTestRepositoryRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1FinalCertification.ps1') -Raw
        foreach ($forbidden in @('.etl','.exe','.obj','.pdb','fixture-receipt','xperf','normalized','manifest','.wprp')) {
            $source | Should -Match ([regex]::Escape($forbidden))
        }
        $source | Should -Match ([regex]::Escape('Forbidden raw/local artifact entered final review ZIP'))
    }
}
