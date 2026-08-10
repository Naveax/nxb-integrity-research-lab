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

function ConvertTo-NxbSurfaceCanonicalNode {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [char] -or $Value -is [bool] -or
        $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or $Value -is [single] -or
        $Value -is [double] -or $Value -is [decimal]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $dictionaryResult = [ordered]@{}
        foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)) {
            $dictionaryResult[$key] = ConvertTo-NxbSurfaceCanonicalNode -Value $Value[$key]
        }
        return $dictionaryResult
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value | ForEach-Object { ConvertTo-NxbSurfaceCanonicalNode -Value $_ })
        Write-Output -InputObject $items -NoEnumerate
        return
    }
    $objectResult = [ordered]@{}
    foreach ($name in @($Value.PSObject.Properties.Name | Sort-Object -CaseSensitive)) {
        $objectResult[$name] = ConvertTo-NxbSurfaceCanonicalNode -Value $Value.PSObject.Properties[$name].Value
    }
    return $objectResult
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

$providerInventory = @(
    Get-WinEvent -ListProvider * -ErrorAction Stop |
        ForEach-Object {
            $providerName = [string](Get-NxbSurfaceProperty -InputObject $_ -Name 'Name' -DefaultValue '')
            if ([string]::IsNullOrWhiteSpace($providerName)) { return }
            $families = @(
                foreach ($entry in $familyPatterns.GetEnumerator()) {
                    if ($providerName -match [string]$entry.Value) { [string]$entry.Key }
                }
            )
            if ($families.Count -eq 0) { return }
            $logNames = @(
                @(Get-NxbSurfaceProperty -InputObject $_ -Name 'LogLinks' -DefaultValue @()) |
                    ForEach-Object { [string](Get-NxbSurfaceProperty -InputObject $_ -Name 'LogName' -DefaultValue '') } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Sort-Object -Unique
            )
            [pscustomobject][ordered]@{
                provider_name = $providerName
                provider_guid = [string](Get-NxbSurfaceProperty -InputObject $_ -Name 'Id' -DefaultValue '')
                families = @($families | Sort-Object -Unique)
                attached_logs = $logNames
            }
        } |
        Sort-Object @{ Expression = { Get-NxbSurfaceOrdinalHexKey -Value $_.provider_name }; Ascending = $true } |
        Select-Object -First $MaxProviders
)

$surfaceInventory = @(
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
            [pscustomobject][ordered]@{
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
    | Sort-Object `
        @{ Expression = { Get-NxbSurfaceOrdinalHexKey -Value $_.provider_name }; Ascending = $true },
        @{ Expression = { Get-NxbSurfaceOrdinalHexKey -Value $_.log_name }; Ascending = $true } |
        Select-Object -First $MaxSurfaces
)

$usableSurfaceInventory = @($surfaceInventory | Where-Object { $_.status -ceq 'available' })
$discoveryMaterial = [pscustomobject][ordered]@{
    binding_fingerprint_sha256 = $BindingFingerprintSha256.ToLowerInvariant()
    provider_metadata_fingerprint_sha256 = $ProviderMetadataFingerprintSha256.ToLowerInvariant()
    providers = $providerInventory
    surfaces = $surfaceInventory
}
$canonical = ConvertTo-NxbSurfaceCanonicalNode -Value $discoveryMaterial
$discoveryJson = $canonical | ConvertTo-Json -Depth 30 -Compress
$fingerprint = Get-NxbSurfaceSha256Text -Text $discoveryJson

$result = [pscustomobject][ordered]@{
    schema_version = 1
    captured_utc = [DateTime]::UtcNow.ToString('o')
    binding_fingerprint_sha256 = $BindingFingerprintSha256.ToLowerInvariant()
    provider_metadata_fingerprint_sha256 = $ProviderMetadataFingerprintSha256.ToLowerInvariant()
    discovery_fingerprint_sha256 = $fingerprint
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
