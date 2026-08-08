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

function Resolve-NxbStorageBridgePython {
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
$normalizerPath = Join-Path $repositoryRoot 'tools\normalize_xperf_storage_dumper.py'
if (-not (Test-Path -LiteralPath $normalizerPath -PathType Leaf)) {
    throw "Xperf storage dumper normalizer not found: $normalizerPath"
}

$pythonPath = Resolve-NxbStorageBridgePython
if ([string]::IsNullOrWhiteSpace($pythonPath)) {
    throw 'Python not found. Xperf storage normalization requires Python.'
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

$csvPath = Join-Path $tempDirectory 'storage-event-export.csv'
$manifestPath = Join-Path $tempDirectory 'storage-xperf-bridge-manifest.json'
$normalizerHash = (
    Get-FileHash -LiteralPath $normalizerPath -Algorithm SHA256
).Hash.ToLowerInvariant()

$arguments = @(
    $normalizerPath,
    '--input', $inputFull,
    '--output', $csvPath,
    '--manifest', $manifestPath,
    '--normalizer-sha256', $normalizerHash,
    '--max-event-count', [string]$MaxEventCount
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
    $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
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
        throw (
            "Xperf storage dumper normalization failed (exit $exitCode):`n" +
            (@($nativeOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
        )
    }

    foreach ($requiredPath in @($csvPath, $manifestPath)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Storage normalizer output not found: $requiredPath"
        }
    }

    $expectedHeader = @(
        'event_type',
        'timestamp_raw',
        'process_id',
        'thread_id',
        'disk_number',
        'file_key',
        'path',
        'offset_bytes',
        'transfer_bytes',
        'duration_raw',
        'disk_service_time_raw',
        'result_raw'
    ) -join ','
    $header = Get-Content -LiteralPath $csvPath -TotalCount 1
    if ([string]$header -cne $expectedHeader) {
        throw "Normalized storage CSV header mismatch: $header"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $expectedInputHash = (
        Get-FileHash -LiteralPath $inputFull -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    $expectedCsvHash = (
        Get-FileHash -LiteralPath $csvPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()

    if ([int]$manifest.schema_version -ne 1 -or
        [string]$manifest.source_format -cne 'xperf_storage_dumper_text_v1' -or
        [string]$manifest.input_sha256 -cne $expectedInputHash -or
        [string]$manifest.normalizer_sha256 -cne $normalizerHash -or
        [string]$manifest.normalized_csv_sha256 -cne $expectedCsvHash -or
        [int]$manifest.normalized_event_count -le 0 -or
        [bool]$manifest.timing.normalized_duration_us_available) {
        throw 'Xperf storage bridge manifest validation failed.'
    }

    Move-Item -LiteralPath $tempDirectory -Destination $outputFull
}
catch {
    if (Test-Path -LiteralPath $tempDirectory) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force
    }
    throw
}

$finalCsv = Join-Path $outputFull 'storage-event-export.csv'
$finalManifest = Join-Path $outputFull 'storage-xperf-bridge-manifest.json'
Write-Information -MessageData "Xperf storage event export written: $finalCsv" -InformationAction Continue
Write-Information -MessageData "Xperf storage bridge manifest: $finalManifest" -InformationAction Continue

if ($PassThru) {
    $manifest = Get-Content -LiteralPath $finalManifest -Raw | ConvertFrom-Json
    [pscustomobject][ordered]@{
        output_directory = $outputFull
        event_export_path = $finalCsv
        manifest_path = $finalManifest
        normalized_event_count = [int]$manifest.normalized_event_count
        row_counts = $manifest.row_counts
        parser_completeness = [string]$manifest.parser_completeness
        timing = $manifest.timing
        manifest = $manifest
    }
}
