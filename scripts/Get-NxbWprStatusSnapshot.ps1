[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [string]$WprExecutablePath,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force

function Get-NxbUnsignedValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Lines,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LabelPattern
    )

    $pattern = '(?i)^\s*' + $LabelPattern + '\s*:\s*([0-9]+)\s*$'
    $values = [Collections.Generic.List[uint64]]::new()
    foreach ($line in $Lines) {
        $match = [regex]::Match([string]$line, $pattern)
        if ($match.Success) {
            $values.Add([uint64]$match.Groups[1].Value)
        }
    }
    return @($values)
}

function Get-NxbSnapshotCounter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [uint64[]]$CollectorValues,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [uint64[]]$FallbackValues,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SnapshotSha256,

        [Parameter(Mandatory)]
        [int]$ExitCode
    )

    if ($ExitCode -ne 0) {
        return [ordered]@{
            status = 'failed'
            value = $null
            source = $null
            reason = "wpr -status başarısız oldu (exit $ExitCode)."
        }
    }

    if ($CollectorValues.Count -gt 0) {
        $sum = [uint64]0
        foreach ($value in $CollectorValues) {
            $sum += $value
        }
        return [ordered]@{
            status = 'measured'
            value = $sum
            source = "wpr_status_snapshot:$SnapshotSha256;field=collector_events_lost"
            reason = $null
        }
    }

    if ($FallbackValues.Count -gt 0) {
        return [ordered]@{
            status = 'measured'
            value = [uint64]$FallbackValues[0]
            source = "wpr_status_snapshot:$SnapshotSha256;field=dropped_event"
            reason = $null
        }
    }

    return [ordered]@{
        status = 'unavailable'
        value = $null
        source = "wpr_status_snapshot:$SnapshotSha256"
        reason = 'WPR status çıktısında Events Lost veya Dropped event alanı bulunamadı.'
    }
}

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
[void](Test-NxbPathSafety -Path $experimentFull -RootPath $experimentFull)
$manifestPath = Join-Path $experimentFull 'manifest.json'
$sessionPath = Join-Path $experimentFull 'trace-session.json'
foreach ($requiredPath in @($manifestPath, $sessionPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "WPR status snapshot girdisi bulunamadı: $requiredPath"
    }
    [void](Test-NxbPathSafety -Path $requiredPath -RootPath $experimentFull)
}

$manifest = Read-NxbJson -Path $manifestPath
$session = Read-NxbJson -Path $sessionPath
$experimentId = [string](Split-Path -Leaf $experimentFull)
if ([string]$manifest.experiment_id -cne $experimentId) {
    throw 'Manifest experiment_id ile deney dizini uyuşmuyor.'
}
if ([string]$manifest.status -cne 'recording' -or [string]$session.status -cne 'recording') {
    throw 'WPR status snapshot yalnız recording durumunda alınabilir.'
}

$wprPath = Resolve-NxbExecutablePath -Name 'wpr.exe' -ExplicitPath $WprExecutablePath
$analysisRoot = Join-Path $experimentFull 'analysis'
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $analysisRoot 'wpr-status-pre-stop.json'
}
$outputFull = Get-NxbFullPath -Path $OutputPath
[void](Get-NxbRelativePath -BasePath $experimentFull -ChildPath $outputFull)
if (Test-Path -LiteralPath $outputFull) {
    throw "WPR status snapshot zaten var: $outputFull"
}
$outputParent = Split-Path -Parent $outputFull
if (Test-Path -LiteralPath $outputParent -PathType Container) {
    [void](Test-NxbPathSafety -Path $outputParent -RootPath $experimentFull)
}

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

$rawOutput = @()
$exitCode = 1
try {
    $ErrorActionPreference = 'Continue'
    if ($nativePreferenceAvailable) {
        Set-Variable `
            -Name PSNativeCommandUseErrorActionPreference `
            -Value $false `
            -Scope Local
    }
    $rawOutput = @(& $wprPath -status collectors -details 2>&1)
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

$lines = @($rawOutput | ForEach-Object { [string]$_ })
$rawText = $lines -join [Environment]::NewLine
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $rawHash = ([BitConverter]::ToString(
        $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($rawText))
    )).Replace('-', '').ToLowerInvariant()
}
finally {
    $sha.Dispose()
}

$collectorValues = @(Get-NxbUnsignedValues -Lines $lines -LabelPattern 'Events\s+Lost')
$droppedValues = @(Get-NxbUnsignedValues -Lines $lines -LabelPattern 'Dropped\s+event')
$eventsLost = Get-NxbSnapshotCounter `
    -CollectorValues $collectorValues `
    -FallbackValues $droppedValues `
    -SnapshotSha256 $rawHash `
    -ExitCode $exitCode

$snapshot = [ordered]@{
    schema_version = 1
    captured_utc = [DateTime]::UtcNow.ToString('o')
    experiment_id = $experimentId
    command = [ordered]@{
        executable = $wprPath
        arguments = @('-status', 'collectors', '-details')
    }
    status = if ($exitCode -eq 0) { 'measured' } else { 'failed' }
    exit_code = $exitCode
    raw_output_sha256 = $rawHash
    raw_output = $lines
    events_lost = $eventsLost
    buffers_lost = [ordered]@{
        status = 'unsupported'
        value = $null
        source = $null
        reason = 'wpr -status çıktısı LogBuffersLost alanını güvenilir biçimde sağlamıyor.'
    }
    realtime_buffers_lost = [ordered]@{
        status = 'unsupported'
        value = $null
        source = $null
        reason = 'File-mode WPR status çıktısı RealTimeBuffersLost alanını sağlamıyor.'
    }
}

$written = $false
if ($PSCmdlet.ShouldProcess($outputFull, 'Write WPR pre-stop status snapshot')) {
    if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
        New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
    }
    [void](Test-NxbPathSafety -Path $outputParent -RootPath $experimentFull)
    Write-NxbJsonAtomic -Path $outputFull -InputObject $snapshot -Depth 16
    $written = $true
}

if ($PassThru) {
    return [pscustomobject]$snapshot
}
if ($written) {
    Write-Output $outputFull
}
