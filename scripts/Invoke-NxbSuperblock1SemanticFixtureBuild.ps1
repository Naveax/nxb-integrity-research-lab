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

function Import-NxbSemanticDeveloperEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$VsDevCmd,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$WorkingDirectory
    )

    $cmdPath = (Get-Command cmd.exe -ErrorAction Stop).Source
    $environmentScript = Join-Path $WorkingDirectory 'capture-vs-environment.cmd'
    $environmentLog = Join-Path $WorkingDirectory 'vs-environment.log'
    $lines = @(
        '@echo off',
        ('call "{0}" -no_logo -arch=x64 -host_arch=x64' -f $VsDevCmd),
        'if errorlevel 1 exit /b %errorlevel%',
        'set'
    )
    [IO.File]::WriteAllLines($environmentScript,$lines,[Text.ASCIIEncoding]::new())

    $output = @(& $cmdPath /d /c $environmentScript 2>&1)
    $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    [IO.File]::WriteAllLines(
        $environmentLog,
        @($output | ForEach-Object { [string]$_ }),
        [Text.UTF8Encoding]::new($false)
    )
    if ($exitCode -ne 0) {
        foreach ($line in $output) {
            Write-Information -MessageData ([string]$line) -InformationAction Continue
        }
        throw "Visual Studio developer environment initialization failed: exit=$exitCode log=$environmentLog"
    }

    $imported = 0
    foreach ($line in $output) {
        $text = [string]$line
        $separator = $text.IndexOf('=')
        if ($separator -le 0) {
            continue
        }
        $name = $text.Substring(0,$separator)
        $value = $text.Substring($separator + 1)
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }
        [Environment]::SetEnvironmentVariable($name,$value,'Process')
        $imported++
    }
    if ($imported -lt 10) {
        throw "Visual Studio developer environment import was unexpectedly sparse: imported=$imported"
    }

    $compiler = (Get-Command cl.exe -ErrorAction Stop).Source
    $linker = (Get-Command link.exe -ErrorAction Stop).Source
    return [pscustomobject][ordered]@{
        compiler = [IO.Path]::GetFullPath($compiler)
        linker = [IO.Path]::GetFullPath($linker)
        imported_variable_count = $imported
        environment_log_path = $environmentLog
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

$vswhere = Resolve-NxbSemanticVsWhere
$installationPath = @(
    & $vswhere -latest -products '*' -requires 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' -property installationPath
) | Select-Object -First 1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$installationPath)) {
    throw 'Visual Studio C++ x64 Build Tools installation was not resolved.'
}
$installationPath = [IO.Path]::GetFullPath(([string]$installationPath).Trim())
$vsDevCmd = Join-Path $installationPath 'Common7\Tools\VsDevCmd.bat'
if (-not (Test-Path -LiteralPath $vsDevCmd -PathType Leaf)) {
    throw "VsDevCmd.bat is missing: $vsDevCmd"
}

$exePath = Join-Path $outputFull 'NXB-Superblock1SemanticFixture.exe'
$objectPath = Join-Path $outputFull 'NXB-Superblock1SemanticFixture.obj'
$buildLogPath = Join-Path $outputFull 'build.log'
$receiptPath = Join-Path $outputFull 'semantic-fixture-build-receipt.json'

$developerEnvironment = Import-NxbSemanticDeveloperEnvironment -VsDevCmd $vsDevCmd -WorkingDirectory $outputFull
$compiler = [string]$developerEnvironment.compiler
$compilerArguments = @(
    '/nologo',
    '/std:c++17',
    '/EHsc',
    '/W4',
    '/WX',
    '/O2',
    '/DUNICODE',
    '/D_UNICODE',
    ('/Fo{0}' -f $objectPath),
    $sourcePath,
    ('/Fe{0}' -f $exePath),
    '/link',
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
    schema_version = 2
    status = 'passed'
    head_sha = $currentHead
    source_sha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    executable_sha256 = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
    executable_length = [int64](Get-Item -LiteralPath $exePath).Length
    architecture = 'x64'
    compiler_environment = 'Visual Studio VsDevCmd imported into PowerShell process'
    compiler_path = $compiler
    linker_path = [string]$developerEnvironment.linker
    imported_environment_variables = [int]$developerEnvironment.imported_variable_count
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
    build_exit_code = $buildExit
}
Write-Information -MessageData "SUPERBLOCK semantic fixture build passed: $($result.executable_sha256)" -InformationAction Continue
if ($PassThru) { return $result }
