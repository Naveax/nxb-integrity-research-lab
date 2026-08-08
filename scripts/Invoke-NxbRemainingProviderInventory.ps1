[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter()]
    [ValidateRange(16, 1024)]
    [int]$RecordLimit = 256,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NxbRemainingProviderCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines,

        [Parameter(Mandatory)]
        [string]$Pattern,

        [Parameter(Mandatory)]
        [int]$Limit
    )

    $linePattern = '^\s*(?<name>.+?)\s+(?<guid>\{[0-9a-fA-F-]{36}\})\s*$'
    $records = @(
        foreach ($line in $Lines) {
            $match = [regex]::Match([string]$line, $linePattern)
            if (-not $match.Success) { continue }

            $name = $match.Groups['name'].Value.Trim()
            if ($name -notmatch $Pattern) { continue }

            [pscustomobject][ordered]@{
                name = $name
                guid = $match.Groups['guid'].Value.ToLowerInvariant()
            }
        }
    ) | Sort-Object -Property name,guid -Unique

    $selected = @($records | Select-Object -First $Limit)
    return [pscustomobject][ordered]@{
        candidate_count = @($records).Count
        emitted_count = $selected.Count
        truncated = (@($records).Count -gt $selected.Count)
        candidates = $selected
    }
}

function Get-NxbRemainingChannelCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines,

        [Parameter(Mandatory)]
        [string]$Pattern,

        [Parameter(Mandatory)]
        [int]$Limit
    )

    $records = @(
        $Lines |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { $_ -and $_ -match $Pattern } |
            Sort-Object -Unique
    )
    $selected = @($records | Select-Object -First $Limit)

    return [pscustomobject][ordered]@{
        candidate_count = $records.Count
        emitted_count = $selected.Count
        truncated = ($records.Count -gt $selected.Count)
        candidates = $selected
    }
}

if ($env:OS -cne 'Windows_NT') {
    throw 'Remaining provider inventory requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Remaining provider inventory requires PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}

$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'Remaining provider inventory requires a clean exact-head worktree.'
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

$channelOutput = @(& $wevtutil.Source el 2>&1)
$channelExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
if ($channelExit -ne 0) {
    throw "wevtutil channel inventory failed with exit code $channelExit."
}

$providerLines = @($providerOutput | ForEach-Object { [string]$_ })
$channelLines = @($channelOutput | ForEach-Object { [string]$_ })

$networkPattern = '(?i)(ndis|tcpip|winsock|dns|network|http|webio)'
$kernelPattern = '(?i)(kernel|process|thread|image|registry|service|driver)'
$devicePattern = '(?i)(pnp|pci|device|driver|whea|iommu|dma)'
$powerPattern = '(?i)(power|thermal|energy|battery|acpi)'

$result = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    head_sha = $currentHead
    captured_utc = [DateTime]::UtcNow.ToString('o')
    record_limit = $RecordLimit
    providers = [ordered]@{
        network = Get-NxbRemainingProviderCandidate `
            -Lines $providerLines -Pattern $networkPattern -Limit $RecordLimit
        kernel_lifecycle = Get-NxbRemainingProviderCandidate `
            -Lines $providerLines -Pattern $kernelPattern -Limit $RecordLimit
        device_driver = Get-NxbRemainingProviderCandidate `
            -Lines $providerLines -Pattern $devicePattern -Limit $RecordLimit
        power_thermal = Get-NxbRemainingProviderCandidate `
            -Lines $providerLines -Pattern $powerPattern -Limit $RecordLimit
    }
    event_channels = [ordered]@{
        network = Get-NxbRemainingChannelCandidate `
            -Lines $channelLines -Pattern $networkPattern -Limit $RecordLimit
        kernel_lifecycle = Get-NxbRemainingChannelCandidate `
            -Lines $channelLines -Pattern $kernelPattern -Limit $RecordLimit
        device_driver = Get-NxbRemainingChannelCandidate `
            -Lines $channelLines -Pattern $devicePattern -Limit $RecordLimit
        power_thermal = Get-NxbRemainingChannelCandidate `
            -Lines $channelLines -Pattern $powerPattern -Limit $RecordLimit
    }
    capability_contract = [ordered]@{
        system_capabilities_schema = 'schemas/system-capabilities.schema.json'
        system_capabilities_collector = 'scripts/Get-SystemCapabilities.ps1'
        required_existing_domains = @(
            'gpu',
            'network',
            'bus_and_devices',
            'firmware',
            'security',
            'power'
        )
    }
    claims = [ordered]@{
        provider_identity_only = $true
        keyword_semantics_validated = $false
        event_ids_validated = $false
        network_connection_semantics = $false
        network_latency_semantics = $false
        device_lifecycle_semantics = $false
        kernel_lifecycle_semantics = $false
        power_thermal_representative = $false
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
    throw 'Remaining provider inventory dirtied the exact-head worktree.'
}

Write-Information -MessageData "Remaining provider inventory written: $outputFull" -InformationAction Continue
Write-Information -MessageData "Network providers: $($result.providers.network.candidate_count)" -InformationAction Continue
Write-Information -MessageData "Kernel providers: $($result.providers.kernel_lifecycle.candidate_count)" -InformationAction Continue
Write-Information -MessageData "Device providers: $($result.providers.device_driver.candidate_count)" -InformationAction Continue
Write-Information -MessageData "Power/thermal providers: $($result.providers.power_thermal.candidate_count)" -InformationAction Continue
Write-Information -MessageData 'Provider/event semantics enabled: False' -InformationAction Continue

if ($PassThru) {
    return $result
}
