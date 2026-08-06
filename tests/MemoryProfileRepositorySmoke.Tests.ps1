BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:SmokePath = Join-Path `
        $script:RepositoryRoot `
        'scripts\Test-MemoryProfileRepositorySmoke.ps1'
}

Describe 'NXB memory profile repository smoke' {
    It 'validates the committed memory profile foundation' {
        { & $script:SmokePath } | Should -Not -Throw
    }
}
