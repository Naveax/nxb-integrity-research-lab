[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [string]$XperfExecutablePath,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [string]$ReportPath,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force

function Get-NxbTraceStatisticValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Lines,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$LabelPatterns
    )

    foreach ($labelPattern in $LabelPatterns) {
        $pattern = '(?i)^\s*' + $labelPattern + '\s*[:=]\s*([0-9][0-9,]*)\s*$'
        foreach ($line in $Lines) {
            $match = [regex]::Match([string]$line, $pattern)
            if ($match.Success) {
                return [uint64]$match.Groups[1].Value.Replace(',', '')
            }
        }
    }
    return $null
}

function Get-NxbStatisticEvidence {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Source,

        [Parameter(Mandatory)]
        [ValidateSet('measured', 'unsupported', 'unavailable', 'failed')]
        [string]$FallbackStatus,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FallbackReason
    )

    if ($null -ne $Value) {
        return [ordered]@{
            status = 'measured'
            value = [uint64]$Value
            source = $Source
            reason = $null
        }
    }

    return [ordered]@{
        status = $FallbackStatus
        value = $null
        source = if ($FallbackStatus -eq 'unavailable') { $Source } else { $null }
        reason = $FallbackReason
    }
}

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
[void](Test-NxbPathSafety -Path $experimentFull -RootPath $experimentFull)
$etlPath = Join-Path $experimentFull 'traces\performance.etl'
if (-not (Test-Path -LiteralPath $etlPath -PathType Leaf)) {
    throw "ETL bulunamadı: $etlPath"
}
[void](Test-NxbPathSafety -Path $etlPath -RootPath $experimentFull)

$analysisRoot = Join-Path $experimentFull 'analysis'
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $analysisRoot 'etl-trace-statistics.json'
}
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $analysisRoot 'xperf-tracestats.txt'
}
$outputFull = Get-NxbFullPath -Path $OutputPath
$reportFull = Get-NxbFullPath -Path $ReportPath
[void](Get-NxbRelativePath -BasePath $experimentFull -ChildPath $outputFull)
[void](Get-NxbRelativePath -BasePath $experimentFull -ChildPath $reportFull)
if ($outputFull.Equals($reportFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ETL statistics JSON ve xperf rapor yolları aynı olamaz.'
}
foreach ($path in @($outputFull, $reportFull)) {
    if (Test-Path -LiteralPath $path) {
        throw "ETL trace statistics çıktısı zaten var: $path"
    }
    $parent = Split-Path -Parent $path
    if (Test-Path -LiteralPath $parent -PathType Container) {
        [void](Test-NxbPathSafety -Path $parent -RootPath $experimentFull)
    }
}

if (-not $PSCmdlet.ShouldProcess(
    $experimentFull,
    'Collect and write post-stop ETL trace statistics'
)) {
    return
}

if (-not (Test-Path -LiteralPath $analysisRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $analysisRoot -Force | Out-Null
}
[void](Test-NxbPathSafety -Path $analysisRoot -RootPath $experimentFull)

$xperfPath = $null
$resolveFailure = $null
try {
    $xperfPath = Resolve-NxbExecutablePath `
        -Name 'xperf.exe' `
        -ExplicitPath $XperfExecutablePath
}
catch {
    $resolveFailure = $_.Exception.Message
}

$exitCode = $null
$commandOutput = @()
if ($null -ne $xperfPath) {
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

    try {
        $ErrorActionPreference = 'Continue'
        if ($nativePreferenceAvailable) {
            Set-Variable `
                -Name PSNativeCommandUseErrorActionPreference `
                -Value $false `
                -Scope Local
        }
        $commandOutput = @(& $xperfPath `
            -i $etlPath `
            -o $reportFull `
            -a tracestats `
            -timespan `
            -timezone utc 2>&1)
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
}

$reportLines = if (Test-Path -LiteralPath $reportFull -PathType Leaf) {
    @(Get-Content -LiteralPath $reportFull)
}
else {
    @()
}
$combinedLines = @(
    @($commandOutput | ForEach-Object { [string]$_ })
    $reportLines
)
$combinedText = $combinedLines -join [Environment]::NewLine
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $statisticsHash = ([BitConverter]::ToString(
        $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($combinedText))
    )).Replace('-', '').ToLowerInvariant()
}
finally {
    $sha.Dispose()
}
$source = "xperf_tracestats:$statisticsHash"

$eventsLostValue = Get-NxbTraceStatisticValue `
    -Lines $combinedLines `
    -LabelPatterns @('Events\s+Lost', 'Lost\s+Events')
$buffersLostValue = Get-NxbTraceStatisticValue `
    -Lines $combinedLines `
    -LabelPatterns @('Buffers\s+Lost', 'Lost\s+Buffers')
$buffersWrittenValue = Get-NxbTraceStatisticValue `
    -Lines $combinedLines `
    -LabelPatterns @('Buffers\s+Written', 'Written\s+Buffers')

if ($null -eq $xperfPath) {
    $fallbackStatus = 'unsupported'
    $fallbackReason = "xperf.exe kullanılamıyor: $resolveFailure"
    $status = 'unsupported'
}
elseif ($exitCode -ne 0) {
    $fallbackStatus = 'failed'
    $fallbackReason = "xperf tracestats başarısız oldu (exit $exitCode)."
    $status = 'failed'
}
elseif ($null -eq $eventsLostValue -and
    $null -eq $buffersLostValue -and
    $null -eq $buffersWrittenValue) {
    $fallbackStatus = 'unavailable'
    $fallbackReason = 'xperf tracestats çıktısında beklenen trace-header sayaçları bulunamadı.'
    $status = 'unavailable'
}
else {
    $fallbackStatus = 'unavailable'
    $fallbackReason = 'Bu sayaç xperf tracestats çıktısında bulunamadı.'
    $status = 'measured'
}

$statistics = [ordered]@{
    schema_version = 1
    captured_utc = [DateTime]::UtcNow.ToString('o')
    experiment_id = [string](Split-Path -Leaf $experimentFull)
    status = $status
    command = [ordered]@{
        executable = $xperfPath
        arguments = @(
            '-i', $etlPath,
            '-o', $reportFull,
            '-a', 'tracestats',
            '-timespan',
            '-timezone', 'utc'
        )
    }
    exit_code = $exitCode
    statistics_sha256 = $statisticsHash
    events_lost = Get-NxbStatisticEvidence `
        -Value $eventsLostValue `
        -Source "$source;field=events_lost" `
        -FallbackStatus $fallbackStatus `
        -FallbackReason $fallbackReason
    buffers_lost = Get-NxbStatisticEvidence `
        -Value $buffersLostValue `
        -Source "$source;field=buffers_lost" `
        -FallbackStatus $fallbackStatus `
        -FallbackReason $fallbackReason
    buffers_written = Get-NxbStatisticEvidence `
        -Value $buffersWrittenValue `
        -Source "$source;field=buffers_written" `
        -FallbackStatus $fallbackStatus `
        -FallbackReason $fallbackReason
    realtime_buffers_lost = [ordered]@{
        status = 'unsupported'
        value = $null
        source = $null
        reason = 'File-mode ETL header does not represent real-time consumer delivery loss.'
    }
}

Write-NxbJsonAtomic -Path $outputFull -InputObject $statistics -Depth 16

if ($PassThru) {
    return [pscustomobject]$statistics
}
Write-Output $outputFull
