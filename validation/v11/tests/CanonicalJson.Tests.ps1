BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $script:EvidenceStorePath = Join-Path $script:RepositoryRoot 'scripts\Nxb.EvidenceStore.psm1'
    $script:CanonicalWrapperPath = Join-Path $script:RepositoryRoot 'validation\v11\scripts\ConvertTo-NxbV11CanonicalAuthority.ps1'
    $script:ExtractorPath = Join-Path $script:RepositoryRoot 'validation\v11\scripts\Expand-NxbV11VerifiedArchive.ps1'
    $script:SchemaPath = Join-Path $script:RepositoryRoot 'schemas\nxb-artifact-tree-manifest.schema.json'
    $script:CanonicalFixturePath = Join-Path $script:RepositoryRoot 'validation\v11\fixtures\canonical-json\conformance-v1.json'
    $script:ManifestFixturePath = Join-Path $script:RepositoryRoot 'validation\v11\fixtures\artifact-tree\manifest-valid.json'
    $script:ArchiveCasesPath = Join-Path $script:RepositoryRoot 'validation\v11\fixtures\verified-archive\cases-v1.json'

    Import-Module $script:EvidenceStorePath -Force

    function Get-TopLevelParameterName {
        param([Parameter(Mandatory = $true)][string]$Path)

        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $Path,
            [ref]$tokens,
            [ref]$errors
        )
        @($errors).Count | Should -Be 0
        $paramBlock = $ast.ParamBlock
        $paramBlock | Should -Not -BeNullOrEmpty
        return @($paramBlock.Parameters | ForEach-Object {
            [string]$_.Name.VariablePath.UserPath
        })
    }

    function Write-Utf8NoBom {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
        )

        [IO.File]::WriteAllText(
            $Path,
            $Text,
            [Text.UTF8Encoding]::new($false, $true)
        )
    }

    function ConvertFrom-V11TestJson {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
            [string]$Text,
            [int]$Depth = 20
        )

        process {
            $command = Get-Command ConvertFrom-Json -CommandType Cmdlet -ErrorAction Stop
            if ($command.Parameters.ContainsKey('Depth')) {
                $Text | ConvertFrom-Json -Depth $Depth
            }
            else {
                $Text | ConvertFrom-Json
            }
        }
    }
}

Describe 'V11 A0/S1 canonical bootstrap seed' {
    It 'preserves the frozen predecessor canonical JSON smoke vector' {
        $fixture = Get-Content -LiteralPath $script:CanonicalFixturePath -Raw |
            ConvertFrom-V11TestJson -Depth 20

        $inputObject = [ordered]@{
            z = 1
            list = @(3, "x`n", $false)
            a = [ordered]@{
                b = $true
                a = $null
            }
        }

        $canonical = ConvertTo-NxbCanonicalJson -InputObject $inputObject
        $canonical | Should -BeExactly ([string]$fixture.historical_smoke.expected_canonical)
        (Get-NxbSha256Hex -Text $canonical) |
            Should -BeExactly ([string]$fixture.historical_smoke.expected_sha256)
    }

    It 'keeps the extractor ABI at exactly nine mandatory named parameters' {
        $actual = @(Get-TopLevelParameterName -Path $script:ExtractorPath)
        $expected = @(
            'ArchivePath',
            'ArchiveKind',
            'DestinationRoot',
            'ExpectedSha256',
            'MaxEntries',
            'MaxEntryBytes',
            'MaxTotalBytes',
            'MaxCompressionRatio',
            'ResultPath'
        )

        $actual.Count | Should -Be $expected.Count
        for ($i = 0; $i -lt $expected.Count; $i++) {
            $actual[$i] | Should -BeExactly $expected[$i]
        }

        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $script:ExtractorPath,
            [ref]$tokens,
            [ref]$errors
        )
        @($errors).Count | Should -Be 0
        foreach ($parameter in $ast.ParamBlock.Parameters) {
            $parameter.Attributes.Count | Should -BeGreaterThan 0
            $parameter.Extent.Text | Should -Match 'Mandatory\s*=\s*\$true'
        }
    }

    It 'keeps the canonical wrapper ABI at exactly four mandatory named parameters' {
        $actual = @(Get-TopLevelParameterName -Path $script:CanonicalWrapperPath)
        $expected = @(
            'InputJsonPath',
            'OutputCanonicalJsonPath',
            'SchemaPath',
            'EvidenceStoreModulePath'
        )

        $actual.Count | Should -Be $expected.Count
        for ($i = 0; $i -lt $expected.Count; $i++) {
            $actual[$i] | Should -BeExactly $expected[$i]
        }
    }

    It 'accepts only the exact admitted LF or CRLF schema and EvidenceStore byte identities' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
        $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
            'nxb-v11-evidence-eol-{0}' -f [Guid]::NewGuid().ToString('N')
        )
        $schemasRoot = Join-Path $temporaryRoot 'schemas'
        $scriptsRoot = Join-Path $temporaryRoot 'scripts'
        [void][IO.Directory]::CreateDirectory($schemasRoot)
        [void][IO.Directory]::CreateDirectory($scriptsRoot)
        $temporarySchema = Join-Path $schemasRoot 'nxb-artifact-tree-manifest.schema.json'
        $temporaryModule = Join-Path $scriptsRoot 'Nxb.EvidenceStore.psm1'
        $output = Join-Path $temporaryRoot 'manifest.canonical.json'

        try {
            Copy-Item -LiteralPath $script:SchemaPath -Destination $temporarySchema
            $schemaBytes = [IO.File]::ReadAllBytes($script:SchemaPath)
            $schemaText = [Text.UTF8Encoding]::new($false, $true).GetString($schemaBytes)
            $schemaLfText = $schemaText.Replace("`r`n", "`n")
            $schemaCrlfText = $schemaLfText.Replace("`n", "`r`n")
            $moduleBytes = [IO.File]::ReadAllBytes($script:EvidenceStorePath)
            $moduleText = [Text.UTF8Encoding]::new($false, $true).GetString($moduleBytes)
            $lfText = $moduleText.Replace("`r`n", "`n")
            $crlfText = $lfText.Replace("`n", "`r`n")
            [IO.File]::WriteAllText(
                $temporarySchema,
                $schemaCrlfText,
                [Text.UTF8Encoding]::new($false, $true)
            )
            [IO.File]::WriteAllText(
                $temporaryModule,
                $crlfText,
                [Text.UTF8Encoding]::new($false, $true)
            )

            (Get-FileHash -LiteralPath $temporarySchema -Algorithm SHA256).Hash.ToLowerInvariant() |
                Should -BeExactly '8952dfcee0732679249d5de2a0e5eabacd8ab1cce2698974c6f5c48b322a4785'
            (Get-FileHash -LiteralPath $temporaryModule -Algorithm SHA256).Hash.ToLowerInvariant() |
                Should -BeExactly 'baa711b12592dff95d1155953f183454f44af31e72f61b05d6388add9555d4f3'

            & $script:CanonicalWrapperPath `
                -InputJsonPath $script:ManifestFixturePath `
                -OutputCanonicalJsonPath $output `
                -SchemaPath $temporarySchema `
                -EvidenceStoreModulePath $temporaryModule
            Test-Path -LiteralPath $output -PathType Leaf | Should -BeTrue

            Remove-Item -LiteralPath $output -Force
            [IO.File]::WriteAllText(
                $temporarySchema,
                $schemaLfText,
                [Text.UTF8Encoding]::new($false, $true)
            )
            [IO.File]::WriteAllText(
                $temporaryModule,
                $lfText,
                [Text.UTF8Encoding]::new($false, $true)
            )
            (Get-FileHash -LiteralPath $temporarySchema -Algorithm SHA256).Hash.ToLowerInvariant() |
                Should -BeExactly '208f84e22e7604c252a95307b5009acf7f524d89d51d609c96aed40b1bfe492f'
            (Get-FileHash -LiteralPath $temporaryModule -Algorithm SHA256).Hash.ToLowerInvariant() |
                Should -BeExactly '207a3e379e411fa6761f21cf01810135572d87033779ec8f791fa0befcd17cd7'

            & $script:CanonicalWrapperPath `
                -InputJsonPath $script:ManifestFixturePath `
                -OutputCanonicalJsonPath $output `
                -SchemaPath $temporarySchema `
                -EvidenceStoreModulePath $temporaryModule
            Test-Path -LiteralPath $output -PathType Leaf | Should -BeTrue

            Remove-Item -LiteralPath $output -Force
            [IO.File]::WriteAllText(
                $temporarySchema,
                ($schemaLfText + ' '),
                [Text.UTF8Encoding]::new($false, $true)
            )
            {
                & $script:CanonicalWrapperPath `
                    -InputJsonPath $script:ManifestFixturePath `
                    -OutputCanonicalJsonPath $output `
                    -SchemaPath $temporarySchema `
                    -EvidenceStoreModulePath $temporaryModule
            } | Should -Throw '*Schema raw SHA-256 drift*'
            Test-Path -LiteralPath $output | Should -BeFalse

            [IO.File]::WriteAllText(
                $temporarySchema,
                $schemaLfText,
                [Text.UTF8Encoding]::new($false, $true)
            )
            [IO.File]::WriteAllText(
                $temporaryModule,
                ($crlfText + '# byte drift'),
                [Text.UTF8Encoding]::new($false, $true)
            )
            {
                & $script:CanonicalWrapperPath `
                    -InputJsonPath $script:ManifestFixturePath `
                    -OutputCanonicalJsonPath $output `
                    -SchemaPath $temporarySchema `
                    -EvidenceStoreModulePath $temporaryModule
            } | Should -Throw '*EvidenceStore raw SHA-256 drift*'
            Test-Path -LiteralPath $output | Should -BeFalse
        }
        finally {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
            Import-Module $script:EvidenceStorePath -Force
        }
    }

    It 'rejects relative archive paths before extraction state is touched' {
        $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
            'nxb-v11-extractor-path-{0}' -f [Guid]::NewGuid().ToString('N')
        )
        [void][IO.Directory]::CreateDirectory($temporaryRoot)
        $resultPath = Join-Path $temporaryRoot 'result.json'
        $previousMaterializationRoot = [Environment]::GetEnvironmentVariable(
            'NXB_V11_MATERIALIZATION_ROOT',
            'Process'
        )
        [Environment]::SetEnvironmentVariable(
            'NXB_V11_MATERIALIZATION_ROOT',
            $temporaryRoot,
            'Process'
        )
        try {
            {
                & $script:ExtractorPath `
                    -ArchivePath 'relative.zip' `
                    -ArchiveKind 'python-wheel' `
                    -DestinationRoot $temporaryRoot `
                    -ExpectedSha256 ('0' * 64) `
                    -MaxEntries 1 `
                    -MaxEntryBytes 1 `
                    -MaxTotalBytes 1 `
                    -MaxCompressionRatio 1 `
                    -ResultPath $resultPath
            } | Should -Throw '*absolute normalized path*'
            Test-Path -LiteralPath $resultPath | Should -BeFalse
        }
        finally {
            [Environment]::SetEnvironmentVariable(
                'NXB_V11_MATERIALIZATION_ROOT',
                $previousMaterializationRoot,
                'Process'
            )
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'binds the exact artifact-tree schema contract markers' {
        $schemaBytes = [IO.File]::ReadAllBytes($script:SchemaPath)
        $schemaBytes.Length | Should -BeGreaterThan 0
        if ($schemaBytes.Length -ge 3) {
            @($schemaBytes[0], $schemaBytes[1], $schemaBytes[2]) -join ',' |
                Should -Not -Be '239,187,191'
        }

        $schema = [Text.UTF8Encoding]::new($false, $true).GetString($schemaBytes) |
            ConvertFrom-V11TestJson -Depth 20
        [string]$schema.'$schema' |
            Should -BeExactly 'https://json-schema.org/draft/2020-12/schema'
        [string]$schema.'$id' |
            Should -BeExactly 'urn:nxb:schema:nxb-artifact-tree-manifest:v1'
        [string]$schema.type | Should -BeExactly 'object'
        [bool]$schema.additionalProperties | Should -BeFalse
        [string]$schema.properties.contract_id.const |
            Should -BeExactly 'nxb-artifact-tree-manifest-v1'
    }

    It 'canonicalizes the admitted logical manifest through the predecessor primitive' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
        $fixture = Get-Content -LiteralPath $script:CanonicalFixturePath -Raw |
            ConvertFrom-V11TestJson -Depth 20
        $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
            'nxb-v11-canonical-{0}' -f [Guid]::NewGuid().ToString('N')
        )
        [void][IO.Directory]::CreateDirectory($temporaryRoot)
        $output = Join-Path $temporaryRoot 'manifest.canonical.json'

        try {
            & $script:CanonicalWrapperPath `
                -InputJsonPath $script:ManifestFixturePath `
                -OutputCanonicalJsonPath $output `
                -SchemaPath $script:SchemaPath `
                -EvidenceStoreModulePath $script:EvidenceStorePath

            $bytes = [IO.File]::ReadAllBytes($output)
            $bytes.Length | Should -BeGreaterThan 0
            $bytes[0] | Should -Be 0x7B
            $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
            $text | Should -BeExactly ([string]$fixture.artifact_tree_fixture.expected_canonical)
            (Get-NxbSha256Hex -InputBytes $bytes) |
                Should -BeExactly ([string]$fixture.artifact_tree_fixture.expected_sha256)
            $text.EndsWith("`n") | Should -BeFalse
            $text.EndsWith("`r") | Should -BeFalse
        }
        finally {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects duplicate raw JSON properties before object conversion can launder them' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
        $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
            'nxb-v11-duplicate-{0}' -f [Guid]::NewGuid().ToString('N')
        )
        [void][IO.Directory]::CreateDirectory($temporaryRoot)
        $inputPath = Join-Path $temporaryRoot 'duplicate.json'
        $output = Join-Path $temporaryRoot 'out.json'

        try {
            $raw = '{"contract_id":"nxb-artifact-tree-manifest-v1","contract_id":"nxb-artifact-tree-manifest-v1","root_role":"fixture-root","file_count":0,"total_bytes":0,"files":[]}'
            Write-Utf8NoBom -Path $inputPath -Text $raw

            {
                & $script:CanonicalWrapperPath `
                    -InputJsonPath $inputPath `
                    -OutputCanonicalJsonPath $output `
                    -SchemaPath $script:SchemaPath `
                    -EvidenceStoreModulePath $script:EvidenceStorePath
            } | Should -Throw '*duplicate property*'
            Test-Path -LiteralPath $output | Should -BeFalse
        }
        finally {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects artifact rows that are not strict ordinal UTF-8 path order' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
        $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
            'nxb-v11-order-{0}' -f [Guid]::NewGuid().ToString('N')
        )
        [void][IO.Directory]::CreateDirectory($temporaryRoot)
        $inputPath = Join-Path $temporaryRoot 'unsorted.json'
        $output = Join-Path $temporaryRoot 'out.json'

        try {
            $raw = '{"contract_id":"nxb-artifact-tree-manifest-v1","root_role":"fixture-root","file_count":2,"total_bytes":0,"files":[{"relative_path":"z.txt","byte_length":0,"sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},{"relative_path":"a.txt","byte_length":0,"sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}]}'
            Write-Utf8NoBom -Path $inputPath -Text $raw

            {
                & $script:CanonicalWrapperPath `
                    -InputJsonPath $inputPath `
                    -OutputCanonicalJsonPath $output `
                    -SchemaPath $script:SchemaPath `
                    -EvidenceStoreModulePath $script:EvidenceStorePath
            } | Should -Throw '*strict ordinal UTF-8 path order*'
            Test-Path -LiteralPath $output | Should -BeFalse
        }
        finally {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps hostile verified-archive names as fixture data rather than repository paths' {
        $fixture = Get-Content -LiteralPath $script:ArchiveCasesPath -Raw |
            ConvertFrom-V11TestJson -Depth 20

        [string]$fixture.profile |
            Should -BeExactly 'nxb-v11-verified-archive-fixture-cases-v1'
        @($fixture.valid).Count | Should -BeGreaterThan 0
        @($fixture.invalid).Count | Should -BeGreaterThan 5
        @($fixture.invalid | Where-Object { [string]$_.case -eq 'traversal' }).Count |
            Should -Be 1
        @($fixture.invalid | Where-Object { [string]$_.case -eq 'ads_colon' }).Count |
            Should -Be 1
        @($fixture.invalid | Where-Object { [string]$_.case -eq 'reserved_dos' }).Count |
            Should -Be 1
    }
}
