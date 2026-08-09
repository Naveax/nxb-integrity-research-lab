$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $repositoryRoot 'fixtures\superblock1-multidomain\main.cpp'
$buildPath = Join-Path $repositoryRoot 'scripts\Invoke-NxbSuperblock1SemanticFixtureBuild.ps1'
$certificationPath = Join-Path $repositoryRoot 'scripts\Invoke-NxbSuperblock1SemanticEligibilityCertificationV2.ps1'

Describe 'SUPERBLOCK 1 controlled same-PID semantic fixture V2 contract' {
    It 'keeps source build and V2 certification repo-owned' {
        Test-Path -LiteralPath $sourcePath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $buildPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $certificationPath -PathType Leaf | Should -BeTrue
    }

    It 'uses hardware D3D11 without WARP fallback' {
        $sourceText = Get-Content -LiteralPath $sourcePath -Raw
        $sourceText | Should -Match ([regex]::Escape('D3D_DRIVER_TYPE_HARDWARE'))
        $sourceText | Should -Not -Match ([regex]::Escape('D3D_DRIVER_TYPE_WARP'))
        $sourceText | Should -Match ([regex]::Escape('D3D11CreateDeviceAndSwapChain'))
    }

    It 'bounds Present loopback file and socket waits' {
        $sourceText = Get-Content -LiteralPath $sourcePath -Raw
        $sourceText | Should -Match 'kPresentCount\s*=\s*128'
        $sourceText | Should -Match 'kLoopbackBytes\s*=\s*64u\s*\*\s*1024u'
        $sourceText | Should -Match 'kFileBytes\s*=\s*64u\s*\*\s*1024u'
        $sourceText | Should -Match 'kSocketTimeoutMilliseconds\s*=\s*5000'
        $sourceText | Should -Match ([regex]::Escape('swap_chain->Present(0, 0)'))
        $sourceText | Should -Match ([regex]::Escape('select(0, &read_set'))
    }

    It 'keeps the network stimulus localhost-only' {
        $sourceText = Get-Content -LiteralPath $sourcePath -Raw
        $sourceText | Should -Match ([regex]::Escape('GetAddrInfoW(L"localhost"'))
        $sourceText | Should -Match ([regex]::Escape('INADDR_LOOPBACK'))
        $sourceText | Should -Not -Match 'https?://|www\.|8\.8\.8\.8|1\.1\.1\.1'
    }

    It 'performs registry reads without registry writes' {
        $sourceText = Get-Content -LiteralPath $sourcePath -Raw
        $sourceText | Should -Match ([regex]::Escape('RegOpenCurrentUser(KEY_READ'))
        $sourceText | Should -Match ([regex]::Escape('RegQueryInfoKeyW'))
        $sourceText | Should -Not -Match 'RegSetValue|RegCreateKey|RegDeleteKey|RegDeleteValue'
    }

    It 'uses strict x64 MSVC compilation' {
        $buildText = Get-Content -LiteralPath $buildPath -Raw
        $buildText | Should -Match ([regex]::Escape('Microsoft.VisualStudio.Component.VC.Tools.x86.x64'))
        $buildText | Should -Match ([regex]::Escape('VsDevCmd.bat'))
        $buildText | Should -Match ([regex]::Escape('/W4 /WX'))
        $buildText | Should -Match ([regex]::Escape('/std:c++17'))
    }

    It 'does not assign to the automatic Profile variable' {
        $certificationText = Get-Content -LiteralPath $certificationPath -Raw
        $certificationText | Should -Not -Match '(?im)^\s*\$profile\s*='
        $certificationText | Should -Match '\$profileContract\s*='
    }

    It 'uses controlled JSON boolean conversion' {
        $certificationText = Get-Content -LiteralPath $certificationPath -Raw
        $certificationText | Should -Match ([regex]::Escape('function ConvertTo-NxbSemanticBoolean'))
        $certificationText | Should -Match ([regex]::Escape('[bool]::TryParse'))
        $certificationText | Should -Not -Match '\[bool\]\$fixtureReceipt\.'
    }

    It 'uses StrictMode-safe nested property access for optional counts' {
        $certificationText = Get-Content -LiteralPath $certificationPath -Raw
        $certificationText | Should -Match ([regex]::Escape('function Get-NxbSemanticProperty'))
        $certificationText | Should -Match ([regex]::Escape("'target_pid.domain_counts.gpu'"))
        $certificationText | Should -Match ([regex]::Escape('-DefaultValue 0'))
    }

    It 'quotes the fixture receipt argument explicitly' {
        $certificationText = Get-Content -LiteralPath $certificationPath -Raw
        $certificationText | Should -Match '\$fixtureReceiptArgument\s*='
        $certificationText | Should -Match ([regex]::Escape('-ArgumentList @($fixtureReceiptArgument)'))
    }

    It 'never auto-cancels a pre-existing WPR session' {
        $certificationText = Get-Content -LiteralPath $certificationPath -Raw
        $certificationText | Should -Match ([regex]::Escape('$sessionOwned = $false'))
        $certificationText | Should -Match ([regex]::Escape('$sessionOwned = $true'))
        $certificationText | Should -Match ([regex]::Escape('if ($sessionOwned)'))
        $certificationText | Should -Match ([regex]::Escape('Cancelling only the WPR session started and owned'))
    }

    It 'requires all three fixture PID domains to be positive' {
        $certificationText = Get-Content -LiteralPath $certificationPath -Raw
        $certificationText | Should -Match '\$targetGpu\s*-le\s*0'
        $certificationText | Should -Match '\$targetNetwork\s*-le\s*0'
        $certificationText | Should -Match '\$targetKernel\s*-le\s*0'
    }

    It 'requires deterministic normalization and correlation replay' {
        $certificationText = Get-Content -LiteralPath $certificationPath -Raw
        $certificationText | Should -Match ([regex]::Escape('Semantic normalization replay is not byte-identical.'))
        $certificationText | Should -Match ([regex]::Escape('Semantic correlation replay is not byte-identical.'))
    }

    It 'keeps semantic causal and completeness claims conservative' {
        $certificationText = Get-Content -LiteralPath $certificationPath -Raw
        foreach ($claimName in @(
            'present_event_mapping_validated',
            'present_pairing_semantics',
            'tcp_connection_lifecycle_validated',
            'causal_relationship_validated',
            'root_cause_validated'
        )) {
            $certificationText | Should -Match ([regex]::Escape($claimName))
        }
        $certificationText | Should -Match ([regex]::Escape("trace_completeness = 'not_claimed'"))
    }

    It 'forbids raw ETL dumper normalized rows and pair records from the review ZIP' {
        $certificationText = Get-Content -LiteralPath $certificationPath -Raw
        foreach ($forbiddenName in @('.etl','xperf-dumper','normalized-events','correlation-records','wpr-status','.wprp')) {
            $certificationText | Should -Match ([regex]::Escape($forbiddenName))
        }
    }
}