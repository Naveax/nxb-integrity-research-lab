[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NxbOptionalCommandRecord {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [string[]]$FallbackPaths = @()
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return [pscustomobject][ordered]@{
            name = $Name
            status = 'available'
            path = [string]$command.Source
        }
    }

    foreach ($candidate in $FallbackPaths) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [pscustomobject][ordered]@{
                name = $Name
                status = 'available'
                path = [IO.Path]::GetFullPath($candidate)
            }
        }
    }

    return [pscustomobject][ordered]@{
        name = $Name
        status = 'unavailable'
        path = $null
    }
}

if ($env:OS -cne 'Windows_NT') {
    throw 'GPU provider inventory requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'GPU provider inventory requires PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}
$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'GPU provider inventory requires a clean exact-head worktree.'
}

$outputFull = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $outputFull) {
    throw "OutputPath already exists: $outputFull"
}
$outputDirectory = Split-Path -Parent $outputFull
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
}

$logman = Get-Command logman.exe -ErrorAction Stop
$wevtutil = Get-Command wevtutil.exe -ErrorAction Stop

$providerOutput = @(& $logman.Source query providers 2>&1)
$providerExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
if ($providerExit -ne 0) {
    throw "logman provider inventory failed with exit code $providerExit."
}

$providerCandidates = [Collections.Generic.List[object]]::new()
$providerPattern = '(?i)(dxg|directx|graphics|dwm|present|gpu)'
$providerLinePattern = '^\s*(?<name>.+?)\s+(?<guid>\{[0-9a-fA-F-]{36}\})\s*$'
foreach ($line in $providerOutput) {
    $text = [string]$line
    $match = [regex]::Match($text, $providerLinePattern)
    if (-not $match.Success) { continue }
    $name = $match.Groups['name'].Value.Trim()
    if ($name -notmatch $providerPattern) { continue }
    $providerCandidates.Add([pscustomobject][ordered]@{
        name = $name
        guid = $match.Groups['guid'].Value.ToLowerInvariant()
    })
}

$channelOutput = @(& $wevtutil.Source el 2>&1)
$channelExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
if ($channelExit -ne 0) {
    throw "wevtutil channel inventory failed with exit code $channelExit."
}
$channelCandidates = @(
    $channelOutput |
        ForEach-Object { ([string]$_).Trim() } |
        Where-Object { $_ -and $_ -match $providerPattern } |
        Sort-Object -Unique
)

$os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
$adapters = @(
    Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
        Sort-Object -Property Name,PNPDeviceID |
        ForEach-Object {
            [pscustomobject][ordered]@{
                name = [string]$_.Name
                adapter_compatibility = [string]$_.AdapterCompatibility
                video_processor = [string]$_.VideoProcessor
                driver_version = [string]$_.DriverVersion
                driver_date_utc = if ($null -eq $_.DriverDate) {
                    $null
                }
                else {
                    ([datetime]$_.DriverDate).ToUniversalTime().ToString('o')
                }
                pnp_device_id = [string]$_.PNPDeviceID
                adapter_ram_bytes = if ($null -eq $_.AdapterRAM) { $null } else { [uint64]$_.AdapterRAM }
            }
        }
)

$wptRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Windows Performance Toolkit'
$gpuViewFallbacks = @(
    (Join-Path $wptRoot 'gpuview\GPUView.exe'),
    (Join-Path $wptRoot 'GPUView.exe')
)
$wpt = @(
    Get-NxbOptionalCommandRecord -Name 'wpr.exe'
    Get-NxbOptionalCommandRecord -Name 'wpa.exe'
    Get-NxbOptionalCommandRecord -Name 'xperf.exe'
    Get-NxbOptionalCommandRecord -Name 'GPUView.exe' -FallbackPaths $gpuViewFallbacks
)

$result = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    head_sha = $currentHead
    captured_utc = [DateTime]::UtcNow.ToString('o')
    machine_name = [string]$env:COMPUTERNAME
    os = [ordered]@{
        caption = [string]$os.Caption
        version = [string]$os.Version
        build_number = [string]$os.BuildNumber
        last_boot_utc = ([datetime]$os.LastBootUpTime).ToUniversalTime().ToString('o')
    }
    display_adapters = $adapters
    etw_provider_inventory = [ordered]@{
        source = 'logman query providers'
        candidate_count = $providerCandidates.Count
        candidates = @($providerCandidates)
    }
    event_channels = [ordered]@{
        source = 'wevtutil el'
        candidate_count = $channelCandidates.Count
        candidates = $channelCandidates
    }
    wpt_binaries = $wpt
    claims = [ordered]@{
        provider_semantics_validated = $false
        keyword_masks_validated = $false
        event_ids_validated = $false
        present_semantics = $false
        submission_semantics = $false
        queue_context_semantics = $false
        queue_wait_semantics = $false
        gpu_execution_duration_semantics = $false
        trace_completeness = 'not_claimed'
    }
}

[IO.File]::WriteAllText(
    $outputFull,
    (($result | ConvertTo-Json -Depth 20) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

$postDirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) {
    throw 'GPU provider inventory dirtied the exact-head worktree.'
}

Write-Information -MessageData "GPU provider inventory written: $outputFull" -InformationAction Continue
Write-Information -MessageData "Display adapters: $($adapters.Count)" -InformationAction Continue
Write-Information -MessageData "GPU/graphics provider candidates: $($providerCandidates.Count)" -InformationAction Continue
Write-Information -MessageData "GPU/graphics event channels: $($channelCandidates.Count)" -InformationAction Continue

if ($PassThru) { return $result }
