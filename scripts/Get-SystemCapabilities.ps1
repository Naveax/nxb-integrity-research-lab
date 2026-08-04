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

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $experimentFull 'baseline\system-capabilities.json'
}

$collectionErrors = [System.Collections.Generic.List[object]]::new()

function Invoke-NxbCapabilityQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Domain,

        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    try {
        $data = & $Action
        return [ordered]@{
            status = 'available'
            data   = $data
        }
    }
    catch {
        $collectionErrors.Add([pscustomobject]@{
            domain  = $Domain
            message = $_.Exception.Message
        })

        return [ordered]@{
            status = 'unavailable'
            data   = $null
        }
    }
}

function Get-NxbCommandCapability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return [pscustomobject]@{
            name      = $Name
            available = $false
            path      = $null
            version   = $null
        }
    }

    $version = $null
    if ($command.PSObject.Properties.Name -contains 'Version' -and $null -ne $command.Version) {
        $version = $command.Version.ToString()
    }

    return [pscustomobject]@{
        name      = $Name
        available = $true
        path      = $command.Source
        version   = $version
    }
}

$systemProduct = $null
try {
    $systemProduct = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop |
        Select-Object -First 1
}
catch {
    $collectionErrors.Add([pscustomobject]@{
        domain  = 'machine_identity'
        message = $_.Exception.Message
    })
}

$machineId = if ($null -ne $systemProduct -and -not [string]::IsNullOrWhiteSpace([string]$systemProduct.UUID)) {
    [string]$systemProduct.UUID
}
else {
    [string]$env:COMPUTERNAME
}

$domains = [ordered]@{}

$domains.operating_system = Invoke-NxbCapabilityQuery -Domain 'operating_system' -Action {
    $os = Get-CimInstance Win32_OperatingSystem | Select-Object -First 1
    $computer = Get-CimInstance Win32_ComputerSystem | Select-Object -First 1

    [ordered]@{
        caption                  = $os.Caption
        version                  = $os.Version
        build_number             = $os.BuildNumber
        architecture             = $os.OSArchitecture
        install_date             = if ($os.InstallDate) { $os.InstallDate.ToUniversalTime().ToString('o') } else { $null }
        last_boot_utc            = if ($os.LastBootUpTime) { $os.LastBootUpTime.ToUniversalTime().ToString('o') } else { $null }
        total_visible_memory_kb  = [long]$os.TotalVisibleMemorySize
        free_physical_memory_kb  = [long]$os.FreePhysicalMemory
        total_virtual_memory_kb  = [long]$os.TotalVirtualMemorySize
        free_virtual_memory_kb   = [long]$os.FreeVirtualMemory
        manufacturer             = $computer.Manufacturer
        model                    = $computer.Model
        system_type              = $computer.SystemType
        hypervisor_present       = [bool]$computer.HypervisorPresent
        domain                   = $computer.Domain
    }
}

$domains.cpu = Invoke-NxbCapabilityQuery -Domain 'cpu' -Action {
    @(Get-CimInstance Win32_Processor | ForEach-Object {
        [ordered]@{
            device_id                              = $_.DeviceID
            name                                   = $_.Name
            manufacturer                           = $_.Manufacturer
            architecture                           = $_.Architecture
            address_width                          = $_.AddressWidth
            data_width                             = $_.DataWidth
            cores                                  = $_.NumberOfCores
            logical_processors                     = $_.NumberOfLogicalProcessors
            max_clock_mhz                          = $_.MaxClockSpeed
            current_clock_mhz                      = $_.CurrentClockSpeed
            l2_cache_kb                            = $_.L2CacheSize
            l3_cache_kb                            = $_.L3CacheSize
            virtualization_firmware_enabled        = $_.VirtualizationFirmwareEnabled
            second_level_address_translation       = $_.SecondLevelAddressTranslationExtensions
            vm_monitor_mode_extensions             = $_.VMMonitorModeExtensions
            processor_id                           = $_.ProcessorId
        }
    })
}

$domains.memory = Invoke-NxbCapabilityQuery -Domain 'memory' -Action {
    $modules = @(Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
        [ordered]@{
            bank_label                = $_.BankLabel
            device_locator            = $_.DeviceLocator
            capacity_bytes            = [long]$_.Capacity
            speed_mhz                 = $_.Speed
            configured_clock_mhz      = $_.ConfiguredClockSpeed
            data_width                = $_.DataWidth
            total_width               = $_.TotalWidth
            form_factor               = $_.FormFactor
            memory_type               = $_.MemoryType
            smbios_memory_type        = $_.SMBIOSMemoryType
            manufacturer              = $_.Manufacturer
            part_number               = ([string]$_.PartNumber).Trim()
        }
    })

    $pageFile = @(Get-CimInstance Win32_PageFileUsage | ForEach-Object {
        [ordered]@{
            name                    = $_.Name
            allocated_base_size_mb  = $_.AllocatedBaseSize
            current_usage_mb        = $_.CurrentUsage
            peak_usage_mb           = $_.PeakUsage
        }
    })

    [ordered]@{
        modules   = $modules
        page_file = $pageFile
    }
}

$domains.gpu = Invoke-NxbCapabilityQuery -Domain 'gpu' -Action {
    @(Get-CimInstance Win32_VideoController | ForEach-Object {
        [ordered]@{
            name                   = $_.Name
            pnp_device_id          = $_.PNPDeviceID
            adapter_ram_bytes      = if ($null -ne $_.AdapterRAM) { [long]$_.AdapterRAM } else { $null }
            driver_version         = $_.DriverVersion
            driver_date            = if ($_.DriverDate) { $_.DriverDate.ToUniversalTime().ToString('o') } else { $null }
            video_processor        = $_.VideoProcessor
            current_width          = $_.CurrentHorizontalResolution
            current_height         = $_.CurrentVerticalResolution
            current_refresh_hz     = $_.CurrentRefreshRate
            status                 = $_.Status
        }
    })
}

$domains.storage = Invoke-NxbCapabilityQuery -Domain 'storage' -Action {
    $diskDrives = @(Get-CimInstance Win32_DiskDrive | ForEach-Object {
        [ordered]@{
            device_id             = $_.DeviceID
            model                 = $_.Model
            interface_type        = $_.InterfaceType
            media_type            = $_.MediaType
            firmware_revision     = $_.FirmwareRevision
            size_bytes            = if ($null -ne $_.Size) { [long]$_.Size } else { $null }
            bytes_per_sector      = $_.BytesPerSector
            partitions            = $_.Partitions
            pnp_device_id         = $_.PNPDeviceID
            status                = $_.Status
        }
    })

    $logicalDisks = @(Get-CimInstance Win32_LogicalDisk | ForEach-Object {
        [ordered]@{
            device_id             = $_.DeviceID
            drive_type            = $_.DriveType
            file_system           = $_.FileSystem
            volume_name           = $_.VolumeName
            size_bytes            = if ($null -ne $_.Size) { [long]$_.Size } else { $null }
            free_space_bytes      = if ($null -ne $_.FreeSpace) { [long]$_.FreeSpace } else { $null }
        }
    })

    $physicalDisks = @()
    $physicalDiskCommand = Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue
    if ($null -ne $physicalDiskCommand) {
        $physicalDisks = @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
            [ordered]@{
                friendly_name       = $_.FriendlyName
                media_type          = [string]$_.MediaType
                bus_type            = [string]$_.BusType
                health_status       = [string]$_.HealthStatus
                operational_status  = @($_.OperationalStatus | ForEach-Object { [string]$_ })
                size_bytes          = [long]$_.Size
                logical_sector_size = $_.LogicalSectorSize
                physical_sector_size = $_.PhysicalSectorSize
            }
        })
    }

    [ordered]@{
        disk_drives    = $diskDrives
        logical_disks  = $logicalDisks
        physical_disks = $physicalDisks
    }
}

$domains.network = Invoke-NxbCapabilityQuery -Domain 'network' -Action {
    $adapters = @(Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.PhysicalAdapter -eq $true } | ForEach-Object {
        [ordered]@{
            name                  = $_.Name
            net_connection_id     = $_.NetConnectionID
            adapter_type          = $_.AdapterType
            mac_address           = $_.MACAddress
            speed_bps             = if ($null -ne $_.Speed) { [long]$_.Speed } else { $null }
            pnp_device_id         = $_.PNPDeviceID
            service_name          = $_.ServiceName
            net_enabled           = $_.NetEnabled
            status                = $_.Status
        }
    })

    $configurations = @(Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true } | ForEach-Object {
        [ordered]@{
            description           = $_.Description
            dhcp_enabled          = $_.DHCPEnabled
            ip_addresses          = @($_.IPAddress)
            ip_subnets            = @($_.IPSubnet)
            default_gateways      = @($_.DefaultIPGateway)
            dns_servers           = @($_.DNSServerSearchOrder)
            mtu                   = $_.MTU
        }
    })

    [ordered]@{
        adapters       = $adapters
        configurations = $configurations
    }
}

$domains.bus_and_devices = Invoke-NxbCapabilityQuery -Domain 'bus_and_devices' -Action {
    $deviceClasses = @(Get-CimInstance Win32_PnPEntity |
        Group-Object PNPClass |
        Sort-Object Name |
        ForEach-Object {
            [ordered]@{
                pnp_class = if ([string]::IsNullOrWhiteSpace($_.Name)) { 'Unknown' } else { $_.Name }
                count     = $_.Count
            }
        })

    $signedDrivers = @(Get-CimInstance Win32_PnPSignedDriver | ForEach-Object {
        [ordered]@{
            device_name     = $_.DeviceName
            device_class    = $_.DeviceClass
            driver_version  = $_.DriverVersion
            manufacturer    = $_.Manufacturer
            inf_name        = $_.InfName
            is_signed       = $_.IsSigned
            signer          = $_.Signer
        }
    })

    [ordered]@{
        device_class_counts = $deviceClasses
        signed_drivers      = $signedDrivers
    }
}

$domains.firmware = Invoke-NxbCapabilityQuery -Domain 'firmware' -Action {
    $bios = Get-CimInstance Win32_BIOS | Select-Object -First 1
    $baseBoard = Get-CimInstance Win32_BaseBoard | Select-Object -First 1

    [ordered]@{
        bios = [ordered]@{
            manufacturer       = $bios.Manufacturer
            name               = $bios.Name
            smbios_version     = $bios.SMBIOSBIOSVersion
            release_date       = if ($bios.ReleaseDate) { $bios.ReleaseDate.ToUniversalTime().ToString('o') } else { $null }
            serial_number      = $bios.SerialNumber
        }
        baseboard = [ordered]@{
            manufacturer       = $baseBoard.Manufacturer
            product            = $baseBoard.Product
            version            = $baseBoard.Version
            serial_number      = $baseBoard.SerialNumber
        }
    }
}

$domains.security = Invoke-NxbCapabilityQuery -Domain 'security' -Action {
    $secureBoot = $null
    try {
        $secureBoot = [bool](Confirm-SecureBootUEFI -ErrorAction Stop)
    }
    catch {
        $secureBoot = $null
    }

    $tpmData = $null
    $getTpm = Get-Command Get-Tpm -ErrorAction SilentlyContinue
    if ($null -ne $getTpm) {
        try {
            $tpm = Get-Tpm -ErrorAction Stop
            $tpmData = [ordered]@{
                present          = $tpm.TpmPresent
                ready            = $tpm.TpmReady
                enabled          = $tpm.TpmEnabled
                activated        = $tpm.TpmActivated
                owned            = $tpm.TpmOwned
                manufacturer_id  = $tpm.ManufacturerIdTxt
                specification    = $tpm.SpecVersion
            }
        }
        catch {
            $tpmData = $null
        }
    }

    $deviceGuard = $null
    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop |
            Select-Object -First 1
        $deviceGuard = [ordered]@{
            virtualization_based_security_status = $dg.VirtualizationBasedSecurityStatus
            security_services_configured         = @($dg.SecurityServicesConfigured)
            security_services_running            = @($dg.SecurityServicesRunning)
            required_security_properties         = @($dg.RequiredSecurityProperties)
            available_security_properties        = @($dg.AvailableSecurityProperties)
            code_integrity_policy_enforcement     = $dg.CodeIntegrityPolicyEnforcementStatus
            user_mode_code_integrity_policy       = $dg.UsermodeCodeIntegrityPolicyEnforcementStatus
        }
    }
    catch {
        $deviceGuard = $null
    }

    [ordered]@{
        secure_boot = $secureBoot
        tpm         = $tpmData
        device_guard = $deviceGuard
    }
}

$domains.power = Invoke-NxbCapabilityQuery -Domain 'power' -Action {
    $activeScheme = $null
    $powercfg = Get-Command powercfg.exe -ErrorAction SilentlyContinue
    if ($null -ne $powercfg) {
        $activeScheme = (& $powercfg.Source /getactivescheme 2>&1 | Out-String).Trim()
    }

    $batteries = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | ForEach-Object {
        [ordered]@{
            name                       = $_.Name
            status                     = $_.Status
            estimated_charge_remaining = $_.EstimatedChargeRemaining
            battery_status             = $_.BatteryStatus
        }
    })

    [ordered]@{
        active_power_scheme = $activeScheme
        batteries           = $batteries
    }
}

$domains.tooling = Invoke-NxbCapabilityQuery -Domain 'tooling' -Action {
    @(
        Get-NxbCommandCapability -Name 'wpr.exe'
        Get-NxbCommandCapability -Name 'wpa.exe'
        Get-NxbCommandCapability -Name 'xperf.exe'
        Get-NxbCommandCapability -Name 'windbg.exe'
        Get-NxbCommandCapability -Name 'kdnet.exe'
        Get-NxbCommandCapability -Name 'gpuview.exe'
        Get-NxbCommandCapability -Name 'presentmon.exe'
        Get-NxbCommandCapability -Name 'python.exe'
        Get-NxbCommandCapability -Name 'pwsh.exe'
        Get-NxbCommandCapability -Name 'git.exe'
    )
}

$inventory = [ordered]@{
    schema_version     = 1
    captured_utc       = [DateTime]::UtcNow.ToString('o')
    machine_id         = $machineId
    computer_name      = [string]$env:COMPUTERNAME
    powershell_version = $PSVersionTable.PSVersion.ToString()
    domains            = $domains
    collection_errors  = @($collectionErrors)
}

Write-NxbJsonAtomic -Path $OutputPath -InputObject $inventory -Depth 24

Write-Host "Tam sistem capability envanteri oluşturuldu: $OutputPath"
Write-Output $OutputPath
