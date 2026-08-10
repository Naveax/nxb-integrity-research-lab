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

function Get-NxbPlatformEventProperty {
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

function Get-NxbPlatformEventSha256Text {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha256.Dispose() }
}

function ConvertTo-NxbPlatformEventCanonicalNode {
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
            $dictionaryResult[$key] = ConvertTo-NxbPlatformEventCanonicalNode -Value $Value[$key]
        }
        return $dictionaryResult
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value | ForEach-Object { ConvertTo-NxbPlatformEventCanonicalNode -Value $_ })
        Write-Output -InputObject $items -NoEnumerate
        return
    }
    $objectResult = [ordered]@{}
    foreach ($name in @($Value.PSObject.Properties.Name | Sort-Object -CaseSensitive)) {
        $objectResult[$name] = ConvertTo-NxbPlatformEventCanonicalNode -Value $Value.PSObject.Properties[$name].Value
    }
    return $objectResult
}

function Write-NxbPlatformEventJson {
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

function ConvertTo-NxbPlatformEventDefinition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$EventDefinition)
    $keywords = @(
        @(Get-NxbPlatformEventProperty -InputObject $EventDefinition -Name 'Keywords' -DefaultValue @()) |
            ForEach-Object {
                [string](Get-NxbPlatformEventProperty -InputObject $_ -Name 'DisplayName' -DefaultValue (Get-NxbPlatformEventProperty -InputObject $_ -Name 'Name' -DefaultValue ''))
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
    $level = Get-NxbPlatformEventProperty -InputObject $EventDefinition -Name 'Level'
    $task = Get-NxbPlatformEventProperty -InputObject $EventDefinition -Name 'Task'
    $opcode = Get-NxbPlatformEventProperty -InputObject $EventDefinition -Name 'Opcode'
    return [pscustomobject][ordered]@{
        id = [int](Get-NxbPlatformEventProperty -InputObject $EventDefinition -Name 'Id' -DefaultValue 0)
        version = [int](Get-NxbPlatformEventProperty -InputObject $EventDefinition -Name 'Version' -DefaultValue 0)
        level = if ($null -eq $level) { $null } else { [string](Get-NxbPlatformEventProperty -InputObject $level -Name 'DisplayName' -DefaultValue (Get-NxbPlatformEventProperty -InputObject $level -Name 'Name' -DefaultValue '')) }
        task = if ($null -eq $task) { $null } else { [string](Get-NxbPlatformEventProperty -InputObject $task -Name 'DisplayName' -DefaultValue (Get-NxbPlatformEventProperty -InputObject $task -Name 'Name' -DefaultValue '')) }
        opcode = if ($null -eq $opcode) { $null } else { [string](Get-NxbPlatformEventProperty -InputObject $opcode -Name 'DisplayName' -DefaultValue (Get-NxbPlatformEventProperty -InputObject $opcode -Name 'Name' -DefaultValue '')) }
        keywords = $keywords
    }
}

function Get-NxbPlatformEventShapeKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$EventRecord)
    $id = [int](Get-NxbPlatformEventProperty -InputObject $EventRecord -Name 'Id' -DefaultValue 0)
    $version = [int](Get-NxbPlatformEventProperty -InputObject $EventRecord -Name 'Version' -DefaultValue 0)
    $level = [string](Get-NxbPlatformEventProperty -InputObject $EventRecord -Name 'LevelDisplayName' -DefaultValue '')
    $task = [string](Get-NxbPlatformEventProperty -InputObject $EventRecord -Name 'TaskDisplayName' -DefaultValue '')
    $opcode = [string](Get-NxbPlatformEventProperty -InputObject $EventRecord -Name 'OpcodeDisplayName' -DefaultValue '')
    return ('{0}|{1}|{2}|{3}|{4}' -f $id,$version,$level,$task,$opcode)
}

$providerNames = @(
    'Microsoft-Windows-CodeIntegrity',
    'Microsoft-Windows-DeviceGuard',
    'Microsoft-Windows-Kernel-Boot',
    'Microsoft-Windows-Kernel-PnP',
    'Microsoft-Windows-Kernel-Power',
    'Microsoft-Windows-Kernel-Processor-Power',
    'Microsoft-Windows-UserPnp',
    'Microsoft-Windows-WHEA-Logger'
)
$startTime = [DateTime]::UtcNow.AddDays(-1 * $LookbackDays)
$providerRecords = foreach ($providerName in $providerNames) {
    try {
        $providerInfo = Get-WinEvent -ListProvider $providerName -ErrorAction Stop
        $providerGuid = [string](Get-NxbPlatformEventProperty -InputObject $providerInfo -Name 'Id' -DefaultValue '')
        $definitions = @(
            @(Get-NxbPlatformEventProperty -InputObject $providerInfo -Name 'Events' -DefaultValue @()) |
                ForEach-Object { ConvertTo-NxbPlatformEventDefinition -EventDefinition $_ } |
                Sort-Object id,version,level,task,opcode
        )
        $logNames = @(
            @(Get-NxbPlatformEventProperty -InputObject $providerInfo -Name 'LogLinks' -DefaultValue @()) |
                ForEach-Object { [string](Get-NxbPlatformEventProperty -InputObject $_ -Name 'LogName' -DefaultValue '') } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )
        $logRecords = foreach ($logName in $logNames) {
            $logInfo = $null
            try { $logInfo = Get-WinEvent -ListLog $logName -ErrorAction Stop }
            catch {
                [pscustomobject][ordered]@{
                    log_name = $logName
                    status = 'unavailable'
                    enabled = $null
                    record_count = $null
                    sampled_event_count = $null
                    oldest_sample_utc = $null
                    newest_sample_utc = $null
                    shapes = @()
                    reason = 'list_log_failed'
                }
                continue
            }
            $enabled = [bool](Get-NxbPlatformEventProperty -InputObject $logInfo -Name 'IsEnabled' -DefaultValue $false)
            $recordCountRaw = Get-NxbPlatformEventProperty -InputObject $logInfo -Name 'RecordCount'
            $recordCount = if ($null -eq $recordCountRaw) { $null } else { [int64]$recordCountRaw }
            if (-not $enabled) {
                [pscustomobject][ordered]@{
                    log_name = $logName
                    status = 'disabled'
                    enabled = $false
                    record_count = $recordCount
                    sampled_event_count = 0
                    oldest_sample_utc = $null
                    newest_sample_utc = $null
                    shapes = @()
                    reason = 'log_disabled'
                }
                continue
            }
            try {
                $events = @(
                    Get-WinEvent -FilterHashtable @{
                        LogName = $logName
                        ProviderName = $providerName
                        StartTime = $startTime
                    } -MaxEvents $MaxEventsPerLog -ErrorAction Stop
                )
                $shapeGroups = @(
                    $events |
                        Group-Object { Get-NxbPlatformEventShapeKey -EventRecord $_ } |
                        ForEach-Object {
                            $parts = $_.Name.Split('|',5)
                            [pscustomobject][ordered]@{
                                id = [int]$parts[0]
                                version = [int]$parts[1]
                                level = $parts[2]
                                task = $parts[3]
                                opcode = $parts[4]
                                count = [int]$_.Count
                            }
                        } |
                        Sort-Object id,version,level,task,opcode
                )
                $times = @($events | ForEach-Object { Get-NxbPlatformEventProperty -InputObject $_ -Name 'TimeCreated' } | Where-Object { $null -ne $_ })
                $oldest = if ($times.Count -eq 0) { $null } else { ([DateTime]($times | Sort-Object | Select-Object -First 1)).ToUniversalTime().ToString('o') }
                $newest = if ($times.Count -eq 0) { $null } else { ([DateTime]($times | Sort-Object -Descending | Select-Object -First 1)).ToUniversalTime().ToString('o') }
                [pscustomobject][ordered]@{
                    log_name = $logName
                    status = 'available'
                    enabled = $true
                    record_count = $recordCount
                    sampled_event_count = [int]$events.Count
                    oldest_sample_utc = $oldest
                    newest_sample_utc = $newest
                    shapes = $shapeGroups
                    reason = $null
                }
            }
            catch {
                [pscustomobject][ordered]@{
                    log_name = $logName
                    status = 'unavailable'
                    enabled = $true
                    record_count = $recordCount
                    sampled_event_count = $null
                    oldest_sample_utc = $null
                    newest_sample_utc = $null
                    shapes = @()
                    reason = 'bounded_query_failed'
                }
            }
        }
        [pscustomobject][ordered]@{
            provider_name = $providerName
            status = 'available'
            provider_guid = $providerGuid
            event_definition_count = [int]$definitions.Count
            event_definitions = $definitions
            attached_log_count = [int]$logNames.Count
            logs = @($logRecords | Sort-Object log_name)
            reason = $null
        }
    }
    catch {
        [pscustomobject][ordered]@{
            provider_name = $providerName
            status = 'unavailable'
            provider_guid = $null
            event_definition_count = $null
            event_definitions = @()
            attached_log_count = $null
            logs = @()
            reason = 'provider_metadata_failed'
        }
    }
}
$providers = @($providerRecords | Sort-Object provider_name)
$metadataMaterial = [pscustomobject][ordered]@{
    binding_fingerprint_sha256 = $BindingFingerprintSha256.ToLowerInvariant()
    providers = @($providers | ForEach-Object {
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
$canonicalMetadata = ConvertTo-NxbPlatformEventCanonicalNode -Value $metadataMaterial
$metadataJson = $canonicalMetadata | ConvertTo-Json -Depth 40 -Compress
$metadataFingerprint = Get-NxbPlatformEventSha256Text -Text $metadataJson
$result = [pscustomobject][ordered]@{
    schema_version = 1
    captured_utc = [DateTime]::UtcNow.ToString('o')
    lookback_days = $LookbackDays
    max_events_per_log = $MaxEventsPerLog
    binding_fingerprint_sha256 = $BindingFingerprintSha256.ToLowerInvariant()
    provider_metadata_fingerprint_sha256 = $metadataFingerprint
    providers = $providers
    claims = [pscustomobject][ordered]@{
        raw_event_message_exposed = $false
        raw_event_xml_exposed = $false
        raw_event_payload_exposed = $false
        provider_metadata_inventory = $true
        bounded_recent_event_shape_inventory = $true
        event_id_semantics = $false
        event_task_opcode_semantics = $false
        device_lifecycle_semantics = $false
        power_causality = $false
        firmware_causality = $false
        continuous_trace_completeness = 'not_claimed'
    }
}
Write-NxbPlatformEventJson -Path $OutputPath -InputObject $result
Write-Information -MessageData "NXB platform event baseline written: $([IO.Path]::GetFullPath($OutputPath))" -InformationAction Continue
if ($PassThru) { return $result }
Write-Output ([IO.Path]::GetFullPath($OutputPath))
