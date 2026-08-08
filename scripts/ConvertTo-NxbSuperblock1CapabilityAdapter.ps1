[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$CapabilityPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NxbCapabilityProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-NxbCapabilityListCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Domain,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    if ([string]$Domain.status -cnotin @('available','partial')) { return $null }
    if ($null -eq $Domain.data) { return $null }
    $value = Get-NxbCapabilityProperty -Object $Domain.data -Name $Name
    if ($null -eq $value) { return $null }
    return @($value).Count
}

function Get-NxbCapabilityObjectPresence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Domain,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    if ([string]$Domain.status -cnotin @('available','partial')) { return $null }
    if ($null -eq $Domain.data) { return $null }
    return ($null -ne (Get-NxbCapabilityProperty -Object $Domain.data -Name $Name))
}

$capabilityFull = [IO.Path]::GetFullPath($CapabilityPath)
$outputFull = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $outputFull) {
    throw "OutputPath already exists: $outputFull"
}
$outputDirectory = Split-Path -Parent $outputFull
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
}

$capability = Get-Content -LiteralPath $capabilityFull -Raw | ConvertFrom-Json
if ([int]$capability.schema_version -ne 1) {
    throw "Unsupported capability schema version: $($capability.schema_version)"
}
if ([string]::IsNullOrWhiteSpace([string]$capability.machine_id)) {
    throw 'Capability snapshot machine_id is required.'
}

$requiredDomains = @('network','bus_and_devices','firmware','security','power')
$domainMap = [ordered]@{}
foreach ($domainName in $requiredDomains) {
    $domainProperty = $capability.domains.PSObject.Properties[$domainName]
    if ($null -eq $domainProperty) {
        throw "Capability snapshot missing required domain: $domainName"
    }
    $domain = $domainProperty.Value
    if ([string]$domain.status -cnotin @('available','partial','unavailable')) {
        throw "Capability domain has unsupported status: $domainName=$($domain.status)"
    }
    $domainMap[$domainName] = $domain
}

$network = $domainMap.network
$devices = $domainMap.bus_and_devices
$firmware = $domainMap.firmware
$security = $domainMap.security
$power = $domainMap.power

$signedDriverCount = Get-NxbCapabilityListCount -Domain $devices -Name 'signed_drivers'
$signedTrueCount = $null
$signedFalseCount = $null
$signedUnknownCount = $null
if ($null -ne $signedDriverCount) {
    $signedDrivers = @(Get-NxbCapabilityProperty -Object $devices.data -Name 'signed_drivers')
    $signedTrueCount = @($signedDrivers | Where-Object { $_.is_signed -eq $true }).Count
    $signedFalseCount = @($signedDrivers | Where-Object { $_.is_signed -eq $false }).Count
    $signedUnknownCount = @($signedDrivers | Where-Object { $null -eq $_.is_signed }).Count
}

$secureBootValue = $null
$tpmRecordPresent = $null
$deviceGuardPresent = $null
if ([string]$security.status -cin @('available','partial') -and $null -ne $security.data) {
    $secureBootValue = Get-NxbCapabilityProperty -Object $security.data -Name 'secure_boot'
    $tpmRecordPresent = $null -ne (Get-NxbCapabilityProperty -Object $security.data -Name 'tpm')
    $deviceGuardPresent = $null -ne (Get-NxbCapabilityProperty -Object $security.data -Name 'device_guard')
}

$activePowerSchemePresent = $null
if ([string]$power.status -cin @('available','partial') -and $null -ne $power.data) {
    $activeScheme = Get-NxbCapabilityProperty -Object $power.data -Name 'active_power_scheme'
    $activePowerSchemePresent = -not [string]::IsNullOrWhiteSpace([string]$activeScheme)
}

$result = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    adapter = 'nxb-superblock1-capability-v1'
    source = [ordered]@{
        capability_sha256 = (Get-FileHash -LiteralPath $capabilityFull -Algorithm SHA256).Hash.ToLowerInvariant()
        captured_utc = [string]$capability.captured_utc
        machine_id = [string]$capability.machine_id
    }
    domains = [ordered]@{
        network = [ordered]@{
            status = [string]$network.status
            adapter_count = Get-NxbCapabilityListCount -Domain $network -Name 'adapters'
            configuration_count = Get-NxbCapabilityListCount -Domain $network -Name 'configurations'
        }
        device_driver = [ordered]@{
            status = [string]$devices.status
            device_class_row_count = Get-NxbCapabilityListCount -Domain $devices -Name 'device_class_counts'
            signed_driver_count = $signedDriverCount
            signed_true_count = $signedTrueCount
            signed_false_count = $signedFalseCount
            signed_unknown_count = $signedUnknownCount
        }
        firmware = [ordered]@{
            status = [string]$firmware.status
            bios_record_present = Get-NxbCapabilityObjectPresence -Domain $firmware -Name 'bios'
            baseboard_record_present = Get-NxbCapabilityObjectPresence -Domain $firmware -Name 'baseboard'
        }
        security = [ordered]@{
            status = [string]$security.status
            secure_boot = $secureBootValue
            tpm_record_present = $tpmRecordPresent
            device_guard_record_present = $deviceGuardPresent
        }
        power = [ordered]@{
            status = [string]$power.status
            active_power_scheme_present = $activePowerSchemePresent
            battery_count = Get-NxbCapabilityListCount -Domain $power -Name 'batteries'
        }
    }
    evidence_policy = [ordered]@{
        missing_is_zero = $false
        unavailable_counts_are_null = $true
        raw_mac_addresses_emitted = $false
        raw_serial_numbers_emitted = $false
        raw_power_scheme_text_emitted = $false
    }
    claims = [ordered]@{
        network_connection_semantics = $false
        network_latency_semantics = $false
        device_lifecycle_semantics = $false
        power_thermal_representative = $false
        firmware_security_effect_semantics = $false
        trace_completeness = 'not_claimed'
    }
}

[IO.File]::WriteAllText(
    $outputFull,
    (($result | ConvertTo-Json -Depth 16) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Information -MessageData "SUPERBLOCK capability adapter written: $outputFull" -InformationAction Continue
Write-Information -MessageData 'Missing/unavailable observations are not synthesized as zero.' -InformationAction Continue
Write-Information -MessageData 'Device/power/firmware semantic claims enabled: False' -InformationAction Continue

if ($PassThru) { return $result }
