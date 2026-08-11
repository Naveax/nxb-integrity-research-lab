$ErrorActionPreference = 'Stop'

Describe 'NXB IRL-005 adaptive observability panel security contract' {
    BeforeAll {
        function Get-NxbAdaptiveSecurityRoot {
            $root = [string]$env:NXB_ADAPTIVE_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_ADAPTIVE_REPOSITORY_ROOT is required.' }
            return [IO.Path]::GetFullPath($root)
        }
    }

    It 'generates a per-process 256-bit mutation token with cryptographic RNG' {
        $root = Get-NxbAdaptiveSecurityRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-NxbAdaptiveObservabilityPanel.ps1') -Raw
        $source | Should -Match ([regex]::Escape('$bytes = [byte[]]::new(32)'))
        $source | Should -Match ([regex]::Escape('[Security.Cryptography.RandomNumberGenerator]::Create()'))
        $source | Should -Match ([regex]::Escape('$processToken = Get-NxbPanelProcessToken'))
    }

    It 'injects the process token only into the served panel HTML placeholder' {
        $root = Get-NxbAdaptiveSecurityRoot
        $server = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-NxbAdaptiveObservabilityPanel.ps1') -Raw
        $html = Get-Content -LiteralPath (Join-Path $root 'ui\adaptive-observability-panel.html') -Raw
        $server | Should -Match ([regex]::Escape('$html.Replace(''__NXB_PANEL_TOKEN__'',$processToken)'))
        $html | Should -Match ([regex]::Escape('const PANEL_TOKEN=''__NXB_PANEL_TOKEN__'';'))
    }

    It 'requires X-NXB-Panel-Token for both mutating endpoints' {
        $root = Get-NxbAdaptiveSecurityRoot
        $server = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-NxbAdaptiveObservabilityPanel.ps1') -Raw
        $html = Get-Content -LiteralPath (Join-Path $root 'ui\adaptive-observability-panel.html') -Raw
        $server | Should -Match ([regex]::Escape('$Request.Headers[''X-NXB-Panel-Token'']'))
        @([regex]::Matches($server,[regex]::Escape('Test-NxbPanelMutationToken -Request $request -ExpectedToken $processToken'))).Count | Should -Be 2
        $html | Should -Match ([regex]::Escape('''X-NXB-Panel-Token'':PANEL_TOKEN'))
    }

    It 'rejects missing or incorrect mutation tokens with HTTP 403' {
        $root = Get-NxbAdaptiveSecurityRoot
        $server = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-NxbAdaptiveObservabilityPanel.ps1') -Raw
        @([regex]::Matches($server,[regex]::Escape('-StatusCode 403'))).Count | Should -Be 2
        $server | Should -Match ([regex]::Escape('{"error":"forbidden"}'))
    }

    It 'does not expose the process token through status or health responses' {
        $root = Get-NxbAdaptiveSecurityRoot
        $server = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-NxbAdaptiveObservabilityPanel.ps1') -Raw
        $statusStart = $server.IndexOf('function Get-NxbPanelStatus')
        $statusEnd = $server.IndexOf('$prefix = ''http://',$statusStart)
        ($statusStart -ge 0) | Should -BeTrue
        ($statusEnd -gt $statusStart) | Should -BeTrue
        $statusBody = $server.Substring($statusStart,$statusEnd-$statusStart)
        $statusBody | Should -Not -Match ([regex]::Escape('$processToken'))
        $server | Should -Match ([regex]::Escape('{"status":"ok","local_only":true}'))
    }
}
