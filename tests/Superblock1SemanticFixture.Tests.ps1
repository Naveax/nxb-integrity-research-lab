$ErrorActionPreference = 'Stop'

Describe 'SUPERBLOCK 1 controlled same-PID semantic fixture contract' {
    BeforeAll {
        function Get-NxbSuperblock1SemanticFixtureTestContext {
            $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
            return [pscustomobject][ordered]@{
                root = $root
                source = Join-Path $root 'fixtures\superblock1-multidomain\main.cpp'
                build = Join-Path $root 'scripts\Invoke-NxbSuperblock1SemanticFixtureBuild.ps1'
                certification = Join-Path $root 'scripts\Invoke-NxbSuperblock1SemanticEligibilityCertification.ps1'
            }
        }
    }

    It 'keeps the native source build runner and certification repo-owned' {
        $context = Get-NxbSuperblock1SemanticFixtureTestContext
        Test-Path -LiteralPath $context.source -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $context.build -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $context.certification -PathType Leaf | Should -BeTrue
    }

    It 'uses hardware D3D11 without a WARP fallback' {
        $context = Get-NxbSuperblock1SemanticFixtureTestContext
        $sourceText = Get-Content -LiteralPath $context.source -Raw
        $sourceText | Should -Match ([regex]::Escape('D3D_DRIVER_TYPE_HARDWARE'))
        $sourceText | Should -Not -Match ([regex]::Escape('D3D_DRIVER_TYPE_WARP'))
        $sourceText | Should -Match ([regex]::Escape('D3D11CreateDeviceAndSwapChain'))
    }

    It 'bounds the Present stimulus' {
        $context = Get-NxbSuperblock1SemanticFixtureTestContext
        $sourceText = Get-Content -LiteralPath $context.source -Raw
        $sourceText | Should -Match 'constexpr\s+UINT\s+kPresentCount\s*=\s*128'
        $sourceText | Should -Match ([regex]::Escape('swap_chain->Present(0, 0)'))
    }

    It 'keeps network activity local bounded and timeout protected' {
        $context = Get-NxbSuperblock1SemanticFixtureTestContext
        $sourceText = Get-Content -LiteralPath $context.source -Raw
        $sourceText | Should -Match ([regex]::Escape('GetAddrInfoW(L"localhost"'))
        $sourceText | Should -Match ([regex]::Escape('INADDR_LOOPBACK'))
        $sourceText | Should -Not -Match 'https?://|www\.|8\.8\.8\.8|1\.1\.1\.1'
        $sourceText | Should -Match 'kLoopbackBytes\s*=\s*64u\s*\*\s*1024u'
        $sourceText | Should -Match 'kFileBytes\s*=\s*64u\s*\*\s*1024u'
        $sourceText | Should -Match 'kSocketTimeoutMilliseconds\s*=\s*5000'
        $sourceText | Should -Match ([regex]::Escape('select(0, &read_set'))
    }

    It 'performs registry reads without registry writes' {
        $context = Get-NxbSuperblock1SemanticFixtureTestContext
        $sourceText = Get-Content -LiteralPath $context.source -Raw
        $sourceText | Should -Match ([regex]::Escape('RegOpenCurrentUser(KEY_READ'))
        $sourceText | Should -Match ([regex]::Escape('RegQueryInfoKeyW'))
        $sourceText | Should -Not -Match 'RegSetValue|RegCreateKey|RegDeleteKey|RegDeleteValue'
        $sourceText | Should -Match 'registry_write_executed'
    }

    It 'joins bounded workers and removes the temporary file' {
        $context = Get-NxbSuperblock1SemanticFixtureTestContext
        $sourceText = Get-Content -LiteralPath $context.source -Raw
        $sourceText | Should -Match 'kWorkerIterations\s*=\s*250000'
        $sourceText | Should -Match ([regex]::Escape('worker.join()'))
        $sourceText | Should -Match ([regex]::Escape('server.join()'))
        $sourceText | Should -Match ([regex]::Escape('GetTempFileNameW'))
        $sourceText | Should -Match ([regex]::Escape('DeleteFileW(temp_file)'))
    }

    It 'records the owned PID and bounded stimulus counters' {
        $context = Get-NxbSuperblock1SemanticFixtureTestContext
        $sourceText = Get-Content -LiteralPath $context.source -Raw
        $sourceText | Should -Match ([regex]::Escape('GetCurrentProcessId()'))
        $sourceText | Should -Match 'present_calls_attempted'
        $sourceText | Should -Match 'present_calls_succeeded'
        $sourceText | Should -Match 'bytes_sent'
        $sourceText | Should -Match 'bytes_received'
    }

    It 'keeps ETW semantic and causal claims disabled' {
        $context = Get-NxbSuperblock1SemanticFixtureTestContext
        $sourceText = Get-Content -LiteralPath $context.source -Raw
        foreach ($claimName in @(
            'etw_event_mapping_validated',
            'present_semantics_validated',
            'network_semantics_validated',
            'kernel_semantics_validated',
            'causal_relationship_validated'
        )) {
            $sourceText | Should -Match ([regex]::Escape($claimName))
        }
    }

    It 'requires exact clean heads external output and owned-session cancellation only' {
        $context = Get-NxbSuperblock1SemanticFixtureTestContext
        $buildText = Get-Content -LiteralPath $context.build -Raw
        $certificationText = Get-Content -LiteralPath $context.certification -Raw
        foreach ($scriptText in @($buildText,$certificationText)) {
            $scriptText | Should -Match ([regex]::Escape('rev-parse HEAD'))
            $scriptText | Should -Match ([regex]::Escape('status --porcelain=v1 --untracked-files=all'))
        }
        $buildText | Should -Match ([regex]::Escape('build output must remain outside the repository worktree'))
        $certificationText | Should -Match ([regex]::Escape('output must remain outside the repository worktree'))
        $certificationText | Should -Match ([regex]::Escape('$sessionOwned = $false'))
        $certificationText | Should -Match ([regex]::Escape('$sessionOwned = $true'))
        $certificationText | Should -Match ([regex]::Escape('if ($sessionOwned)'))
        $certificationText | Should -Match ([regex]::Escape('& $wpr -cancel'))
        $certificationText | Should -Match ([regex]::Escape('no existing session was cancelled'))
    }

    It 'uses installed Visual Studio x64 tools with strict compiler warnings' {
        $context = Get-NxbSuperblock1SemanticFixtureTestContext
        $buildText = Get-Content -LiteralPath $context.build -Raw
        $buildText | Should -Match ([regex]::Escape('Microsoft.VisualStudio.Component.VC.Tools.x86.x64'))
        $buildText | Should -Match ([regex]::Escape('VsDevCmd.bat'))
        $buildText | Should -Match ([regex]::Escape('/W4 /WX'))
        $buildText | Should -Match ([regex]::Escape('/std:c++17'))
    }

    It 'requires same-PID three-domain attribution and deterministic replay' {
        $context = Get-NxbSuperblock1SemanticFixtureTestContext
        $certificationText = Get-Content -LiteralPath $context.certification -Raw
        $certificationText | Should -Match ([regex]::Escape('target_pid.domain_counts.gpu'))
        $certificationText | Should -Match ([regex]::Escape('target_pid.domain_counts.network'))
        $certificationText | Should -Match ([regex]::Escape('target_pid.domain_counts.kernel_lifecycle'))
        $certificationText | Should -Match ([regex]::Escape('$targetGpu -le 0 -or $targetNetwork -le 0 -or $targetKernel -le 0'))
        foreach ($name in @(
            'eventsOneSha','eventsTwoSha','coverageOneSha','coverageTwoSha',
            'recordsOneSha','recordsTwoSha','summaryOneSha','summaryTwoSha'
        )) {
            $certificationText | Should -Match ([regex]::Escape($name))
        }
        $certificationText | Should -Match ([regex]::Escape('not byte-identical'))
    }

    It 'keeps raw ETL dumper normalized rows and pair records out of review evidence' {
        $context = Get-NxbSuperblock1SemanticFixtureTestContext
        $certificationText = Get-Content -LiteralPath $context.certification -Raw
        foreach ($forbidden in @(
            '.etl','.exe','.obj','xperf-dumper','normalized-events','correlation-records','wpr-status','.wprp'
        )) {
            $certificationText | Should -Match ([regex]::Escape($forbidden))
        }
        $certificationText | Should -Match ([regex]::Escape('Forbidden raw/local artifact entered semantic review ZIP'))
    }
}
