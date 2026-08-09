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
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$InputObject
    )
    [IO.File]::WriteAllText(
        $Path,
        (($InputObject | ConvertTo-Json -Depth 16) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
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
$commandPath = Join-Path $outputFull 'build.cmd'
$receiptPath = Join-Path $outputFull 'semantic-fixture-build-receipt.json'

$commandLines = @(
    '@echo off',
    'setlocal',
    ('call "{0}" -no_logo -arch=x64 -host_arch=x64' -f $vsDevCmd),
    'if errorlevel 1 exit /b %errorlevel%',
    ('cl.exe /nologo /std:c++17 /EHsc /W4 /WX /O2 /DUNICODE /D_UNICODE /Fo:"{0}" "{1}" /Fe:"{2}" /link d3d11.lib dxgi.lib user32.lib ws2_32.lib advapi32.lib' -f $objectPath,$sourcePath,$exePath),
    'exit /b %errorlevel%'
)
[IO.File]::WriteAllLines($commandPath,$commandLines,[Text.ASCIIEncoding]::new())

$cmd = (Get-Command cmd.exe -ErrorAction Stop).Source
$buildOutput = @(& $cmd /d /c $commandPath 2>&1)
$buildExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
[IO.File]::WriteAllLines($buildLogPath,@($buildOutput | ForEach-Object { [string]$_ }),[Text.UTF8Encoding]::new($false))
if ($buildExit -ne 0) {
    throw "Semantic fixture native build failed: exit=$buildExit log=$buildLogPath"
}
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw 'Semantic fixture build reported success but the executable is missing.'
}

$receipt = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    head_sha = $currentHead
    source_sha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    executable_sha256 = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
    executable_length = [int64](Get-Item -LiteralPath $exePath).Length
    architecture = 'x64'
    compiler_environment = 'Visual Studio VsDevCmd'
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
}
Write-Information -MessageData "SUPERBLOCK semantic fixture build passed: $($result.executable_sha256)" -InformationAction Continue
if ($PassThru) { return $result }
