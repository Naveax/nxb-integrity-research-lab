[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$BindingFingerprintSha256,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ProviderMetadataFingerprintSha256,
    [Parameter()][ValidateRange(8,128)][int]$MaxProviders = 64,
    [Parameter()][ValidateRange(8,256)][int]$MaxSurfaces = 128,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NxbSurfaceProperty {
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter()][AllowNull()][object]$DefaultValue = $null
    )
    if ($null -eq $InputObject) { return $DefaultValue }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }
    return $property.Value
}

function Get-NxbSurfaceOrdinalHexKey {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Value)
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-NxbSurfaceOrderedStringInventory {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object[]]$Values)
    $set = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($value in @($Values)) {
        $text = [string]$value
        if (-not [string]::IsNullOrWhiteSpace($text)) { [void]$set.Add($text) }
    }
    $items = @($set)
    Write-Output -InputObject $items -NoEnumerate
}

function Get-NxbSurfaceSha256Text {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha256.Dispose() }
}

function Write-NxbSurfaceJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory)][object]$InputObject
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $fullPath,
        (($InputObject | ConvertTo-Json -Depth 30) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

if ($env:OS -cne 'Windows_NT') { throw 'Transition surface discovery requires Windows.' }

$familyPatterns = [ordered]@{
    pnp = '(?i)(pnp|device|setup|install)'
    power = '(?i)(power|energy|battery|processor)'
}

$providerCandidates = @()
foreach ($providerInfo in @(Get-WinEvent -ListProvider * -ErrorAction Stop)) {
    $providerName = [string](Get-NxbSurfaceProperty -InputObject $providerInfo -Name 'Name' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($providerName)) { continue }
    $familiesRaw = @()
    foreach ($entry in $familyPatterns.GetEnumerator()) {
        if ([regex]::IsMatch($providerName,[string]$entry.Value)) { $familiesRaw += [string]$entry.Key }
    }
    if ($familiesRaw.Count -eq 0) { continue }
    $logNameRaw = @(
        @(Get-NxbSurfaceProperty -InputObject $providerInfo -Name 'LogLinks' -DefaultValue @()) |
            ForEach-Object { [string](Get-NxbSurfaceProperty -InputObject $_ -Name 'LogName' -DefaultValue '') } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $providerCandidates += [pscustomobject][ordered]@{
        provider_name = $providerName
        provider_guid = [string](Get-NxbSurfaceProperty -InputObject $providerInfo -Name 'Id' -DefaultValue '')
        families = Get-NxbSurfaceOrderedStringInventory -Values $familiesRaw
        attached_logs = Get-NxbSurfaceOrderedStringInventory -Values $logNameRaw
    }
}

$providerInventory = @(
    $providerCandidates |
        Sort-Object @{ Expression = { Get-NxbSurfaceOrdinalHexKey -Value $_.provider_name }; Ascending = $true } |
        Select-Object -First $MaxProviders
)

$surfaceCandidates = @()
foreach ($provider in $providerInventory) {
    foreach ($logName in @($provider.attached_logs)) {
        $status = 'unavailable'
        $enabled = $null
        $reason = 'list_log_failed'
        try {
            $logInfo = Get-WinEvent -ListLog $logName -ErrorAction Stop
            $enabled = [bool](Get-NxbSurfaceProperty -InputObject $logInfo -Name 'IsEnabled' -DefaultValue $false)
            if ($enabled) { $status = 'available'; $reason = $null }
            else { $status = 'disabled'; $reason = 'log_disabled' }
        }
        catch { }
        $surfaceCandidates += [pscustomobject][ordered]@{
            provider_name = [string]$provider.provider_name
            provider_guid = [string]$provider.provider_guid
            families = @($provider.families)
            log_name = [string]$logName
            status = $status
            enabled = $enabled
            reason = $reason
        }
    }
}

$surfaceInventory = @(
    $surfaceCandidates |
        Sort-Object `
            @{ Expression = { Get-NxbSurfaceOrdinalHexKey -Value $_.provider_name }; Ascending = $true },
            @{ Expression = { Get-NxbSurfaceOrdinalHexKey -Value $_.log_name }; Ascending = $true } |
        Select-Object -First $MaxSurfaces
)
$usableSurfaceInventory = @($surfaceInventory | Where-Object { $_.status -ceq 'available' })

$fingerprintLines = @(
    'binding' + "`t" + $BindingFingerprintSha256.ToLowerInvariant()
    'metadata' + "`t" + $ProviderMetadataFingerprintSha256.ToLowerInvariant()
)
foreach ($provider in $providerInventory) {
    $fingerprintLines += ('P' + "`t" + [string]$provider.provider_name + "`t" + [string]$provider.provider_guid + "`t" + (@($provider.families) -join '|') + "`t" + (@($provider.attached_logs) -join '|'))
}
foreach ($surface in $surfaceInventory) {
    $enabledText = if ($null -eq $surface.enabled) { 'null' } elseif ([bool]$surface.enabled) { 'true' } else { 'false' }
    $reasonText = if ($null -eq $surface.reason) { '' } else { [string]$surface.reason }
    $fingerprintLines += ('S' + "`t" + [string]$surface.provider_name + "`t" + [string]$surface.provider_guid + "`t" + (@($surface.families) -join '|') + "`t" + [string]$surface.log_name + "`t" + [string]$surface.status + "`t" + $enabledText + "`t" + $reasonText)
}
$fingerprintMaterial = $fingerprintLines -join "`n"
$fingerprint = Get-NxbSurfaceSha256Text -Text $fingerprintMaterial

$result = [pscustomobject][ordered]@{
    schema_version = 2
    captured_utc = [DateTime]::UtcNow.ToString('o')
    binding_fingerprint_sha256 = $BindingFingerprintSha256.ToLowerInvariant()
    provider_metadata_fingerprint_sha256 = $ProviderMetadataFingerprintSha256.ToLowerInvariant()
    discovery_fingerprint_sha256 = $fingerprint
    fingerprint_contract = 'ordinal_tsv_v1'
    max_providers = $MaxProviders
    max_surfaces = $MaxSurfaces
    provider_count = [int]$providerInventory.Count
    surface_count = [int]$surfaceInventory.Count
    usable_surface_count = [int]$usableSurfaceInventory.Count
    providers = $providerInventory
    surfaces = $surfaceInventory
    claims = [pscustomobject][ordered]@{
        provider_name_family_discovery = $true
        attached_log_discovery = $true
        event_id_semantics = $false
        device_lifecycle_semantics = $false
        power_causality = $false
        firmware_causality = $false
        continuous_trace_completeness = 'not_claimed'
    }
}

Write-NxbSurfaceJson -Path $OutputPath -InputObject $result
Write-Information -MessageData "NXB transition surface discovery written: $([IO.Path]::GetFullPath($OutputPath)) providers=$($providerInventory.Count) surfaces=$($surfaceInventory.Count) usable=$($usableSurfaceInventory.Count) fingerprint=$fingerprint" -InformationAction Continue
if ($PassThru) { return $result }
Write-Output ([IO.Path]::GetFullPath($OutputPath))
