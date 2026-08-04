BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ModulePath = Join-Path $script:RepositoryRoot 'scripts\Nxb.EvidenceStore.psm1'
    Import-Module $script:ModulePath -Force
}

Describe 'NXB evidence canonical JSON' {
    It 'sorts object properties ordinally and preserves array order' {
        $inputObject = [ordered]@{
            z = 1
            list = @(3, "x`n", $false)
            a = [ordered]@{
                b = $true
                a = $null
            }
        }

        $canonical = ConvertTo-NxbCanonicalJson -InputObject $inputObject

        $canonical | Should -Be '{"a":{"a":null,"b":true},"list":[3,"x\n",false],"z":1}'
        (Get-NxbCanonicalJsonHash -InputObject $inputObject) |
            Should -Be '170f36671e659fda9fdc5237be36ae283a2e5a63c03029ce11cb6b4c17f839a7'
    }

    It 'produces the same bytes for different property insertion orders' {
        $first = [ordered]@{
            z = 1
            a = [ordered]@{ b = 2; a = 1 }
        }
        $second = [ordered]@{
            a = [ordered]@{ a = 1; b = 2 }
            z = 1
        }

        $firstJson = ConvertTo-NxbCanonicalJson -InputObject $first
        $secondJson = ConvertTo-NxbCanonicalJson -InputObject $second

        $firstJson | Should -Be $secondJson
        (Get-NxbCanonicalJsonHash -InputObject $first) |
            Should -Be (Get-NxbCanonicalJsonHash -InputObject $second)
    }

    It 'excludes only named root properties from the hash input' {
        $record = [ordered]@{
            record_sha256 = ('0' * 64)
            payload = [ordered]@{
                record_sha256 = 'nested-value'
            }
            sequence = 0
        }

        $canonical = ConvertTo-NxbCanonicalJson `
            -InputObject $record `
            -ExcludeRootProperty 'record_sha256'

        $canonical | Should -Be '{"payload":{"record_sha256":"nested-value"},"sequence":0}'
    }

    It 'changes the hash when array order changes' {
        $first = [ordered]@{ values = @(1, 2, 3) }
        $second = [ordered]@{ values = @(3, 2, 1) }

        (Get-NxbCanonicalJsonHash -InputObject $first) |
            Should -Not -Be (Get-NxbCanonicalJsonHash -InputObject $second)
    }

    It 'matches the standard SHA-256 vector for abc' {
        (Get-NxbSha256Hex -Text 'abc') |
            Should -Be 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    }

    It 'rejects floating-point values in hash-bearing JSON' {
        {
            ConvertTo-NxbCanonicalJson -InputObject ([ordered]@{ value = [double]1.5 })
        } | Should -Throw '*Floating-point value is not allowed*'
    }

    It 'writes canonical UTF-8 without BOM atomically' {
        $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
            'nxb-canonical-{0}' -f [guid]::NewGuid()
        )
        $outputPath = Join-Path $temporaryRoot 'record.json'

        try {
            Write-NxbCanonicalJsonAtomic `
                -Path $outputPath `
                -InputObject ([ordered]@{ text = 'Türkçe'; value = 7 }) `
                -Confirm:$false

            $bytes = [IO.File]::ReadAllBytes($outputPath)
            $bytes.Length | Should -BeGreaterThan 3
            $bytes[0] | Should -Be 0x7B
            [Text.UTF8Encoding]::new($false, $true).GetString($bytes) |
                Should -Be '{"text":"Türkçe","value":7}'
        }
        finally {
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }
}
