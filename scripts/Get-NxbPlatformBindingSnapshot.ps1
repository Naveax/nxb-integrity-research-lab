[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$collectionErrors = [System.Collections.Generic.List[object]]::new()

function Get-NxbPlatformProperty {
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

function Get-NxbPlatformSha256Text {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha256.Dispose() }
}

function Write-NxbPlatformJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory)][object]$InputObject
    )
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        [IO.Path]::GetFullPath($Path),
        (($InputObject | ConvertTo-Json -Depth 40) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

function Add-NxbPlatformCollectionError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Domain,
        [Parameter(Mandatory)][object]$Exception
    )
    $collectionErrors.Add([pscustomobject][ordered]@{
        domain = $Domain
        error_type = $Exception.GetType().FullName
    })
}

function Get-NxbPlatformUnavailableBlock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Reason)
    return [pscustomobject][ordered]@{ status='unavailable'; data=$null; reason=$Reason }
}

function Invoke-NxbPlatformQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Domain,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    try {
        $data = & $Action
        return [pscustomobject][ordered]@{ status='available'; data=$data; reason=$null }
    }
    catch {
        Add-NxbPlatformCollectionError -Domain $Domain -Exception $_.Exception
        return [pscustomobject][ordered]@{ status='unavailable'; data=$null; reason='query_failed' }
    }
}

function ConvertTo-NxbPlatformCanonicalNode {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [char] -or $Value -is [bool] -or
        $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or $Value -is [single] -or
        $Value -is [double] -or $Value -is [decimal]) { return $Value }

    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)) {
            $result[$key] = ConvertTo-NxbPlatformCanonicalNode -Value $Value[$key]
        }
        return $result
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        return @($Value | ForEach-Object { ConvertTo-NxbPlatformCanonicalNode -Value $_ })
    }

    $objectResult = [ordered]@{}
    foreach ($name in @($Value.PSObject.Properties.Name | Sort-Object -CaseSensitive)) {
        $objectResult[$name] = ConvertTo-NxbPlatformCanonicalNode -Value $Value.PSObject.Properties[$name].Value
    }
    return $objectResult
}

function Get-NxbPlatformEventSources {
    [CmdletBinding()]
    param()
    $providerNames = @(
        'Microsoft-Windows-Kernel-PnP',
        'Microsoft-Windows-UserPnp',
        'Microsoft-Windows-WHEA-Logger',
        'Microsoft-Windows-Kernel-Power',
        'Microsoft-Windows-Kernel-Processor-Power',
        'Microsoft-Windows-Kernel-Boot',
        'Microsoft-Windows-CodeIntegrity',
        'Microsoft-Windows-DeviceGuard'
    )
    $records = foreach ($providerName in $providerNames) {
        try {
            $providerInfo = Get-WinEvent -ListProvider $providerName -ErrorAction Stop
            $providerGuid = Get-NxbPlatformProperty -InputObject $providerInfo -Name 'Id'
            $logs = @(
                @(Get-NxbPlatformProperty -InputObject $providerInfo -Name 'LogLinks' -DefaultValue @()) |
                    ForEach-Object { [string](Get-NxbPlatformProperty -InputObject $_ -Name 'LogName' -DefaultValue '') } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Sort-Object -Unique
            )
            [pscustomobject][ordered]@{
                provider_name = $providerName
                status = 'available'
                provider_guid = if ($null -eq $providerGuid) { $null } else { [string]$providerGuid }
                logs = $logs
            }
        }
        catch {
            [pscustomobject][ordered]@{
                provider_name = $providerName
                status = 'unavailable'
                provider_guid = $null
                logs = @()
            }
        }
    }
    return @($records | Sort-Object provider_name)
}

function Get-NxbPlatformBcdValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Key
    )
    $pattern = '(?im)^\s*' + [regex]::Escape($Key) + '\s+(.+?)\s*$'
    $valueMatch = [regex]::Match($Text,$pattern)
    if (-not $valueMatch.Success) { return $null }
    return $valueMatch.Groups[1].Value.Trim()
}

$os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop | Select-Object -First 1
$product = $null
try { $product = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop | Select-Object -First 1 }
catch { Add-NxbPlatformCollectionError -Domain 'identity.computer_system_product' -Exception $_.Exception }

$rawMachineId = $null
$machineIdSource = $null
if ($null -ne $product) {
    $candidateUuid = [string](Get-NxbPlatformProperty -InputObject $product -Name 'UUID' -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($candidateUuid) -and $candidateUuid -notmatch '^(?i)(0{8}-0{4}-0{4}-0{4}-0{12}|f{8}-f{4}-f{4}-f{4}-f{12})$') {
        $rawMachineId = $candidateUuid.Trim().ToLowerInvariant()
        $machineIdSource = 'computer_system_product_uuid'
    }
}
if ([string]::IsNullOrWhiteSpace($rawMachineId)) {
    $rawMachineId = [string]$env:COMPUTERNAME
    $machineIdSource = 'computer_name_fallback'
}

$identity = [pscustomobject][ordered]@{
    machine_id_sha256 = Get-NxbPlatformSha256Text -Text $rawMachineId
    machine_id_source = $machineIdSource
    boot_utc = ([DateTime]$os.LastBootUpTime).ToUniversalTime().ToString('o')
    os_version = [string]$os.Version
    os_build = [string]$os.BuildNumber
    os_architecture = if ($null -eq $os.OSArchitecture) { $null } else { [string]$os.OSArchitecture }
}

$pnpPropertyCommand = Get-Command Get-PnpDeviceProperty -ErrorAction SilentlyContinue
$pciStats = [ordered]@{ attempted=0; succeeded=0; failed=0 }
$pnpEntities = Invoke-NxbPlatformQuery -Domain 'devices.pnp_entities' -Action {
    $rawEntities = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop)
    $records = foreach ($entity in $rawEntities) {
        $rawDeviceId = [string](Get-NxbPlatformProperty -InputObject $entity -Name 'PNPDeviceID' -DefaultValue '')
        $isPci = $rawDeviceId.StartsWith('PCI\',[StringComparison]::OrdinalIgnoreCase)
        $busNumber = $null
        $busAddress = $null
        $locationInfo = $null
        $locationPathHashes = @()
        if ($isPci -and $null -ne $pnpPropertyCommand -and -not [string]::IsNullOrWhiteSpace($rawDeviceId)) {
            $pciStats.attempted++
            try {
                $propertyRows = @(Get-PnpDeviceProperty -InstanceId $rawDeviceId -KeyName @(
                    'DEVPKEY_Device_BusNumber',
                    'DEVPKEY_Device_Address',
                    'DEVPKEY_Device_LocationInfo',
                    'DEVPKEY_Device_LocationPaths'
                ) -ErrorAction Stop)
                foreach ($propertyRow in $propertyRows) {
                    $keyName = [string](Get-NxbPlatformProperty -InputObject $propertyRow -Name 'KeyName' -DefaultValue '')
                    $dataValue = Get-NxbPlatformProperty -InputObject $propertyRow -Name 'Data'
                    switch ($keyName) {
                        'DEVPKEY_Device_BusNumber' { if ($null -ne $dataValue) { $busNumber = [int64]$dataValue } }
                        'DEVPKEY_Device_Address' { if ($null -ne $dataValue) { $busAddress = [int64]$dataValue } }
                        'DEVPKEY_Device_LocationInfo' { if ($null -ne $dataValue) { $locationInfo = [string]$dataValue } }
                        'DEVPKEY_Device_LocationPaths' {
                            $locationPathHashes = @(@($dataValue) | ForEach-Object { Get-NxbPlatformSha256Text -Text ([string]$_) } | Sort-Object)
                        }
                    }
                }
                $pciStats.succeeded++
            }
            catch { $pciStats.failed++ }
        }
        [pscustomobject][ordered]@{
            device_id_sha256 = Get-NxbPlatformSha256Text -Text $rawDeviceId
            name = [string](Get-NxbPlatformProperty -InputObject $entity -Name 'Name' -DefaultValue '')
            pnp_class = [string](Get-NxbPlatformProperty -InputObject $entity -Name 'PNPClass' -DefaultValue '')
            manufacturer = [string](Get-NxbPlatformProperty -InputObject $entity -Name 'Manufacturer' -DefaultValue '')
            service = [string](Get-NxbPlatformProperty -InputObject $entity -Name 'Service' -DefaultValue '')
            status = [string](Get-NxbPlatformProperty -InputObject $entity -Name 'Status' -DefaultValue '')
            config_manager_error_code = [int](Get-NxbPlatformProperty -InputObject $entity -Name 'ConfigManagerErrorCode' -DefaultValue 0)
            is_pci = $isPci
            bus_number = $busNumber
            bus_address = $busAddress
            location_info = $locationInfo
            location_path_sha256 = $locationPathHashes
        }
    }
    $orderedRecords = @($records | Sort-Object device_id_sha256)
    [pscustomobject][ordered]@{
        total_count = $orderedRecords.Count
        pci_count = @($orderedRecords | Where-Object { $_.is_pci }).Count
        problem_count = @($orderedRecords | Where-Object { $_.config_manager_error_code -ne 0 }).Count
        records = $orderedRecords
    }
}

$pciEnrichment = if ($null -eq $pnpPropertyCommand) {
    Get-NxbPlatformUnavailableBlock -Reason 'Get-PnpDeviceProperty_unavailable'
}
elseif ([string]$pnpEntities.status -cne 'available') {
    [pscustomobject][ordered]@{ status='failed'; data=$null; reason='pnp_inventory_unavailable' }
}
else {
    $enrichmentStatus = if ([int]$pciStats.failed -gt 0) { 'partial' } else { 'available' }
    [pscustomobject][ordered]@{
        status = $enrichmentStatus
        data = [pscustomobject][ordered]@{
            attempted = [int]$pciStats.attempted
            succeeded = [int]$pciStats.succeeded
            failed = [int]$pciStats.failed
        }
        reason = if ($enrichmentStatus -ceq 'partial') { 'one_or_more_property_queries_failed' } else { $null }
    }
}

$signedDrivers = Invoke-NxbPlatformQuery -Domain 'devices.signed_drivers' -Action {
    $rawRows = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop)
    $records = @($rawRows | ForEach-Object {
        $rawDeviceId = [string](Get-NxbPlatformProperty -InputObject $_ -Name 'DeviceID' -DefaultValue '')
        [pscustomobject][ordered]@{
            device_id_sha256 = Get-NxbPlatformSha256Text -Text $rawDeviceId
            device_name = [string](Get-NxbPlatformProperty -InputObject $_ -Name 'DeviceName' -DefaultValue '')
            device_class = [string](Get-NxbPlatformProperty -InputObject $_ -Name 'DeviceClass' -DefaultValue '')
            driver_version = [string](Get-NxbPlatformProperty -InputObject $_ -Name 'DriverVersion' -DefaultValue '')
            driver_provider = [string](Get-NxbPlatformProperty -InputObject $_ -Name 'DriverProviderName' -DefaultValue '')
            manufacturer = [string](Get-NxbPlatformProperty -InputObject $_ -Name 'Manufacturer' -DefaultValue '')
            inf_name = [string](Get-NxbPlatformProperty -InputObject $_ -Name 'InfName' -DefaultValue '')
            is_signed = if ($null -eq (Get-NxbPlatformProperty -InputObject $_ -Name 'IsSigned')) { $null } else { [bool](Get-NxbPlatformProperty -InputObject $_ -Name 'IsSigned') }
        }
    } | Sort-Object device_id_sha256,driver_version)
    $emitted = @($records | Select-Object -First 1024)
    [pscustomobject][ordered]@{
        total_count = $records.Count
        emitted_count = $emitted.Count
        truncated = ($records.Count -gt $emitted.Count)
        signed_count = @($records | Where-Object { $_.is_signed -eq $true }).Count
        unsigned_count = @($records | Where-Object { $_.is_signed -eq $false }).Count
        records = $emitted
    }
}

$systemDrivers = Invoke-NxbPlatformQuery -Domain 'devices.system_drivers' -Action {
    $records = @(Get-CimInstance Win32_SystemDriver -ErrorAction Stop | ForEach-Object {
        [pscustomobject][ordered]@{
            name = [string](Get-NxbPlatformProperty -InputObject $_ -Name 'Name' -DefaultValue '')
            display_name = [string](Get-NxbPlatformProperty -InputObject $_ -Name 'DisplayName' -DefaultValue '')
            start_mode = [string](Get-NxbPlatformProperty -InputObject $_ -Name 'StartMode' -DefaultValue '')
            service_type = [string](Get-NxbPlatformProperty -InputObject $_ -Name 'ServiceType' -DefaultValue '')
        }
    } | Sort-Object name)
    $emitted = @($records | Select-Object -First 1024)
    [pscustomobject][ordered]@{
        total_count = $records.Count
        emitted_count = $emitted.Count
        truncated = ($records.Count -gt $emitted.Count)
        records = $emitted
    }
}

$powerPolicyScript = Join-Path $PSScriptRoot 'Get-NxbActivePowerPolicy.ps1'
$activePowerScheme = Invoke-NxbPlatformQuery -Domain 'power.active_power_scheme' -Action {
    $policy = & $powerPolicyScript -PassThru
    [pscustomobject][ordered]@{
        scheme_guid = [string](Get-NxbPlatformProperty -InputObject $policy -Name 'scheme_guid' -DefaultValue '')
        name = if ($null -eq (Get-NxbPlatformProperty -InputObject $policy -Name 'name')) { $null } else { [string](Get-NxbPlatformProperty -InputObject $policy -Name 'name') }
    }
}

$processorClock = Invoke-NxbPlatformQuery -Domain 'volatile.processor_clock' -Action {
    @(Get-CimInstance Win32_Processor -ErrorAction Stop | ForEach-Object {
        [pscustomobject][ordered]@{
            device_id = [string](Get-NxbPlatformProperty -InputObject $_ -Name 'DeviceID' -DefaultValue '')
            name = [string](Get-NxbPlatformProperty -InputObject $_ -Name 'Name' -DefaultValue '')
            current_clock_mhz = [int64](Get-NxbPlatformProperty -InputObject $_ -Name 'CurrentClockSpeed' -DefaultValue 0)
            max_clock_mhz = [int64](Get-NxbPlatformProperty -InputObject $_ -Name 'MaxClockSpeed' -DefaultValue 0)
        }
    } | Sort-Object device_id)
}

$battery = Invoke-NxbPlatformQuery -Domain 'volatile.battery' -Action {
    $rows = @(Get-CimInstance Win32_Battery -ErrorAction Stop | ForEach-Object {
        [pscustomobject][ordered]@{
            name = [string](Get-NxbPlatformProperty -InputObject $_ -Name 'Name' -DefaultValue '')
            status = [string](Get-NxbPlatformProperty -InputObject $_ -Name 'Status' -DefaultValue '')
            estimated_charge_remaining = Get-NxbPlatformProperty -InputObject $_ -Name 'EstimatedChargeRemaining'
            battery_status = Get-NxbPlatformProperty -InputObject $_ -Name 'BatteryStatus'
        }
    })
    [pscustomobject][ordered]@{ count=$rows.Count; batteries=@($rows) }
}

$thermalZones = Invoke-NxbPlatformQuery -Domain 'volatile.thermal_zones' -Action {
    $rows = @(Get-CimInstance -Namespace 'root\wmi' -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop | ForEach-Object {
        $instanceName = [string](Get-NxbPlatformProperty -InputObject $_ -Name 'InstanceName' -DefaultValue '')
        $rawTemperature = Get-NxbPlatformProperty -InputObject $_ -Name 'CurrentTemperature'
        $rawValue = if ($null -eq $rawTemperature) { $null } else { [double]$rawTemperature }
        [pscustomobject][ordered]@{
            zone_id_sha256 = Get-NxbPlatformSha256Text -Text $instanceName
            current_temperature_tenths_kelvin = $rawValue
            current_temperature_celsius = if ($null -eq $rawValue) { $null } else { [Math]::Round(($rawValue / 10.0) - 273.15,2) }
            source = 'MSAcpi_ThermalZoneTemperature'
        }
    } | Sort-Object zone_id_sha256)
    [pscustomobject][ordered]@{
        exposed_zone_count = $rows.Count
        representative_temperature_claimed = $false
        zones = $rows
    }
}

$bios = Invoke-NxbPlatformQuery -Domain 'firmware_security.bios' -Action {
    $biosRow = Get-CimInstance Win32_BIOS -ErrorAction Stop | Select-Object -First 1
    $boardRow = Get-CimInstance Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1
    [pscustomobject][ordered]@{
        bios = [pscustomobject][ordered]@{
            manufacturer = [string](Get-NxbPlatformProperty -InputObject $biosRow -Name 'Manufacturer' -DefaultValue '')
            name = [string](Get-NxbPlatformProperty -InputObject $biosRow -Name 'Name' -DefaultValue '')
            smbios_version = [string](Get-NxbPlatformProperty -InputObject $biosRow -Name 'SMBIOSBIOSVersion' -DefaultValue '')
            release_date = if ($null -eq (Get-NxbPlatformProperty -InputObject $biosRow -Name 'ReleaseDate')) { $null } else { ([DateTime](Get-NxbPlatformProperty -InputObject $biosRow -Name 'ReleaseDate')).ToUniversalTime().ToString('o') }
        }
        baseboard = [pscustomobject][ordered]@{
            manufacturer = [string](Get-NxbPlatformProperty -InputObject $boardRow -Name 'Manufacturer' -DefaultValue '')
            product = [string](Get-NxbPlatformProperty -InputObject $boardRow -Name 'Product' -DefaultValue '')
            version = [string](Get-NxbPlatformProperty -InputObject $boardRow -Name 'Version' -DefaultValue '')
        }
    }
}

$secureBoot = $null
try {
    $secureBootRegistry = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -Name UEFISecureBootEnabled -ErrorAction Stop
    $secureBoot = [pscustomobject][ordered]@{
        status='available'
        data=[pscustomobject][ordered]@{ enabled=([int]$secureBootRegistry.UEFISecureBootEnabled -eq 1); source='registry_state' }
        reason=$null
    }
}
catch {
    $secureBootCommand = Get-Command Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
    if ($null -eq $secureBootCommand) {
        $secureBoot = Get-NxbPlatformUnavailableBlock -Reason 'secure_boot_interface_unavailable'
    }
    else {
        try {
            $secureBoot = [pscustomobject][ordered]@{
                status='available'
                data=[pscustomobject][ordered]@{ enabled=[bool](Confirm-SecureBootUEFI -ErrorAction Stop); source='Confirm-SecureBootUEFI' }
                reason=$null
            }
        }
        catch {
            Add-NxbPlatformCollectionError -Domain 'firmware_security.secure_boot' -Exception $_.Exception
            $secureBoot = Get-NxbPlatformUnavailableBlock -Reason 'secure_boot_query_failed'
        }
    }
}

$tpm = $null
try {
    $tpmRow = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $tpmRow) {
        $tpm = Get-NxbPlatformUnavailableBlock -Reason 'no_tpm_instance'
    }
    else {
        $tpm = [pscustomobject][ordered]@{
            status='available'
            data=[pscustomobject][ordered]@{
                enabled_initial = Get-NxbPlatformProperty -InputObject $tpmRow -Name 'IsEnabled_InitialValue'
                activated_initial = Get-NxbPlatformProperty -InputObject $tpmRow -Name 'IsActivated_InitialValue'
                owned_initial = Get-NxbPlatformProperty -InputObject $tpmRow -Name 'IsOwned_InitialValue'
                manufacturer_id = [string](Get-NxbPlatformProperty -InputObject $tpmRow -Name 'ManufacturerIdTxt' -DefaultValue '')
                spec_version = [string](Get-NxbPlatformProperty -InputObject $tpmRow -Name 'SpecVersion' -DefaultValue '')
            }
            reason=$null
        }
    }
}
catch {
    Add-NxbPlatformCollectionError -Domain 'firmware_security.tpm' -Exception $_.Exception
    $tpm = Get-NxbPlatformUnavailableBlock -Reason 'tpm_query_failed'
}

$deviceGuard = $null
try {
    $deviceGuardRow = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $deviceGuardRow) {
        $deviceGuard = Get-NxbPlatformUnavailableBlock -Reason 'no_device_guard_instance'
    }
    else {
        $deviceGuard = [pscustomobject][ordered]@{
            status='available'
            data=[pscustomobject][ordered]@{
                virtualization_based_security_status = Get-NxbPlatformProperty -InputObject $deviceGuardRow -Name 'VirtualizationBasedSecurityStatus'
                security_services_configured = @(@(Get-NxbPlatformProperty -InputObject $deviceGuardRow -Name 'SecurityServicesConfigured' -DefaultValue @()) | ForEach-Object { [int]$_ } | Sort-Object)
                security_services_running = @(@(Get-NxbPlatformProperty -InputObject $deviceGuardRow -Name 'SecurityServicesRunning' -DefaultValue @()) | ForEach-Object { [int]$_ } | Sort-Object)
                required_security_properties = @(@(Get-NxbPlatformProperty -InputObject $deviceGuardRow -Name 'RequiredSecurityProperties' -DefaultValue @()) | ForEach-Object { [int]$_ } | Sort-Object)
                available_security_properties = @(@(Get-NxbPlatformProperty -InputObject $deviceGuardRow -Name 'AvailableSecurityProperties' -DefaultValue @()) | ForEach-Object { [int]$_ } | Sort-Object)
                code_integrity_policy_enforcement_status = Get-NxbPlatformProperty -InputObject $deviceGuardRow -Name 'CodeIntegrityPolicyEnforcementStatus'
                usermode_code_integrity_policy_enforcement_status = Get-NxbPlatformProperty -InputObject $deviceGuardRow -Name 'UsermodeCodeIntegrityPolicyEnforcementStatus'
            }
            reason=$null
        }
    }
}
catch {
    Add-NxbPlatformCollectionError -Domain 'firmware_security.device_guard' -Exception $_.Exception
    $deviceGuard = Get-NxbPlatformUnavailableBlock -Reason 'device_guard_query_failed'
}

$virtualization = Invoke-NxbPlatformQuery -Domain 'firmware_security.virtualization' -Action {
    $computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop | Select-Object -First 1
    $processors = @(Get-CimInstance Win32_Processor -ErrorAction Stop | ForEach-Object {
        [pscustomobject][ordered]@{
            device_id = [string](Get-NxbPlatformProperty -InputObject $_ -Name 'DeviceID' -DefaultValue '')
            virtualization_firmware_enabled = Get-NxbPlatformProperty -InputObject $_ -Name 'VirtualizationFirmwareEnabled'
            second_level_address_translation = Get-NxbPlatformProperty -InputObject $_ -Name 'SecondLevelAddressTranslationExtensions'
            vm_monitor_mode_extensions = Get-NxbPlatformProperty -InputObject $_ -Name 'VMMonitorModeExtensions'
        }
    } | Sort-Object device_id)
    [pscustomobject][ordered]@{
        hypervisor_present = [bool](Get-NxbPlatformProperty -InputObject $computerSystem -Name 'HypervisorPresent' -DefaultValue $false)
        processors = $processors
    }
}

$bootConfiguration = $null
$bcdEditCommand = Get-Command bcdedit.exe -ErrorAction SilentlyContinue
if ($null -eq $bcdEditCommand) {
    $bootConfiguration = Get-NxbPlatformUnavailableBlock -Reason 'bcdedit_unavailable'
}
else {
    try {
        $bcdOutput = @(& $bcdEditCommand.Source /enum '{current}' 2>&1)
        $bcdExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        if ($bcdExit -ne 0) { throw [InvalidOperationException]::new("bcdedit_exit_$bcdExit") }
        $bcdText = $bcdOutput -join [Environment]::NewLine
        $bootConfiguration = [pscustomobject][ordered]@{
            status='available'
            data=[pscustomobject][ordered]@{
                output_sha256 = Get-NxbPlatformSha256Text -Text $bcdText
                debug = Get-NxbPlatformBcdValue -Text $bcdText -Key 'debug'
                testsigning = Get-NxbPlatformBcdValue -Text $bcdText -Key 'testsigning'
                nointegritychecks = Get-NxbPlatformBcdValue -Text $bcdText -Key 'nointegritychecks'
                hypervisorlaunchtype = Get-NxbPlatformBcdValue -Text $bcdText -Key 'hypervisorlaunchtype'
            }
            reason=$null
        }
    }
    catch {
        Add-NxbPlatformCollectionError -Domain 'firmware_security.boot_configuration' -Exception $_.Exception
        $bootConfiguration = [pscustomobject][ordered]@{ status='failed'; data=$null; reason='bcdedit_query_failed' }
    }
}

$bindings = [pscustomobject][ordered]@{
    devices = [pscustomobject][ordered]@{
        pnp_entities = $pnpEntities
        signed_drivers = $signedDrivers
        system_drivers = $systemDrivers
        pci_property_enrichment = $pciEnrichment
    }
    power = [pscustomobject][ordered]@{
        active_power_scheme = $activePowerScheme
    }
    firmware_security = [pscustomobject][ordered]@{
        bios = $bios
        secure_boot = $secureBoot
        tpm = $tpm
        device_guard = $deviceGuard
        virtualization = $virtualization
        boot_configuration = $bootConfiguration
    }
}

$volatileState = [pscustomobject][ordered]@{
    processor_clock = $processorClock
    battery = $battery
    thermal_zones = $thermalZones
}

$eventSources = Get-NxbPlatformEventSources
$fingerprintMaterial = [pscustomobject][ordered]@{
    identity = $identity
    bindings = $bindings
    event_sources = $eventSources
}
$canonicalFingerprintMaterial = ConvertTo-NxbPlatformCanonicalNode -Value $fingerprintMaterial
$fingerprintJson = $canonicalFingerprintMaterial | ConvertTo-Json -Depth 40 -Compress
$bindingFingerprint = Get-NxbPlatformSha256Text -Text $fingerprintJson

$snapshot = [pscustomobject][ordered]@{
    schema_version = 1
    captured_utc = [DateTime]::UtcNow.ToString('o')
    identity = $identity
    bindings = $bindings
    volatile_state = $volatileState
    event_sources = $eventSources
    binding_fingerprint_sha256 = $bindingFingerprint
    claims = [pscustomobject][ordered]@{
        raw_machine_identifier_exposed = $false
        raw_pnp_identifier_exposed = $false
        serial_number_exposed = $false
        volatile_state_in_binding_fingerprint = $false
        pcie_bdf_semantics = $false
        device_lifecycle_semantics = $false
        thermal_representativeness = $false
        power_causality = $false
        firmware_causality = $false
        root_cause_validated = $false
    }
    collection_errors = @($collectionErrors)
}

Write-NxbPlatformJson -Path $OutputPath -InputObject $snapshot
Write-Information -MessageData "NXB platform binding snapshot written: $([IO.Path]::GetFullPath($OutputPath))" -InformationAction Continue
if ($PassThru) { return $snapshot }
Write-Output ([IO.Path]::GetFullPath($OutputPath))
