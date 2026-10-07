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

    It 'rejects wheel name, version, tag and pip-bootstrap substitution' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-wheel-negative-{0}' -f [Guid]::NewGuid().ToString('N'))
        $work = Join-Path $root 'work'
        [void][IO.Directory]::CreateDirectory($work)

        try {
            foreach ($variant in @('name', 'version', 'tags', 'bootstrap')) {
                $lock = New-TestPythonLock
                switch ($variant) {
                    'name' {
                        $lock.packages[0].wheel_filename = 'rogue-4.26.0-py3-none-any.whl'
                        $pattern = 'wheel distribution name'
                    }
                    'version' {
                        $lock.packages[0].wheel_filename = 'jsonschema-4.27.0-py3-none-any.whl'
                        $pattern = 'wheel version'
                    }
                    'tags' {
                        $lock.packages[0].wheel_tags = @('cp312-cp312-win_amd64')
                        $pattern = 'wheel tags'
                    }
                    'bootstrap' {
                        $lock.pip_bootstrap.artifact_name = 'rogue-26.2.1-py3-none-any.whl'
                        $pattern = 'pip bootstrap wheel distribution/version'
                    }
                }
                $lockPath = Join-Path $root ($variant + '.lock')
                $output = Join-Path $work ($variant + '.txt')
                Write-Utf8NoBom -Path $lockPath -Text (ConvertTo-NxbCanonicalJson -InputObject $lock)
                $result = Invoke-V11Python -Arguments @(
                    $script:MaterializerPath, '--lock', $lockPath,
                    '--work-root', $work, '--output', $output
                )
                $result.ExitCode | Should -Be 2
                $result.Text | Should -Match $pattern
                Test-Path -LiteralPath $output | Should -BeFalse
            }
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'accepts complete expanded PEP 427 wheel tags' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-wheel-expanded-{0}' -f [Guid]::NewGuid().ToString('N'))
        $work = Join-Path $root 'work'
        [void][IO.Directory]::CreateDirectory($work)

        try {
            $lock = New-TestPythonLock
            $lock.packages[0].wheel_filename = 'jsonschema-4.26.0-py2.py3-none-any.whl'
            $lock.packages[0].wheel_tags = @('py2-none-any', 'py3-none-any')
            $lockPath = Join-Path $root 'expanded.lock'
            $output = Join-Path $work 'expanded.txt'
            Write-Utf8NoBom -Path $lockPath -Text (ConvertTo-NxbCanonicalJson -InputObject $lock)
            $result = Invoke-V11Python -Arguments @(
                $script:MaterializerPath, '--lock', $lockPath,
                '--work-root', $work, '--output', $output
            )
            $result.ExitCode | Should -Be 0
            $result.Text | Should -Match 'NXB_V11_PYTHON_REQUIREMENTS_PROJECTION_PASS'
            Test-Path -LiteralPath $output | Should -BeTrue
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

Describe 'V11 native-impact classifier' {
    BeforeAll {
        $script:ImpactPolicyPath = Join-Path $script:RepositoryRoot 'config\nxb-native-impact-policy.json'
        $script:ImpactSchemaPath = Join-Path $script:RepositoryRoot 'schemas\nxb-native-impact-policy.schema.json'
        $script:ImpactToolPath = Join-Path $script:RepositoryRoot 'validation\v11\tools\classify_native_impact.py'
        $script:ImpactFixturePath = Join-Path $script:RepositoryRoot 'validation\v11\fixtures\native-impact-classifier\cases-v1.json'
    }

    It 'keeps the native-impact policy canonical, strict and fail-closed by default' {
        $policyBytes = [IO.File]::ReadAllBytes($script:ImpactPolicyPath)
        $policyText = [Text.UTF8Encoding]::new($false, $true).GetString($policyBytes)
        $policy = $policyText | ConvertFrom-Json
        (ConvertTo-NxbCanonicalJson -InputObject $policy) | Should -BeExactly $policyText
        $policyText.EndsWith([string][char]10) | Should -BeFalse

        [string]$policy.authority | Should -BeExactly 'nxb-native-impact-policy-v1'
        [int]$policy.schema_version | Should -Be 1
        @($policy.classification_precedence) |
            Should -Be @('native_required', 'hosted_authority_only', 'non_authority_metadata')
        @($policy.forbidden_broad_patterns) | Should -Contain 'docs/**'
        @($policy.forbidden_broad_patterns) | Should -Contain '*.md'
        @($policy.native_roots | Where-Object { [string]$_.path -eq 'validation/v11/tools/' }).Count |
            Should -Be 1
        @($policy.hosted_authority_only_roots | Where-Object { [string]$_.path -eq 'docs/hosted-authority-fixture/' }).Count |
            Should -Be 1
        @($policy.non_authority_metadata_roots | Where-Object { [string]$_.path -eq 'docs/non-authority-fixture/' }).Count |
            Should -Be 1

        $schema = Get-Content -LiteralPath $script:ImpactSchemaPath -Raw | ConvertFrom-Json
        [string]$schema.'$id' | Should -BeExactly 'urn:nxb:schema:nxb-native-impact-policy:v1'
        [bool]$schema.additionalProperties | Should -BeFalse
        [string]$schema.properties.authority.const | Should -BeExactly 'nxb-native-impact-policy-v1'
        [bool]$schema.'$defs'.rootRule.additionalProperties | Should -BeFalse
        [bool]$schema.'$defs'.edge.additionalProperties | Should -BeFalse
    }

    It 'matches every native-impact fixture decision deterministically' {
        $fixtures = Get-Content -LiteralPath $script:ImpactFixturePath -Raw |
            ConvertFrom-Json
        [string]$fixtures.authority |
            Should -BeExactly 'nxb-native-impact-classifier-fixtures-v1'
        @($fixtures.cases).Count | Should -BeGreaterOrEqual 12

        $root = Join-Path ([IO.Path]::GetTempPath()) (
            'nxb-v11-impact-{0}' -f [Guid]::NewGuid().ToString('N')
        )
        [void][IO.Directory]::CreateDirectory($root)
        $seenIds = @{}

        try {
            $index = 0
            foreach ($case in @($fixtures.cases)) {
                $id = [string]$case.id
                $seenIds.ContainsKey($id) | Should -BeFalse
                $seenIds[$id] = $true

                $inputObject = [ordered]@{
                    authority = 'nxb-native-impact-classification-input-v1'
                    schema_version = 1
                    repository = [string]$fixtures.repository
                    base_sha = [string]$fixtures.base_sha
                    head_sha = [string]$fixtures.head_sha
                    merge_base_sha = [string]$fixtures.merge_base_sha
                    changed_paths = @($case.changes)
                    base_dependency_edges = @($case.base_dependency_edges)
                    candidate_dependency_edges = @($case.candidate_dependency_edges)
                }

                $inputPath = Join-Path $root ('case-{0}.input.json' -f $index)
                $outputPath = Join-Path $root ('case-{0}.output.json' -f $index)
                Write-Utf8NoBom -Path $inputPath -Text (
                    ConvertTo-NxbCanonicalJson -InputObject $inputObject
                )

                $run = Invoke-V11Python -Arguments @(
                    $script:ImpactToolPath,
                    '--policy', $script:ImpactPolicyPath,
                    '--input', $inputPath,
                    '--output', $outputPath
                )
                $run.ExitCode | Should -Be 0
                Test-Path -LiteralPath $outputPath -PathType Leaf | Should -BeTrue

                $resultText = Get-Content -LiteralPath $outputPath -Raw
                $result = $resultText | ConvertFrom-Json
                (ConvertTo-NxbCanonicalJson -InputObject $result) |
                    Should -BeExactly $resultText
                [string]$result.authority |
                    Should -BeExactly 'nxb-native-impact-classification-v1'
                [string]$result.impact_class |
                    Should -BeExactly ([string]$case.expected_impact_class)
                [string]$result.decision_kind |
                    Should -BeExactly ([string]$case.expected_decision_kind)
                [int]$result.unmatched_path_count |
                    Should -Be ([int]$case.expected_unmatched_path_count)
                ([string]$result.impact_policy_sha256) |
                    Should -Match '^[0-9a-f]{64}$'
                ([string]$result.impact_graph_sha256) |
                    Should -Match '^[0-9a-f]{64}$'
                ([string]$result.changed_path_set_sha256) |
                    Should -Match '^[0-9a-f]{64}$'
                $index++
            }

            foreach ($requiredId in @(
                'workflow-change',
                'hosted-only-fixture',
                'non-authority-fixture-script-extension',
                'dependency-closure-indirect-json',
                'rename-safe-to-native',
                'rename-native-to-safe',
                'delete-native',
                'mixed-safe-native',
                'unknown-new-file',
                'base-edge-removed-candidate',
                'classifier-self-change',
                'symlink-shape'
            )) {
                $seenIds.ContainsKey($requiredId) | Should -BeTrue
            }
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps the classifier core free of network and child-process execution' {
        $source = Get-Content -LiteralPath $script:ImpactToolPath -Raw
        $source | Should -Not -Match '(?m)^\s*import\s+(subprocess|socket|urllib|http|requests)\b'
        $source | Should -Not -Match '\b(subprocess|os\.system|Popen)\b'
        $source | Should -Match 'unknown_unclassified_path'
        $source | Should -Match 'native_dependency_closure'
    }
}


Describe 'V11 successor known-error scanner' {
    BeforeAll {
        $script:KnownErrorPolicyPath = Join-Path $script:RepositoryRoot 'config\nxb-v11-known-error-signatures.json'
        $script:KnownErrorPolicySchemaPath = Join-Path $script:RepositoryRoot 'schemas\nxb-v11-known-error-signatures.schema.json'
        $script:KnownErrorScanSchemaPath = Join-Path $script:RepositoryRoot 'schemas\nxb-v11-known-error-scan.schema.json'
        $script:KnownErrorToolPath = Join-Path $script:RepositoryRoot 'validation\v11\tools\scan_v11_known_errors.py'
        $script:KnownErrorFixturePath = Join-Path $script:RepositoryRoot 'validation\v11\fixtures\known-error\cases-v1.json'
    }

    It 'keeps signature policy canonical and forbids failure override' {
        $policyBytes = [IO.File]::ReadAllBytes($script:KnownErrorPolicyPath)
        $policyText = [Text.UTF8Encoding]::new($false, $true).GetString($policyBytes)
        $policy = $policyText | ConvertFrom-Json
        (ConvertTo-NxbCanonicalJson -InputObject $policy) | Should -BeExactly $policyText
        $policyText.EndsWith([string][char]10) | Should -BeFalse
        [string]$policy.authority | Should -BeExactly 'nxb-v11-known-error-signatures-v1'
        [int]$policy.schema_version | Should -Be 1

        $ids = @($policy.rules | ForEach-Object { [string]$_.id })
        $ids.Count | Should -BeGreaterThan 0
        @($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
        foreach ($rule in @($policy.rules)) {
            [string]$rule.id | Should -Match '^NXB-V11-ERR-[0-9]{3}$'
            [string]$rule.severity | Should -BeExactly 'error'
            [bool]$rule.failure_override_permitted | Should -BeFalse
            @($rule.applies_to).Count | Should -BeGreaterThan 0
        }

        $signatureSchema = Get-Content -LiteralPath $script:KnownErrorPolicySchemaPath -Raw |
            ConvertFrom-Json
        [string]$signatureSchema.'$id' |
            Should -BeExactly 'urn:nxb:schema:nxb-v11-known-error-signatures:v1'
        [bool]$signatureSchema.additionalProperties | Should -BeFalse
        [bool]$signatureSchema.'$defs'.rule.additionalProperties | Should -BeFalse
        [bool]$signatureSchema.'$defs'.rule.properties.failure_override_permitted.const |
            Should -BeFalse

        $scanSchema = Get-Content -LiteralPath $script:KnownErrorScanSchemaPath -Raw |
            ConvertFrom-Json
        [string]$scanSchema.'$id' |
            Should -BeExactly 'urn:nxb:schema:nxb-v11-known-error-scan:v1'
        [bool]$scanSchema.additionalProperties | Should -BeFalse
        [bool]$scanSchema.properties.failure_override_permitted.const | Should -BeFalse
        [bool]$scanSchema.'$defs'.finding.additionalProperties | Should -BeFalse
    }

    It 'reproduces every logical known-error fixture decision' {
        $fixtures = Get-Content -LiteralPath $script:KnownErrorFixturePath -Raw |
            ConvertFrom-Json
        [string]$fixtures.authority |
            Should -BeExactly 'nxb-v11-known-error-fixtures-v1'
        @($fixtures.cases).Count | Should -Be 10

        $root = Join-Path ([IO.Path]::GetTempPath()) (
            'nxb-v11-known-error-{0}' -f [Guid]::NewGuid().ToString('N')
        )
        [void][IO.Directory]::CreateDirectory($root)

        try {
            $index = 0
            foreach ($case in @($fixtures.cases)) {
                $relative = 'fixture/{0:d2}-{1}' -f $index,([string]$case.filename)
                $full = Join-Path $root $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $full))
                Write-Utf8NoBom -Path $full -Text ([string]$case.source)

                $input = [ordered]@{
                    authority = 'nxb-v11-known-error-scan-input-v1'
                    schema_version = 1
                    repository = 'fixture/repository'
                    entries = @(
                        [ordered]@{
                            path = $relative
                            validation_class = [string]$case.validation_class
                        }
                    )
                }
                $inputPath = Join-Path $root ('input-{0:d2}.json' -f $index)
                $outputPath = Join-Path $root ('output-{0:d2}.json' -f $index)
                Write-Utf8NoBom -Path $inputPath -Text (
                    ConvertTo-NxbCanonicalJson -InputObject $input
                )

                $run = Invoke-V11Python -Arguments @(
                    $script:KnownErrorToolPath,
                    '--repository-root', $root,
                    '--policy', $script:KnownErrorPolicyPath,
                    '--input', $inputPath,
                    '--output', $outputPath
                )
                $run.ExitCode | Should -Be 0

                $resultText = Get-Content -LiteralPath $outputPath -Raw
                $result = $resultText | ConvertFrom-Json
                (ConvertTo-NxbCanonicalJson -InputObject $result) |
                    Should -BeExactly $resultText
                [string]$result.authority |
                    Should -BeExactly 'nxb-v11-known-error-scan-v1'
                [bool]$result.failure_override_permitted | Should -BeFalse

                $expectedIds = @($case.expected_ids | ForEach-Object { [string]$_ } | Sort-Object)
                $actualIds = @($result.findings | ForEach-Object { [string]$_.id } | Sort-Object)
                $actualIds | Should -Be $expectedIds
                [int]$result.finding_count | Should -Be $expectedIds.Count
                [string]$result.status |
                    Should -BeExactly $(if ($expectedIds.Count -eq 0) { 'passed' } else { 'failed' })
                $index++
            }
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports zero findings across the current successor judging-source subset' {
        $entries = @(
            [ordered]@{ path = 'validation/v11/scripts/ConvertTo-NxbV11CanonicalAuthority.ps1'; validation_class = 'executable_powershell' },
            [ordered]@{ path = 'validation/v11/scripts/Expand-NxbV11VerifiedArchive.ps1'; validation_class = 'executable_powershell' },
            [ordered]@{ path = 'validation/v11/tests/CanonicalJson.Tests.ps1'; validation_class = 'pester_test' },
            [ordered]@{ path = 'validation/v11/tests/V11Compatibility.Tests.ps1'; validation_class = 'pester_test' },
            [ordered]@{ path = 'validation/v11/tools/build_artifact_tree_manifest.py'; validation_class = 'executable_python' },
            [ordered]@{ path = 'validation/v11/tools/materialize_python_requirements.py'; validation_class = 'executable_python' },
            [ordered]@{ path = 'validation/v11/tools/run_pinned_pip.py'; validation_class = 'executable_python' },
            [ordered]@{ path = 'validation/v11/tools/classify_native_impact.py'; validation_class = 'executable_python' },
            [ordered]@{ path = 'validation/v11/tools/scan_v11_known_errors.py'; validation_class = 'executable_python' },
            [ordered]@{ path = 'validation/v11/tools/validate_v11_compatibility.py'; validation_class = 'executable_python' }
        )
        $root = Join-Path ([IO.Path]::GetTempPath()) (
            'nxb-v11-known-error-current-{0}' -f [Guid]::NewGuid().ToString('N')
        )
        [void][IO.Directory]::CreateDirectory($root)
        $inputPath = Join-Path $root 'input.json'
        $outputPath = Join-Path $root 'output.json'

        try {
            $input = [ordered]@{
                authority = 'nxb-v11-known-error-scan-input-v1'
                schema_version = 1
                repository = 'Naveax/nxb-integrity-research-lab'
                entries = $entries
            }
            Write-Utf8NoBom -Path $inputPath -Text (
                ConvertTo-NxbCanonicalJson -InputObject $input
            )
            $run = Invoke-V11Python -Arguments @(
                $script:KnownErrorToolPath,
                '--repository-root', $script:RepositoryRoot,
                '--policy', $script:KnownErrorPolicyPath,
                '--input', $inputPath,
                '--output', $outputPath
            )
            $run.ExitCode | Should -Be 0
            $result = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
            [string]$result.status | Should -BeExactly 'passed'
            [int]$result.entry_count | Should -Be 10
            [int]$result.finding_count | Should -Be 0
            @($result.findings).Count | Should -Be 0
            [bool]$result.failure_override_permitted | Should -BeFalse
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'fails closed on duplicate, traversal and missing scan paths' {
        $root = Join-Path ([IO.Path]::GetTempPath()) (
            'nxb-v11-known-error-invalid-{0}' -f [Guid]::NewGuid().ToString('N')
        )
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'fixture'))
        $existing = Join-Path $root 'fixture\safe.ps1'
        Write-Utf8NoBom -Path $existing -Text 'Write-Output ''ok'''

        try {
            $cases = @(
                [ordered]@{
                    name = 'duplicate'
                    entries = @(
                        [ordered]@{ path = 'fixture/safe.ps1'; validation_class = 'executable_powershell' },
                        [ordered]@{ path = 'fixture/safe.ps1'; validation_class = 'pester_test' }
                    )
                    expected = 'duplicate scan path'
                },
                [ordered]@{
                    name = 'traversal'
                    entries = @(
                        [ordered]@{ path = '../escape.ps1'; validation_class = 'executable_powershell' }
                    )
                    expected = 'traversal segment'
                },
                [ordered]@{
                    name = 'missing'
                    entries = @(
                        [ordered]@{ path = 'fixture/missing.py'; validation_class = 'executable_python' }
                    )
                    expected = 'missing/non-file'
                }
            )

            foreach ($case in $cases) {
                $inputPath = Join-Path $root (([string]$case.name) + '.json')
                $outputPath = Join-Path $root (([string]$case.name) + '.out.json')
                $input = [ordered]@{
                    authority = 'nxb-v11-known-error-scan-input-v1'
                    schema_version = 1
                    repository = 'fixture/repository'
                    entries = @($case.entries)
                }
                Write-Utf8NoBom -Path $inputPath -Text (
                    ConvertTo-NxbCanonicalJson -InputObject $input
                )
                $run = Invoke-V11Python -Arguments @(
                    $script:KnownErrorToolPath,
                    '--repository-root', $root,
                    '--policy', $script:KnownErrorPolicyPath,
                    '--input', $inputPath,
                    '--output', $outputPath
                )
                $run.ExitCode | Should -Be 2
                $run.Text | Should -Match ([regex]::Escape([string]$case.expected))
                Test-Path -LiteralPath $outputPath | Should -BeFalse
            }
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps the scanner core offline and process-free' {
        $source = Get-Content -LiteralPath $script:KnownErrorToolPath -Raw
        $source | Should -Not -Match '(?m)^\s*import\s+(subprocess|socket|urllib|http|requests)\b'
        $source | Should -Not -Match '\b(subprocess|os\.system|Popen)\b'
        $source | Should -Match 'failure_override_permitted'
    }
}


Describe 'V11 review ZIP structural preflight (no admission)' {
    It 'requires explicit structural and authority modes and never claims physical authority' {
        $tool = Join-Path $script:RepositoryRoot 'validation\v11\tools\validate_v11_compatibility.py'
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-zip-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        $zip = Join-Path $root 'review.zip'
        $generator = @'
import json, sys, zipfile
names = {
  'environment-fingerprint.json': 'nxb-compatibility-environment-fingerprint-v1',
  'compatibility-plan.json': 'nxb-v11-compatibility-plan-v1',
  'endurance-cycle-summary.json': 'nxb-v11-endurance-cycle-summary-v1',
  'known-error-scan.json': 'nxb-v11-known-error-scan-v1',
  'independent-validation.json': 'nxb-v11-compatibility-independent-v1',
  'compatibility-certification-receipt.json': 'synthetic-not-admitted',
}
keys = sorted(names)
with zipfile.ZipFile(sys.argv[1], 'w', compression=zipfile.ZIP_DEFLATED) as output:
    for key in keys:
        data = {'authority': names[key], 'status': 'synthetic'}
        text = json.dumps(data, sort_keys=True, separators=(',', ':'))
        output.writestr(key, text.encode('utf-8'))
'@
        try {
            $made = Invoke-V11Python -Arguments @('-c', $generator, $zip)
            $made.ExitCode | Should -Be 0
            $missingMode = Invoke-V11Python -Arguments @(
                $tool,
                '--authority-mode', 'physical-compatibility',
                '--zip', $zip
            )
            $missingMode.ExitCode | Should -Be 2
            $missingMode.Text | Should -Match '--mode'

            $missingAuthorityMode = Invoke-V11Python -Arguments @(
                $tool,
                '--mode', 'structural-preflight',
                '--zip', $zip
            )
            $missingAuthorityMode.ExitCode | Should -Be 2
            $missingAuthorityMode.Text | Should -Match '--authority-mode'

            $inspection = Invoke-V11Python -Arguments @(
                $tool,
                '--mode', 'structural-preflight',
                '--authority-mode', 'physical-compatibility',
                '--zip', $zip
            )
            $inspection.ExitCode | Should -Be 0
            $doc = $inspection.Text | ConvertFrom-Json
            [string]$doc.status | Should -BeExactly 'STRUCTURE_ONLY'
            [string]$doc.authority_mode | Should -BeExactly 'physical-compatibility'
            [string]$doc.expected_filename_set_sha256 |
                Should -BeExactly '5874922efe9cc136886e8d590b05ebe7c3604e8b509314ea767788467b711d17'
            [string]$doc.observed_filename_set_sha256 |
                Should -BeExactly '5874922efe9cc136886e8d590b05ebe7c3604e8b509314ea767788467b711d17'
            [int]$doc.filename_count | Should -Be 6
            [bool]$doc.admitted | Should -BeFalse
            [bool]$doc.physical_compatibility_claimed | Should -BeFalse
            [int]$doc.entry_count | Should -Be 6
            @($doc.unverified_gates).Count | Should -BeGreaterThan 0
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'separates A0-hosted from physical six-entry artifacts by trusted caller mode' {
        $tool = Join-Path $script:RepositoryRoot 'validation\v11\tools\validate_v11_compatibility.py'
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-zip-a0-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        $zip = Join-Path $root 'a0-review.zip'
        $generator = @'
import json, sys, zipfile
names = {
  'compatibility-policy-summary.json': 'synthetic-policy-summary',
  'canonicalization-conformance.json': 'synthetic-canonicalization',
  'native-impact-classifier-fixtures.json': 'synthetic-native-impact',
  'known-error-scan.json': 'nxb-v11-known-error-scan-v1',
  'independent-validation.json': 'synthetic-a0-independent',
  'a0-substrate-receipt.json': 'nxb-v11-a0-substrate-receipt-v1',
}
with zipfile.ZipFile(sys.argv[1], 'w', compression=zipfile.ZIP_DEFLATED) as output:
    for key in sorted(names):
        data = {'authority': names[key], 'status': 'synthetic'}
        output.writestr(
            key,
            json.dumps(data, sort_keys=True, separators=(',', ':')).encode('utf-8'),
        )
'@
        try {
            $made = Invoke-V11Python -Arguments @('-c', $generator, $zip)
            $made.ExitCode | Should -Be 0

            $a0 = Invoke-V11Python -Arguments @(
                $tool,
                '--mode', 'structural-preflight',
                '--authority-mode', 'a0-hosted',
                '--zip', $zip
            )
            $a0.ExitCode | Should -Be 0
            $doc = $a0.Text | ConvertFrom-Json
            [string]$doc.authority_mode | Should -BeExactly 'a0-hosted'
            [string]$doc.expected_filename_set_sha256 |
                Should -BeExactly '79ca4d7140bfccd859cd2952e70f7dc636a1612ad1b475f7509e57bd4cd7c977'
            [string]$doc.observed_filename_set_sha256 |
                Should -BeExactly '79ca4d7140bfccd859cd2952e70f7dc636a1612ad1b475f7509e57bd4cd7c977'
            [int]$doc.filename_count | Should -Be 6
            [bool]$doc.admitted | Should -BeFalse

            $wrongMode = Invoke-V11Python -Arguments @(
                $tool,
                '--mode', 'structural-preflight',
                '--authority-mode', 'physical-compatibility',
                '--zip', $zip
            )
            $wrongMode.ExitCode | Should -Be 2
            $wrongMode.Text | Should -Match 'names differ from selected authority-mode contract'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects missing, unsafe and non-canonical synthetic review entries' {
        $tool = Join-Path $script:RepositoryRoot 'validation\v11\tools\validate_v11_compatibility.py'
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-zip-negative-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        $generator = @'
import json,sys,zipfile
names = {
 'environment-fingerprint.json':'nxb-compatibility-environment-fingerprint-v1',
 'compatibility-plan.json':'nxb-v11-compatibility-plan-v1',
 'endurance-cycle-summary.json':'nxb-v11-endurance-cycle-summary-v1',
 'known-error-scan.json':'nxb-v11-known-error-scan-v1',
 'independent-validation.json':'nxb-v11-compatibility-independent-v1',
 'compatibility-certification-receipt.json':'synthetic-not-admitted',
}
mode = sys.argv[2]
keys = sorted(names)
if mode == 'missing': keys = keys[:-1]
if mode == 'unsafe': keys[0] = '../unexpected.json'
with zipfile.ZipFile(sys.argv[1],'w',compression=zipfile.ZIP_DEFLATED) as output:
 for key in keys:
  data = {'authority':names.get(key,'synthetic'),'status':'synthetic'}
  text = json.dumps(data,sort_keys=True,separators=(',',':'))
  if mode == 'pretty' and key == 'compatibility-plan.json': text=json.dumps(data,indent=2)
  output.writestr(key,text.encode('utf-8'))
'@
        try {
            foreach ($case in @(
                @{ mode='missing'; error='entry count' },
                @{ mode='unsafe'; error='names differ' },
                @{ mode='pretty'; error='non-canonical JSON' }
            )) {
                $zip = Join-Path $root (([string]$case.mode) + '.zip')
                $made = Invoke-V11Python -Arguments @('-c', $generator, $zip, [string]$case.mode)
                $made.ExitCode | Should -Be 0
                $run = Invoke-V11Python -Arguments @(
                    $tool,
                    '--mode', 'structural-preflight',
                    '--authority-mode', 'physical-compatibility',
                    '--zip', $zip
                )
                $run.ExitCode | Should -Be 2
                $run.Text | Should -Match ([regex]::Escape([string]$case.error))
            }
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}


Describe 'V11 ZIP digest/parser snapshot binding (claim-free)' {
    It 'preserves entry and outer hash identity when the disk ZIP is swapped before parsing' {
        $tool = Join-Path $script:RepositoryRoot 'validation\v11\tools\validate_v11_compatibility.py'
        $probe = @'
import hashlib
import importlib.util
import json
import os
import tempfile
import zipfile
from pathlib import Path
import sys

path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("nxb_envelope_candidate", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory(prefix="nxb-zip-snapshot-") as base:
    root = Path(base)
    original = root / "review.zip"
    replacement = root / "replacement.zip"
    authority = {
        **module.KNOWN_AUTHORITY_BY_MODE["physical-compatibility"],
        "compatibility-certification-receipt.json": "synthetic-not-admitted",
    }
    def make(dest, state):
        content_hashes = {}
        with zipfile.ZipFile(dest, mode="w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name in sorted(module.AUTHORITY_MODE_NAMES["physical-compatibility"]):
                data = json.dumps({"authority": authority[name], "status": state}, sort_keys=True, separators=(",", ":")).encode("utf-8")
                archive.writestr(name, data)
                content_hashes[name] = hashlib.sha256(data).hexdigest()
        return content_hashes
    expected = make(original, "original")
    make(replacement, "swapped")
    original_digest = hashlib.sha256(original.read_bytes()).hexdigest()
    real_zipfile = zipfile.ZipFile
    seen = []
    def swap_before_parse(file, *args, **kwargs):
        seen.append(type(file).__name__)
        os.replace(replacement, original)
        return real_zipfile(file, *args, **kwargs)
    zipfile.ZipFile = swap_before_parse
    try:
        report = module.inspect_zip(
            original, "physical-compatibility", original_digest
        )
    finally:
        zipfile.ZipFile = real_zipfile
    assert len(seen) == 1, seen
    assert seen == ["BytesIO"], seen
    assert report["zip_sha256"] == original_digest
    assert all(row["sha256"] == expected[row["name"]] for row in report["entries"])
    assert not report["admitted"] and not report["physical_compatibility_claimed"]
    assert hashlib.sha256(original.read_bytes()).hexdigest() != original_digest
    print("SNAPSHOT_RACE_TEST_PASS: digest and six inspected entries came from original in-memory bytes")
    try:
        module.inspect_zip(
            original, "physical-compatibility", original_digest
        )
    except module.PreflightError as e:
        assert "digest mismatch" in str(e), str(e)
        print("SWAPPED_DISK_CONTENT_REJECTED_PASS")
    else:
        raise AssertionError("unexpected swapped digest acceptance")
'@
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-zip-race-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($tempRoot)
        $probePath = Join-Path $tempRoot 'zip-snapshot-race.py'
        try {
            [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($false, $true))
            $run = Invoke-V11Python -Arguments @($probePath, $tool)
            $run.ExitCode | Should -Be 0
            $run.Text | Should -Match 'SNAPSHOT_RACE_TEST_PASS'
            $run.Text | Should -Match 'SWAPPED_DISK_CONTENT_REJECTED_PASS'
        }
        finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'V11 ZIP malformed Unicode and nesting fail-closed behavior' {
    It 'rejects unpaired surrogate keys/values and deeply nested JSON with exit 2' {
        $tool = Join-Path $script:RepositoryRoot 'validation\v11\tools\validate_v11_compatibility.py'
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-zip-json-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        $generatorPath = Join-Path $root 'generate-json-edge-zip.py'
        $generator = @'
import json
import sys
import zipfile

authorities = {
    "environment-fingerprint.json": "nxb-compatibility-environment-fingerprint-v1",
    "compatibility-plan.json": "nxb-v11-compatibility-plan-v1",
    "endurance-cycle-summary.json": "nxb-v11-endurance-cycle-summary-v1",
    "known-error-scan.json": "nxb-v11-known-error-scan-v1",
    "independent-validation.json": "nxb-v11-compatibility-independent-v1",
    "compatibility-certification-receipt.json": "synthetic-not-admitted",
}
mode = sys.argv[2]
with zipfile.ZipFile(sys.argv[1], "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for name in sorted(authorities):
        payload = {"authority": authorities[name], "status": "synthetic"}
        if name == "compatibility-plan.json" and mode == "surrogate-value":
            payload["bad"] = chr(0xD800)
        if name == "compatibility-plan.json" and mode == "surrogate-key":
            payload[chr(0xD800)] = "bad"
        if name == "compatibility-plan.json" and mode == "deeply-nested":
            content = (
                '{"authority":"nxb-v11-compatibility-plan-v1","nested":'
                + "[" * 1200 + "0" + "]" * 1200 + "}"
            ).encode("utf-8")
        else:
            content = json.dumps(
                payload, ensure_ascii=True, sort_keys=True, separators=(",", ":")
            ).encode("utf-8")
        archive.writestr(name, content)
'@
        try {
            [IO.File]::WriteAllText($generatorPath, $generator, [Text.UTF8Encoding]::new($false, $true))
            foreach ($case in @(
                @{ mode = 'valid'; accepted = $true; pattern = 'STRUCTURE_ONLY' },
                @{ mode = 'surrogate-value'; accepted = $false; pattern = 'unpaired Unicode surrogate' },
                @{ mode = 'surrogate-key'; accepted = $false; pattern = 'unpaired Unicode surrogate' },
                @{ mode = 'deeply-nested'; accepted = $false; pattern = 'malformed JSON|JSON nesting' }
            )) {
                $zip = Join-Path $root (([string]$case.mode) + '.zip')
                $made = Invoke-V11Python -Arguments @($generatorPath, $zip, [string]$case.mode)
                $made.ExitCode | Should -Be 0
                $run = Invoke-V11Python -Arguments @(
                    $tool,
                    '--mode', 'structural-preflight',
                    '--authority-mode', 'physical-compatibility',
                    '--zip', $zip
                )
                if ($case.accepted) {
                    $run.ExitCode | Should -Be 0
                    $doc = $run.Text | ConvertFrom-Json
                    [string]$doc.status | Should -BeExactly 'STRUCTURE_ONLY'
                    [bool]$doc.admitted | Should -BeFalse
                }
                else {
                    $run.ExitCode | Should -Be 2
                    $run.Text | Should -Match 'NXB_V11_REVIEW_ZIP_PREFLIGHT_ERROR'
                    $run.Text | Should -Match ([string]$case.pattern)
                }
            }
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}


Describe 'V11 primary schema semantic preflight (claim-free)' {
    It 'validates exactly the four frozen primary schemas without admission' {
        $tool = Join-Path $script:RepositoryRoot 'validation\v11\tools\validate_v11_compatibility.py'
        $schemaRoot = Join-Path $script:RepositoryRoot 'schemas'
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-primary-schema-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        $generatorPath = Join-Path $root 'generate-primary-review.py'
        $generator = @'
import json
import pathlib
import sys
import zipfile
repo = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
mode = sys.argv[3]
fixtures = repo / "validation" / "v11" / "fixtures" / "native-runtime"
documents = {
 "environment-fingerprint.json": json.loads((fixtures / "environment-fingerprint-v1.synthetic.json").read_text(encoding="utf-8")),
 "compatibility-plan.json": json.loads((fixtures / "compatibility-plan-v1.synthetic.json").read_text(encoding="utf-8")),
 "endurance-cycle-summary.json": json.loads((fixtures / "endurance-cycle-summary-v1.synthetic.json").read_text(encoding="utf-8")),
 "known-error-scan.json": {"authority":"nxb-v11-known-error-scan-v1","schema_version":1,"signature_policy_sha256":"7"*64,"entry_count":0,"rule_count":0,"finding_count":0,"status":"passed","failure_override_permitted":False,"findings":[]},
 "independent-validation.json": {"authority":"nxb-v11-compatibility-independent-v1","status":"synthetic"},
 "compatibility-certification-receipt.json": {"authority":"synthetic-not-admitted","status":"synthetic"},
}
if mode == "bad-environment": documents["environment-fingerprint.json"]["worktree_clean"] = False
with zipfile.ZipFile(destination,"w",compression=zipfile.ZIP_DEFLATED) as archive:
 for name in sorted(documents): archive.writestr(name,json.dumps(documents[name],ensure_ascii=False,sort_keys=True,separators=(",",":"),allow_nan=False).encode("utf-8"))
'@
        try {
            [IO.File]::WriteAllText($generatorPath, $generator, [Text.UTF8Encoding]::new($false, $true))
            $zip = Join-Path $root 'good.zip'
            (Invoke-V11Python -Arguments @($generatorPath, $script:RepositoryRoot, $zip, 'good')).ExitCode | Should -Be 0
            $run = Invoke-V11Python -Arguments @($tool,'--mode','primary-schema-preflight','--authority-mode','physical-compatibility','--zip',$zip,'--schema-root',$schemaRoot)
            $run.ExitCode | Should -Be 0
            $doc = $run.Text | ConvertFrom-Json
            [string]$doc.status | Should -BeExactly 'PRIMARY_SCHEMAS_VALIDATED'
            [bool]$doc.schema_semantics_validated | Should -BeTrue
            [int]$doc.primary_schema_documents_validated | Should -Be 4
            [string]$doc.schema_validator_version | Should -BeExactly '4.26.0'
            [bool]$doc.schema_validator_package_provenance_admitted | Should -BeFalse
            [bool]$doc.admitted | Should -BeFalse
            [bool]$doc.physical_compatibility_claimed | Should -BeFalse
            @($doc.unverified_gates) | Should -Not -Contain 'schema_semantics'
            @($doc.unverified_gates) | Should -Contain 'validation_toolchain_provenance'
            @($doc.unverified_gates) | Should -Contain 'internal_evidence_dag'
            @($doc.unverified_gates) | Should -Contain 'policy_and_lock_bindings'
        }
        finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects primary semantic drift and any non-admitted schema byte identity' {
        $tool = Join-Path $script:RepositoryRoot 'validation\v11\tools\validate_v11_compatibility.py'
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-primary-schema-negative-' + [Guid]::NewGuid().ToString('N'))
        $schemaRoot = Join-Path $root 'schemas'
        [void][IO.Directory]::CreateDirectory($schemaRoot)
        $generatorPath = Join-Path $root 'generate-primary-review.py'
        $generator = @'
import json,pathlib,sys,zipfile
repo=pathlib.Path(sys.argv[1]); destination=pathlib.Path(sys.argv[2]); mode=sys.argv[3]
fixtures=repo/"validation"/"v11"/"fixtures"/"native-runtime"
documents={
 "environment-fingerprint.json":json.loads((fixtures/"environment-fingerprint-v1.synthetic.json").read_text(encoding="utf-8")),
 "compatibility-plan.json":json.loads((fixtures/"compatibility-plan-v1.synthetic.json").read_text(encoding="utf-8")),
 "endurance-cycle-summary.json":json.loads((fixtures/"endurance-cycle-summary-v1.synthetic.json").read_text(encoding="utf-8")),
 "known-error-scan.json":{"authority":"nxb-v11-known-error-scan-v1","schema_version":1,"signature_policy_sha256":"7"*64,"entry_count":0,"rule_count":0,"finding_count":0,"status":"passed","failure_override_permitted":False,"findings":[]},
 "independent-validation.json":{"authority":"nxb-v11-compatibility-independent-v1","status":"synthetic"},
 "compatibility-certification-receipt.json":{"authority":"synthetic-not-admitted","status":"synthetic"}}
if mode=="bad-environment": documents["environment-fingerprint.json"]["worktree_clean"]=False
with zipfile.ZipFile(destination,"w",compression=zipfile.ZIP_DEFLATED) as archive:
 for name in sorted(documents): archive.writestr(name,json.dumps(documents[name],ensure_ascii=False,sort_keys=True,separators=(",",":"),allow_nan=False).encode("utf-8"))
'@
        try {
            [IO.File]::WriteAllText($generatorPath, $generator, [Text.UTF8Encoding]::new($false, $true))
            foreach ($schemaName in @('nxb-v11-environment-fingerprint.schema.json','nxb-v11-compatibility-plan.schema.json','nxb-v11-endurance-cycle-summary.schema.json','nxb-v11-known-error-scan.schema.json')) {
                Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot ('schemas\' + $schemaName)) -Destination (Join-Path $schemaRoot $schemaName)
            }
            $badZip = Join-Path $root 'bad-environment.zip'
            (Invoke-V11Python -Arguments @($generatorPath,$script:RepositoryRoot,$badZip,'bad-environment')).ExitCode | Should -Be 0
            $semantic = Invoke-V11Python -Arguments @($tool,'--mode','primary-schema-preflight','--authority-mode','physical-compatibility','--zip',$badZip,'--schema-root',$schemaRoot)
            $semantic.ExitCode | Should -Be 2
            $semantic.Text | Should -Match 'primary schema semantic validation failed'
            $goodZip = Join-Path $root 'good.zip'
            (Invoke-V11Python -Arguments @($generatorPath,$script:RepositoryRoot,$goodZip,'good')).ExitCode | Should -Be 0
            $environmentSchema = Join-Path $schemaRoot 'nxb-v11-environment-fingerprint.schema.json'
            [IO.File]::AppendAllText($environmentSchema, ' ', [Text.UTF8Encoding]::new($false, $true))
            $schemaDrift = Invoke-V11Python -Arguments @($tool,'--mode','primary-schema-preflight','--authority-mode','physical-compatibility','--zip',$goodZip,'--schema-root',$schemaRoot)
            $schemaDrift.ExitCode | Should -Be 2
            $schemaDrift.Text | Should -Match 'primary schema source SHA-256 drift'
        }
        finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'keeps structural preflight stdlib-only and rejects misplaced schema-root input' {
        $tool = Join-Path $script:RepositoryRoot 'validation\v11\tools\validate_v11_compatibility.py'
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-structural-stdlib-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        $zip = Join-Path $root 'review.zip'
        $generatorPath = Join-Path $root 'generate-structural.py'
        $generator = @'
import json,sys,zipfile
authorities={"environment-fingerprint.json":"nxb-compatibility-environment-fingerprint-v1","compatibility-plan.json":"nxb-v11-compatibility-plan-v1","endurance-cycle-summary.json":"nxb-v11-endurance-cycle-summary-v1","known-error-scan.json":"nxb-v11-known-error-scan-v1","independent-validation.json":"nxb-v11-compatibility-independent-v1","compatibility-certification-receipt.json":"synthetic-not-admitted"}
with zipfile.ZipFile(sys.argv[1],"w",compression=zipfile.ZIP_DEFLATED) as archive:
 for name in sorted(authorities): archive.writestr(name,json.dumps({"authority":authorities[name],"status":"synthetic"},sort_keys=True,separators=(",",":")).encode("utf-8"))
'@
        try {
            [IO.File]::WriteAllText($generatorPath, $generator, [Text.UTF8Encoding]::new($false, $true))
            (Invoke-V11Python -Arguments @($generatorPath,$zip)).ExitCode | Should -Be 0
            $stdlib = Invoke-V11Python -Arguments @('-S',$tool,'--mode','structural-preflight','--authority-mode','physical-compatibility','--zip',$zip)
            $stdlib.ExitCode | Should -Be 0
            [string](($stdlib.Text | ConvertFrom-Json).status) | Should -BeExactly 'STRUCTURE_ONLY'
            $misplaced = Invoke-V11Python -Arguments @($tool,'--mode','structural-preflight','--authority-mode','physical-compatibility','--zip',$zip,'--schema-root',(Join-Path $script:RepositoryRoot 'schemas'))
            $misplaced.ExitCode | Should -Be 2
            $misplaced.Text | Should -Match 'schema-root is only valid'
        }
        finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
