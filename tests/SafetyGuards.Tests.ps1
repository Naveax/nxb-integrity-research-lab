BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsRoot = Join-Path $script:RepositoryRoot 'scripts'
}

Describe 'NXB safety guards' {
    It 'rejects an untracked synthetic blocked artifact candidate' {
        $relativePath = "tests/.synthetic-{0}.dmp" -f [guid]::NewGuid().ToString('N')
        $fullPath = Join-Path $script:RepositoryRoot $relativePath

        try {
            'synthetic dump fixture' | Set-Content -LiteralPath $fullPath -Encoding Ascii

            {
                & (Join-Path $script:ScriptsRoot 'Test-PublicRepositoryContent.ps1') `
                    -RepositoryRoot $script:RepositoryRoot `
                    -AdditionalRelativePath $relativePath
            } | Should -Throw '*engellenmiş uzantı*'
        }
        finally {
            if (Test-Path -LiteralPath $fullPath) {
                Remove-Item -LiteralPath $fullPath -Force
            }
        }
    }

    It 'rejects a junction inside an experiment evidence tree' {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("nxb-reparse-{0}" -f [guid]::NewGuid())
        $junctionPath = $null

        try {
            & (Join-Path $script:ScriptsRoot 'Initialize-Lab.ps1') `
                -Root $tempRoot `
                -Role Target | Out-Null

            $experiment = & (Join-Path $script:ScriptsRoot 'New-Experiment.ps1') `
                -Root $tempRoot `
                -Name 'Reparse-Point-Test' `
                -Hypothesis 'Evidence collection rejects junction traversal'

            $externalPath = Join-Path $tempRoot 'external-evidence'
            New-Item -ItemType Directory -Path $externalPath -Force | Out-Null
            'outside experiment' |
                Set-Content -LiteralPath (Join-Path $externalPath 'outside.txt') -Encoding UTF8

            $junctionPath = Join-Path $experiment 'logs\external-junction'
            $command = "mklink /J `"$junctionPath`" `"$externalPath`""
            $output = & cmd.exe /d /c $command 2>&1
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                throw "Junction fixture oluşturulamadı (exit $exitCode): $($output -join [Environment]::NewLine)"
            }

            {
                & (Join-Path $script:ScriptsRoot 'Finalize-Experiment.ps1') `
                    -ExperimentPath $experiment
            } | Should -Throw '*Reparse point*'

            $manifest = Get-Content -LiteralPath (Join-Path $experiment 'manifest.json') -Raw |
                ConvertFrom-Json
            $manifest.status | Should -Be 'prepared'
        }
        finally {
            if ($null -ne $junctionPath -and (Test-Path -LiteralPath $junctionPath)) {
                & cmd.exe /d /c "rmdir `"$junctionPath`"" 2>&1 | Out-Null
            }

            if (Test-Path -LiteralPath $tempRoot) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }
}
