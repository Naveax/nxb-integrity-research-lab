[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$BindingFingerprintSha256,
    [Parameter()][ValidateRange(1,30)][int]$LookbackDays = 7,
    [Parameter()][ValidateRange(1,512)][int]$MaxEventsPerLog = 128,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NxbPlatformEventV3Sha256Text {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha256.Dispose() }
}

function ConvertTo-NxbPlatformEventV3CanonicalNode {
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
            $dictionaryResult[$key] = ConvertTo-NxbPlatformEventV3CanonicalNode -Value $Value[$key]
        }
        return $dictionaryResult
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value | ForEach-Object { ConvertTo-NxbPlatformEventV3CanonicalNode -Value $_ })
        Write-Output -InputObject $items -NoEnumerate
        return
    }
    $objectResult = [ordered]@{}
    foreach ($name in @($Value.PSObject.Properties.Name | Sort-Object -CaseSensitive)) {
        $objectResult[$name] = ConvertTo-NxbPlatformEventV3CanonicalNode -Value $Value.PSObject.Properties[$name].Value
    }
    return $objectResult
}

function Get-NxbPlatformEventV3OrdinalHexKey {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Value)
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-NxbPlatformEventV3OrdinalStringSet {
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

function Get-NxbPlatformEventV3OrderedDefinitionInventory {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object[]]$Values)
    $items = @(
        @($Values) | Sort-Object `
            @{ Expression = { [int]$_.id }; Ascending = $true },
            @{ Expression = { [int]$_.version }; Ascending = $true },
            @{ Expression = { Get-NxbPlatformEventV3OrdinalHexKey -Value $_.level }; Ascending = $true },
            @{ Expression = { Get-NxbPlatformEventV3OrdinalHexKey -Value $_.task }; Ascending = $true },
            @{ Expression = { Get-NxbPlatformEventV3OrdinalHexKey -Value $_.opcode }; Ascending = $true }
    )
    Write-Output -InputObject $items -NoEnumerate
}

function Get-NxbPlatformEventV3OrderedShapeInventory {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object[]]$Values)
    $items = @(
        @($Values) | Sort-Object `
            @{ Expression = { [int]$_.id }; Ascending = $true },
            @{ Expression = { [int]$_.version }; Ascending = $true },
            @{ Expression = { Get-NxbPlatformEventV3OrdinalHexKey -Value $_.level }; Ascending = $true },
            @{ Expression = { Get-NxbPlatformEventV3OrdinalHexKey -Value $_.task }; Ascending = $true },
            @{ Expression = { Get-NxbPlatformEventV3OrdinalHexKey -Value $_.opcode }; Ascending = $true }
    )
    Write-Output -InputObject $items -NoEnumerate
}

function Get-NxbPlatformEventV3OrderedLogInventory {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object[]]$Values)
    $items = @(@($Values) | Sort-Object @{ Expression = { Get-NxbPlatformEventV3OrdinalHexKey -Value $_.log_name }; Ascending = $true })
    Write-Output -InputObject $items -NoEnumerate
}

function Get-NxbPlatformEventV3OrderedProviderInventory {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object[]]$Values)
    $items = @(@($Values) | Sort-Object @{ Expression = { Get-NxbPlatformEventV3OrdinalHexKey -Value $_.provider_name }; Ascending = $true })
    Write-Output -InputObject $items -NoEnumerate
}

function Write-NxbPlatformEventV3Json {
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
        (($InputObject | ConvertTo-Json -Depth 40) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

$collectorV1 = Join-Path $PSScriptRoot 'Get-NxbPlatformEventBaseline.ps1'
if (-not (Test-Path -LiteralPath $collectorV1 -PathType Leaf)) { throw "L1 V1 collector missing: $collectorV1" }
$tempPath = [IO.Path]::GetFullPath($OutputPath) + '.v1.tmp'
try {
    & $collectorV1 -OutputPath $tempPath -BindingFingerprintSha256 $BindingFingerprintSha256 -LookbackDays $LookbackDays -MaxEventsPerLog $MaxEventsPerLog | Out-Null
    $snapshot = Get-Content -LiteralPath $tempPath -Raw | ConvertFrom-Json
    if ($null -eq $snapshot) { throw 'L1 V1 collector produced no snapshot JSON.' }

    foreach ($provider in @($snapshot.providers)) {
        foreach ($definition in @($provider.event_definitions)) {
            $definition.keywords = Get-NxbPlatformEventV3OrdinalStringSet -Values @($definition.keywords)
        }
        $provider.event_definitions = Get-NxbPlatformEventV3OrderedDefinitionInventory -Values @($provider.event_definitions)
        $provider.event_definition_count = [int]@($provider.event_definitions).Count
        foreach ($log in @($provider.logs)) {
            $log.shapes = Get-NxbPlatformEventV3OrderedShapeInventory -Values @($log.shapes)
        }
        $provider.logs = Get-NxbPlatformEventV3OrderedLogInventory -Values @($provider.logs)
        $provider.attached_log_count = [int]@($provider.logs).Count
    }
    $snapshot.providers = Get-NxbPlatformEventV3OrderedProviderInventory -Values @($snapshot.providers)

    $metadataMaterial = [pscustomobject][ordered]@{
        binding_fingerprint_sha256 = [string]$snapshot.binding_fingerprint_sha256
        providers = @($snapshot.providers | ForEach-Object {
            [pscustomobject][ordered]@{
                provider_name = $_.provider_name
                status = $_.status
                provider_guid = $_.provider_guid
                event_definition_count = $_.event_definition_count
                event_definitions = $_.event_definitions
                attached_log_count = $_.attached_log_count
                attached_logs = @($_.logs | ForEach-Object { $_.log_name })
                reason = $_.reason
            }
        })
    }
    $canonicalMetadata = ConvertTo-NxbPlatformEventV3CanonicalNode -Value $metadataMaterial
    $metadataJson = $canonicalMetadata | ConvertTo-Json -Depth 40 -Compress
    $snapshot.provider_metadata_fingerprint_sha256 = Get-NxbPlatformEventV3Sha256Text -Text $metadataJson
    Write-NxbPlatformEventV3Json -Path $OutputPath -InputObject $snapshot
}
finally {
    if (Test-Path -LiteralPath $tempPath -PathType Leaf) { Remove-Item -LiteralPath $tempPath -Force }
}

Write-Information -MessageData "NXB platform event baseline V3 written: $([IO.Path]::GetFullPath($OutputPath))" -InformationAction Continue
if ($PassThru) { return $snapshot }
Write-Output ([IO.Path]::GetFullPath($OutputPath))
