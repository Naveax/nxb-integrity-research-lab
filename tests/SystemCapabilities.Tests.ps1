BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsRoot = Join-Path $script:RepositoryRoot 'scripts'
}

Describe 'NXB full-system capability inventory' {
    BeforeEach {
        $script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("nxb-capability-{0}" -f [guid]::NewGuid())
        & (Join-Path $script:ScriptsRoot 'Initialize-Lab.ps1') `
            -Root $script:TempRoot `
            -Role Target | Out-Null

        $script:ExperimentPath = & (Join-Path $script:ScriptsRoot 'New-Experiment.ps1') `
            -Root $script:TempRoot `
            -Name 'Capability-Test' `
            -Hypothesis 'System domains are inventoried in a canonical document'
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force
        }
    }

    It 'creates a schema-versioned capability document' {
        $path = & (Join-Path $script:ScriptsRoot 'Get-SystemCapabilities.ps1') `
            -ExperimentPath $script:ExperimentPath

        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue

        $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $document.schema_version | Should -Be 1
        $document.machine_id | Should -Not -BeNullOrEmpty
        $document.computer_name | Should -Not -BeNullOrEmpty
        $document.captured_utc | Should -Not -BeNullOrEmpty
    }

    It 'contains every required system domain' {
        $path = & (Join-Path $script:ScriptsRoot 'Get-SystemCapabilities.ps1') `
            -ExperimentPath $script:ExperimentPath
        $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json

        $required = @(
            'operating_system',
            'cpu',
            'memory',
            'gpu',
            'storage',
            'network',
            'bus_and_devices',
            'firmware',
            'security',
            'power',
            'tooling'
        )

        foreach ($domain in $required) {
            $document.domains.PSObject.Properties.Name | Should -Contain $domain
            $document.domains.$domain.status |
                Should -BeIn @('available', 'partial', 'unavailable')
        }
    }

    It 'passes the Draft 2020-12 capability schema' {
        & (Join-Path $script:ScriptsRoot 'Get-SystemCapabilities.ps1') `
            -ExperimentPath $script:ExperimentPath | Out-Null

        {
            & (Join-Path $script:ScriptsRoot 'Test-SystemCapabilities.ps1') `
                -ExperimentPath $script:ExperimentPath
        } | Should -Not -Throw
    }

    It 'anchors the capability document into finalized evidence' {
        & (Join-Path $script:ScriptsRoot 'Get-SystemCapabilities.ps1') `
            -ExperimentPath $script:ExperimentPath | Out-Null

        & (Join-Path $script:ScriptsRoot 'Finalize-Experiment.ps1') `
            -ExperimentPath $script:ExperimentPath

        $evidence = Get-Content -LiteralPath (Join-Path $script:ExperimentPath 'evidence.sha256') -Raw
        $evidence | Should -Match 'baseline[\\/]system-capabilities\.json'
    }
}
