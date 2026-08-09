$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $repositoryRoot 'fixtures\superblock1-multidomain\main.cpp'
$buildPath = Join-Path $repositoryRoot 'scripts\Invoke-NxbSuperblock1SemanticFixtureBuild.ps1'

Describe 'SUPERBLOCK 1 controlled same-PID semantic fixture contract' {
    It 'keeps the native source and build runner repo-owned' {
        Test-Path -LiteralPath $sourcePath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $buildPath -PathType Leaf | Should -BeTrue
    }

    It 'uses hardware D3D11 without a WARP fallback' {
        $sourceText = Get-Content -LiteralPath $sourcePath -Raw
        $sourceText | Should -Match ([regex]::Escape('D3D_DRIVER_TYPE_HARDWARE'))
        $sourceText | Should -Not -Match ([regex]::Escape('D3D_DRIVER_TYPE_WARP'))
        $sourceText | Should -Match ([regex]::Escape('D3D11CreateDeviceAndSwapChain'))
    }

    It 'bounds the Present stimulus' {
        $sourceText = Get-Content -LiteralPath $sourcePath -Raw
        $sourceText | Should -Match 'constexpr\s+UINT\s+kPresentCount\s*=\s*128'
        $sourceText | Should -Match ([regex]::Escape('swap_chain->Present(0, 0)'))
    }

    It 'uses only localhost and IPv4 loopback for the network stimulus' {
        $sourceText = Get-Content -LiteralPath $sourcePath -Raw
        $sourceText | Should -Match ([regex]::Escape('GetAddrInfoW(L"localhost"'))
        $sourceText | Should -Match ([regex]::Escape('INADDR_LOOPBACK'))
        $sourceText | Should -Match ([regex]::Escape('external_network_used\": false'))
    }

    It 'bounds the loopback payload and file payload' {
        $sourceText = Get-Content -LiteralPath $sourcePath -Raw
        $sourceText | Should -Match 'kLoopbackBytes\s*=\s*64u\s*\*\s*1024u'
        $sourceText | Should -Match 'kFileBytes\s*=\s*64u\s*\*\s*1024u'
    }

    It 'performs registry reads without registry writes' {
        $sourceText = Get-Content -LiteralPath $sourcePath -Raw
        $sourceText | Should -Match ([regex]::Escape('RegOpenCurrentUser(KEY_READ'))
        $sourceText | Should -Match ([regex]::Escape('RegQueryInfoKeyW'))
        $sourceText | Should -Not -Match 'RegSetValue|RegCreateKey|RegDeleteKey|RegDeleteValue'
        $sourceText | Should -Match ([regex]::Escape('registry_write_executed\": false'))
    }

    It 'creates and joins bounded worker threads' {
        $sourceText = Get-Content -LiteralPath $sourcePath -Raw
        $sourceText | Should -Match 'kWorkerIterations\s*=\s*250000'
        $sourceText | Should -Match ([regex]::Escape('worker.join()'))
        $sourceText | Should -Match ([regex]::Escape('server.join()'))
    }

    It 'deletes the bounded temporary file' {
        $sourceText = Get-Content -LiteralPath $sourcePath -Raw
        $sourceText | Should -Match ([regex]::Escape('GetTempFileNameW'))
        $sourceText | Should -Match ([regex]::Escape('DeleteFileW(temp_file)'))
    }

    It 'records the owned process PID and stimulus counters' {
        $sourceText = Get-Content -LiteralPath $sourcePath -Raw
        $sourceText | Should -Match ([regex]::Escape('GetCurrentProcessId()'))
        $sourceText | Should -Match ([regex]::Escape('present_calls_attempted'))
        $sourceText | Should -Match ([regex]::Escape('bytes_sent'))
        $sourceText | Should -Match ([regex]::Escape('bytes_received'))
    }

    It 'keeps ETW and causal semantics disabled in the fixture receipt' {
        $sourceText = Get-Content -LiteralPath $sourcePath -Raw
        foreach ($literal in @(
            'etw_event_mapping_validated\": false',
            'present_semantics_validated\": false',
            'network_semantics_validated\": false',
            'kernel_semantics_validated\": false',
            'causal_relationship_validated\": false'
        )) {
            $sourceText | Should -Match ([regex]::Escape($literal))
        }
    }

    It 'requires an exact clean head and external build directory' {
        $buildText = Get-Content -LiteralPath $buildPath -Raw
        $buildText | Should -Match ([regex]::Escape('rev-parse HEAD'))
        $buildText | Should -Match ([regex]::Escape('status --porcelain=v1 --untracked-files=all'))
        $buildText | Should -Match ([regex]::Escape('build output must remain outside the repository worktree'))
    }

    It 'uses the installed Visual Studio C++ x64 environment and strict compiler warnings' {
        $buildText = Get-Content -LiteralPath $buildPath -Raw
        $buildText | Should -Match ([regex]::Escape('Microsoft.VisualStudio.Component.VC.Tools.x86.x64'))
        $buildText | Should -Match ([regex]::Escape('VsDevCmd.bat'))
        $buildText | Should -Match ([regex]::Escape('/W4 /WX'))
        $buildText | Should -Match ([regex]::Escape('/std:c++17'))
    }
}
