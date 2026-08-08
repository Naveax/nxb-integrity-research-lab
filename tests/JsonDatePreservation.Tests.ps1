BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:CommonModule = Join-Path `
        $script:RepositoryRoot `
        'scripts\Nxb.Lab.Common.psm1'
    Import-Module $script:CommonModule -Force
}

Describe 'NXB JSON date preservation' {
    BeforeEach {
        $script:TempRoot = Join-Path `
            ([IO.Path]::GetTempPath()) `
            ("nxb-json-date-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        $script:JsonPath = Join-Path $script:TempRoot 'document.json'
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force
        }
    }

    It 'keeps an ISO-8601 timestamp as a string on every supported edition' {
        $timestamp = '2026-08-05T19:38:24.0833668Z'
        $document = [ordered]@{
            started_utc = $timestamp
        }
        Write-NxbJsonAtomic `
            -Path $script:JsonPath `
            -InputObject $document `
            -Depth 4

        $roundTrip = Read-NxbJson -Path $script:JsonPath

        $roundTrip.started_utc.GetType().FullName |
            Should -Be 'System.String'
        $roundTrip.started_utc | Should -BeExactly $timestamp
    }
}
