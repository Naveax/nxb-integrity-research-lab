BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:SmokeScript = Join-Path `
        $script:RepositoryRoot `
        'scripts\Test-TraceLossRepositorySmoke.ps1'
}

Describe 'NXB trace-loss repository smoke gate' {
    It 'validates the strict schema, canonical fixture and PowerShell parser surface' {
        { & $script:SmokeScript } | Should -Not -Throw
    }
}
