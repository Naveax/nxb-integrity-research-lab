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

Describe 'V11 known-error scanner bounded source reads (claim-free)' {
    It 'caps policy, input and scanned source reads before parsing' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-known-error-bounds-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        $probePath = Join-Path $root 'probe.py'
        $probe = @'
import importlib.util
from pathlib import Path
import sys
import tempfile

spec = importlib.util.spec_from_file_location("nxb_scan", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory(prefix="nxb-known-error-bounds-") as scratch:
    root = Path(scratch)
    policy = root / "source.json"
    policy.write_bytes(b'{"ok":true}')
    for label in ("policy", "input"):
        obj, original = module.load_canonical_json(str(policy), label)
        assert obj == {"ok": True} and original == b'{"ok":true}'
        with policy.open("wb") as stream:
            stream.truncate(8 * 1024 * 1024 + 1)
        try:
            module.load_canonical_json(str(policy), label)
        except module.ScanError as exc:
            if "byte ceiling" not in str(exc):
                raise AssertionError(f"{label} bypassed byte limit: {exc}") from exc
        else:
            raise AssertionError(f"{label} accepted oversized canonical input")
        policy.write_bytes(b'{"ok":true}')
    source = root / "code.py"
    source.write_bytes(b"safe source")
    assert module.read_source(str(source), "code.py") == "safe source"
    with source.open("wb") as stream:
        stream.truncate(8 * 1024 * 1024 + 1)
    try:
        module.read_source(str(source), "code.py")
    except module.ScanError as exc:
        if "byte ceiling" not in str(exc):
            raise AssertionError(f"source bypassed byte limit: {exc}") from exc
    else:
        raise AssertionError("oversized source accepted")
print("known-error scan canonical/source read bounds: 3 oversized rejected, controls passed")
'@
        try {
            [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($false))
            $tool = Join-Path $script:RepositoryRoot 'validation\v11\tools\scan_v11_known_errors.py'
            $run = Invoke-V11Python -Arguments @($probePath, $tool)
            if ($run.ExitCode -ne 0) { throw ('Scanner byte bounds probe failed: ' + $run.Text) }
            $run.Text | Should -Match 'known-error scan canonical/source read bounds: 3 oversized rejected, controls passed'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
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


Describe 'V11 native-impact classifier bounded JSON inputs (claim-free)' {
    It 'bounds policy and graph input bytes before JSON parsing' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-impact-bounds-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        $probePath = Join-Path $root 'probe.py'
        $probe = @'
import importlib.util
from pathlib import Path
import sys
import tempfile

spec = importlib.util.spec_from_file_location("nxb_impact", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory(prefix="nxb-impact-json-bounds-") as scratch:
    root = Path(scratch)
    input_file = root / "input.json"
    input_file.write_bytes(b'{"ok":true}')
    for label in ("policy", "input"):
        obj, original = module.load_canonical_json(str(input_file), label)
        assert obj == {"ok": True} and original == b'{"ok":true}'
        with input_file.open("wb") as stream:
            stream.truncate(32 * 1024 * 1024 + 1)
        try:
            module.load_canonical_json(str(input_file), label)
        except module.ImpactError as exc:
            if "byte ceiling" not in str(exc):
                raise AssertionError(f"{label} was not rejected by byte limit: {exc}") from exc
        else:
            raise AssertionError(f"{label} accepted oversized input")
        input_file.write_bytes(b'{"ok":true}')
print("native-impact policy/input byte bounds: ordinary controls and 2 oversized sources passed")
'@
        try {
            [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($false))
            $tool = Join-Path $script:RepositoryRoot 'validation\v11\tools\classify_native_impact.py'
            $run = Invoke-V11Python -Arguments @($probePath, $tool)
            if ($run.ExitCode -ne 0) { throw ('Classifier bound probe failed: ' + $run.Text) }
            $run.Text | Should -Match 'native-impact policy/input byte bounds: ordinary controls and 2 oversized sources passed'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
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
            [ordered]@{ path = 'validation/v11/scripts/Get-NxbCompatibilityEnvironmentFingerprint.ps1'; validation_class = 'executable_powershell' },
            [ordered]@{ path = 'validation/v11/scripts/Invoke-NxbV11CandidateDispatcher.ps1'; validation_class = 'executable_powershell' },
            [ordered]@{ path = 'validation/v11/scripts/Invoke-NxbV11CompatibilityHostedValidation.ps1'; validation_class = 'executable_powershell' },
            [ordered]@{ path = 'validation/v11/scripts/Invoke-NxbV11CompatibilityNativeValidation.ps1'; validation_class = 'executable_powershell' },
            [ordered]@{ path = 'validation/v11/scripts/Invoke-NxbV11EnduranceCycle.ps1'; validation_class = 'executable_powershell' },
            [ordered]@{ path = 'validation/v11/tests/CanonicalJson.Tests.ps1'; validation_class = 'pester_test' },
            [ordered]@{ path = 'validation/v11/tests/V11Compatibility.Tests.ps1'; validation_class = 'pester_test' },
            [ordered]@{ path = 'validation/v11/tests/V11NativeCompatibility.Tests.ps1'; validation_class = 'pester_test' },
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
            [int]$result.entry_count | Should -Be 16
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


Describe 'V11 known-error scan source ancestry (claim-free)' {
    It 'rejects junction ancestors of the repository root and nested scanned file' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-scanner-ancestor-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        $probePath = Join-Path $root 'probe.py'
        $probe = @'
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location("nxb_scan", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory(prefix="nxb-known-error-ancestor-") as scratch:
    base = Path(scratch)
    real = base / "real"
    (real / "sub").mkdir(parents=True)
    (real / "sub" / "source.txt").write_text("safe", encoding="utf-8")
    aliases = [(base / "root-alias", real), (real / "src-alias", real / "sub")]
    for alias, target in aliases:
        if os.name == "nt":
            result = subprocess.run(
                ["cmd", "/d", "/c", "mklink", "/J", str(alias), str(target)],
                capture_output=True, text=True, check=False,
            )
            if result.returncode:
                raise AssertionError("junction setup failed: " + result.stderr)
        else:
            alias.symlink_to(target, target_is_directory=True)
    try:
        assert module.assert_repository_root(str(real)) == str(real)
        assert module.resolve_repository_file(str(real), "sub/source.txt") == str(real / "sub" / "source.txt")
        for check in (
            lambda: module.assert_repository_root(str(aliases[0][0] / "sub")),
            lambda: module.resolve_repository_file(str(real), "src-alias/source.txt"),
        ):
            try:
                check()
            except module.ScanError:
                pass
            else:
                raise AssertionError("scanner accepted reparse-backed ancestry")
    finally:
        for alias, _ in reversed(aliases):
            if os.name == "nt":
                alias.rmdir()
            else:
                alias.unlink()
print("known-error scanner ancestry: 2 rejected, 2 ordinary controls passed")
'@
        try {
            [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($false))
            $tool = Join-Path $script:RepositoryRoot 'validation\v11\tools\scan_v11_known_errors.py'
            $run = Invoke-V11Python -Arguments @($probePath, $tool)
            if ($run.ExitCode -ne 0) { throw ('Scanner ancestry probe failed: ' + $run.Text) }
            $run.Text | Should -Match 'known-error scanner ancestry: 2 rejected, 2 ordinary controls passed'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
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
  'compatibility-certification-receipt.json': 'nxb-v11-compatibility-certification-receipt-v1',
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
 'compatibility-certification-receipt.json':'nxb-v11-compatibility-certification-receipt-v1',
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
        "compatibility-certification-receipt.json": "nxb-v11-compatibility-certification-receipt-v1",
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
    "compatibility-certification-receipt.json": "nxb-v11-compatibility-certification-receipt-v1",
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
 "compatibility-certification-receipt.json": {"authority":"nxb-v11-compatibility-certification-receipt-v1","status":"synthetic"},
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
 "compatibility-certification-receipt.json":{"authority":"nxb-v11-compatibility-certification-receipt-v1","status":"synthetic"}}
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
authorities={"environment-fingerprint.json":"nxb-compatibility-environment-fingerprint-v1","compatibility-plan.json":"nxb-v11-compatibility-plan-v1","endurance-cycle-summary.json":"nxb-v11-endurance-cycle-summary-v1","known-error-scan.json":"nxb-v11-known-error-scan-v1","independent-validation.json":"nxb-v11-compatibility-independent-v1","compatibility-certification-receipt.json":"nxb-v11-compatibility-certification-receipt-v1"}
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


Describe 'V11 terminal compatibility schema DAG contract (claim-free)' {
    It 'validates the frozen terminal identities and rejects self/outer-hash cycles' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-terminal-schema-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        $probe = Join-Path $root 'validate-terminal-schemas.py'
        $source = @'
import copy
import json
import pathlib
import sys
from importlib.metadata import version

from jsonschema import Draft202012Validator
from jsonschema.exceptions import ValidationError

repo = pathlib.Path(sys.argv[1])
schema_root = repo / "schemas"
fixture_root = repo / "validation" / "v11" / "fixtures" / "compatibility-artifact"

assert version("jsonschema") == "4.26.0"

independent_schema = json.loads(
    (schema_root / "nxb-v11-independent-validation.schema.json").read_text(encoding="utf-8")
)
receipt_schema = json.loads(
    (schema_root / "nxb-v11-compatibility-receipt.schema.json").read_text(encoding="utf-8")
)
independent = json.loads(
    (fixture_root / "independent-validation-v1.synthetic.json").read_text(encoding="utf-8")
)
receipt = json.loads(
    (fixture_root / "compatibility-receipt-v1.synthetic.json").read_text(encoding="utf-8")
)

assert independent_schema["$id"] == "urn:nxb:schema:nxb-v11-independent-validation:v1"
assert receipt_schema["$id"] == "urn:nxb:schema:nxb-v11-compatibility-receipt:v1"
assert independent_schema["additionalProperties"] is False
assert receipt_schema["additionalProperties"] is False

Draft202012Validator.check_schema(independent_schema)
Draft202012Validator.check_schema(receipt_schema)
independent_validator = Draft202012Validator(independent_schema)
receipt_validator = Draft202012Validator(receipt_schema)
independent_validator.validate(independent)
receipt_validator.validate(receipt)

primary_hashes = {
    "environment_fingerprint_sha256",
    "compatibility_plan_sha256",
    "endurance_summary_sha256",
    "known_error_scan_sha256",
}
assert primary_hashes <= set(independent_schema["required"])
assert "independent_validation_sha256" not in independent_schema["properties"]
assert "independent_validation_sha256" in receipt_schema["required"]
assert primary_hashes <= set(receipt_schema["required"])

selector_fields = {
    "compatibility_policy_sha256",
    "validation_toolchain_lock_sha256",
    "powershell_runtime_admission_receipt_sha256",
    "trusted_preparation_receipt_sha256",
    "powershell_module_lock_sha256",
    "selected_host_python_dependency_lock_path",
    "selected_host_python_dependency_lock_sha256",
    "adk_wpt_preparation_receipt_sha256",
}
assert set(independent_schema["$defs"]["selectorProvenance"]["required"]) == selector_fields
assert set(receipt_schema["$defs"]["selectorProvenance"]["required"]) == selector_fields

for forbidden in (
    "receipt_sha256",
    "compatibility_certification_receipt_sha256",
    "outer_zip_sha256",
    "artifact_sha256",
):
    assert forbidden not in independent_schema["properties"]
    assert forbidden not in receipt_schema["properties"]

def rejected(validator, document):
    try:
        validator.validate(document)
    except ValidationError:
        return
    raise AssertionError("negative control unexpectedly passed")

bad = copy.deepcopy(independent)
bad["compatibility_certification_receipt_sha256"] = "0" * 64
rejected(independent_validator, bad)

bad = copy.deepcopy(independent)
bad["outer_zip_sha256"] = "0" * 64
rejected(independent_validator, bad)

bad = copy.deepcopy(independent)
bad["receipt_hash_not_yet_available"] = False
rejected(independent_validator, bad)

bad = copy.deepcopy(independent)
bad["negative_controls_passed"] = 46
rejected(independent_validator, bad)

bad = copy.deepcopy(receipt)
bad["receipt_sha256"] = "0" * 64
rejected(receipt_validator, bad)

bad = copy.deepcopy(receipt)
bad["outer_zip_sha256"] = "0" * 64
rejected(receipt_validator, bad)

bad = copy.deepcopy(receipt)
del bad["independent_validation_sha256"]
rejected(receipt_validator, bad)

bad = copy.deepcopy(receipt)
bad["review_entry_count"] = 7
rejected(receipt_validator, bad)

bad = copy.deepcopy(receipt)
bad["production_boundary"]["release_mutation"] = True
rejected(receipt_validator, bad)

print("TERMINAL_SCHEMA_DAG_PASS")
'@
        try {
            [IO.File]::WriteAllText($probe, $source, [Text.UTF8Encoding]::new($false, $true))
            $run = Invoke-V11Python -Arguments @($probe, $script:RepositoryRoot)
            $run.ExitCode | Should -Be 0
            $run.Text | Should -Match 'TERMINAL_SCHEMA_DAG_PASS'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}


Describe 'V11 six-entry review schema DAG preflight (claim-free)' {
    It 'validates the acyclic six-entry hash graph and rejects cross-document drift' {
        $tool = Join-Path $script:RepositoryRoot 'validation\v11\tools\validate_v11_compatibility.py'
        $schemaRoot = Join-Path $script:RepositoryRoot 'schemas'
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-review-dag-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        $generatorPath = Join-Path $root 'generate-review-dag.py'
        $generator = @'
import copy
import hashlib
import json
import pathlib
import sys
import zipfile

repo = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
mode = sys.argv[3]
native = repo / "validation" / "v11" / "fixtures" / "native-runtime"
terminal = repo / "validation" / "v11" / "fixtures" / "compatibility-artifact"

def load(path):
    return json.loads(path.read_text(encoding="utf-8"))

def canonical(document):
    return json.dumps(
        document,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")

environment = load(native / "environment-fingerprint-v1.synthetic.json")
plan = load(native / "compatibility-plan-v1.synthetic.json")
endurance = load(native / "endurance-cycle-summary-v1.synthetic.json")
known_error = {
    "authority": "nxb-v11-known-error-scan-v1",
    "schema_version": 1,
    "signature_policy_sha256": "7" * 64,
    "entry_count": 0,
    "rule_count": 0,
    "finding_count": 0,
    "status": "passed",
    "failure_override_permitted": False,
    "findings": [],
}
independent = load(terminal / "independent-validation-v1.synthetic.json")
receipt = load(terminal / "compatibility-receipt-v1.synthetic.json")

policy_sha = independent["policy_sha256"]
fingerprint_sha = independent["fingerprint_sha256"]
intent_sha = independent["intent_sha256"]

environment["policy_sha256"] = policy_sha
environment["fingerprint_sha256"] = fingerprint_sha
plan["policy"]["sha256"] = policy_sha
plan["intent"]["sha256"] = intent_sha
endurance["policy_sha256"] = policy_sha
endurance["fingerprint_sha256"] = fingerprint_sha
endurance["intent_sha256"] = intent_sha

receipt["selector_provenance"] = copy.deepcopy(independent["selector_provenance"])
for field in (
    "predecessor_replay_artifact_id",
    "predecessor_replay_sha256",
    "predecessor_replay_receipt_sha256",
):
    receipt[field] = independent[field]

primary = {
    "environment-fingerprint.json": environment,
    "compatibility-plan.json": plan,
    "endurance-cycle-summary.json": endurance,
    "known-error-scan.json": known_error,
}
primary_bytes = {name: canonical(doc) for name, doc in primary.items()}
hash_fields = {
    "environment-fingerprint.json": "environment_fingerprint_sha256",
    "compatibility-plan.json": "compatibility_plan_sha256",
    "endurance-cycle-summary.json": "endurance_summary_sha256",
    "known-error-scan.json": "known_error_scan_sha256",
}
for name, field in hash_fields.items():
    digest = hashlib.sha256(primary_bytes[name]).hexdigest()
    independent[field] = digest
    receipt[field] = digest

if mode == "bad-primary-hash":
    independent["environment_fingerprint_sha256"] = "0" * 64
elif mode == "bad-terminal-identity":
    receipt["candidate_sha"] = "c" * 40
elif mode == "bad-native-join":
    receipt["trusted_native_run_id"] = independent["run_id"] + 1
elif mode == "bad-physical-claim":
    receipt["physical_compatibility_claimed"] = True

independent_bytes = canonical(independent)
receipt["independent_validation_sha256"] = hashlib.sha256(independent_bytes).hexdigest()
documents = dict(primary_bytes)
documents["independent-validation.json"] = independent_bytes
documents["compatibility-certification-receipt.json"] = canonical(receipt)

with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for name in sorted(documents):
        archive.writestr(name, documents[name])
'@
        try {
            [IO.File]::WriteAllText($generatorPath, $generator, [Text.UTF8Encoding]::new($false, $true))
            foreach ($case in @(
                @{ mode = 'good'; accepted = $true; pattern = 'REVIEW_SCHEMAS_DAG_VALIDATED' },
                @{ mode = 'bad-primary-hash'; accepted = $false; pattern = 'independent-validation DAG hash mismatch' },
                @{ mode = 'bad-terminal-identity'; accepted = $false; pattern = 'terminal DAG identity mismatch' },
                @{ mode = 'bad-native-join'; accepted = $false; pattern = 'trusted-native DAG identity mismatch' },
                @{ mode = 'bad-physical-claim'; accepted = $false; pattern = 'claim-free review DAG cannot claim physical compatibility' }
            )) {
                $zip = Join-Path $root (([string]$case.mode) + '.zip')
                $made = Invoke-V11Python -Arguments @($generatorPath, $script:RepositoryRoot, $zip, [string]$case.mode)
                $made.ExitCode | Should -Be 0
                $run = Invoke-V11Python -Arguments @(
                    $tool,
                    '--mode', 'review-schema-dag-preflight',
                    '--authority-mode', 'physical-compatibility',
                    '--zip', $zip,
                    '--schema-root', $schemaRoot
                )
                if ($case.accepted) {
                    $run.ExitCode | Should -Be 0
                    $doc = $run.Text | ConvertFrom-Json
                    [string]$doc.status | Should -BeExactly 'REVIEW_SCHEMAS_DAG_VALIDATED'
                    [bool]$doc.schema_semantics_validated | Should -BeTrue
                    [int]$doc.primary_schema_documents_validated | Should -Be 4
                    [int]$doc.terminal_schema_documents_validated | Should -Be 2
                    [bool]$doc.internal_evidence_dag_validated | Should -BeTrue
                    [bool]$doc.admitted | Should -BeFalse
                    [bool]$doc.physical_compatibility_claimed | Should -BeFalse
                    @($doc.unverified_gates) | Should -Not -Contain 'schema_semantics'
                    @($doc.unverified_gates) | Should -Not -Contain 'internal_evidence_dag'
                    @($doc.unverified_gates) | Should -Contain 'policy_and_lock_bindings'
                    @($doc.unverified_gates) | Should -Contain 'trusted_native_identity'
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


Describe 'V11 A0 hosted and predecessor replay schema closure (claim-free)' {
    It 'validates both frozen schemas and rejects claim, cycle and provenance drift' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-a0-schema-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        $probe = Join-Path $root 'validate-a0-schemas.py'
        $source = @'
import copy, json, pathlib, sys
from importlib.metadata import version
from jsonschema import Draft202012Validator
from jsonschema.exceptions import ValidationError

repo = pathlib.Path(sys.argv[1])
schemas = repo / "schemas"
fixtures = repo / "validation" / "v11" / "fixtures" / "compatibility-artifact"
assert version("jsonschema") == "4.26.0"

a0_schema = json.loads((schemas / "nxb-v11-a0-hosted-substrate.schema.json").read_text(encoding="utf-8"))
a0 = json.loads((fixtures / "a0-hosted-substrate-v1.synthetic.json").read_text(encoding="utf-8"))
pred_schema = json.loads((schemas / "nxb-v11-predecessor-replay-receipt.schema.json").read_text(encoding="utf-8"))
pred = json.loads((fixtures / "predecessor-replay-receipt-v1.synthetic.json").read_text(encoding="utf-8"))

assert a0_schema["$id"] == "urn:nxb:schema:nxb-v11-a0-hosted-substrate:v1"
assert pred_schema["$id"] == "urn:nxb:schema:nxb-v11-predecessor-replay-receipt:v1"
assert a0_schema["additionalProperties"] is False
assert pred_schema["additionalProperties"] is False
assert a0_schema["properties"]["authority"]["const"] == "nxb-v11-a0-hosted-substrate-v1"
assert pred_schema["properties"]["authority"]["const"] == "nxb-v11-predecessor-replay-v1"
assert a0_schema["properties"]["filename_set_sha256"]["const"] == "79ca4d7140bfccd859cd2952e70f7dc636a1612ad1b475f7509e57bd4cd7c977"

expected_names = {
    "compatibility-policy-summary.json",
    "canonicalization-conformance.json",
    "native-impact-classifier-fixtures.json",
    "known-error-scan.json",
    "independent-validation.json",
    "a0-substrate-receipt.json",
}
docs_schema = a0_schema["properties"]["documents"]
assert set(docs_schema["required"]) == expected_names
assert set(docs_schema["properties"]) == expected_names

authorities = {
    "compatibility-policy-summary.json": "nxb-v11-a0-compatibility-policy-summary-v1",
    "canonicalization-conformance.json": "nxb-v11-a0-canonicalization-conformance-v1",
    "native-impact-classifier-fixtures.json": "nxb-v11-a0-native-impact-classifier-fixtures-v1",
    "known-error-scan.json": "nxb-v11-known-error-scan-v1",
    "independent-validation.json": "nxb-v11-a0-independent-validation-v1",
    "a0-substrate-receipt.json": "nxb-v11-a0-substrate-receipt-v1",
}
for name, authority in authorities.items():
    ref = docs_schema["properties"][name]["$ref"].rsplit("/", 1)[-1]
    definition = a0_schema["$defs"][ref]
    assert definition["additionalProperties"] is False
    assert definition["properties"]["authority"]["const"] == authority

independent = a0_schema["$defs"]["independentValidation"]
receipt = a0_schema["$defs"]["a0SubstrateReceipt"]
primaries = {
    "compatibility_policy_summary_sha256",
    "canonicalization_conformance_sha256",
    "native_impact_classifier_fixtures_sha256",
    "known_error_scan_sha256",
}
assert primaries <= set(independent["required"])
assert primaries <= set(receipt["required"])
assert "independent_validation_sha256" not in independent["properties"]
assert "independent_validation_sha256" in receipt["required"]
run_fields = {
    "repository_id","workflow_id","workflow_path","workflow_blob_sha","run_id",
    "run_attempt","event","pr_number","base_ref","head_ref",
}
assert run_fields <= set(independent["required"])
assert run_fields <= set(receipt["required"])
for terminal in (independent, receipt):
    assert terminal["properties"]["repository_id"]["const"] == 1322938859
    assert terminal["properties"]["workflow_path"]["const"] == ".github/workflows/nxb-v11-compatibility.yml"
    assert terminal["properties"]["event"]["const"] == "pull_request"
    assert terminal["properties"]["base_ref"]["const"] == "v11/a0-compatibility-substrate"
assert "production_signer_used" in receipt["required"]
assert receipt["properties"]["production_signer_used"]["const"] is False
assert "production_merge_mutated" in receipt["required"]
assert receipt["properties"]["production_merge_mutated"]["const"] is False
for forbidden in ("receipt_sha256","a0_substrate_receipt_sha256","outer_zip_sha256","artifact_sha256"):
    assert forbidden not in independent["properties"]
    assert forbidden not in receipt["properties"]
    assert forbidden not in pred_schema["properties"]

assert pred_schema["properties"]["entry_count"]["const"] == 7
assert pred_schema["properties"]["predecessor_source_semantics"]["const"] == "frozen-v1"
assert pred_schema["properties"]["replay_environment_acquisition"]["const"] == "successor-locked"
assert pred_schema["properties"]["historical_environment_byte_identity_claimed"]["const"] is False

Draft202012Validator.check_schema(a0_schema)
Draft202012Validator.check_schema(pred_schema)
a0_validator = Draft202012Validator(a0_schema)
pred_validator = Draft202012Validator(pred_schema)
a0_validator.validate(a0)
pred_validator.validate(pred)

expected_artifact = (
    "nxb-v11-predecessor-replay-v1-"
    + pred["predecessor_main_sha"] + "-"
    + pred["observer_successor_head_sha"] + "-"
    + str(pred["run_id"]) + "-" + str(pred["run_attempt"])
)
assert pred["artifact_name"] == expected_artifact

def rejected(validator, document):
    try:
        validator.validate(document)
    except ValidationError:
        return
    raise AssertionError("negative control unexpectedly passed")

for mutate in ("receipt", "outer", "claim", "release", "unknown"):
    bad = copy.deepcopy(a0)
    if mutate == "receipt":
        bad["documents"]["independent-validation.json"]["receipt_hash_not_yet_available"] = False
    elif mutate == "outer":
        bad["documents"]["independent-validation.json"]["outer_zip_hash_not_yet_available"] = False
    elif mutate == "claim":
        bad["documents"]["a0-substrate-receipt.json"]["physical_compatibility_claims"] = 1
    elif mutate == "release":
        bad["documents"]["a0-substrate-receipt.json"]["production_release_updated"] = True
    else:
        bad["documents"]["compatibility-policy-summary.json"]["unexpected"] = True
    rejected(a0_validator, bad)

bad = copy.deepcopy(a0)
bad["documents"]["independent-validation.json"]["event"] = "workflow_dispatch"
rejected(a0_validator, bad)

bad = copy.deepcopy(a0)
bad["documents"]["a0-substrate-receipt.json"]["production_signer_used"] = True
rejected(a0_validator, bad)

bad = copy.deepcopy(a0)
bad["documents"]["a0-substrate-receipt.json"]["production_merge_mutated"] = True
rejected(a0_validator, bad)

for mutate in ("count", "historical", "ambient", "release", "self"):
    bad = copy.deepcopy(pred)
    if mutate == "count":
        bad["entry_count"] = 6
    elif mutate == "historical":
        bad["historical_environment_byte_identity_claimed"] = True
    elif mutate == "ambient":
        bad["replay_environment_acquisition"] = "ambient"
    elif mutate == "release":
        bad["production_boundary"]["release_mutation"] = True
    else:
        bad["outer_zip_sha256"] = "0" * 64
    rejected(pred_validator, bad)

print("A0_HOSTED_PREDECESSOR_SCHEMA_PASS")
'@
        try {
            [IO.File]::WriteAllText($probe, $source, [Text.UTF8Encoding]::new($false, $true))
            $run = Invoke-V11Python -Arguments @($probe, $script:RepositoryRoot)
            $run.ExitCode | Should -Be 0
            $run.Text | Should -Match 'A0_HOSTED_PREDECESSOR_SCHEMA_PASS'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}


Describe 'V11 A0 hosted review schema DAG validator integration (claim-free)' {
    It 'validates the exact hosted DAG and rejects cross-document authority drift' {
        $tool = Join-Path $script:RepositoryRoot 'validation\v11\tools\validate_v11_compatibility.py'
        $schemaRoot = Join-Path $script:RepositoryRoot 'schemas'
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-a0-dag-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        $generatorPath = Join-Path $root 'generate-a0-review.py'
        $generator = @'
import copy
import hashlib
import json
import pathlib
import sys
import zipfile

repo = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
mode = sys.argv[3]
fixture_path = repo / "validation" / "v11" / "fixtures" / "compatibility-artifact" / "a0-hosted-substrate-v1.synthetic.json"
fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
documents = copy.deepcopy(fixture["documents"])
independent = documents["independent-validation.json"]
receipt = documents["a0-substrate-receipt.json"]

def canonical(document):
    return json.dumps(
        document,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")

if mode == "bad-primary-hash":
    independent["compatibility_policy_summary_sha256"] = "0" * 64
    receipt["independent_validation_sha256"] = hashlib.sha256(canonical(independent)).hexdigest()
elif mode == "bad-terminal-run":
    receipt["run_id"] += 1
elif mode == "bad-policy-lock":
    independent["validation_toolchain_lock_sha256"] = "0" * 64
    receipt["validation_toolchain_lock_sha256"] = "0" * 64
    receipt["independent_validation_sha256"] = hashlib.sha256(canonical(independent)).hexdigest()
elif mode == "bad-predecessor-binding":
    receipt["predecessor_replay_artifact_id"] += 1
elif mode == "bad-production-boundary":
    receipt["production_signer_used"] = True
elif mode != "good":
    raise SystemExit("unknown mode")

with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for name in sorted(documents):
        archive.writestr(name, canonical(documents[name]))
'@
        try {
            [IO.File]::WriteAllText($generatorPath, $generator, [Text.UTF8Encoding]::new($false, $true))
            foreach ($case in @(
                @{ mode = 'good'; accepted = $true; pattern = 'A0_HOSTED_SCHEMA_DAG_VALIDATED' },
                @{ mode = 'bad-primary-hash'; accepted = $false; pattern = 'A0 independent-validation DAG hash mismatch for compatibility-policy-summary.json' },
                @{ mode = 'bad-terminal-run'; accepted = $false; pattern = 'A0 terminal DAG identity mismatch: run_id' },
                @{ mode = 'bad-policy-lock'; accepted = $false; pattern = 'A0 validation-toolchain lock mismatch in independent validation' },
                @{ mode = 'bad-predecessor-binding'; accepted = $false; pattern = 'A0 terminal DAG identity mismatch: predecessor_replay_artifact_id' },
                @{ mode = 'bad-production-boundary'; accepted = $false; pattern = 'A0 hosted schema semantic validation failed' }
            )) {
                $zip = Join-Path $root (([string]$case.mode) + '.zip')
                $made = Invoke-V11Python -Arguments @(
                    $generatorPath,
                    $script:RepositoryRoot,
                    $zip,
                    [string]$case.mode
                )
                $made.ExitCode | Should -Be 0

                $run = Invoke-V11Python -Arguments @(
                    $tool,
                    '--mode', 'a0-hosted-schema-dag-preflight',
                    '--authority-mode', 'a0-hosted',
                    '--zip', $zip,
                    '--schema-root', $schemaRoot
                )
                if ($case.accepted) {
                    $run.ExitCode | Should -Be 0
                    $doc = $run.Text | ConvertFrom-Json
                    [string]$doc.status | Should -BeExactly 'A0_HOSTED_SCHEMA_DAG_VALIDATED'
                    [bool]$doc.a0_hosted_schema_validated | Should -BeTrue
                    [bool]$doc.internal_evidence_dag_validated | Should -BeTrue
                    [bool]$doc.admitted | Should -BeFalse
                    [bool]$doc.physical_compatibility_claimed | Should -BeFalse
                    @($doc.unverified_gates) | Should -Contain 'predecessor_replay_artifact_admission'
                    @($doc.unverified_gates) | Should -Contain 'github_run_artifact_and_job_provenance'
                }
                else {
                    $run.ExitCode | Should -Be 2
                    $run.Text | Should -Match ([regex]::Escape([string]$case.pattern))
                }
            }

            $wrongModeZip = Join-Path $root 'wrong-authority-mode.zip'
            $made = Invoke-V11Python -Arguments @(
                $generatorPath,
                $script:RepositoryRoot,
                $wrongModeZip,
                'good'
            )
            $made.ExitCode | Should -Be 0
            $wrong = Invoke-V11Python -Arguments @(
                $tool,
                '--mode', 'a0-hosted-schema-dag-preflight',
                '--authority-mode', 'physical-compatibility',
                '--zip', $wrongModeZip,
                '--schema-root', $schemaRoot
            )
            $wrong.ExitCode | Should -Be 2
            $wrong.Text | Should -Match 'A0 hosted schema preflight requires a0-hosted authority mode'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}


Describe 'V11 predecessor replay seven-entry external preflight (claim-free)' {
    It 'validates frozen predecessor bytes and rejects hash, tuple, partition, runner and production drift' {
        $tool = Join-Path $script:RepositoryRoot 'validation\v11\tools\validate_v11_compatibility.py'
        $schemaRoot = Join-Path $script:RepositoryRoot 'schemas'
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-pred-replay-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        $generatorPath = Join-Path $root 'generate-predecessor-replay.py'
        $generator = @'
import base64
import copy
import hashlib
import json
import pathlib
import sys
import zipfile

repo = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
mode = sys.argv[3]
fixture_path = repo / "validation" / "v11" / "fixtures" / "compatibility-artifact" / "predecessor-replay-receipt-v1.synthetic.json"
wrapper = copy.deepcopy(json.loads(fixture_path.read_text(encoding="utf-8")))

predecessor = "1111111111111111111111111111111111111111"
tree = "2222222222222222222222222222222222222222"
successor = "3333333333333333333333333333333333333333"
run_id = 123456789
attempt = 1
artifact_name = f"nxb-v11-predecessor-replay-v1-{predecessor}-{successor}-{run_id}-{attempt}"

wrapper["predecessor_main_sha"] = predecessor
wrapper["predecessor_tree_sha"] = tree
wrapper["observer_successor_head_sha"] = successor
wrapper["run_id"] = run_id
wrapper["run_attempt"] = attempt
wrapper["artifact_name"] = artifact_name
wrapper["predecessor_policy_sha256"] = "a" * 64

hosted = {
    "schema_version": 1,
    "status": "passed",
    "authority": "nxb-v1-ci-hosted-v1",
    "head_sha": predecessor,
    "pester_version": "5.7.1",
    "psscriptanalyzer_version": "1.25.0",
    "python_version": "Python 3.12.10",
    "known_error_authority": "nxb-v1-ci-known-error-scan-v1",
    "known_error_findings": 0,
    "analyzer_findings": 0,
    "analyzer_process_isolated": True,
    "ps7_passed": 916,
    "ps7_total": 916,
    "ps7_not_run": 0,
    "ps51_passed": 909,
    "ps51_total": 916,
    "ps51_not_run": 7,
    "ps51_excluded_tag": "PS7Only",
    "ps51_expected_excluded": 7,
    "production_release_updated": False,
}
known_error = {
    "schema_version": 1,
    "status": "passed",
    "authority": "nxb-v1-ci-known-error-scan-v1",
    "finding_count": 0,
    "failed_contracts": [],
    "findings": {"base": [], "ci": []},
}
summary = {
    "passed": 909,
    "failed": 0,
    "skipped": 0,
    "not_run": 7,
    "total": 916,
    "excluded_tag": "PS7Only",
    "expected_excluded": 7,
}
ps7_xml = b'<?xml version="1.0" encoding="utf-8"?><test-results name="Pester" total="916" errors="0" failures="0" not-run="0" inconclusive="0" ignored="0" skipped="0" invalid="0" />'
ps51_xml = b'<?xml version="1.0" encoding="utf-8"?><test-results name="Pester" total="909" errors="0" failures="0" not-run="7" inconclusive="0" ignored="0" skipped="0" invalid="0" />'
runner = base64.b64decode(
    "cGFyYW0oW3N0cmluZ10kVGVzdHNQYXRoLFtzdHJpbmddJE1vZHVsZVBhdGgsW3N0cmluZ10kUmVzdWx0UGF0aCxbc3RyaW5nXSRTdW1tYXJ5UGF0aCxbc3RyaW5nXSRFeGNsdWRlZFRhZyxbaW50XSRFeHBlY3RlZEV4Y2x1ZGVkQ291bnQpDQokRXJyb3JBY3Rpb25QcmVmZXJlbmNlPSdTdG9wJw0KSW1wb3J0LU1vZHVsZSAkTW9kdWxlUGF0aCAtRm9yY2UNCiRjb25maWc9TmV3LVBlc3RlckNvbmZpZ3VyYXRpb24NCiRjb25maWcuUnVuLlBhdGg9QCgkVGVzdHNQYXRoKQ0KJGNvbmZpZy5SdW4uUGFzc1RocnU9JHRydWUNCiRjb25maWcuRmlsdGVyLkV4Y2x1ZGVUYWc9QCgkRXhjbHVkZWRUYWcpDQokY29uZmlnLk91dHB1dC5WZXJib3NpdHk9J05vcm1hbCcNCiRjb25maWcuVGVzdFJlc3VsdC5FbmFibGVkPSR0cnVlDQokY29uZmlnLlRlc3RSZXN1bHQuT3V0cHV0Rm9ybWF0PSdOVW5pdFhtbCcNCiRjb25maWcuVGVzdFJlc3VsdC5PdXRwdXRQYXRoPSRSZXN1bHRQYXRoDQokcmVzdWx0PUludm9rZS1QZXN0ZXIgLUNvbmZpZ3VyYXRpb24gJGNvbmZpZw0KJHN1bW1hcnk9W3BzY3VzdG9tb2JqZWN0XVtvcmRlcmVkXUB7IHBhc3NlZD1baW50XSRyZXN1bHQuUGFzc2VkQ291bnQ7IGZhaWxlZD1baW50XSRyZXN1bHQuRmFpbGVkQ291bnQ7IHNraXBwZWQ9W2ludF0kcmVzdWx0LlNraXBwZWRDb3VudDsgbm90X3J1bj1baW50XSRyZXN1bHQuTm90UnVuQ291bnQ7IHRvdGFsPVtpbnRdJHJlc3VsdC5Ub3RhbENvdW50OyBleGNsdWRlZF90YWc9JEV4Y2x1ZGVkVGFnOyBleHBlY3RlZF9leGNsdWRlZD1baW50XSRFeHBlY3RlZEV4Y2x1ZGVkQ291bnQgfQ0KW0lPLkZpbGVdOjpXcml0ZUFsbFRleHQoJFN1bW1hcnlQYXRoLCgoJHN1bW1hcnl8Q29udmVydFRvLUpzb24gLURlcHRoIDQpK1tFbnZpcm9ubWVudF06Ok5ld0xpbmUpLFtUZXh0LlVURjhFbmNvZGluZ106Om5ldygkZmFsc2UpKQ0KaWYgKCRzdW1tYXJ5LmZhaWxlZCAtbmUgMCAtb3IgJHN1bW1hcnkuc2tpcHBlZCAtbmUgMCAtb3IgJHN1bW1hcnkubm90X3J1biAtbmUgJEV4cGVjdGVkRXhjbHVkZWRDb3VudCAtb3IgKCRzdW1tYXJ5LnBhc3NlZCArICRzdW1tYXJ5Lm5vdF9ydW4pIC1uZSAkc3VtbWFyeS50b3RhbCkgeyBleGl0IDEgfQ=="
)

if mode == "bad-hosted-head":
    hosted["head_sha"] = "f" * 40
elif mode == "bad-partition":
    summary["passed"] = 908
elif mode == "bad-runner":
    runner += b" "
elif mode == "bad-name":
    wrapper["artifact_name"] = f"nxb-v11-predecessor-replay-v1-{predecessor}-{successor}-{run_id + 1}-{attempt}"
elif mode == "bad-production":
    wrapper["production_boundary"]["signer_used"] = True
elif mode == "bad-xml":
    ps7_xml = b'<!DOCTYPE x [<!ENTITY x "boom">]><test-results name="Pester" total="916" errors="0" failures="0" not-run="0" inconclusive="0" ignored="0" skipped="0" invalid="0" />'
elif mode not in ("good", "bad-child"):
    raise SystemExit("unknown mode")

def canonical(document):
    return json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")

contents = {
    "hosted-ci-receipt.json": canonical(hosted),
    "known-error-scan.json": canonical(known_error),
    "pester-ps51.xml": ps51_xml,
    "pester-ps7.xml": ps7_xml,
    "ps51-summary.json": canonical(summary),
    "run-ps51.ps1": runner,
}
hash_fields = {
    "hosted-ci-receipt.json": "hosted_ci_receipt_sha256",
    "known-error-scan.json": "known_error_scan_sha256",
    "pester-ps51.xml": "pester_ps51_xml_sha256",
    "pester-ps7.xml": "pester_ps7_xml_sha256",
    "ps51-summary.json": "ps51_summary_sha256",
    "run-ps51.ps1": "run_ps51_sha256",
}
for name, field in hash_fields.items():
    wrapper[field] = hashlib.sha256(contents[name]).hexdigest()

if mode == "bad-child":
    contents["known-error-scan.json"] += b" "

contents["predecessor-replay-receipt.json"] = canonical(wrapper)
with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for name in sorted(contents):
        archive.writestr(name, contents[name])

print(hashlib.sha256(destination.read_bytes()).hexdigest())
print(artifact_name)
'@
        try {
            [IO.File]::WriteAllText($generatorPath, $generator, [Text.UTF8Encoding]::new($false, $true))
            foreach ($case in @(
                @{ mode = 'good'; accepted = $true; pattern = 'PREDECESSOR_REPLAY_ARTIFACT_VALIDATED' },
                @{ mode = 'bad-child'; accepted = $false; pattern = 'predecessor replay child SHA-256 mismatch for known-error-scan.json' },
                @{ mode = 'bad-hosted-head'; accepted = $false; pattern = 'frozen hosted receipt predecessor head mismatch' },
                @{ mode = 'bad-partition'; accepted = $false; pattern = 'frozen PS5.1 summary partition mismatch: passed' },
                @{ mode = 'bad-runner'; accepted = $false; pattern = 'frozen predecessor run-ps51.ps1 byte identity drift' },
                @{ mode = 'bad-name'; accepted = $false; pattern = 'predecessor replay independent tuple mismatch: artifact_name' },
                @{ mode = 'bad-production'; accepted = $false; pattern = 'predecessor replay wrapper schema semantic validation failed' },
                @{ mode = 'bad-xml'; accepted = $false; pattern = 'pester-ps7.xml: XML DTD/entity declarations forbidden' }
            )) {
                $zip = Join-Path $root (([string]$case.mode) + '.zip')
                $made = Invoke-V11Python -Arguments @(
                    $generatorPath,
                    $script:RepositoryRoot,
                    $zip,
                    [string]$case.mode
                )
                $made.ExitCode | Should -Be 0
                $lines = @($made.Text.Trim().Split([Environment]::NewLine, [StringSplitOptions]::RemoveEmptyEntries))
                $zipHash = [string]$lines[0]
                $artifactName = [string]$lines[1]

                $run = Invoke-V11Python -Arguments @(
                    $tool,
                    '--mode', 'predecessor-replay-external-preflight',
                    '--zip', $zip,
                    '--schema-root', $schemaRoot,
                    '--expected-zip-sha256', $zipHash,
                    '--expected-predecessor-main-sha', '1111111111111111111111111111111111111111',
                    '--expected-predecessor-tree-sha', '2222222222222222222222222222222222222222',
                    '--expected-observer-successor-head-sha', '3333333333333333333333333333333333333333',
                    '--expected-run-id', '123456789',
                    '--expected-run-attempt', '1',
                    '--expected-artifact-name', $artifactName,
                    '--expected-predecessor-policy-sha256', ('a' * 64)
                )
                if ($case.accepted) {
                    $run.ExitCode | Should -Be 0
                    $doc = $run.Text | ConvertFrom-Json
                    [string]$doc.status | Should -BeExactly 'PREDECESSOR_REPLAY_ARTIFACT_VALIDATED'
                    [bool]$doc.wrapper_schema_validated | Should -BeTrue
                    [bool]$doc.child_hash_bindings_validated | Should -BeTrue
                    [bool]$doc.frozen_pester_partition_validated | Should -BeTrue
                    [bool]$doc.frozen_run_ps51_identity_validated | Should -BeTrue
                    [bool]$doc.admitted | Should -BeFalse
                    @($doc.unverified_gates) | Should -Contain 'github_run_and_artifact_metadata_provenance'
                    @($doc.unverified_gates) | Should -Contain 'runtime_and_package_byte_provenance'
                }
                else {
                    $run.ExitCode | Should -Be 2
                    $run.Text | Should -Match ([regex]::Escape([string]$case.pattern))
                }
            }

            $goodZip = Join-Path $root 'wrong-digest.zip'
            $made = Invoke-V11Python -Arguments @(
                $generatorPath,
                $script:RepositoryRoot,
                $goodZip,
                'good'
            )
            $made.ExitCode | Should -Be 0
            $lines = @($made.Text.Trim().Split([Environment]::NewLine, [StringSplitOptions]::RemoveEmptyEntries))
            $wrongDigest = Invoke-V11Python -Arguments @(
                $tool,
                '--mode', 'predecessor-replay-external-preflight',
                '--zip', $goodZip,
                '--schema-root', $schemaRoot,
                '--expected-zip-sha256', ('0' * 64),
                '--expected-predecessor-main-sha', '1111111111111111111111111111111111111111',
                '--expected-predecessor-tree-sha', '2222222222222222222222222222222222222222',
                '--expected-observer-successor-head-sha', '3333333333333333333333333333333333333333',
                '--expected-run-id', '123456789',
                '--expected-run-attempt', '1',
                '--expected-artifact-name', [string]$lines[1],
                '--expected-predecessor-policy-sha256', ('a' * 64)
            )
            $wrongDigest.ExitCode | Should -Be 2
            $wrongDigest.Text | Should -Match 'independently supplied predecessor replay ZIP digest mismatch'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects reparse-point ancestor aliases for every external compatibility input' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-ancestor-preflight-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        $probePath = Join-Path $root 'test-ancestor.py'
        $probe = @'
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location("nxb_v11_preflight", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory(prefix="nxb-v11-external-paths-") as scratch:
    root = Path(scratch)
    real = root / "real"
    real.mkdir()
    (real / "schema").mkdir()
    (real / "sample.zip").write_bytes(b"placeholder")
    alias = root / "alias"
    if os.name == "nt":
        made = subprocess.run(
            ["cmd", "/d", "/c", "mklink", "/J", str(alias), str(real)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
        )
        if made.returncode != 0:
            raise AssertionError(f"junction setup failed: {made.stderr}")
    else:
        alias.symlink_to(real, target_is_directory=True)
    try:
        checks = {
            "review ZIP": lambda: module._ordinary_zip(alias / "sample.zip"),
            "schema root": lambda: module._ordinary_schema_root(alias / "schema"),
            "predecessor ZIP": lambda: module._predecessor_ordinary_path(alias / "sample.zip", directory=False),
            "predecessor schema": lambda: module._predecessor_ordinary_path(alias / "schema", directory=True),
        }
        for label, check in checks.items():
            try:
                check()
            except module.PreflightError:
                pass
            else:
                raise AssertionError(f"{label} accepted reparse-backed ancestor")
        print("external ancestor path checks: 4 rejected")
    finally:
        if os.name == "nt":
            alias.rmdir()
        else:
            alias.unlink()
'@
        try {
            [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($false))
            $tool = Join-Path $script:RepositoryRoot 'validation\v11\tools\validate_v11_compatibility.py'
            $run = Invoke-V11Python -Arguments @($probePath, $tool)
            if ($run.ExitCode -ne 0) { throw ('Ancestor probe failed: ' + $run.Text) }
            $run.ExitCode | Should -Be 0
            $run.Text | Should -Match 'external ancestor path checks: 4 rejected'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

}


Describe 'V11 A0 central toolchain and compatibility-policy schema closure (claim-free)' {
    It 'validates strict ownership schemas and rejects recursive, stale, fake and prematurely-enabled authority' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-central-policy-schema-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        $probe = Join-Path $root 'validate-central-policy-schemas.py'
        $source = @'
import copy
import json
import pathlib
import sys
from importlib.metadata import version

from jsonschema import Draft202012Validator
from jsonschema.exceptions import ValidationError

repo = pathlib.Path(sys.argv[1])
schemas = repo / "schemas"
fixtures = repo / "validation" / "v11" / "fixtures" / "compatibility-artifact"

assert version("jsonschema") == "4.26.0"

central_schema = json.loads(
    (schemas / "nxb-v11-validation-toolchain-lock.schema.json").read_text(encoding="utf-8")
)
central = json.loads(
    (fixtures / "validation-toolchain-lock-v1.synthetic.json").read_text(encoding="utf-8")
)
policy_schema = json.loads(
    (schemas / "nxb-v11-compatibility-policy.schema.json").read_text(encoding="utf-8")
)
policy = json.loads(
    (fixtures / "compatibility-policy-v1.synthetic.json").read_text(encoding="utf-8")
)

assert central_schema["$id"] == "urn:nxb:schema:nxb-v11-validation-toolchain-lock:v1"
assert policy_schema["$id"] == "urn:nxb:schema:nxb-v11-compatibility-policy:v1"
assert central_schema["additionalProperties"] is False
assert policy_schema["additionalProperties"] is False
assert central_schema["properties"]["authority"]["const"] == "nxb-v11-validation-toolchain-lock-v1"
assert policy_schema["properties"]["authority"]["const"] == "nxb-v11-compatibility-policy-v1"

for forbidden in (
    "validation_toolchain_lock_sha256",
    "pester_package_sha256",
    "psscriptanalyzer_package_sha256",
    "packages",
    "modules",
):
    assert forbidden not in central_schema["properties"]

for forbidden in ("policy_sha256", "compatibility_policy_sha256", "shared_pins"):
    assert forbidden not in policy_schema["properties"]

assert central_schema["properties"]["action_pin_set_sha256"]["const"] == (
    "3bd5b7957b1b599e40c5d7e7d6afebf755d2b4021d62fa316d016b4ff7eccf0b"
)
assert central_schema["properties"]["powershell_runtime_admission_authority"]["const"] == (
    "nxb-v11-powershell-runtime-admission-v2"
)
assert central_schema["properties"]["selected_host_python_dependency_lock_path"]["const"] == (
    "validation/v11/locks/validator-py312.lock"
)

actions = central_schema["$defs"]["actions"]["prefixItems"]
assert [(x["properties"]["repository"]["const"], x["properties"]["commit_sha"]["const"]) for x in actions] == [
    ("actions/checkout", "3d3c42e5aac5ba805825da76410c181273ba90b1"),
    ("actions/setup-python", "5fda3b95a4ea91299a34e894583c3862153e4b97"),
    ("actions/upload-artifact", "ea165f8d65b6e75b540449e92b4886f43607fa02"),
]

expected_ids = {
    "win11-25h2-x64-ps76-py312-adk26100",
    "win11-25h2-x64-ps76-py314-adk26100",
    "win11-25h2-x64-ps76-py313-adk26100",
    "win11-25h2-x64-ps75-py312-adk26100",
    "win11-25h2-x64-ps74-py312-adk26100",
    "win11-24h2-enterprise-education-x64-ps76-py312-adk26100",
    "win10-22h2-x64-ps76-py312-adk26100-legacy-esu",
    "win11-26h1-arm64-ps76-py312-adk28000",
}
assert {cell["id"] for cell in policy["cells"]} == expected_ids
assert len(policy["cells"]) == 8
assert all(cell["status"] == "provisional-disabled" for cell in policy["cells"])
assert all("selectors" not in cell for cell in policy["cells"])
assert policy["predecessor"] == {
    "main_sha": "9203ab9f89ff4383832119683eb4e19df5490213",
    "main_tree_sha": "241d3086e9bcb5a847445258cab25bff4fd34da8",
    "issue": 26,
    "pr": 48,
}
assert policy["review"] == {"entry_count": 6, "retention_days": 7}

Draft202012Validator.check_schema(central_schema)
Draft202012Validator.check_schema(policy_schema)
central_validator = Draft202012Validator(central_schema)
policy_validator = Draft202012Validator(policy_schema)
central_validator.validate(central)
policy_validator.validate(policy)

def rejected(validator, document):
    try:
        validator.validate(document)
    except ValidationError:
        return
    raise AssertionError("negative control unexpectedly passed")

bad = copy.deepcopy(central)
bad["validation_toolchain_lock_sha256"] = "0" * 64
rejected(central_validator, bad)

bad = copy.deepcopy(central)
bad["pester_package_sha256"] = "0" * 64
rejected(central_validator, bad)

bad = copy.deepcopy(central)
bad["actions"][2]["commit_sha"] = "0" * 40
rejected(central_validator, bad)

bad = copy.deepcopy(central)
bad["actions"][0], bad["actions"][1] = bad["actions"][1], bad["actions"][0]
rejected(central_validator, bad)

bad = copy.deepcopy(central)
bad["powershell_runtime_admission_authority"] = "nxb-v11-powershell-runtime-admission-v1"
rejected(central_validator, bad)

bad = copy.deepcopy(central)
bad["selected_host_python_dependency_lock_path"] = "validation/v11/locks/validator-py313.lock"
rejected(central_validator, bad)

bad = copy.deepcopy(central)
bad["validation_host_powershell"]["version"] = "7.6.5"
rejected(central_validator, bad)

bad = copy.deepcopy(central)
bad["validation_host_python"]["version"] = "3.12.11"
rejected(central_validator, bad)

bad = copy.deepcopy(policy)
bad["policy_sha256"] = "0" * 64
rejected(policy_validator, bad)

bad = copy.deepcopy(policy)
bad["compatibility_policy_sha256"] = "0" * 64
rejected(policy_validator, bad)

bad = copy.deepcopy(policy)
bad["shared_pins"] = {}
rejected(policy_validator, bad)

bad = copy.deepcopy(policy)
bad["predecessor"]["main_sha"] = "0" * 40
rejected(policy_validator, bad)

bad = copy.deepcopy(policy)
bad["review"]["entry_count"] = 7
rejected(policy_validator, bad)

bad = copy.deepcopy(policy)
bad["cells"].pop()
rejected(policy_validator, bad)

bad = copy.deepcopy(policy)
bad["cells"][0]["status"] = "enabled"
del bad["cells"][0]["disabled_reason"]
del bad["cells"][0]["unresolved_gates"]
rejected(policy_validator, bad)

bad = copy.deepcopy(policy)
del bad["cells"][0]["unresolved_gates"]
rejected(policy_validator, bad)

bad = copy.deepcopy(policy)
bad["cells"][0]["selectors"] = {
    "modules": {
        "powershell_module_lock_path": "validation/v11/locks/powershell-modules.lock.json",
        "powershell_module_lock_sha256": "TBD",
    }
}
rejected(policy_validator, bad)

bad = copy.deepcopy(policy)
bad["cells"][0]["package_inventory"] = []
rejected(policy_validator, bad)

print("CENTRAL_POLICY_SCHEMA_PASS")
'@
        try {
            [IO.File]::WriteAllText($probe, $source, [Text.UTF8Encoding]::new($false, $true))
            $run = Invoke-V11Python -Arguments @($probe, $script:RepositoryRoot)
            $run.ExitCode | Should -Be 0
            $run.Text | Should -Match 'CENTRAL_POLICY_SCHEMA_PASS'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}


Describe 'V11 compatibility authority documentation source contract' {
    It 'keeps the public authority map claim-free and bound to frozen identities' {
        $path = Join-Path $script:RepositoryRoot 'docs\NXB-V11-COMPATIBILITY-AUTHORITY.md'
        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        $bytes = [IO.File]::ReadAllBytes($path)
        $bytes.Length | Should -BeGreaterThan 0
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)

        foreach ($token in @(
            'A0_ALLOWLIST_VERSION=6',
            'A0_ALLOWLIST_AUTHORITY_COMMENT=5426682541',
            'A0_HOSTED_ARTIFACT_AUTHORITY=nxb-v11-a0-hosted-substrate-v1',
            'A0_SUBSTRATE_RECEIPT_AUTHORITY=nxb-v11-a0-substrate-receipt-v1',
            'PREDECESSOR_REPLAY_AUTHORITY=nxb-v11-predecessor-replay-v1',
            'CENTRAL_TOOLCHAIN_AUTHORITY=nxb-v11-validation-toolchain-lock-v1',
            'COMPATIBILITY_POLICY_AUTHORITY=nxb-v11-compatibility-policy-v1',
            'PHYSICAL_COMPATIBILITY_CLAIMS=0',
            'NATIVE_WPT_DISPATCH_PERFORMED=false',
            'LIVE6_AUTHORITY_HOST=DESKTOP-ONDD84S\umut',
            'LIVE6_DIAGNOSTIC_PROMOTION_COMMENT=6000434321',
            'LIVE6_DIAGNOSTIC_PROMOTION_STATE=ISSUED_UNCONSUMED',
            'LIVE6_DIAGNOSTIC_SHA256=4bf7a001ab7f161151f5b9a4feaf092c46f45acd847a7ff445476c1ccd8a099e',
            'LIVE6_DIAGNOSTIC_RESULT_STATE=ABSENT',
            'LIVE6_RUNTIME_PROMOTION_STATE=ABSENT',
            'A0_REMAINING_MANDATORY_EXACT_PATHS=7',
            'LIVE6_BLOCKER_CHECKPOINT_COMMENT=6053582069',
            '9203ab9f89ff4383832119683eb4e19df5490213',
            '241d3086e9bcb5a847445258cab25bff4fd34da8',
            '3d3c42e5aac5ba805825da76410c181273ba90b1',
            '5fda3b95a4ea91299a34e894583c3862153e4b97',
            'ea165f8d65b6e75b540449e92b4886f43607fa02',
            '3bd5b7957b1b599e40c5d7e7d6afebf755d2b4021d62fa316d016b4ff7eccf0b',
            '035ac21a439c448be6ad6d946bd3526162f678b1858d09562b69c5616a49397b',
            'compatibility-policy-summary.json',
            'canonicalization-conformance.json',
            'native-impact-classifier-fixtures.json',
            'known-error-scan.json',
            'independent-validation.json',
            'a0-substrate-receipt.json',
            'hosted-ci-receipt.json',
            'pester-ps51.xml',
            'pester-ps7.xml',
            'ps51-summary.json',
            'run-ps51.ps1',
            'predecessor-replay-receipt.json',
            'This document is explanatory source.'
        )) {
            ([regex]::Matches($text, [regex]::Escape($token))).Count | Should -BeGreaterThan 0
        }

        $text | Should -Not -Match 'PHYSICAL_COMPATIBILITY_CLAIMS=1'
        $text | Should -Not -Match 'NATIVE_WPT_DISPATCH_PERFORMED=true'
        $text | Should -Match 'pull_request_target.*forbidden'
        $text | Should -Match 'runtime / trusted-preparation execution chain remains a separate HOLD'
        $text | Should -Match 'single-use promotion `6000434321` remains `ISSUED / UNCONSUMED`'
        $text | Should -Match 'Exactly seven mandatory A0 exact paths remain unresolved'
        $text | Should -Match 'No SYSTEM, scheduled-task, token-substitution, private-desktop, alternate-host, or CI workaround'
        $text | Should -Match 'Editing this file cannot make a disabled cell enabled'
    }
}


Describe 'V11 candidate dispatcher exact intent binding' {
    BeforeAll {
        $script:DispatcherPath = Join-Path $script:RepositoryRoot 'validation\v11\scripts\Invoke-NxbV11CandidateDispatcher.ps1'
        $script:PwshPath = [IO.Path]::GetFullPath((Get-Command pwsh -ErrorAction Stop).Source)

        function Get-TestSha256Text {
            param([Parameter(Mandatory = $true)][string]$Text)
            $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($Text)
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
            }
            finally {
                $sha.Dispose()
            }
        }

        function Invoke-TestGit {
            param(
                [Parameter(Mandatory = $true)][string]$Repository,
                [Parameter(Mandatory = $true)][string[]]$Arguments
            )
            $previous = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $output = @(& git -C $Repository @Arguments 2>&1 | ForEach-Object { [string]$_ })
                $exitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previous
            }
            if ($exitCode -ne 0) {
                throw "git $($Arguments -join ' ') failed: $($output -join ' | ')"
            }
            return @($output)
        }

        function Get-TestGitOne {
            param(
                [Parameter(Mandatory = $true)][string]$Repository,
                [Parameter(Mandatory = $true)][string[]]$Arguments
            )
            $rows = @(Invoke-TestGit -Repository $Repository -Arguments $Arguments |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($rows.Count -ne 1) {
                throw "git $($Arguments -join ' ') expected one row, got $($rows.Count)"
            }
            return $rows[0].Trim()
        }

        function New-DispatcherFixture {
            param([ValidateSet('enabled', 'provisional-disabled')][string]$CellStatus = 'enabled')

            $outer = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-dispatcher-' + [Guid]::NewGuid().ToString('N'))
            $repository = Join-Path $outer 'repo'
            $out = Join-Path $outer 'out'
            [void][IO.Directory]::CreateDirectory($repository)
            [void][IO.Directory]::CreateDirectory($out)

            [void](Invoke-TestGit -Repository $repository -Arguments @('init', '--quiet'))
            [void](Invoke-TestGit -Repository $repository -Arguments @('config', 'user.name', 'NXB Test'))
            [void](Invoke-TestGit -Repository $repository -Arguments @('config', 'user.email', 'nxb-test@example.invalid'))
            [void](Invoke-TestGit -Repository $repository -Arguments @('config', 'core.autocrlf', 'false'))

            [void][IO.Directory]::CreateDirectory((Join-Path $repository 'scripts'))
            Copy-Item -LiteralPath $script:EvidenceStorePath -Destination (Join-Path $repository 'scripts\Nxb.EvidenceStore.psm1') -Force
            (Get-FileHash -LiteralPath (Join-Path $repository 'scripts\Nxb.EvidenceStore.psm1') -Algorithm SHA256).Hash.ToLowerInvariant() |
                Should -BeExactly '207a3e379e411fa6761f21cf01810135572d87033779ec8f791fa0befcd17cd7'
            Write-Utf8NoBom -Path (Join-Path $repository 'base.txt') -Text 'base'
            [void](Invoke-TestGit -Repository $repository -Arguments @('add', '--', 'scripts/Nxb.EvidenceStore.psm1', 'base.txt'))
            [void](Invoke-TestGit -Repository $repository -Arguments @('commit', '--quiet', '-m', 'base'))
            $baseSha = Get-TestGitOne -Repository $repository -Arguments @('rev-parse', 'HEAD')
            $baseTree = Get-TestGitOne -Repository $repository -Arguments @('rev-parse', 'HEAD^{tree}')

            Write-Utf8NoBom -Path (Join-Path $repository 'candidate.txt') -Text 'candidate'
            [void](Invoke-TestGit -Repository $repository -Arguments @('add', '--', 'candidate.txt'))
            [void](Invoke-TestGit -Repository $repository -Arguments @('commit', '--quiet', '-m', 'candidate'))
            $candidateSha = Get-TestGitOne -Repository $repository -Arguments @('rev-parse', 'HEAD')
            $candidateTree = Get-TestGitOne -Repository $repository -Arguments @('rev-parse', 'HEAD^{tree}')

            [void](Invoke-TestGit -Repository $repository -Arguments @('checkout', '--quiet', '-b', 'dispatcher', $baseSha))
            [void][IO.Directory]::CreateDirectory((Join-Path $repository '.github\workflows'))
            [void][IO.Directory]::CreateDirectory((Join-Path $repository 'config'))

            $workflowText = @'
name: NXB V11 Fixture
on:
  workflow_dispatch:
jobs:
  fixture:
    runs-on: windows-2022
    steps:
      - run: Write-Output fixture
'@
            Write-Utf8NoBom -Path (Join-Path $repository '.github\workflows\nxb-v11-compatibility.yml') -Text $workflowText

            $cell = [ordered]@{
                id = 'win11-25h2-x64-ps76-py312-adk26100'
                status = $CellStatus
            }
            $policy = [ordered]@{
                authority = 'nxb-v11-compatibility-policy-v1'
                schema_version = 1
                cells = @($cell)
            }
            $canonicalPolicy = ConvertTo-NxbCanonicalJson -InputObject $policy
            Write-Utf8NoBom -Path (Join-Path $repository 'config\nxb-v11-compatibility-policy.json') -Text $canonicalPolicy
            $policySha = Get-TestSha256Text -Text $canonicalPolicy

            [void](Invoke-TestGit -Repository $repository -Arguments @(
                'add', '--',
                '.github/workflows/nxb-v11-compatibility.yml',
                'config/nxb-v11-compatibility-policy.json'
            ))
            [void](Invoke-TestGit -Repository $repository -Arguments @('commit', '--quiet', '-m', 'dispatcher'))
            $dispatcherSha = Get-TestGitOne -Repository $repository -Arguments @('rev-parse', 'HEAD')
            $dispatcherTree = Get-TestGitOne -Repository $repository -Arguments @('rev-parse', 'HEAD^{tree}')
            $workflowBlob = Get-TestGitOne -Repository $repository -Arguments @(
                'rev-parse',
                ($dispatcherSha + ':.github/workflows/nxb-v11-compatibility.yml')
            )

            $harnessSha = ('a' * 64)
            $candidatePr = [long]123
            $workflowId = [long]777
            $intent = [ordered]@{
                authority = 'nxb-v11-compatibility-dispatch-intent-v1'
                execution_mode = 'candidate'
                repository = 'Naveax/nxb-integrity-research-lab'
                repository_id = [long]1322938859
                workflow_path = '.github/workflows/nxb-v11-compatibility.yml'
                workflow_id = $workflowId
                admitted_dispatcher_sha = $dispatcherSha
                admitted_dispatcher_tree = $dispatcherTree
                admitted_workflow_blob_sha = $workflowBlob
                harness_manifest_sha256 = $harnessSha
                candidate_sha = $candidateSha
                candidate_tree = $candidateTree
                candidate_pr = $candidatePr
                base_sha = $baseSha
                base_tree = $baseTree
                policy_sha256 = $policySha
                cell_id = 'win11-25h2-x64-ps76-py312-adk26100'
                endurance_tier = '1h'
                runner_class = 'nxb-native'
            }
            $intentSha = Get-TestSha256Text -Text (ConvertTo-NxbCanonicalJson -InputObject $intent)

            @((Invoke-TestGit -Repository $repository -Arguments @('status', '--porcelain=v1', '--untracked-files=all')) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count | Should -Be 0

            return [pscustomobject]@{
                Outer = $outer
                Repository = [IO.Path]::GetFullPath($repository)
                OutputRoot = [IO.Path]::GetFullPath($out)
                ModulePath = [IO.Path]::GetFullPath((Join-Path $repository 'scripts\Nxb.EvidenceStore.psm1'))
                BaseSha = $baseSha
                BaseTree = $baseTree
                CandidateSha = $candidateSha
                CandidateTree = $candidateTree
                DispatcherSha = $dispatcherSha
                DispatcherTree = $dispatcherTree
                WorkflowBlob = $workflowBlob
                WorkflowId = $workflowId
                HarnessSha = $harnessSha
                PolicySha = $policySha
                CandidatePr = $candidatePr
                IntentSha = $intentSha
            }
        }

        function Invoke-DispatcherChild {
            param(
                [Parameter(Mandatory = $true)]$Fixture,
                [string]$ExpectedIntentSha256,
                [string]$OutputReceiptPath,
                [long]$RunId = 987654321,
                [long]$RunAttempt = 1
            )

            if ([string]::IsNullOrWhiteSpace($ExpectedIntentSha256)) {
                $ExpectedIntentSha256 = [string]$Fixture.IntentSha
            }
            if ([string]::IsNullOrWhiteSpace($OutputReceiptPath)) {
                $OutputReceiptPath = [IO.Path]::GetFullPath((Join-Path $Fixture.OutputRoot ('receipt-' + [Guid]::NewGuid().ToString('N') + '.json')))
            }

            $configPath = Join-Path $Fixture.OutputRoot ('config-' + [Guid]::NewGuid().ToString('N') + '.json')
            $resultPath = Join-Path $Fixture.OutputRoot ('result-' + [Guid]::NewGuid().ToString('N') + '.json')
            $runnerPath = Join-Path $Fixture.OutputRoot ('runner-' + [Guid]::NewGuid().ToString('N') + '.ps1')

            $config = [ordered]@{
                RepositoryRoot = [string]$Fixture.Repository
                ExecutionMode = 'candidate'
                Repository = 'Naveax/nxb-integrity-research-lab'
                RepositoryId = [long]1322938859
                WorkflowPath = '.github/workflows/nxb-v11-compatibility.yml'
                WorkflowId = [long]$Fixture.WorkflowId
                AdmittedDispatcherSha = [string]$Fixture.DispatcherSha
                AdmittedDispatcherTree = [string]$Fixture.DispatcherTree
                AdmittedWorkflowBlobSha = [string]$Fixture.WorkflowBlob
                HarnessManifestSha256 = [string]$Fixture.HarnessSha
                CandidateSha = [string]$Fixture.CandidateSha
                CandidateTree = [string]$Fixture.CandidateTree
                CandidatePr = [long]$Fixture.CandidatePr
                BaseSha = [string]$Fixture.BaseSha
                BaseTree = [string]$Fixture.BaseTree
                PolicySha256 = [string]$Fixture.PolicySha
                CellId = 'win11-25h2-x64-ps76-py312-adk26100'
                EnduranceTier = '1h'
                RunnerClass = 'nxb-native'
                ExpectedIntentSha256 = $ExpectedIntentSha256
                EvidenceStoreModulePath = [string]$Fixture.ModulePath
                OutputReceiptPath = $OutputReceiptPath
                RunId = $RunId
                RunAttempt = $RunAttempt
                Event = 'workflow_dispatch'
            }
            Write-Utf8NoBom -Path $configPath -Text ($config | ConvertTo-Json -Compress -Depth 20)

            $runner = @'
param(
    [Parameter(Mandatory = $true)][string]$DispatcherPath,
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$ResultPath
)
$ErrorActionPreference = 'Stop'
try {
    $c = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable -Depth 50
    $params = @{
        RepositoryRoot = [string]$c.RepositoryRoot
        ExecutionMode = [string]$c.ExecutionMode
        Repository = [string]$c.Repository
        RepositoryId = [long]$c.RepositoryId
        WorkflowPath = [string]$c.WorkflowPath
        WorkflowId = [long]$c.WorkflowId
        AdmittedDispatcherSha = [string]$c.AdmittedDispatcherSha
        AdmittedDispatcherTree = [string]$c.AdmittedDispatcherTree
        AdmittedWorkflowBlobSha = [string]$c.AdmittedWorkflowBlobSha
        HarnessManifestSha256 = [string]$c.HarnessManifestSha256
        CandidateSha = [string]$c.CandidateSha
        CandidateTree = [string]$c.CandidateTree
        CandidatePr = [long]$c.CandidatePr
        BaseSha = [string]$c.BaseSha
        BaseTree = [string]$c.BaseTree
        PolicySha256 = [string]$c.PolicySha256
        CellId = [string]$c.CellId
        EnduranceTier = [string]$c.EnduranceTier
        RunnerClass = [string]$c.RunnerClass
        ExpectedIntentSha256 = [string]$c.ExpectedIntentSha256
        EvidenceStoreModulePath = [string]$c.EvidenceStoreModulePath
        OutputReceiptPath = [string]$c.OutputReceiptPath
        RunId = [long]$c.RunId
        RunAttempt = [long]$c.RunAttempt
        Event = [string]$c.Event
        PassThru = $true
    }
    $result = & $DispatcherPath @params
    $json = $result | ConvertTo-Json -Compress -Depth 20
    [IO.File]::WriteAllText($ResultPath, $json, [Text.UTF8Encoding]::new($false, $true))
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
'@
            Write-Utf8NoBom -Path $runnerPath -Text $runner

            $previous = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $output = @(& $script:PwshPath -NoLogo -NoProfile -File $runnerPath -DispatcherPath $script:DispatcherPath -ConfigPath $configPath -ResultPath $resultPath 2>&1 | ForEach-Object { [string]$_ })
                $exitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previous
            }

            $result = $null
            if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
                $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            }
            return [pscustomobject]@{
                ExitCode = [int]$exitCode
                Text = ($output -join [Environment]::NewLine)
                Result = $result
                ReceiptPath = $OutputReceiptPath
            }
        }
    }

    It 'recomputes the exact candidate intent and writes only an external immutable receipt' {
        $fixture = New-DispatcherFixture
        try {
            $run = Invoke-DispatcherChild -Fixture $fixture
            $run.ExitCode | Should -Be 0
            [string]$run.Result.status | Should -BeExactly 'passed'
            [string]$run.Result.authority | Should -BeExactly 'nxb-v11-compatibility-dispatch-intent-v1'
            [string]$run.Result.execution_mode | Should -BeExactly 'candidate'
            [string]$run.Result.intent_sha256 | Should -BeExactly $fixture.IntentSha
            [bool]$run.Result.receipt_written | Should -BeTrue
            [bool]$run.Result.repository_mutated | Should -BeFalse
            [bool]$run.Result.dispatch_performed_by_this_script | Should -BeFalse

            Test-Path -LiteralPath $run.ReceiptPath -PathType Leaf | Should -BeTrue
            $bytes = [IO.File]::ReadAllBytes($run.ReceiptPath)
            ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
            $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
            $text.EndsWith([string][char]10) | Should -BeFalse
            $receipt = $text | ConvertFrom-Json
            [string]$receipt.authority | Should -BeExactly 'nxb-v11-compatibility-dispatch-intent-receipt-v1'
            [string]$receipt.status | Should -BeExactly 'passed'
            [string]$receipt.intent_sha256 | Should -BeExactly $fixture.IntentSha
            [long]$receipt.run_id | Should -Be 987654321
            [long]$receipt.run_attempt | Should -Be 1
            [string]$receipt.event | Should -BeExactly 'workflow_dispatch'
            [bool]$receipt.intent_recomputed_valid | Should -BeTrue
            [bool]$receipt.repository_mutated | Should -BeFalse
            [bool]$receipt.dispatch_performed_by_this_script | Should -BeFalse

            @((Invoke-TestGit -Repository $fixture.Repository -Arguments @('status', '--porcelain=v1', '--untracked-files=all')) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count | Should -Be 0
        }
        finally {
            Remove-Item -LiteralPath $fixture.Outer -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'fails closed on intent drift, dirty checkout, in-repository receipt and disabled cell' {
        $fixture = New-DispatcherFixture
        try {
            $wrongIntent = Invoke-DispatcherChild -Fixture $fixture -ExpectedIntentSha256 ('0' * 64)
            $wrongIntent.ExitCode | Should -Be 1
            $wrongIntent.Text | Should -Match 'intent SHA-256 mismatch'

            Write-Utf8NoBom -Path (Join-Path $fixture.Repository 'dirty.txt') -Text 'dirty'
            $dirty = Invoke-DispatcherChild -Fixture $fixture
            $dirty.ExitCode | Should -Be 1
            $dirty.Text | Should -Match 'worktree must be clean'
            Remove-Item -LiteralPath (Join-Path $fixture.Repository 'dirty.txt') -Force

            $insideReceipt = [IO.Path]::GetFullPath((Join-Path $fixture.Repository 'receipt.json'))
            $inside = Invoke-DispatcherChild -Fixture $fixture -OutputReceiptPath $insideReceipt
            $inside.ExitCode | Should -Be 1
            $inside.Text | Should -Match 'must be outside the trusted repository worktree'
            Test-Path -LiteralPath $insideReceipt | Should -BeFalse
        }
        finally {
            Remove-Item -LiteralPath $fixture.Outer -Recurse -Force -ErrorAction SilentlyContinue
        }

        $disabled = New-DispatcherFixture -CellStatus provisional-disabled
        try {
            $run = Invoke-DispatcherChild -Fixture $disabled
            $run.ExitCode | Should -Be 1
            $run.Text | Should -Match 'CellId is not enabled'
        }
        finally {
            Remove-Item -LiteralPath $disabled.Outer -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'remains verification-only and contains no dispatch or network mutation primitive' {
        $source = Get-Content -LiteralPath $script:DispatcherPath -Raw
        $source | Should -Not -Match '(?im)\bgh\s+(api|workflow|run)\b'
        $source | Should -Not -Match '(?i)\bInvoke-(WebRequest|RestMethod)\b'
        $source | Should -Not -Match '(?i)\bStart-Process\b'
        $source | Should -Not -Match '(?im)\bgit\s+(push|commit|merge|tag|reset|checkout)\b'
        $source | Should -Not -Match '(?i)\b(upload-artifact|download-artifact)\b'
        $source | Should -Match 'dispatch_performed_by_this_script\s*=\s*\$false'
    }
}


Describe 'V11 A0 hosted source preflight (claim-free)' {
    BeforeAll {
        $script:HostedPreflightPath = Join-Path $script:RepositoryRoot 'validation\v11\scripts\Invoke-NxbV11CompatibilityHostedValidation.ps1'
        $script:HostedPwshPath = [IO.Path]::GetFullPath((Get-Command pwsh -ErrorAction Stop).Source)

        function Invoke-HostedTestGit {
            param(
                [Parameter(Mandatory = $true)][string]$Repository,
                [Parameter(Mandatory = $true)][string[]]$Arguments
            )
            $previous = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $output = @(& git -C $Repository @Arguments 2>&1 | ForEach-Object { [string]$_ })
                $exitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previous
            }
            if ($exitCode -ne 0) {
                throw "git $($Arguments -join ' ') failed: $($output -join ' | ')"
            }
            return @($output)
        }

        function Get-HostedTestGitOne {
            param(
                [Parameter(Mandatory = $true)][string]$Repository,
                [Parameter(Mandatory = $true)][string[]]$Arguments
            )
            $rows = @(Invoke-HostedTestGit -Repository $Repository -Arguments $Arguments | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($rows.Count -ne 1) {
                throw "git $($Arguments -join ' ') expected one row, got $($rows.Count)"
            }
            return $rows[0].Trim()
        }

        function New-HostedSourceFixture {
            param(
                [ValidateSet('allowed', 'outside', 'script-fixture')]
                [string]$Mode = 'allowed',
                [switch]$Dirty
            )

            $outer = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-hosted-preflight-' + [Guid]::NewGuid().ToString('N'))
            $repository = Join-Path $outer 'repo'
            [void][IO.Directory]::CreateDirectory($outer)

            $previous = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $cloneOutput = @(& git clone --quiet --no-hardlinks $script:RepositoryRoot $repository 2>&1 | ForEach-Object { [string]$_ })
                $cloneExit = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previous
            }
            if ($cloneExit -ne 0) {
                throw "fixture clone failed: $($cloneOutput -join ' | ')"
            }

            [void](Invoke-HostedTestGit -Repository $repository -Arguments @('config', 'user.name', 'NXB Test'))
            [void](Invoke-HostedTestGit -Repository $repository -Arguments @('config', 'user.email', 'nxb-test@example.invalid'))
            [void](Invoke-HostedTestGit -Repository $repository -Arguments @('config', 'core.autocrlf', 'false'))
            [void](Invoke-HostedTestGit -Repository $repository -Arguments @('checkout', '--quiet', '--detach', '9203ab9f89ff4383832119683eb4e19df5490213'))

            switch ($Mode) {
                'allowed' {
                    $relative = 'validation/v11/fixtures/compatibility-artifact/source-preflight.synthetic.json'
                    $content = '{}'
                }
                'outside' {
                    $relative = 'outside-v11.txt'
                    $content = 'outside'
                }
                'script-fixture' {
                    $relative = 'validation/v11/fixtures/compatibility-artifact/hidden.ps1'
                    $content = 'Write-Output hidden'
                }
            }

            $full = Join-Path $repository ($relative.Replace('/', '\'))
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $full))
            Write-Utf8NoBom -Path $full -Text $content
            [void](Invoke-HostedTestGit -Repository $repository -Arguments @('add', '--', $relative))
            [void](Invoke-HostedTestGit -Repository $repository -Arguments @('commit', '--quiet', '-m', 'hosted preflight fixture'))

            $candidateSha = Get-HostedTestGitOne -Repository $repository -Arguments @('rev-parse', 'HEAD')
            $candidateTree = Get-HostedTestGitOne -Repository $repository -Arguments @('rev-parse', 'HEAD^{tree}')

            if ($Dirty) {
                Write-Utf8NoBom -Path $full -Text ($content + ' dirty')
            }

            return [pscustomobject]@{
                Outer = $outer
                Repository = [IO.Path]::GetFullPath($repository)
                ModulePath = [IO.Path]::GetFullPath((Join-Path $repository 'scripts\Nxb.EvidenceStore.psm1'))
                CandidateSha = $candidateSha
                CandidateTree = $candidateTree
            }
        }

        function Invoke-HostedPreflightChild {
            param(
                [Parameter(Mandatory = $true)]$Fixture,
                [string]$CandidateTree
            )

            if ([string]::IsNullOrWhiteSpace($CandidateTree)) {
                $CandidateTree = [string]$Fixture.CandidateTree
            }

            $runnerPath = Join-Path $Fixture.Outer ('runner-' + [Guid]::NewGuid().ToString('N') + '.ps1')
            $runner = @'
param(
    [Parameter(Mandatory = $true)][string]$HostedPath,
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$CandidateSha,
    [Parameter(Mandatory = $true)][string]$CandidateTree,
    [Parameter(Mandatory = $true)][string]$EvidenceStoreModulePath
)
$ErrorActionPreference = 'Stop'
try {
    $result = & $HostedPath -RepositoryRoot $RepositoryRoot -CandidateSha $CandidateSha -CandidateTree $CandidateTree -EvidenceStoreModulePath $EvidenceStoreModulePath -PassThru
    $result | ConvertTo-Json -Compress -Depth 30
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
'@
            Write-Utf8NoBom -Path $runnerPath -Text $runner

            $previous = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $output = @(& $script:HostedPwshPath -NoLogo -NoProfile -File $runnerPath -HostedPath $script:HostedPreflightPath -RepositoryRoot $Fixture.Repository -CandidateSha $Fixture.CandidateSha -CandidateTree $CandidateTree -EvidenceStoreModulePath $Fixture.ModulePath 2>&1 | ForEach-Object { [string]$_ })
                $exitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previous
            }

            $text = $output -join [Environment]::NewLine
            $result = $null
            if ($exitCode -eq 0) {
                $result = $text | ConvertFrom-Json
            }
            return [pscustomobject]@{
                ExitCode = [int]$exitCode
                Text = $text
                Result = $result
            }
        }
    }

    It 'reconstructs frozen allowlist and coverage while remaining non-admitting' {
        $fixture = New-HostedSourceFixture -Mode allowed
        try {
            $run = Invoke-HostedPreflightChild -Fixture $fixture
            $run.ExitCode | Should -Be 0
            [string]$run.Result.status | Should -BeExactly 'SOURCE_PREFLIGHT_ONLY'
            [bool]$run.Result.admitted | Should -BeFalse
            [int]$run.Result.physical_compatibility_claims | Should -Be 0
            [bool]$run.Result.native_wpt_dispatch_performed | Should -BeFalse
            [bool]$run.Result.repository_mutated | Should -BeFalse
            [int]$run.Result.allowlist_version | Should -Be 6
            [long]$run.Result.allowlist_authority_comment_id | Should -Be 5426682541
            [int]$run.Result.a0_allowlist_exact_path_count | Should -Be 44
            [int]$run.Result.a0_allowlist_subtree_rule_count | Should -Be 7
            [string]$run.Result.a0_allowlist_sha256 | Should -BeExactly '5764ed8ff14b6816c28935d1e317197512ae39e888bf4ecf61fee9ebd9ceb57e'
            [int]$run.Result.a0_changed_path_count | Should -Be 1
            [string]$run.Result.a0_changed_path_set_sha256 | Should -Match '^[0-9a-f]{64}$'
            [string]$run.Result.validation_coverage_sha256 | Should -Match '^[0-9a-f]{64}$'
            [int]$run.Result.validation_class_counts.logical_fixture_spec | Should -Be 1
            [bool]$run.Result.source_surface_complete | Should -BeFalse
            @($run.Result.missing_mandatory_paths).Count | Should -BeGreaterThan 0
            [string]$run.Result.candidate_sha | Should -BeExactly $fixture.CandidateSha
            [string]$run.Result.candidate_tree_sha | Should -BeExactly $fixture.CandidateTree
            [string]$run.Result.predecessor_main_sha | Should -BeExactly '9203ab9f89ff4383832119683eb4e19df5490213'
            [string]$run.Result.predecessor_tree_sha | Should -BeExactly '241d3086e9bcb5a847445258cab25bff4fd34da8'
        }
        finally {
            Remove-Item -LiteralPath $fixture.Outer -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects out-of-scope and executable-like fixture changes' {
        $outside = New-HostedSourceFixture -Mode outside
        try {
            $run = Invoke-HostedPreflightChild -Fixture $outside
            $run.ExitCode | Should -Be 1
            $run.Text | Should -Match 'outside or ambiguously inside A0 allowlist v6'
        }
        finally {
            Remove-Item -LiteralPath $outside.Outer -Recurse -Force -ErrorAction SilentlyContinue
        }

        $scriptFixture = New-HostedSourceFixture -Mode script-fixture
        try {
            $run = Invoke-HostedPreflightChild -Fixture $scriptFixture
            $run.ExitCode | Should -Be 1
            $run.Text | Should -Match 'fixture path has executable/package-like content extension'
        }
        finally {
            Remove-Item -LiteralPath $scriptFixture.Outer -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects dirty candidate state and candidate tree drift' {
        $dirty = New-HostedSourceFixture -Mode allowed -Dirty
        try {
            $run = Invoke-HostedPreflightChild -Fixture $dirty
            $run.ExitCode | Should -Be 1
            $run.Text | Should -Match 'requires a clean candidate worktree'
        }
        finally {
            Remove-Item -LiteralPath $dirty.Outer -Recurse -Force -ErrorAction SilentlyContinue
        }

        $treeDrift = New-HostedSourceFixture -Mode allowed
        try {
            $run = Invoke-HostedPreflightChild -Fixture $treeDrift -CandidateTree ('0' * 40)
            $run.ExitCode | Should -Be 1
            $run.Text | Should -Match 'candidate tree mismatch'
        }
        finally {
            Remove-Item -LiteralPath $treeDrift.Outer -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps this slice offline, read-only and unable to emit authority artifacts' {
        $source = Get-Content -LiteralPath $script:HostedPreflightPath -Raw
        $source | Should -Not -Match '(?i)\bInvoke-(WebRequest|RestMethod)\b'
        $source | Should -Not -Match '(?im)\bgh\s+(api|workflow|run)\b'
        $source | Should -Not -Match '(?i)\bStart-Process\b'
        $source | Should -Not -Match '(?im)\bgit\s+(push|commit|merge|tag|reset|checkout)\b'
        $source | Should -Not -Match '(?i)\b(upload-artifact|download-artifact|setup-python)\b'
        $source | Should -Not -Match '(?i)\b(Invoke-Pester|Invoke-ScriptAnalyzer)\b'
        $source | Should -Not -Match '(?i)\b(Set-Content|Add-Content|Out-File|WriteAllText|WriteAllBytes|CreateNew)\b'
        $source | Should -Not -Match 'a0-substrate-receipt\.json'
        $source | Should -Match "status\s*=\s*'SOURCE_PREFLIGHT_ONLY'"
        $source | Should -Match 'admitted\s*=\s*\$false'
    }
}

Describe 'V11 bounded schema source loading (claim-free)' {
    It 'rejects four oversized schema sources before their SHA-256 read and accepts frozen ordinary bytes' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-schema-size-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        $probePath = Join-Path $root 'schema-size-probe.py'
        $probe = @'
import importlib.util
from pathlib import Path
import sys
import tempfile

spec = importlib.util.spec_from_file_location("nxb_v11_preflight", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
repository = Path(sys.argv[2])
source = repository / "schemas" / module.A0_HOSTED_SCHEMA_BINDING["filename"]
loaded = module._read_bounded_schema(source, "A0 hosted schema source")
if loaded != source.read_bytes():
    raise AssertionError("bounded reader changed the frozen schema bytes")

with tempfile.TemporaryDirectory(prefix="nxb-v11-schema-size-cases-") as workspace:
    root = Path(workspace)
    cases = (
        (module.PRIMARY_SCHEMA_BINDINGS["environment-fingerprint.json"]["filename"],
         lambda: module._load_primary_schema(root, "environment-fingerprint.json")),
        (module.TERMINAL_SCHEMA_BINDINGS["independent-validation.json"]["filename"],
         lambda: module._load_terminal_schema(root, "independent-validation.json")),
        (module.A0_HOSTED_SCHEMA_BINDING["filename"],
         lambda: module._load_a0_hosted_schema(root)),
        (module.PREDECESSOR_WRAPPER_SCHEMA_FILE,
         lambda: module._predecessor_load_wrapper_schema(root)),
    )
    for name, check in cases:
        candidate = root / name
        with candidate.open("wb") as stream:
            stream.truncate(module.MAX_SCHEMA_BYTES + 1)
        try:
            check()
        except module.PreflightError as error:
            if "schema source byte ceiling" not in str(error):
                raise AssertionError(f"{name}: wrong preflight failure: {error}") from error
        else:
            raise AssertionError(f"{name}: oversized schema accepted")
        candidate.unlink()
print("bounded schema source checks: ordinary bytes and 4 oversized sources PASS")
'@
        try {
            [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($false))
            $tool = Join-Path $script:RepositoryRoot 'validation\v11\tools\validate_v11_compatibility.py'
            $run = Invoke-V11Python -Arguments @($probePath, $tool, $script:RepositoryRoot)
            if ($run.ExitCode -ne 0) { throw ('Schema size probe failed: ' + $run.Text) }
            $run.Text | Should -Match 'bounded schema source checks: ordinary bytes and 4 oversized sources PASS'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'V11 predecessor replay bounded ZIP snapshot (claim-free)' {
    It 'requires an explicitly bounded binary read rather than path.read_bytes' {
        $outer = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-predecessor-zip-bound-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($outer)
        $probePath = Join-Path $outer 'bounded-zip-probe.py'
        $probe = @'
import importlib.util
from pathlib import Path
import sys
import tempfile

spec = importlib.util.spec_from_file_location("nxb_v11_preflight", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class BoundedStream:
    def __init__(self, stream):
        self.stream = stream
    def __enter__(self):
        return self
    def __exit__(self, *args):
        return self.stream.__exit__(*args)
    def read(self, size=-1):
        if size != module.PREDECESSOR_MAX_ZIP_BYTES + 1:
            raise AssertionError(f"predecessor ZIP read not bounded: {size}")
        return self.stream.read(size)

class StreamOnlyPath:
    def __init__(self, actual):
        self.actual = actual
        self.parent = actual.parent
    def is_absolute(self):
        return self.actual.is_absolute()
    def lstat(self):
        return self.actual.lstat()
    def open(self, mode):
        if mode != "rb":
            raise AssertionError(f"unexpected open mode: {mode}")
        return BoundedStream(self.actual.open(mode))
    def read_bytes(self):
        raise AssertionError("unbounded Path.read_bytes() invoked")

with tempfile.TemporaryDirectory(prefix="nxb-v11-predecessor-bounded-") as name:
    real = Path(name) / "sample.zip"
    real.write_bytes(b"not-an-admitted-review-archive")
    predecessor = "1" * 40
    successor = "3" * 40
    kwargs = {
        "path": StreamOnlyPath(real),
        "schema_root": Path(name),
        "expected_zip_sha256": "0" * 64,
        "expected_predecessor_main_sha": predecessor,
        "expected_predecessor_tree_sha": "2" * 40,
        "expected_observer_successor_head_sha": successor,
        "expected_run_id": 123456789,
        "expected_run_attempt": 1,
        "expected_artifact_name": (
            f"nxb-v11-predecessor-replay-v1-{predecessor}-{successor}-123456789-1"
        ),
        "expected_predecessor_policy_sha256": "a" * 64,
    }
    try:
        module.inspect_predecessor_replay(**kwargs)
    except module.PreflightError as error:
        if "independently supplied predecessor replay ZIP digest mismatch" not in str(error):
            raise AssertionError(f"unexpected fail-closed reason: {error}") from error
    else:
        raise AssertionError("mismatched predecessor ZIP digest accepted")
print("predecessor replay ZIP snapshot: bounded stream read and fail-closed SHA PASS")
'@
        try {
            [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($false))
            $validator = Join-Path $script:RepositoryRoot 'validation\v11\tools\validate_v11_compatibility.py'
            $run = Invoke-V11Python -Arguments @($probePath, $validator)
            if ($run.ExitCode -ne 0) { throw ('Predecessor ZIP bounded probe failed: ' + $run.Text) }
            $run.Text | Should -Match 'predecessor replay ZIP snapshot: bounded stream read and fail-closed SHA PASS'
        }
        finally {
            Remove-Item -LiteralPath $outer -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'V11 predecessor replay XML DTD encoding safety (claim-free)' {
    It 'rejects UTF-16 encoded DTD payloads while keeping ordinary UTF-8 NUnit XML valid' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-xml-dtd-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        $probePath = Join-Path $root 'xml-dtd-encoding.py'
        $probe = @'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("nxb_v11_xml_check", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
attrs = 'name="Pester" total="916" errors="0" failures="0" not-run="0" inconclusive="0" ignored="0" skipped="0" invalid="0"'
ordinary = f'<?xml version="1.0" encoding="utf-8"?><test-results {attrs}/>'
valid = module._predecessor_xml_results(ordinary.encode("utf-8"), "pester-ps7.xml")
assert valid["total"] == 916 and valid["failures"] == 0

for encoding in ("utf-8", "utf-16", "utf-16-le", "utf-16-be"):
    declaration = "utf-8" if encoding == "utf-8" else "utf-16"
    payload = (
        f'<?xml version="1.0" encoding="{declaration}"?>'
        '<!DOCTYPE test-results [<!ENTITY marker "untrusted">]>'
        f'<test-results {attrs}/>'
    )
    if encoding in ("utf-16-le", "utf-16-be"):
        # Without a BOM, the XML remains invalid for the UTF-16 declaration;
        # the byte-level preflight must reject it before the XML parser.
        data = payload.encode(encoding)
    else:
        data = payload.encode(encoding)
    try:
        module._predecessor_xml_results(data, "pester-ps7.xml")
    except module.PreflightError as error:
        if "forbidden" not in str(error) and "UTF-8" not in str(error):
            raise AssertionError(f"Wrong rejection for {encoding}: {error}") from error
    else:
        raise AssertionError(f"DTD accepted with encoding {encoding}")

print("predecessor XML DTD: utf-8 valid and 4 encoded DTD cases rejected")
'@
        try {
            [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($false))
            $tool = Join-Path $script:RepositoryRoot 'validation\v11\tools\validate_v11_compatibility.py'
            $run = Invoke-V11Python -Arguments @($probePath, $tool)
            if ($run.ExitCode -ne 0) { throw ('Encoded XML DTD probe failed: ' + $run.Text) }
            $run.Text | Should -Match 'predecessor XML DTD: utf-8 valid and 4 encoded DTD cases rejected'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'V11 Python preparation external path ancestry (claim-free)' {
    It 'rejects reparse/junction parents for Python preparation lock, runtime and bootstrap sources' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-python-prep-ancestor-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        $probePath = Join-Path $root 'probe.py'
        $probe = @'
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

materializer = load("nxb_mat", sys.argv[1])
launcher = load("nxb_pip", sys.argv[2])
with tempfile.TemporaryDirectory(prefix="nxb-v11-prep-ancestors-") as scratch:
    base = Path(scratch)
    real = base / "real"
    inner = real / "inner"
    inner.mkdir(parents=True)
    (inner / "source.lock").write_bytes(b"test")
    alias = base / "alias"
    if os.name == "nt":
        made = subprocess.run(
            ["cmd", "/d", "/c", "mklink", "/J", str(alias), str(real)],
            capture_output=True, text=True, check=False,
        )
        if made.returncode:
            raise AssertionError(f"junction setup failed: {made.stderr}")
    else:
        alias.symlink_to(real, target_is_directory=True)
    try:
        for module in (materializer, launcher):
            assert module.assert_ordinary_directory(str(inner), "ordinary") == str(inner)
            assert module.assert_ordinary_file(str(inner / "source.lock"), "ordinary") == str(inner / "source.lock")
            for check in (
                lambda: module.assert_ordinary_directory(str(alias / "inner"), "test directory"),
                lambda: module.assert_ordinary_file(str(alias / "inner" / "source.lock"), "test file"),
            ):
                try:
                    check()
                except (materializer.ProjectionError, launcher.PinnedPipError):
                    pass
                else:
                    raise AssertionError("Python preparation accepted reparse-backed ancestor")
    finally:
        if os.name == "nt":
            alias.rmdir()
        else:
            alias.unlink()
print("Python preparation ancestry: 4 junction cases rejected, ordinary controls passed")
'@
        try {
            [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($false))
            $materializer = Join-Path $script:RepositoryRoot 'validation\v11\tools\materialize_python_requirements.py'
            $launcher = Join-Path $script:RepositoryRoot 'validation\v11\tools\run_pinned_pip.py'
            $run = Invoke-V11Python -Arguments @($probePath, $materializer, $launcher)
            if ($run.ExitCode -ne 0) { throw ('Python preparation ancestry probe failed: ' + $run.Text) }
            $run.Text | Should -Match 'Python preparation ancestry: 4 junction cases rejected, ordinary controls passed'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}


Describe 'V11 bounded Python preparation inputs (claim-free)' {
    It 'bounds dependency lock and pip METADATA reads before parsing' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-preparation-bounds-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        $probePath = Join-Path $root 'preparation-bounds.py'
        $probe = @'
import importlib.util
import json
from pathlib import Path
import sys
import tempfile

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

materializer = load("nxb_materializer", sys.argv[1])
launcher = load("nxb_pip_launcher", sys.argv[2])

with tempfile.TemporaryDirectory(prefix="nxb-v11-python-input-bounds-") as scratch:
    root = Path(scratch)
    lock = root / "lock.json"
    lock.write_bytes(b'{"a":1}')
    if materializer.load_canonical_json(str(lock)) != {"a": 1}:
        raise AssertionError("ordinary canonical input drift")
    metadata_root = root / "pip-26.2.1.dist-info"
    metadata_root.mkdir()
    metadata = metadata_root / "METADATA"
    metadata.write_bytes(b"Name: pip\nVersion: 26.2.1\n\n")
    if launcher.read_dist_info_version(str(metadata_root)) != ("pip", "26.2.1"):
        raise AssertionError("ordinary pip metadata drift")

    with lock.open("wb") as file:
        file.truncate(materializer.MAX_LOCK_BYTES + 1)
    try:
        materializer.load_canonical_json(str(lock))
    except materializer.ProjectionError as error:
        if "lock byte ceiling" not in str(error):
            raise AssertionError(f"wrong lock rejection: {error}") from error
    else:
        raise AssertionError("oversized lock was accepted")

    with metadata.open("wb") as file:
        file.truncate(launcher.MAX_PIP_METADATA_BYTES + 1)
    try:
        launcher.read_dist_info_version(str(metadata_root))
    except launcher.PinnedPipError as error:
        if "pip METADATA byte ceiling" not in str(error):
            raise AssertionError(f"wrong metadata rejection: {error}") from error
    else:
        raise AssertionError("oversized METADATA was accepted")

print("Python preparation bounded input checks: ordinary and 2 oversized sources PASS")
'@
        try {
            [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($false))
            $materializer = Join-Path $script:RepositoryRoot 'validation\v11\tools\materialize_python_requirements.py'
            $launcher = Join-Path $script:RepositoryRoot 'validation\v11\tools\run_pinned_pip.py'
            $run = Invoke-V11Python -Arguments @($probePath, $materializer, $launcher)
            if ($run.ExitCode -ne 0) { throw ('Python preparation bounded probe failed: ' + $run.Text) }
            $run.Text | Should -Match 'Python preparation bounded input checks: ordinary and 2 oversized sources PASS'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'V11 artifact tree manifest ancestor safety (claim-free)' {
    It 'rejects reparse/symlink ancestors for root and output without blocking ordinary paths' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-tree-ancestor-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        $probePath = Join-Path $root 'probe.py'
        $probe = @'
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location("nxb_tree", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory(prefix="nxb-artifact-tree-ancestor-") as scratch:
    base = Path(scratch)
    real = base / "real"
    (real / "child").mkdir(parents=True)
    alias = base / "alias"
    if os.name == "nt":
        result = subprocess.run(
            ["cmd", "/d", "/c", "mklink", "/J", str(alias), str(real)],
            capture_output=True, text=True, check=False,
        )
        if result.returncode:
            raise AssertionError("junction setup failed: " + result.stderr)
    else:
        alias.symlink_to(real, target_is_directory=True)
    try:
        if module.assert_ordinary_directory(str(real / "child"), "root") != str(real / "child"):
            raise AssertionError("ordinary root rejected")
        if module.assert_output_path(str(real / "child" / "out.json")) != str(real / "child" / "out.json"):
            raise AssertionError("ordinary output parent rejected")
        rejected = 0
        for operation in (
            lambda: module.assert_ordinary_directory(str(alias / "child"), "root"),
            lambda: module.assert_output_path(str(alias / "child" / "out.json")),
        ):
            try:
                operation()
            except module.ManifestError:
                rejected += 1
            else:
                raise AssertionError("reparse-backed ancestor was accepted")
        assert rejected == 2
    finally:
        if os.name == "nt":
            alias.rmdir()
        else:
            alias.unlink()
print("artifact tree ancestor root/output checks: 2 rejected, controls passed")
'@
        try {
            [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($false))
            $tool = Join-Path $script:RepositoryRoot 'validation\v11\tools\build_artifact_tree_manifest.py'
            $run = Invoke-V11Python -Arguments @($probePath, $tool)
            if ($run.ExitCode -ne 0) { throw ('Artifact tree ancestor probe failed: ' + $run.Text) }
            $run.Text | Should -Match 'artifact tree ancestor root/output checks: 2 rejected, controls passed'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'V11 artifact-tree manifest file identity reconciliation (claim-free)' {
    It 'rejects replacement of an ordinary file after enumeration without creating a manifest' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-artifact-file-drift-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        $probePath = Join-Path $root 'file-identity-probe.py'
        $probe = @'
import hashlib
import importlib.util
import os
from pathlib import Path
import sys
import tempfile

spec = importlib.util.spec_from_file_location("nxb_tree", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory(prefix="nxb-v11-tree-drift-") as scratch:
    base = Path(scratch)
    root = base / "inputs"
    root.mkdir()
    target = root / "evidence.bin"
    target.write_bytes(b"A" * 256)
    normal = module.build_manifest(str(root), "test-root")
    if normal["files"][0]["sha256"] != hashlib.sha256(b"A" * 256).hexdigest():
        raise AssertionError("ordinary immutable input digest changed")
    replacement = base / "replacement.bin"
    replacement.write_bytes(b"B" * 256)
    original_hash = module.sha256_file
    replaced = False
    def swap_before_read(path, *args, **kwargs):
        global replaced
        if not replaced:
            replaced = True
            os.replace(replacement, target)
        return original_hash(path, *args, **kwargs)
    module.sha256_file = swap_before_read
    try:
        module.build_manifest(str(root), "test-root")
    except module.ManifestError as exc:
        if "changed during hashing" not in str(exc):
            raise AssertionError("unexpected replacement rejection: " + str(exc)) from exc
    else:
        raise AssertionError("manifest accepted replacement after enumeration")
    if not replaced:
        raise AssertionError("replacement race hook was not exercised")
print("artifact tree file identity drift: replacement rejected, ordinary control passed")
'@
        try {
            [IO.File]::WriteAllText($probePath, $probe, [Text.UTF8Encoding]::new($false))
            $tool = Join-Path $script:RepositoryRoot 'validation\v11\tools\build_artifact_tree_manifest.py'
            $run = Invoke-V11Python -Arguments @($probePath, $tool)
            if ($run.ExitCode -ne 0) { throw ('Artifact tree file identity probe failed: ' + $run.Text) }
            $run.Text | Should -Match 'artifact tree file identity drift: replacement rejected, ordinary control passed'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
