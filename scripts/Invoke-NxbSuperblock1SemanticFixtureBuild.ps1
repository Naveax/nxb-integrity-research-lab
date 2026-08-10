[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-NxbSemanticVsWhere {
    [CmdletBinding()]
    param()

    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe')
    )
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw 'vswhere.exe was not found in the standard Visual Studio Installer directories.'
}

function Write-NxbSemanticJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory)][object]$InputObject
    )
    [IO.File]::WriteAllText(
        $Path,
        (($InputObject | ConvertTo-Json -Depth 16) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

function Get-NxbSemanticLatestVersionDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$Root,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RequiredRelativePath
    )

    $candidates = @(
        Get-ChildItem -LiteralPath $Root -Directory -ErrorAction Stop |
            ForEach-Object {
                $parsed = $null
                if ([version]::TryParse($_.Name,[ref]$parsed)) {
                    $required = Join-Path $_.FullName $RequiredRelativePath
                    if (Test-Path -LiteralPath $required -PathType Leaf) {
                        [pscustomobject]@{
                            Version = $parsed
                            Path = $_.FullName
                        }
                    }
                }
            } |
            Sort-Object Version -Descending
    )
    if ($candidates.Count -eq 0) {
        throw "No version directory under '$Root' contains '$RequiredRelativePath'."
    }
    return [string]$candidates[0].Path
}

function Resolve-NxbSemanticNativeToolchain {
    [CmdletBinding()]
    param()

    $vswhere = Resolve-NxbSemanticVsWhere
    $installationPath = @(
        & $vswhere -latest -products '*' -requires 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' -property installationPath
    ) | Select-Object -First 1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$installationPath)) {
        throw 'Visual Studio C++ x64 Build Tools installation was not resolved.'
    }
    $installationPath = [IO.Path]::GetFullPath(([string]$installationPath).Trim())

    $msvcVersionsRoot = Join-Path $installationPath 'VC\Tools\MSVC'
    if (-not (Test-Path -LiteralPath $msvcVersionsRoot -PathType Container)) {
        throw "MSVC tools root is missing: $msvcVersionsRoot"
    }
    $msvcRoot = Get-NxbSemanticLatestVersionDirectory -Root $msvcVersionsRoot -RequiredRelativePath 'bin\Hostx64\x64\cl.exe'
    $compiler = Join-Path $msvcRoot 'bin\Hostx64\x64\cl.exe'
    $linker = Join-Path $msvcRoot 'bin\Hostx64\x64\link.exe'
    $msvcInclude = Join-Path $msvcRoot 'include'
    $msvcLib = Join-Path $msvcRoot 'lib\x64'

    $registryBase = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64
    )
    try {
        $kitsKey = $registryBase.OpenSubKey('SOFTWARE\Microsoft\Windows Kits\Installed Roots')
        if ($null -eq $kitsKey) {
            throw 'Windows Kits Installed Roots registry key is unavailable.'
        }
        try {
            $kitsRoot10 = [string]$kitsKey.GetValue('KitsRoot10',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
        finally {
            $kitsKey.Dispose()
        }
    }
    finally {
        $registryBase.Dispose()
    }
    if ([string]::IsNullOrWhiteSpace($kitsRoot10)) {
        throw 'KitsRoot10 is unavailable in Windows Kits registry metadata.'
    }
    $kitsRoot10 = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($kitsRoot10))

    $sdkIncludeVersions = Join-Path $kitsRoot10 'Include'
    $sdkIncludeRoot = Get-NxbSemanticLatestVersionDirectory -Root $sdkIncludeVersions -RequiredRelativePath 'um\Windows.h'
    $sdkVersion = Split-Path -Leaf $sdkIncludeRoot
    $sdkLibRoot = Join-Path (Join-Path $kitsRoot10 'Lib') $sdkVersion
    $sdkBinRoot = Join-Path (Join-Path $kitsRoot10 'bin') $sdkVersion

    $includePaths = @(
        $msvcInclude,
        (Join-Path $sdkIncludeRoot 'ucrt'),
        (Join-Path $sdkIncludeRoot 'shared'),
        (Join-Path $sdkIncludeRoot 'um'),
        (Join-Path $sdkIncludeRoot 'winrt')
    )
    $libraryPaths = @(
        $msvcLib,
        (Join-Path $sdkLibRoot 'ucrt\x64'),
        (Join-Path $sdkLibRoot 'um\x64')
    )
    $requiredFiles = @(
        $compiler,
        $linker,
        (Join-Path $msvcInclude 'vector'),
        (Join-Path $sdkIncludeRoot 'um\Windows.h'),
        (Join-Path $sdkIncludeRoot 'um\d3d11.h'),
        (Join-Path $sdkLibRoot 'um\x64\d3d11.lib'),
        (Join-Path $sdkLibRoot 'um\x64\dxgi.lib'),
        (Join-Path $sdkLibRoot 'um\x64\ws2_32.lib'),
        (Join-Path $sdkLibRoot 'um\x64\advapi32.lib'),
        (Join-Path $sdkLibRoot 'ucrt\x64\ucrt.lib')
    )
    foreach ($requiredFile in $requiredFiles) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "Semantic native toolchain component is missing: $requiredFile"
        }
    }
    foreach ($includePath in $includePaths) {
        if (-not (Test-Path -LiteralPath $includePath -PathType Container)) {
            throw "Semantic native include path is missing: $includePath"
        }
    }
    foreach ($libraryPath in $libraryPaths) {
        if (-not (Test-Path -LiteralPath $libraryPath -PathType Container)) {
            throw "Semantic native library path is missing: $libraryPath"
        }
    }

    return [pscustomobject][ordered]@{
        installation_path = $installationPath
        msvc_root = $msvcRoot
        sdk_root = $kitsRoot10
        sdk_version = $sdkVersion
        compiler = [IO.Path]::GetFullPath($compiler)
        linker = [IO.Path]::GetFullPath($linker)
        sdk_bin_x64 = Join-Path $sdkBinRoot 'x64'
        include_paths = @($includePaths)
        library_paths = @($libraryPaths)
    }
}

if ($env:OS -cne 'Windows_NT') { throw 'Semantic fixture build requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Semantic fixture build requires PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected=$ExpectedHead actual=$currentHead"
}
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'Semantic fixture build requires a clean exact-head worktree.'
}

$sourcePath = Join-Path $repositoryRoot 'fixtures\superblock1-multidomain\main.cpp'
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Semantic fixture source is missing: $sourcePath"
}

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$repositoryPrefix = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\') + '\'
if ($outputFull.StartsWith($repositoryPrefix,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Semantic fixture build output must remain outside the repository worktree.'
}
if (Test-Path -LiteralPath $outputFull) {
    throw "Semantic fixture build output already exists: $outputFull"
}
[IO.Directory]::CreateDirectory($outputFull) | Out-Null

$exePath = Join-Path $outputFull 'NXB-Superblock1SemanticFixture.exe'
$objectPath = Join-Path $outputFull 'NXB-Superblock1SemanticFixture.obj'
$buildLogPath = Join-Path $outputFull 'build.log'
$receiptPath = Join-Path $outputFull 'semantic-fixture-build-receipt.json'

$toolchain = Resolve-NxbSemanticNativeToolchain
$compiler = [string]$toolchain.compiler
$compilerArguments = @(
    '/nologo',
    '/std:c++17',
    '/EHsc',
    '/W4',
    '/WX',
    '/O2',
    '/DUNICODE',
    '/D_UNICODE'
)
foreach ($includePath in @($toolchain.include_paths)) {
    $compilerArguments += ('/I{0}' -f [string]$includePath)
}
$compilerArguments += @(
    ('/Fo{0}' -f $objectPath),
    $sourcePath,
    ('/Fe{0}' -f $exePath),
    '/link'
)
foreach ($libraryPath in @($toolchain.library_paths)) {
    $compilerArguments += ('/LIBPATH:{0}' -f [string]$libraryPath)
}
$compilerArguments += @(
    'd3d11.lib',
    'dxgi.lib',
    'user32.lib',
    'ws2_32.lib',
    'advapi32.lib'
)

$buildOutput = @(& $compiler @compilerArguments 2>&1)
$buildExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
[IO.File]::WriteAllLines(
    $buildLogPath,
    @($buildOutput | ForEach-Object { [string]$_ }),
    [Text.UTF8Encoding]::new($false)
)
if ($buildExit -ne 0) {
    Write-Information -MessageData '=== NATIVE COMPILER OUTPUT ===' -InformationAction Continue
    foreach ($line in $buildOutput) {
        Write-Information -MessageData ([string]$line) -InformationAction Continue
    }
    throw "Semantic fixture native build failed: compiler=$compiler exit=$buildExit log=$buildLogPath"
}
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw 'Semantic fixture build reported success but the executable is missing.'
}

$receipt = [pscustomobject][ordered]@{
    schema_version = 3
    status = 'passed'
    head_sha = $currentHead
    source_sha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    executable_sha256 = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
    executable_length = [int64](Get-Item -LiteralPath $exePath).Length
    architecture = 'x64'
    compiler_environment = 'Direct MSVC plus explicit Windows SDK include/lib paths'
    compiler_path = $compiler
    linker_path = [string]$toolchain.linker
    msvc_root = [string]$toolchain.msvc_root
    windows_sdk_root = [string]$toolchain.sdk_root
    windows_sdk_version = [string]$toolchain.sdk_version
    build_exit_code = $buildExit
    claims = [ordered]@{
        executable_built_from_exact_head_source = $true
        hardware_d3d11_runtime_validated = $false
        etw_event_mapping_validated = $false
        trace_completeness = 'not_claimed'
    }
}
Write-NxbSemanticJson -Path $receiptPath -InputObject $receipt

$result = [pscustomobject][ordered]@{
    status = 'passed'
    head_sha = $currentHead
    source_path = $sourcePath
    source_sha256 = [string]$receipt.source_sha256
    executable_path = $exePath
    executable_sha256 = [string]$receipt.executable_sha256
    build_log_path = $buildLogPath
    receipt_path = $receiptPath
    compiler_path = $compiler
    linker_path = [string]$toolchain.linker
    msvc_root = [string]$toolchain.msvc_root
    windows_sdk_version = [string]$toolchain.sdk_version
    build_exit_code = $buildExit
}
Write-Information -MessageData "SUPERBLOCK semantic fixture build passed: $($result.executable_sha256)" -InformationAction Continue
if ($PassThru) { return $result }
