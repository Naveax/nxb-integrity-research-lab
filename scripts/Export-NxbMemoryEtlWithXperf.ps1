[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$EtlPath,

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

if ($env:OS -cne 'Windows_NT') {
    throw 'Raw memory ETL export requires real Windows.'
}

$bridgePath = Join-Path `
    $PSScriptRoot `
    'ConvertFrom-NxbXperfMemoryDumper.ps1'
if (-not (Test-Path -LiteralPath $bridgePath -PathType Leaf)) {
    throw "Xperf memory bridge not found: $bridgePath"
}

$xperf = Get-Command xperf.exe -ErrorAction SilentlyContinue
if ($null -eq $xperf) {
    throw 'xperf.exe was not found. Install the Windows Performance Toolkit.'
}

$etlFull = [IO.Path]::GetFullPath($EtlPath)
$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$etlItem = Get-Item -LiteralPath $etlFull -Force
if (($etlItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "EtlPath cannot be a reparse point: $etlFull"
}
if ([IO.Path]::GetExtension($etlFull) -cne '.etl') {
    throw "EtlPath must use the .etl extension: $etlFull"
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

$dumpPath = Join-Path $tempDirectory 'memory-xperf-dumper.txt'
$normalizedDirectory = Join-Path $tempDirectory 'normalized'
$receiptPath = Join-Path $tempDirectory 'memory-xperf-export-receipt.json'
$etlHash = (
    Get-FileHash -LiteralPath $etlFull -Algorithm SHA256
).Hash.ToLowerInvariant()
$xperfHash = (
    Get-FileHash -LiteralPath $xperf.Source -Algorithm SHA256
).Hash.ToLowerInvariant()
$bridgeHash = (
    Get-FileHash -LiteralPath $bridgePath -Algorithm SHA256
).Hash.ToLowerInvariant()

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

$xperfOutput = @()
$xperfExitCode = 1
try {
    $ErrorActionPreference = 'Continue'
    if ($nativePreferenceAvailable) {
        Set-Variable `
            -Name PSNativeCommandUseErrorActionPreference `
            -Value $false `
            -Scope Local
    }
    $xperfOutput = @(
        & $xperf.Source `
            -i $etlFull `
            -o $dumpPath `
            -a dumper 2>&1
    )
    $xperfExitCode = if ($null -eq $LASTEXITCODE) {
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
    if ($xperfExitCode -ne 0) {
        $message = @($xperfOutput | ForEach-Object { [string]$_ }) -join `
            [Environment]::NewLine
        throw "xperf dumper failed (exit $xperfExitCode):`n$message"
    }
    if (-not (Test-Path -LiteralPath $dumpPath -PathType Leaf)) {
        throw "xperf dumper output not found: $dumpPath"
    }
    if ((Get-Item -LiteralPath $dumpPath).Length -le 0) {
        throw 'xperf dumper output is empty.'
    }

    $bridgeResult = & $bridgePath `
        -InputPath $dumpPath `
        -OutputDirectory $normalizedDirectory `
        -MaxEventCount $MaxEventCount `
        -PassThru

    $normalizedCsv = [string]$bridgeResult.event_export_path
    $normalizedManifest = [string]$bridgeResult.manifest_path
    $dumpHash = (
        Get-FileHash -LiteralPath $dumpPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    $csvHash = (
        Get-FileHash -LiteralPath $normalizedCsv -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    $manifestHash = (
        Get-FileHash -LiteralPath $normalizedManifest -Algorithm SHA256
    ).Hash.ToLowerInvariant()

    $receipt = [pscustomobject][ordered]@{
        schema_version = 1
        source_format = 'xperf_etl_dumper_bridge'
        etl_sha256 = $etlHash
        xperf_sha256 = $xperfHash
        xperf_path = [string]$xperf.Source
        xperf_exit_code = $xperfExitCode
        dumper_sha256 = $dumpHash
        bridge_sha256 = $bridgeHash
        normalized_csv_sha256 = $csvHash
        normalized_manifest_sha256 = $manifestHash
        covered_event_types = @($bridgeResult.covered_event_types)
        normalized_event_count = [int]$bridgeResult.normalized_event_count
        process_attribution = [string]$bridgeResult.process_attribution
        claims = [ordered]@{
            missing_event_type_means_zero = $false
            trace_completeness = 'not_claimed'
            hard_fault_bytes_exact = $false
        }
    }

    [IO.File]::WriteAllText(
        $receiptPath,
        ($receipt | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false)
    )

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

$finalReceipt = Join-Path $outputFull 'memory-xperf-export-receipt.json'
Write-Host "Raw memory ETL exported with xperf: $outputFull"
Write-Host "Xperf export receipt: $finalReceipt"

if ($PassThru) {
    Get-Content -LiteralPath $finalReceipt -Raw | ConvertFrom-Json
}
