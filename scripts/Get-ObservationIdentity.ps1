[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force

function Get-NxbSha256Text {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha256.ComputeHash($bytes)
        return -join ($hash | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha256.Dispose()
    }
}

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
$manifestPath = Join-Path $experimentFull 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Manifest bulunamadı: $manifestPath"
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $experimentFull 'baseline\observation-identity.json'
}

$manifest = Read-NxbJson -Path $manifestPath
$capabilityPath = Join-Path $experimentFull 'baseline\system-capabilities.json'

$machineId = $null
$osBuild = $null
$lastBootUtc = $null

if (Test-Path -LiteralPath $capabilityPath -PathType Leaf) {
    $capability = Read-NxbJson -Path $capabilityPath
    $machineId = [string]$capability.machine_id

    if ($capability.domains.operating_system.status -eq 'available') {
        $osBuild = [string]$capability.domains.operating_system.data.build_number
        $lastBootUtc = [string]$capability.domains.operating_system.data.last_boot_utc
    }
}

if ([string]::IsNullOrWhiteSpace($machineId)) {
    $product = Get-CimInstance Win32_ComputerSystemProduct | Select-Object -First 1
    $machineId = if ($null -ne $product -and -not [string]::IsNullOrWhiteSpace([string]$product.UUID)) {
        [string]$product.UUID
    }
    else {
        [string]$env:COMPUTERNAME
    }
}

if ([string]::IsNullOrWhiteSpace($lastBootUtc) -or [string]::IsNullOrWhiteSpace($osBuild)) {
    $os = Get-CimInstance Win32_OperatingSystem | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($lastBootUtc) -and $os.LastBootUpTime) {
        $lastBootUtc = $os.LastBootUpTime.ToUniversalTime().ToString('o')
    }
    if ([string]::IsNullOrWhiteSpace($osBuild)) {
        $osBuild = [string]$os.BuildNumber
    }
}

$bootMaterial = '{0}|{1}|{2}' -f $machineId, $lastBootUtc, $osBuild
$bootId = Get-NxbSha256Text -Text $bootMaterial

$ticks = [Diagnostics.Stopwatch]::GetTimestamp()
$frequency = [Diagnostics.Stopwatch]::Frequency
$monotonicNs = [long](([decimal]$ticks * [decimal]1000000000) / [decimal]$frequency)
$utcOffsetMinutes = [int][TimeZoneInfo]::Local.GetUtcOffset([DateTime]::UtcNow).TotalMinutes

$identity = [ordered]@{
    schema_version = 1
    experiment_id  = [string]$manifest.experiment_id
    machine_id     = $machineId
    boot_id        = $bootId
    captured_utc   = [DateTime]::UtcNow.ToString('o')
    last_boot_utc  = if ([string]::IsNullOrWhiteSpace($lastBootUtc)) { $null } else { $lastBootUtc }
    os_build       = if ([string]::IsNullOrWhiteSpace($osBuild)) { $null } else { $osBuild }
    clock          = [ordered]@{
        source                 = 'System.Diagnostics.Stopwatch'
        stopwatch_frequency_hz = [long]$frequency
        sample_ticks           = [long]$ticks
        sample_monotonic_ns    = $monotonicNs
        utc_offset_minutes     = $utcOffsetMinutes
    }
}

Write-NxbJsonAtomic -Path $OutputPath -InputObject $identity -Depth 12

Write-Host "Observation identity oluşturuldu: $OutputPath"
Write-Output $OutputPath
