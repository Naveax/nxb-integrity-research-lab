$ErrorActionPreference = 'Stop'

Describe 'SUPERBLOCK 1 repeated semantic ON/OFF control contract' {
    BeforeAll {
        function Get-NxbSemanticControlTestRepositoryRoot {
            $root = [string]$env:NXB_SEMANTIC_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) {
                throw 'NXB_SEMANTIC_REPOSITORY_ROOT is required for semantic control tests.'
            }
            $fullRoot = [IO.Path]::GetFullPath($root)
            if (-not (Test-Path -LiteralPath $fullRoot -PathType Container)) {
                throw "NXB semantic-control repository root does not exist: $fullRoot"
            }
            return $fullRoot
        }
    }

    It 'keeps fixture build certification and analyzer repo-owned' {
        $root = Get-NxbSemanticControlTestRepositoryRoot
        foreach ($relative in @(
            'fixtures\superblock1-semantic-controls\main.cpp',
            'scripts\Invoke-NxbSuperblock1SemanticControlFixtureBuild.ps1',
            'scripts\Invoke-NxbSuperblock1SemanticControlCertification.ps1',
            'scripts\Invoke-NxbSuperblock1SemanticControlAnalysis.ps1',
            'tools\analyze_superblock1_semantic_controls.py'
        )) {
            Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf | Should -BeTrue
        }
    }

    It 'supports exactly the five intended control modes' {
        $root = Get-NxbSemanticControlTestRepositoryRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'fixtures\superblock1-semantic-controls\main.cpp') -Raw
        foreach ($mode in @('all_on','gpu_off','network_off','kernel_off','minimal')) {
            $source | Should -Match ([regex]::Escape('L"' + $mode + '"'))
        }
        $source | Should -Not -Match 'gpu_only|network_only|kernel_only'
    }

    It 'accepts receipt path plus optional mode and defaults to all_on' {
        $root = Get-NxbSemanticControlTestRepositoryRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'fixtures\superblock1-semantic-controls\main.cpp') -Raw
        $source | Should -Match ([regex]::Escape('argc != 2 && argc != 3'))
        $source | Should -Match ([regex]::Escape('FixtureMode mode = FixtureMode::AllOn'))
        $source | Should -Match ([regex]::Escape('ParseMode(argv[2], mode)'))
    }

    It 'uses hardware D3D11 and exactly 128 Presents without WARP' {
        $root = Get-NxbSemanticControlTestRepositoryRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'fixtures\superblock1-semantic-controls\main.cpp') -Raw
        $source | Should -Match 'kPresentCount\s*=\s*128'
        $source | Should -Match ([regex]::Escape('D3D_DRIVER_TYPE_HARDWARE'))
        $source | Should -Not -Match ([regex]::Escape('D3D_DRIVER_TYPE_WARP'))
        $source | Should -Match ([regex]::Escape('swap_chain->Present(0, 0)'))
        $source | Should -Match ([regex]::Escape('result.presents_succeeded == kPresentCount'))
    }

    It 'keeps network stimulus loopback-only and bounded' {
        $root = Get-NxbSemanticControlTestRepositoryRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'fixtures\superblock1-semantic-controls\main.cpp') -Raw
        $source | Should -Match ([regex]::Escape('GetAddrInfoW(L"localhost"'))
        $source | Should -Match ([regex]::Escape('INADDR_LOOPBACK'))
        $source | Should -Match 'kLoopbackBytes\s*=\s*64u\s*\*\s*1024u'
        $source | Should -Match 'kSocketTimeoutMilliseconds\s*=\s*5000'
        $source | Should -Not -Match 'https?://|www\.|8\.8\.8\.8|1\.1\.1\.1'
    }

    It 'keeps explicit kernel stimulus bounded and read-only for registry' {
        $root = Get-NxbSemanticControlTestRepositoryRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'fixtures\superblock1-semantic-controls\main.cpp') -Raw
        $source | Should -Match ([regex]::Escape('RegOpenCurrentUser(KEY_READ'))
        $source | Should -Match ([regex]::Escape('RegQueryInfoKeyW'))
        $source | Should -Not -Match 'RegSetValue|RegCreateKey|RegDeleteKey|RegDeleteValue'
        $source | Should -Match 'kFileBytes\s*=\s*64u\s*\*\s*1024u'
        $source | Should -Match 'kWorkerIterations\s*=\s*250000'
    }

    It 'tracks network and explicit kernel workers separately' {
        $root = Get-NxbSemanticControlTestRepositoryRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'fixtures\superblock1-semantic-controls\main.cpp') -Raw
        foreach ($name in @('network_server_thread_created','network_server_thread_joined','kernel_worker_thread_created','kernel_worker_thread_joined')) {
            $source | Should -Match ([regex]::Escape($name))
        }
    }

    It 'builds with direct MSVC and explicit Windows SDK resolution without cmd bootstrap' {
        $root = Get-NxbSemanticControlTestRepositoryRoot
        $build = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1SemanticControlFixtureBuild.ps1') -Raw
        $build | Should -Match ([regex]::Escape('Microsoft.VisualStudio.Component.VC.Tools.x86.x64'))
        $build | Should -Match ([regex]::Escape('KitsRoot10'))
        $build | Should -Match ([regex]::Escape('bin\Hostx64\x64\cl.exe'))
        $build | Should -Not -Match 'VsDevCmd\.bat|vcvars|capture-vs-environment|cmd\.exe'
    }

    It 'uses strict direct compiler arguments and required libraries' {
        $root = Get-NxbSemanticControlTestRepositoryRoot
        $build = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1SemanticControlFixtureBuild.ps1') -Raw
        foreach ($argument in @('/std:c++17','/EHsc','/W4','/WX','/O2','/DUNICODE','/D_UNICODE','/link')) {
            $build | Should -Match ([regex]::Escape("'$argument'"))
        }
        $build | Should -Match ([regex]::Escape('$buildOutput = @(& $compiler @compilerArguments 2>&1)'))
        foreach ($library in @('d3d11.lib','dxgi.lib','user32.lib','ws2_32.lib','advapi32.lib')) {
            $build | Should -Match ([regex]::Escape("'$library'"))
        }
    }

    It 'runs exactly ten alternating A-B control scenarios in one matrix' {
        $root = Get-NxbSemanticControlTestRepositoryRoot
        $cert = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1SemanticControlCertification.ps1') -Raw
        foreach ($id in @('all_on_a','gpu_off_a','network_off_a','kernel_off_a','minimal_a','minimal_b','kernel_off_b','network_off_b','gpu_off_b','all_on_b')) {
            $cert | Should -Match ([regex]::Escape("id='$id'"))
        }
        ([regex]::Matches($cert,"id='(?:all_on|gpu_off|network_off|kernel_off|minimal)_[ab]'",[Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count | Should -Be 10
    }

    It 'uses one owned WPR session and never cancels a pre-existing session' {
        $root = Get-NxbSemanticControlTestRepositoryRoot
        $cert = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1SemanticControlCertification.ps1') -Raw
        $cert | Should -Match ([regex]::Escape('$sessionOwned = $false'))
        $cert | Should -Match ([regex]::Escape('$sessionOwned = $true'))
        $cert | Should -Match ([regex]::Escape('if ($sessionOwned)'))
        $cert | Should -Match ([regex]::Escape('Pre-existing WPR sessions are never auto-cancelled.'))
        ([regex]::Matches($cert,'& \$wpr -start')).Count | Should -Be 1
        ([regex]::Matches($cert,'& \$wpr -stop')).Count | Should -Be 1
    }

    It 'validates every fixture receipt mode PID and stimulus flags' {
        $root = Get-NxbSemanticControlTestRepositoryRoot
        $cert = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1SemanticControlCertification.ps1') -Raw
        foreach ($needle in @("'mode'","'pid'","'stimulus_enabled.gpu'","'stimulus_enabled.network'","'stimulus_enabled.explicit_kernel'",'Fixture stimulus flags mismatch')) {
            $cert | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'normalizes the same dumper twice and requires byte-identical outputs' {
        $root = Get-NxbSemanticControlTestRepositoryRoot
        $cert = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1SemanticControlCertification.ps1') -Raw
        $cert | Should -Match ([regex]::Escape('$normalOne = & $normalizerScript'))
        $cert | Should -Match ([regex]::Escape('$normalTwo = & $normalizerScript'))
        $cert | Should -Match ([regex]::Escape('Semantic control normalization replay is not byte-identical.'))
    }

    It 'runs the differential analyzer twice and requires byte-identical summary replay' {
        $root = Get-NxbSemanticControlTestRepositoryRoot
        $cert = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1SemanticControlCertification.ps1') -Raw
        $cert | Should -Match ([regex]::Escape('$analysisOne = & $analysisScript'))
        $cert | Should -Match ([regex]::Escape('$analysisTwo = & $analysisScript'))
        $cert | Should -Match ([regex]::Escape('Semantic control analysis replay is not byte-identical.'))
    }

    It 'requires repeated exact Present start-stop counts in positive and negative controls' {
        $root = Get-NxbSemanticControlTestRepositoryRoot
        $tool = Get-Content -LiteralPath (Join-Path $root 'tools\analyze_superblock1_semantic_controls.py') -Raw
        $tool | Should -Match ([regex]::Escape('event_count(item, present_start) == 128'))
        $tool | Should -Match ([regex]::Escape('event_count(item, present_stop) == 128'))
        $tool | Should -Match ([regex]::Escape('event_count(item, present_start) == 0'))
        $tool | Should -Match ([regex]::Escape('event_count(item, present_stop) == 0'))
        $tool | Should -Match ([regex]::Escape('controlled_present_count_mapping_validated'))
    }

    It 'requires network positive and negative controls across both repetitions' {
        $root = Get-NxbSemanticControlTestRepositoryRoot
        $tool = Get-Content -LiteralPath (Join-Path $root 'tools\analyze_superblock1_semantic_controls.py') -Raw
        $tool | Should -Match ([regex]::Escape('network_positive = all('))
        $tool | Should -Match ([regex]::Escape('network_negative = all('))
        $tool | Should -Match ([regex]::Escape('family_count(item, "network:dns") > 0'))
        $tool | Should -Match ([regex]::Escape('family_count(item, "network:tcp") == 0'))
    }

    It 'keeps pairing timing causality kernel registry and generalization claims conservative' {
        $root = Get-NxbSemanticControlTestRepositoryRoot
        $tool = Get-Content -LiteralPath (Join-Path $root 'tools\analyze_superblock1_semantic_controls.py') -Raw
        foreach ($claim in @(
            'present_event_mapping_generalized','present_pairing_semantics','present_success_semantics',
            'kernel_lifecycle_semantics','registry_operation_semantics','timestamp_unit_resolved',
            'causal_relationship_validated','root_cause_validated'
        )) {
            $tool | Should -Match ([regex]::Escape('"' + $claim + '": False'))
        }
        $tool | Should -Match ([regex]::Escape('"explicit_stimulus_differential"'))
        $tool | Should -Match ([regex]::Escape('"trace_completeness": "not_claimed"'))
    }

    It 'forbids raw capture normalized manifest executable and WPR artifacts from review ZIP' {
        $root = Get-NxbSemanticControlTestRepositoryRoot
        $cert = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock1SemanticControlCertification.ps1') -Raw
        foreach ($forbidden in @('.etl','.exe','.obj','xperf-dumper','normalized-events','manifest','wpr-status','.wprp')) {
            $cert | Should -Match ([regex]::Escape($forbidden))
        }
        $cert | Should -Match ([regex]::Escape('Forbidden raw/local artifact entered review ZIP'))
    }
}
