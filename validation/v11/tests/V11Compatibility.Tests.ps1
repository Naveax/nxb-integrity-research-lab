BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $script:EvidenceStorePath = Join-Path $script:RepositoryRoot 'scripts\Nxb.EvidenceStore.psm1'
    $script:SchemaPath = Join-Path $script:RepositoryRoot 'schemas\nxb-v11-python-dependency-lock.schema.json'
    $script:MaterializerPath = Join-Path $script:RepositoryRoot 'validation\v11\tools\materialize_python_requirements.py'
    $script:LauncherPath = Join-Path $script:RepositoryRoot 'validation\v11\tools\run_pinned_pip.py'
    $script:Lf = [string][char]10

    Import-Module $script:EvidenceStorePath -Force

    if (-not [string]::IsNullOrWhiteSpace($env:NXB_V11_PYTHON)) {
        $script:PythonPath = [IO.Path]::GetFullPath($env:NXB_V11_PYTHON)
    }
    else {
        $pythonCommand = Get-Command python -ErrorAction Stop
        $script:PythonPath = [IO.Path]::GetFullPath($pythonCommand.Source)
    }
    Test-Path -LiteralPath $script:PythonPath -PathType Leaf | Should -BeTrue

    function Write-Utf8NoBom {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
        )
        [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false, $true))
    }

    function New-TestPythonLock {
        param(
            [switch]$DuplicateName,
            [switch]$UnsortedTags
        )

        $hashA = (('a' * 64) -join '')
        $hashC = (('c' * 64) -join '')
        $hashD = (('d' * 64) -join '')
        $hashE = (('e' * 64) -join '')
        $commit = (('b' * 40) -join '')
        $firstTags = @(if ($UnsortedTags) { 'z-tag'; 'a-tag' } else { 'py3-none-any' })
        $secondName = if ($DuplicateName) { 'jsonschema' } else { 'pyyaml' }

        return [ordered]@{
            authority = 'nxb-v11-python-dependency-lock-v1'
            schema_version = 1
            python_full_version = '3.12.10'
            architecture = 'x64'
            platform_tag = 'win_amd64'
            generation_python_version = '3.12.10'
            generation_pip_version = '26.2.1'
            source_index_identity = 'https://pypi.org/simple'
            artifact_tree_profile = 'nxb-artifact-tree-manifest-v1'
            pip_bootstrap = [ordered]@{
                authority = 'nxb-v11-pip-bootstrap-v1'
                version = '26.2.1'
                artifact_name = 'pip-26.2.1-py3-none-any.whl'
                artifact_sha256 = $hashA
                source_project = 'pip'
                source_index_identity = 'https://pypi.org/simple'
                publisher_identity = 'PyPI Trusted Publishing'
                source_repository = 'https://github.com/pypa/pip'
                source_commit = $commit
                source_tag = 'refs/tags/26.2.1'
                provenance_subject_sha256 = $hashA
                python_requires = '>=3.10'
                artifact_tree_manifest_sha256 = $hashC
            }
            packages = @(
                [ordered]@{
                    normalized_name = 'jsonschema'
                    version = '4.26.0'
                    wheel_filename = 'jsonschema-4.26.0-py3-none-any.whl'
                    wheel_sha256 = $hashD
                    wheel_tags = $firstTags
                },
                [ordered]@{
                    normalized_name = $secondName
                    version = '6.0.3'
                    wheel_filename = 'PyYAML-6.0.3-cp312-cp312-win_amd64.whl'
                    wheel_sha256 = $hashE
                    wheel_tags = @('cp312-cp312-win_amd64')
                }
            )
        }
    }

    function Invoke-V11Python {
        param([Parameter(Mandatory = $true)][string[]]$Arguments)

        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = @(& $script:PythonPath @Arguments 2>&1 | ForEach-Object { [string]$_ })
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        return [pscustomobject]@{
            ExitCode = $exitCode
            Output = $output
            Text = ($output -join [Environment]::NewLine)
        }
    }

    function Save-EnvironmentSubset {
        $saved = @{}
        foreach ($item in Get-ChildItem Env:) {
            if ($item.Name -match '^(?i:PIP_)' -or $item.Name -in @('PYTHONPATH', 'PYTHONHOME')) {
                $saved[$item.Name] = [string]$item.Value
            }
        }
        return $saved
    }

    function Set-HermeticPipEnvironment {
        foreach ($item in @(Get-ChildItem Env:)) {
            if ($item.Name -match '^(?i:PIP_)' -or $item.Name -in @('PYTHONPATH', 'PYTHONHOME')) {
                Remove-Item -LiteralPath ('Env:{0}' -f $item.Name) -ErrorAction SilentlyContinue
            }
        }
        $env:PIP_CONFIG_FILE = 'NUL'
        $env:PIP_DISABLE_PIP_VERSION_CHECK = '1'
    }

    function Restore-EnvironmentSubset {
        param([Parameter(Mandatory = $true)][hashtable]$Saved)

        foreach ($item in @(Get-ChildItem Env:)) {
            if ($item.Name -match '^(?i:PIP_)' -or $item.Name -in @('PYTHONPATH', 'PYTHONHOME')) {
                Remove-Item -LiteralPath ('Env:{0}' -f $item.Name) -ErrorAction SilentlyContinue
            }
        }
        foreach ($name in $Saved.Keys) {
            Set-Item -LiteralPath ('Env:{0}' -f $name) -Value $Saved[$name]
        }
    }
}

Describe 'V11 A0 Python dependency authority' {
    It 'binds a strict shared Python dependency-lock schema' {
        $bytes = [IO.File]::ReadAllBytes($script:SchemaPath)
        $bytes.Length | Should -BeGreaterThan 0
        if ($bytes.Length -ge 3) {
            (@($bytes[0], $bytes[1], $bytes[2]) -join ',') | Should -Not -Be '239,187,191'
        }

        $schema = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) | ConvertFrom-Json
        [string]$schema.'$schema' | Should -BeExactly 'https://json-schema.org/draft/2020-12/schema'
        [string]$schema.'$id' | Should -BeExactly 'urn:nxb:schema:nxb-v11-python-dependency-lock:v1'
        [bool]$schema.additionalProperties | Should -BeFalse
        [string]$schema.properties.authority.const | Should -BeExactly 'nxb-v11-python-dependency-lock-v1'
        [string]$schema.'$defs'.pipBootstrap.properties.authority.const | Should -BeExactly 'nxb-v11-pip-bootstrap-v1'
        [bool]$schema.'$defs'.package.additionalProperties | Should -BeFalse
    }

    It 'materializes the exact deterministic requirements projection' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-projection-{0}' -f [Guid]::NewGuid().ToString('N'))
        $work = Join-Path $root 'work'
        [void][IO.Directory]::CreateDirectory($work)
        $lockPath = Join-Path $root 'lock.json'
        $output = Join-Path $work 'requirements.txt'

        try {
            $canonical = ConvertTo-NxbCanonicalJson -InputObject (New-TestPythonLock)
            Write-Utf8NoBom -Path $lockPath -Text $canonical

            $result = Invoke-V11Python -Arguments @(
                $script:MaterializerPath,
                '--lock', $lockPath,
                '--work-root', $work,
                '--output', $output
            )
            $result.ExitCode | Should -Be 0
            $result.Text | Should -Match '^NXB_V11_PYTHON_REQUIREMENTS_PROJECTION_PASS '

            $expected = (
                'jsonschema==4.26.0 --hash=sha256:' + (('d' * 64) -join '') + $script:Lf +
                'pyyaml==6.0.3 --hash=sha256:' + (('e' * 64) -join '') + $script:Lf
            )
            [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($output)) |
                Should -BeExactly $expected
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects non-canonical locks and duplicate package identity' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-projection-negative-{0}' -f [Guid]::NewGuid().ToString('N'))
        $work = Join-Path $root 'work'
        [void][IO.Directory]::CreateDirectory($work)

        try {
            $prettyPath = Join-Path $root 'pretty.json'
            $pretty = New-TestPythonLock | ConvertTo-Json -Depth 20
            Write-Utf8NoBom -Path $prettyPath -Text $pretty
            $prettyResult = Invoke-V11Python -Arguments @(
                $script:MaterializerPath,
                '--lock', $prettyPath,
                '--work-root', $work,
                '--output', (Join-Path $work 'pretty.txt')
            )
            $prettyResult.ExitCode | Should -Be 2
            $prettyResult.Text | Should -Match 'not NXB canonical JSON'

            $duplicatePath = Join-Path $root 'duplicate.json'
            $duplicate = ConvertTo-NxbCanonicalJson -InputObject (New-TestPythonLock -DuplicateName)
            Write-Utf8NoBom -Path $duplicatePath -Text $duplicate
            $duplicateResult = Invoke-V11Python -Arguments @(
                $script:MaterializerPath,
                '--lock', $duplicatePath,
                '--work-root', $work,
                '--output', (Join-Path $work 'duplicate.txt')
            )
            $duplicateResult.ExitCode | Should -Be 2
            $duplicateResult.Text | Should -Match 'duplicate normalized package name'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'runs only the exact pip package from the owned isolated bootstrap root' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-pinned-pip-{0}' -f [Guid]::NewGuid().ToString('N'))
        $work = Join-Path $root 'work'
        $bootstrap = Join-Path $work 'pip-bootstrap'
        $pipRoot = Join-Path $bootstrap 'pip'
        $distRoot = Join-Path $bootstrap 'pip-26.2.1.dist-info'
        [void][IO.Directory]::CreateDirectory($pipRoot)
        [void][IO.Directory]::CreateDirectory($distRoot)

        Write-Utf8NoBom -Path (Join-Path $pipRoot '__init__.py') -Text ('__version__ = "26.2.1"' + $script:Lf)
        Write-Utf8NoBom -Path (Join-Path $pipRoot '__main__.py') -Text (
            'import sys' + $script:Lf +
            'print("FAKE_PIP_MAIN " + " ".join(sys.argv[1:]))' + $script:Lf
        )
        Write-Utf8NoBom -Path (Join-Path $distRoot 'METADATA') -Text (
            'Metadata-Version: 2.1' + $script:Lf +
            'Name: pip' + $script:Lf +
            'Version: 26.2.1' + $script:Lf + $script:Lf
        )

        $saved = Save-EnvironmentSubset
        try {
            Set-HermeticPipEnvironment
            $result = Invoke-V11Python -Arguments @(
                '-I', '-S', $script:LauncherPath,
                '--work-root', $work,
                '--bootstrap-root', $bootstrap,
                '--runtime-root', (Split-Path -Parent $script:PythonPath),
                '--repository-root', $script:RepositoryRoot,
                '--expected-python-executable', $script:PythonPath,
                '--expected-version', '26.2.1',
                '--', '--version'
            )
            $result.ExitCode | Should -Be 0
            $result.Text | Should -Match 'FAKE_PIP_MAIN --version'
        }
        finally {
            Restore-EnvironmentSubset -Saved $saved
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects ambient pip source selectors before bootstrap execution' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-pinned-pip-env-{0}' -f [Guid]::NewGuid().ToString('N'))
        $work = Join-Path $root 'work'
        $bootstrap = Join-Path $work 'pip-bootstrap'
        $pipRoot = Join-Path $bootstrap 'pip'
        $distRoot = Join-Path $bootstrap 'pip-26.2.1.dist-info'
        [void][IO.Directory]::CreateDirectory($pipRoot)
        [void][IO.Directory]::CreateDirectory($distRoot)

        Write-Utf8NoBom -Path (Join-Path $pipRoot '__init__.py') -Text '__version__ = "26.2.1"'
        Write-Utf8NoBom -Path (Join-Path $pipRoot '__main__.py') -Text 'raise SystemExit(0)'
        Write-Utf8NoBom -Path (Join-Path $distRoot 'METADATA') -Text (
            'Metadata-Version: 2.1' + $script:Lf +
            'Name: pip' + $script:Lf +
            'Version: 26.2.1' + $script:Lf
        )

        $saved = Save-EnvironmentSubset
        try {
            Set-HermeticPipEnvironment
            $env:PIP_INDEX_URL = 'https://evil.invalid/simple'
            $result = Invoke-V11Python -Arguments @(
                '-I', '-S', $script:LauncherPath,
                '--work-root', $work,
                '--bootstrap-root', $bootstrap,
                '--runtime-root', (Split-Path -Parent $script:PythonPath),
                '--repository-root', $script:RepositoryRoot,
                '--expected-python-executable', $script:PythonPath,
                '--expected-version', '26.2.1',
                '--', '--version'
            )
            $result.ExitCode | Should -Be 2
            $result.Text | Should -Match 'ambient PIP_\* environment entries are forbidden'
        }
        finally {
            Restore-EnvironmentSubset -Saved $saved
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps projection and launcher implementations free of network/process substitution helpers' {
        $materializer = Get-Content -LiteralPath $script:MaterializerPath -Raw
        $launcher = Get-Content -LiteralPath $script:LauncherPath -Raw

        $materializer | Should -Not -Match '(?m)^\s*import\s+(subprocess|socket|urllib|http|requests)\b'
        $materializer | Should -Not -Match '\b(run|Popen|system)\s*\('
        $launcher | Should -Not -Match '(?m)^\s*import\s+(subprocess|socket|urllib|http|requests)\b'
        $launcher | Should -Not -Match '\b(subprocess|os\.system)\b'
    }
}
Describe 'V11 A0 supply-chain schema contracts' {
    BeforeAll {
        $script:ModuleLockSchemaPath = Join-Path $script:RepositoryRoot 'schemas\nxb-v11-powershell-module-lock.schema.json'
        $script:WheelhouseSchemaPath = Join-Path $script:RepositoryRoot 'schemas\nxb-v11-wheelhouse-manifest.schema.json'
        $script:InstalledSchemaPath = Join-Path $script:RepositoryRoot 'schemas\nxb-v11-installed-distribution-manifest.schema.json'
        $script:ModuleRootSchemaPath = Join-Path $script:RepositoryRoot 'schemas\nxb-v11-module-root-manifest.schema.json'

        function Read-Schema {
            param([Parameter(Mandatory = $true)][string]$Path)

            $bytes = [IO.File]::ReadAllBytes($Path)
            $bytes.Length | Should -BeGreaterThan 0
            if ($bytes.Length -ge 3) {
                (@($bytes[0], $bytes[1], $bytes[2]) -join ',') |
                    Should -Not -Be '239,187,191'
            }
            return [Text.UTF8Encoding]::new($false, $true).GetString($bytes) |
                ConvertFrom-Json
        }
    }

    It 'binds the PowerShell module lock v2 schema without recursive digest fields' {
        $schema = Read-Schema -Path $script:ModuleLockSchemaPath
        [string]$schema.'$id' |
            Should -BeExactly 'urn:nxb:schema:nxb-v11-powershell-module-lock:v2'
        [bool]$schema.additionalProperties | Should -BeFalse
        [string]$schema.properties.authority.const |
            Should -BeExactly 'nxb-v11-powershell-module-lock-v2'
        [int]$schema.properties.schema_version.const | Should -Be 2
        [int]$schema.properties.modules.minItems | Should -Be 2
        [int]$schema.properties.modules.maxItems | Should -Be 2
        [bool]$schema.'$defs'.module.additionalProperties | Should -BeFalse
        [string]$schema.'$defs'.module.properties.extracted_tree_profile.const |
            Should -BeExactly 'nxb-artifact-tree-manifest-v1'

        $rootPropertyNames = @($schema.properties.PSObject.Properties.Name)
        foreach ($forbidden in @(
            'powershell_module_lock_sha256',
            'validation_toolchain_lock_sha256',
            'compatibility_policy_sha256',
            'receipt_sha256'
        )) {
            $rootPropertyNames | Should -Not -Contain $forbidden
        }

        @($schema.'$defs'.module.properties.allowed_powershell_cells.items.enum) |
            Should -Be @('ps74-prev-lts', 'ps75-stable', 'ps76-primary')
    }

    It 'binds the wheelhouse manifest v1 schema to exact locked wheel bytes' {
        $schema = Read-Schema -Path $script:WheelhouseSchemaPath
        [string]$schema.'$id' |
            Should -BeExactly 'urn:nxb:schema:nxb-v11-wheelhouse-manifest:v1'
        [bool]$schema.additionalProperties | Should -BeFalse
        [string]$schema.properties.authority.const |
            Should -BeExactly 'nxb-v11-wheelhouse-manifest-v1'
        [bool]$schema.'$defs'.wheel.additionalProperties | Should -BeFalse
        [bool]$schema.'$defs'.wheel.properties.wheel_tags.uniqueItems | Should -BeTrue

        $required = @($schema.'$defs'.wheel.required)
        foreach ($name in @(
            'normalized_name',
            'version',
            'wheel_filename',
            'byte_length',
            'wheel_sha256',
            'wheel_tags'
        )) {
            $required | Should -Contain $name
        }
    }

    It 'binds the installed-distribution manifest v1 schema to RECORD-owned files' {
        $schema = Read-Schema -Path $script:InstalledSchemaPath
        [string]$schema.'$id' |
            Should -BeExactly 'urn:nxb:schema:nxb-v11-installed-distribution-manifest:v1'
        [bool]$schema.additionalProperties | Should -BeFalse
        [string]$schema.properties.authority.const |
            Should -BeExactly 'nxb-v11-installed-distribution-manifest-v1'
        [bool]$schema.'$defs'.distribution.additionalProperties | Should -BeFalse
        [bool]$schema.'$defs'.file.additionalProperties | Should -BeFalse

        $required = @($schema.'$defs'.distribution.required)
        foreach ($name in @(
            'source_wheel_filename',
            'source_wheel_sha256',
            'source_extracted_tree_sha256',
            'metadata_relative_path',
            'metadata_sha256',
            'record_relative_path',
            'record_sha256',
            'files'
        )) {
            $required | Should -Contain $name
        }
    }

    It 'binds the module-root manifest v1 schema without host absolute paths' {
        $schema = Read-Schema -Path $script:ModuleRootSchemaPath
        [string]$schema.'$id' |
            Should -BeExactly 'urn:nxb:schema:nxb-v11-module-root-manifest:v1'
        [bool]$schema.additionalProperties | Should -BeFalse
        [string]$schema.properties.authority.const |
            Should -BeExactly 'nxb-v11-module-root-manifest-v1'
        [bool]$schema.'$defs'.module.additionalProperties | Should -BeFalse

        $required = @($schema.'$defs'.module.required)
        foreach ($name in @(
            'normalized_name',
            'name',
            'version',
            'package_sha256',
            'module_manifest_relative',
            'module_manifest_sha256',
            'extracted_tree_sha256',
            'loaded_relative_path'
        )) {
            $required | Should -Contain $name
        }

        [string]$schema.'$defs'.relativePath.pattern | Should -Match '\(\?!/'
        [string]$schema.'$defs'.relativePath.pattern | Should -Match '\\\\'
    }
}