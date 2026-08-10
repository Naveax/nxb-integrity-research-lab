[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-NxbSemanticControlVsWhere {
    [CmdletBinding()]
    param()
    foreach ($candidate in @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe')
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw 'vswhere.exe was not found.'
}

function Get-NxbSemanticControlLatestVersionDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })][string]$Root,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RequiredRelativePath
    )
    $candidates = @(
        Get-ChildItem -LiteralPath $Root -Directory -ErrorAction Stop |
            ForEach-Object {
                $parsed = $null
                if ([version]::TryParse($_.Name,[ref]$parsed)) {
                    $required = Join-Path $_.FullName $RequiredRelativePath
                    if (Test-Path -LiteralPath $required -PathType Leaf) {
                        [pscustomobject]@{ Version = $parsed; Path = $_.FullName }
                    }
                }
            } | Sort-Object Version -Descending
    )
    if ($candidates.Count -eq 0) {
        throw "No version directory under '$Root' contains '$RequiredRelativePath'."
    }
    return [string]$candidates[0].Path
}

function Resolve-NxbSemanticControlToolchain {
    [CmdletBinding()]
    param()
    $vswhere = Resolve-NxbSemanticControlVsWhere
    $installationPath = @(
        & $vswhere -latest -products '*' -requires 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' -property installationPath
    ) | Select-Object -First 1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$installationPath)) {
        throw 'Visual Studio C++ x64 Build Tools installation was not resolved.'
    }
    $installationPath = [IO.Path]::GetFullPath(([string]$installationPath).Trim())
    $msvcVersionsRoot = Join-Path $installationPath 'VC\Tools\MSVC'
    $msvcRoot = Get-NxbSemanticControlLatestVersionDirectory -Root $msvcVersionsRoot -RequiredRelativePath 'bin\Hostx64\x64\cl.exe'
    $compiler = Join-Path $msvcRoot 'bin\Hostx64\x64\cl.exe'
    $linker = Join-Path $msvcRoot 'bin\Hostx64\x64\link.exe'

    $registryBase = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64
    )
    try {
        $kitsKey = $registryBase.OpenSubKey('SOFTWARE\Microsoft\Windows Kits\Installed Roots')
        if ($null -eq $kitsKey) { throw 'Windows Kits Installed Roots registry key is unavailable.' }
        try {
            $kitsRoot10 = [string]$kitsKey.GetValue('KitsRoot10',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
        finally { $kitsKey.Dispose() }
    }
    finally { $registryBase.Dispose() }
    if ([string]::IsNullOrWhiteSpace($kitsRoot10)) { throw 'KitsRoot10 is unavailable.' }
    $kitsRoot10 = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($kitsRoot10))
    $sdkIncludeRoot = Get-NxbSemanticControlLatestVersionDirectory -Root (Join-Path $kitsRoot10 'Include') -RequiredRelativePath 'um\Windows.h'
    $sdkVersion = Split-Path -Leaf $sdkIncludeRoot
    $sdkLibRoot = Join-Path (Join-Path $kitsRoot10 'Lib') $sdkVersion

    $includePaths = @(
        (Join-Path $msvcRoot 'include'),
        (Join-Path $sdkIncludeRoot 'ucrt'),
        (Join-Path $sdkIncludeRoot 'shared'),
        (Join-Path $sdkIncludeRoot 'um'),
        (Join-Path $sdkIncludeRoot 'winrt')
    )
    $libraryPaths = @(
        (Join-Path $msvcRoot 'lib\x64'),
        (Join-Path $sdkLibRoot 'ucrt\x64'),
        (Join-Path $sdkLibRoot 'um\x64')
    )
    foreach ($path in @($compiler,$linker)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Native tool is missing: $path" }
    }
    foreach ($path in $includePaths) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Include path is missing: $path" }
    }
    foreach ($path in $libraryPaths) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Library path is missing: $path" }
    }
    foreach ($library in @('d3d11.lib','dxgi.lib','user32.lib','ws2_32.lib','advapi32.lib')) {
        if (-not (Test-Path -LiteralPath (Join-Path $libraryPaths[-1] $library) -PathType Leaf)) {
            throw "Required Windows SDK library is missing: $library"
        }
    }
    return [pscustomobject][ordered]@{
        compiler = [IO.Path]::GetFullPath($compiler)
        linker = [IO.Path]::GetFullPath($linker)
        msvc_root = $msvcRoot
        sdk_version = $sdkVersion
        include_paths = @($includePaths)
        library_paths = @($libraryPaths)
    }
}

if ($env:OS -cne 'Windows_NT') { throw 'Semantic control fixture build requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Semantic control fixture build requires PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected=$ExpectedHead actual=$currentHead"
}
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Semantic control build requires a clean worktree.' }

$sourcePath = Join-Path $repositoryRoot 'fixtures\superblock1-semantic-controls\main.cpp'
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Control fixture source is missing: $sourcePath" }
$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$repositoryPrefix = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\') + '\'
if ($outputFull.StartsWith($repositoryPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Build output must remain outside the repository.' }
if (Test-Path -LiteralPath $outputFull) { throw "Build output already exists: $outputFull" }
[IO.Directory]::CreateDirectory($outputFull) | Out-Null

$exePath = Join-Path $outputFull 'NXB-Superblock1SemanticControlFixture.exe'
$objectPath = Join-Path $outputFull 'NXB-Superblock1SemanticControlFixture.obj'
$buildLogPath = Join-Path $outputFull 'build.log'
$receiptPath = Join-Path $outputFull 'semantic-control-fixture-build-receipt.json'
$toolchain = Resolve-NxbSemanticControlToolchain
$compiler = [string]$toolchain.compiler
$compilerArguments = @('/nologo','/std:c++17','/EHsc','/W4','/WX','/O2','/DUNICODE','/D_UNICODE')
foreach ($includePath in @($toolchain.include_paths)) { $compilerArguments += ('/I{0}' -f [string]$includePath) }
$compilerArguments += @(('/Fo{0}' -f $objectPath),$sourcePath,('/Fe{0}' -f $exePath),'/link')
foreach ($libraryPath in @($toolchain.library_paths)) { $compilerArguments += ('/LIBPATH:{0}' -f [string]$libraryPath) }
$compilerArguments += @('d3d11.lib','dxgi.lib','user32.lib','ws2_32.lib','advapi32.lib')

$buildOutput = @(& $compiler @compilerArguments 2>&1)
$buildExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
[IO.File]::WriteAllLines($buildLogPath,@($buildOutput | ForEach-Object { [string]$_ }),[Text.UTF8Encoding]::new($false))
if ($buildExit -ne 0) {
    Write-Information -MessageData '=== SEMANTIC CONTROL NATIVE COMPILER OUTPUT ===' -InformationAction Continue
    foreach ($line in $buildOutput) { Write-Information -MessageData ([string]$line) -InformationAction Continue }
    throw "Semantic control fixture build failed: compiler=$compiler exit=$buildExit log=$buildLogPath"
}
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) { throw 'Compiler reported success but executable is missing.' }

$receipt = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    head_sha = $currentHead
    source_sha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    executable_sha256 = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
    executable_length = [int64](Get-Item -LiteralPath $exePath).Length
    architecture = 'x64'
    compiler_path = $compiler
    msvc_root = [string]$toolchain.msvc_root
    windows_sdk_version = [string]$toolchain.sdk_version
    build_exit_code = $buildExit
    claims = [ordered]@{
        exact_head_source = $true
        control_modes_runtime_validated = $false
        etw_event_mapping_validated = $false
        trace_completeness = 'not_claimed'
    }
}
[IO.File]::WriteAllText($receiptPath,(($receipt | ConvertTo-Json -Depth 12) + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
$result = [pscustomobject][ordered]@{
    status = 'passed'
    head_sha = $currentHead
    executable_path = $exePath
    executable_sha256 = [string]$receipt.executable_sha256
    source_sha256 = [string]$receipt.source_sha256
    build_log_path = $buildLogPath
    receipt_path = $receiptPath
}
Write-Information -MessageData "Semantic control fixture build passed: $($result.executable_sha256)" -InformationAction Continue
if ($PassThru) { return $result }
