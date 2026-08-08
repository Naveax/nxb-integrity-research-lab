[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$InputPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,

    [Parameter()]
    [ValidateRange(1, 5000000)]
    [int]$MaxEventCount = 1000000,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-NxbXperfBridgePython {
    [CmdletBinding()]
    param()

    foreach ($candidate in @('python.exe', 'python', 'py.exe', 'py')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return [string]$command.Source
        }
    }
    return $null
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$normalizerPath = Join-Path `
    $repositoryRoot `
    'tools\normalize_xperf_memory_dumper.py'
if (-not (Test-Path -LiteralPath $normalizerPath -PathType Leaf)) {
    throw "Xperf memory dumper normalizer not found: $normalizerPath"
}

$pythonPath = Resolve-NxbXperfBridgePython
if ([string]::IsNullOrWhiteSpace($pythonPath)) {
    throw 'Python not found. Xperf dumper normalization requires Python.'
}

$inputFull = [IO.Path]::GetFullPath($InputPath)
$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$inputItem = Get-Item -LiteralPath $inputFull -Force
if (($inputItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "InputPath cannot be a reparse point: $inputFull"
}
if (Test-Path -LiteralPath $outputFull) {
    throw "OutputDirectory already exists: $outputFull"
}

$outputParent = Split-Path -Parent $outputFull
if ([string]::IsNullOrWhiteSpace($outputParent)) {
    throw "Output parent could not be resolved: $outputFull"
}
[IO.Directory]::CreateDirectory($outputParent) | Out-Null

$tempDirectory = Join-Path `
    $outputParent `
    ('.' + [IO.Path]::GetFileName($outputFull) + '.' +
        [guid]::NewGuid().ToString('N') + '.tmp')
[IO.Directory]::CreateDirectory($tempDirectory) | Out-Null

$csvPath = Join-Path $tempDirectory 'memory-event-export.csv'
$manifestPath = Join-Path `
    $tempDirectory `
    'memory-xperf-bridge-manifest.json'
$normalizerHash = (
    Get-FileHash -LiteralPath $normalizerPath -Algorithm SHA256
).Hash.ToLowerInvariant()

$arguments = @(
    $normalizerPath,
    '--input',
    $inputFull,
    '--output',
    $csvPath,
    '--manifest',
    $manifestPath,
    '--normalizer-sha256',
    $normalizerHash,
    '--max-event-count',
    [string]$MaxEventCount
)

$previousErrorActionPreference = $ErrorActionPreference
$nativePreferenceVariable = Get-Variable `
    -Name PSNativeCommandUseErrorActionPreference `
    -ErrorAction SilentlyContinue
$nativePreferenceAvailable = $null -ne $nativePreferenceVariable
$previousNativePreference = if ($nativePreferenceAvailable) {
    [bool]$nativePreferenceVariable.Value
}
else {
    $null
}

$nativeOutput = @()
$exitCode = 1
try {
    $ErrorActionPreference = 'Continue'
    if ($nativePreferenceAvailable) {
        Set-Variable `
            -Name PSNativeCommandUseErrorActionPreference `
            -Value $false `
            -Scope Local
    }
    $nativeOutput = @(& $pythonPath @arguments 2>&1)
    $exitCode = if ($null -eq $LASTEXITCODE) {
        1
    }
    else {
        [int]$LASTEXITCODE
    }
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
    if ($nativePreferenceAvailable) {
        Set-Variable `
            -Name PSNativeCommandUseErrorActionPreference `
            -Value $previousNativePreference `
            -Scope Local
    }
}

try {
    if ($exitCode -ne 0) {
        $message = @($nativeOutput | ForEach-Object { [string]$_ }) -join `
            [Environment]::NewLine
        throw (
            "Xperf memory dumper normalization failed (exit $exitCode):`n" +
            $message
        )
    }

    foreach ($requiredPath in @($csvPath, $manifestPath)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Normalizer output not found: $requiredPath"
        }
    }

    $header = Get-Content -LiteralPath $csvPath -TotalCount 1
    if ([string]$header -cne `
        'event_type,timestamp_us,process_id,thread_id,size_bytes') {
        throw "Normalized CSV header mismatch: $header"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw |
        ConvertFrom-Json
    $expectedInputHash = (
        Get-FileHash -LiteralPath $inputFull -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    $expectedCsvHash = (
        Get-FileHash -LiteralPath $csvPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()

    if ([int]$manifest.schema_version -ne 1 -or
        [string]$manifest.source_format -cne 'xperf_dumper_text' -or
        [string]$manifest.input_sha256 -cne $expectedInputHash -or
        [string]$manifest.normalizer_sha256 -cne $normalizerHash -or
        [string]$manifest.normalized_csv_sha256 -cne $expectedCsvHash -or
        [int]$manifest.normalized_event_count -le 0 -or
        @($manifest.covered_event_types).Count -le 0) {
        throw 'Xperf memory bridge manifest validation failed.'
    }

    Move-Item `
        -LiteralPath $tempDirectory `
        -Destination $outputFull
}
catch {
    if (Test-Path -LiteralPath $tempDirectory) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force
    }
    throw
}

$finalCsv = Join-Path $outputFull 'memory-event-export.csv'
$finalManifest = Join-Path `
    $outputFull `
    'memory-xperf-bridge-manifest.json'
Write-Host "Xperf memory event export written: $finalCsv"
Write-Host "Xperf memory bridge manifest: $finalManifest"

if ($PassThru) {
    $manifest = Get-Content -LiteralPath $finalManifest -Raw |
        ConvertFrom-Json
    [pscustomobject][ordered]@{
        output_directory = $outputFull
        event_export_path = $finalCsv
        manifest_path = $finalManifest
        covered_event_types = @($manifest.covered_event_types)
        normalized_event_count = [int]$manifest.normalized_event_count
        process_attribution = [string]$manifest.process_attribution
        manifest = $manifest
    }
}
