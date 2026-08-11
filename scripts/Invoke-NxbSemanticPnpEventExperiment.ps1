[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath,
    [Parameter()][ValidateRange(250,3000)][int]$SettleMilliseconds = 750,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NxbSemanticPnpAdministrator {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NxbSemanticPnpSha256Text {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Test-NxbSemanticPnpPresence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstanceId)
    foreach ($device in @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop)) {
        $candidate = [string]$device.PNPDeviceID
        if ($candidate.Equals($InstanceId,[StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Wait-NxbSemanticPnpPresence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][bool]$ExpectedPresent,
        [Parameter()][ValidateRange(1,30)][int]$TimeoutSeconds = 10
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $present = Test-NxbSemanticPnpPresence -InstanceId $InstanceId
        if ($present -eq $ExpectedPresent) { return $true }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Get-NxbSemanticPnpLogInventory {
    [CmdletBinding()]
    param()
    $set = [Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$set.Add('System')
    foreach ($providerName in @(
        'Microsoft-Windows-Kernel-PnP',
        'Microsoft-Windows-UserPnp',
        'Microsoft-Windows-DeviceSetupManager'
    )) {
        try {
            $provider = Get-WinEvent -ListProvider $providerName -ErrorAction Stop
            foreach ($link in @($provider.LogLinks)) {
                $logName = [string]$link.LogName
                if (-not [string]::IsNullOrWhiteSpace($logName)) { [void]$set.Add($logName) }
            }
        }
        catch {
            Write-Verbose -Message ('PnP provider unavailable: {0}' -f $providerName)
        }
    }
    return @($set)
}

function Get-NxbSemanticPnpEventShape {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][DateTime]$StartUtc,
        [Parameter(Mandatory)][DateTime]$EndUtc,
        [Parameter(Mandatory)][string[]]$LogNames
    )
    $shape = [System.Collections.Generic.List[object]]::new()
    foreach ($logName in $LogNames) {
        try {
            $eventRows = @(Get-WinEvent -FilterHashtable @{
                LogName = $logName
                StartTime = $StartUtc.ToLocalTime()
                EndTime = $EndUtc.ToLocalTime()
            } -ErrorAction Stop)
        }
        catch { continue }
        foreach ($eventRow in $eventRows) {
            $xml = ''
            try { $xml = [string]$eventRow.ToXml() } catch { continue }
            if ($xml.IndexOf($InstanceId,[StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $shape.Add([pscustomobject][ordered]@{
                provider_name = [string]$eventRow.ProviderName
                log_name = [string]$eventRow.LogName
                id = [int]$eventRow.Id
                version = if ($null -eq $eventRow.Version) { 0 } else { [int]$eventRow.Version }
                level = if ($null -eq $eventRow.Level) { -1 } else { [int]$eventRow.Level }
                task = if ($null -eq $eventRow.Task) { -1 } else { [int]$eventRow.Task }
                opcode = if ($null -eq $eventRow.Opcode) { -1 } else { [int]$eventRow.Opcode }
                fixture_identity_matched = $true
            })
        }
    }
    return @($shape | Sort-Object provider_name,log_name,id,version,level,task,opcode -Unique)
}

function Get-NxbSemanticPnpShapeKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Shape)
    return ('{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $Shape.provider_name,$Shape.log_name,$Shape.id,$Shape.version,$Shape.level,$Shape.task,$Shape.opcode)
}

function Get-NxbSemanticPnpIdKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Shape)
    return ('{0}|{1}|{2}' -f $Shape.provider_name,$Shape.log_name,$Shape.id)
}

if ($env:OS -cne 'Windows_NT') { throw 'PnP semantic experiment requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'PnP semantic experiment requires PowerShell 7.' }
if (-not (Test-NxbSemanticPnpAdministrator)) { throw 'PnP software-device experiment requires elevated PowerShell 7.' }

if ($null -eq ('Nxb.Semantic.SoftwareDeviceLease' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace Nxb.Semantic {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct SW_DEVICE_CREATE_INFO {
        internal uint cbSize;
        [MarshalAs(UnmanagedType.LPWStr)] internal string pszInstanceId;
        internal IntPtr pszzHardwareIds;
        internal IntPtr pszzCompatibleIds;
        internal IntPtr pContainerId;
        internal uint CapabilityFlags;
        [MarshalAs(UnmanagedType.LPWStr)] internal string pszDeviceDescription;
        [MarshalAs(UnmanagedType.LPWStr)] internal string pszDeviceLocation;
        internal IntPtr pSecurityDescriptor;
    }

    internal static class NativeMethods {
        [UnmanagedFunctionPointer(CallingConvention.Winapi, CharSet = CharSet.Unicode)]
        internal delegate void SW_DEVICE_CREATE_CALLBACK(IntPtr hSwDevice, int createResult, IntPtr context, [MarshalAs(UnmanagedType.LPWStr)] string deviceInstanceId);

        [DllImport("Cfgmgr32.dll", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Winapi)]
        internal static extern int SwDeviceCreate(
            string pszEnumeratorName,
            string pszParentDeviceInstance,
            ref SW_DEVICE_CREATE_INFO pCreateInfo,
            uint cPropertyCount,
            IntPtr pProperties,
            SW_DEVICE_CREATE_CALLBACK pCallback,
            IntPtr pContext,
            out IntPtr phSwDevice);

        [DllImport("Cfgmgr32.dll", CallingConvention = CallingConvention.Winapi)]
        internal static extern void SwDeviceClose(IntPtr hSwDevice);
    }

    public sealed class SoftwareDeviceLease : IDisposable {
        private IntPtr handle;
        public string InstanceId { get; private set; }
        public bool Closed { get; private set; }

        private SoftwareDeviceLease(IntPtr value, string instanceId) {
            handle = value;
            InstanceId = instanceId;
        }

        public static SoftwareDeviceLease Create(string instanceSeed) {
            if (String.IsNullOrWhiteSpace(instanceSeed)) throw new ArgumentException("instanceSeed");
            var info = new SW_DEVICE_CREATE_INFO {
                cbSize = (uint)Marshal.SizeOf(typeof(SW_DEVICE_CREATE_INFO)),
                pszInstanceId = instanceSeed,
                pszzHardwareIds = IntPtr.Zero,
                pszzCompatibleIds = IntPtr.Zero,
                pContainerId = IntPtr.Zero,
                CapabilityFlags = 0x00000001u | 0x00000002u | 0x00000004u,
                pszDeviceDescription = "NXB Semantic Ephemeral Software Device",
                pszDeviceLocation = null,
                pSecurityDescriptor = IntPtr.Zero
            };

            var ready = new ManualResetEventSlim(false);
            int callbackResult = unchecked((int)0x80004005);
            string actualId = null;
            NativeMethods.SW_DEVICE_CREATE_CALLBACK callback = (device, result, context, id) => {
                callbackResult = result;
                actualId = id;
                ready.Set();
            };

            IntPtr handle;
            int hr = NativeMethods.SwDeviceCreate("NXBSEM", "HTREE\\ROOT\\0", ref info, 0, IntPtr.Zero, callback, IntPtr.Zero, out handle);
            if (hr < 0) Marshal.ThrowExceptionForHR(hr);
            if (!ready.Wait(TimeSpan.FromSeconds(10))) {
                if (handle != IntPtr.Zero) NativeMethods.SwDeviceClose(handle);
                throw new TimeoutException("SwDeviceCreate callback timed out.");
            }
            GC.KeepAlive(callback);
            ready.Dispose();
            if (callbackResult < 0) {
                if (handle != IntPtr.Zero) NativeMethods.SwDeviceClose(handle);
                Marshal.ThrowExceptionForHR(callbackResult);
            }
            if (String.IsNullOrWhiteSpace(actualId)) {
                if (handle != IntPtr.Zero) NativeMethods.SwDeviceClose(handle);
                throw new InvalidOperationException("SwDeviceCreate callback returned no instance id.");
            }
            return new SoftwareDeviceLease(handle, actualId);
        }

        public void Close() {
            if (Closed) return;
            if (handle != IntPtr.Zero) {
                NativeMethods.SwDeviceClose(handle);
                handle = IntPtr.Zero;
            }
            Closed = true;
        }

        public void Dispose() { Close(); }
    }
}
'@
}

$startedUtc = [DateTime]::UtcNow
$logInventory = @(Get-NxbSemanticPnpLogInventory)
$repeatResult = [System.Collections.Generic.List[object]]::new()
foreach ($repeat in @('A','B')) {
    $idleStart = [DateTime]::UtcNow
    Start-Sleep -Milliseconds $SettleMilliseconds
    $idleEnd = [DateTime]::UtcNow

    $seed = ('NXB-{0}-{1}' -f $repeat,[Guid]::NewGuid().ToString('N'))
    $createStart = [DateTime]::UtcNow
    $lease = $null
    $actualId = $null
    $presentObserved = $false
    $removedObserved = $false
    try {
        $lease = [Nxb.Semantic.SoftwareDeviceLease]::Create($seed)
        $actualId = [string]$lease.InstanceId
        $presentObserved = Wait-NxbSemanticPnpPresence -InstanceId $actualId -ExpectedPresent $true
        if (-not $presentObserved) { throw 'Ephemeral software device was not observed present.' }
        Start-Sleep -Milliseconds $SettleMilliseconds
        $createEnd = [DateTime]::UtcNow

        $removeStart = [DateTime]::UtcNow
        $lease.Close()
        $removedObserved = Wait-NxbSemanticPnpPresence -InstanceId $actualId -ExpectedPresent $false
        if (-not $removedObserved) { throw 'Ephemeral software device was not observed removed after handle close.' }
        Start-Sleep -Milliseconds $SettleMilliseconds
        $removeEnd = [DateTime]::UtcNow

        $idleShape = @(Get-NxbSemanticPnpEventShape -InstanceId $actualId -StartUtc $idleStart -EndUtc $idleEnd -LogNames $logInventory)
        $createShape = @(Get-NxbSemanticPnpEventShape -InstanceId $actualId -StartUtc $createStart -EndUtc $createEnd -LogNames $logInventory)
        $removeShape = @(Get-NxbSemanticPnpEventShape -InstanceId $actualId -StartUtc $removeStart -EndUtc $removeEnd -LogNames $logInventory)

        $repeatResult.Add([pscustomobject][ordered]@{
            repeat = $repeat
            device_id_sha256 = Get-NxbSemanticPnpSha256Text -Text $actualId
            direct_state = [pscustomobject][ordered]@{
                create_present_observed = $presentObserved
                close_remove_observed = $removedObserved
            }
            idle_event_shapes = $idleShape
            create_event_shapes = $createShape
            remove_event_shapes = $removeShape
            raw_device_instance_id_reviewable = $false
            raw_event_payload_reviewable = $false
            formatted_event_message_reviewable = $false
        })
    }
    finally {
        if ($null -ne $lease) { $lease.Dispose() }
        if (-not [string]::IsNullOrWhiteSpace($actualId)) {
            $cleanupAbsent = Wait-NxbSemanticPnpPresence -InstanceId $actualId -ExpectedPresent $false -TimeoutSeconds 10
            if (-not $cleanupAbsent) { throw 'Ephemeral software-device cleanup verification failed.' }
        }
    }
}

$repeatA = $repeatResult[0]
$repeatB = $repeatResult[1]
$createIdA = @($repeatA.create_event_shapes | ForEach-Object { Get-NxbSemanticPnpIdKey -Shape $_ } | Sort-Object -Unique)
$createIdB = @($repeatB.create_event_shapes | ForEach-Object { Get-NxbSemanticPnpIdKey -Shape $_ } | Sort-Object -Unique)
$removeIdA = @($repeatA.remove_event_shapes | ForEach-Object { Get-NxbSemanticPnpIdKey -Shape $_ } | Sort-Object -Unique)
$removeIdB = @($repeatB.remove_event_shapes | ForEach-Object { Get-NxbSemanticPnpIdKey -Shape $_ } | Sort-Object -Unique)
$createShapeA = @($repeatA.create_event_shapes | ForEach-Object { Get-NxbSemanticPnpShapeKey -Shape $_ } | Sort-Object -Unique)
$createShapeB = @($repeatB.create_event_shapes | ForEach-Object { Get-NxbSemanticPnpShapeKey -Shape $_ } | Sort-Object -Unique)
$removeShapeA = @($repeatA.remove_event_shapes | ForEach-Object { Get-NxbSemanticPnpShapeKey -Shape $_ } | Sort-Object -Unique)
$removeShapeB = @($repeatB.remove_event_shapes | ForEach-Object { Get-NxbSemanticPnpShapeKey -Shape $_ } | Sort-Object -Unique)

$commonCreateId = @($createIdA | Where-Object { $createIdB -contains $_ })
$commonRemoveId = @($removeIdA | Where-Object { $removeIdB -contains $_ })
$commonCreateShape = @($createShapeA | Where-Object { $createShapeB -contains $_ })
$commonRemoveShape = @($removeShapeA | Where-Object { $removeShapeB -contains $_ })
$idleClean = (@($repeatResult | ForEach-Object { @($_.idle_event_shapes) }).Count -eq 0)
$pnpValidated = (@($repeatResult | Where-Object { -not [bool]$_.direct_state.create_present_observed -or -not [bool]$_.direct_state.close_remove_observed }).Count -eq 0)
$eventIdValidated = ($idleClean -and $commonCreateId.Count -gt 0 -and $commonRemoveId.Count -gt 0)
$taskOpcodeValidated = ($eventIdValidated -and $commonCreateShape.Count -gt 0 -and $commonRemoveShape.Count -gt 0)
$endedUtc = [DateTime]::UtcNow

$result = [pscustomobject][ordered]@{
    schema_version = 1
    status = if ($pnpValidated -and $eventIdValidated -and $taskOpcodeValidated) { 'passed' } else { 'failed' }
    started_utc = $startedUtc.ToString('o')
    ended_utc = $endedUtc.ToString('o')
    scope = 'owned-ephemeral-software-device-lifecycle-a-b'
    repeats = @($repeatResult)
    negative_controls = [pscustomobject][ordered]@{
        matched_idle_windows = 2
        fixture_identity_events_in_idle_windows = @($repeatResult | ForEach-Object { @($_.idle_event_shapes) }).Count
        passed = $idleClean
    }
    repeated_event_mapping = [pscustomobject][ordered]@{
        common_create_provider_log_id_count = $commonCreateId.Count
        common_remove_provider_log_id_count = $commonRemoveId.Count
        common_create_full_shape_count = $commonCreateShape.Count
        common_remove_full_shape_count = $commonRemoveShape.Count
        common_create_provider_log_ids = $commonCreateId
        common_remove_provider_log_ids = $commonRemoveId
        common_create_full_shapes = $commonCreateShape
        common_remove_full_shapes = $commonRemoveShape
    }
    cleanup_verified = $true
    claims = [pscustomobject][ordered]@{
        pnp_lifecycle_semantics = $pnpValidated
        event_id_semantics = $eventIdValidated
        event_task_opcode_semantics = $taskOpcodeValidated
        physical_device_mutation_used = $false
        generalized_pnp_semantics_claimed = $false
    }
}

$fullPath = [IO.Path]::GetFullPath($OutputPath)
$parent = Split-Path -Parent $fullPath
if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText($fullPath,(($result | ConvertTo-Json -Depth 20) + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
if ([string]$result.status -cne 'passed') {
    throw ('PnP/event semantic experiment failed: pnp={0} event_id={1} task_opcode={2}' -f $pnpValidated,$eventIdValidated,$taskOpcodeValidated)
}
Write-Information -InformationAction Continue -MessageData ('NXB PnP/event semantic experiment passed: create_ids={0} remove_ids={1}' -f $commonCreateId.Count,$commonRemoveId.Count)
if ($PassThru) { return $result }
Write-Output $fullPath
