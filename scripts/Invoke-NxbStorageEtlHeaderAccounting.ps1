[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$CaptureReceiptPath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$EtlPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter(DontShow)]
    [scriptblock]$HeaderProvider,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-NxbStorageEtlHeaderReader {
    [CmdletBinding()]
    param()

    if ($null -ne ('Nxb.StorageEtlHeaderReader' -as [type])) {
        return
    }

    $typeDefinition = @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;

namespace Nxb
{
    public sealed class StorageEtlHeaderSnapshot
    {
        public uint BufferSize;
        public uint NumberOfProcessors;
        public uint MaximumFileSize;
        public uint LogFileMode;
        public uint BuffersWritten;
        public uint PointerSize;
        public uint EventsLost;
        public uint BuffersLost;
    }

    public static class StorageEtlHeaderReader
    {
        private const uint ProcessTraceModeEventRecord = 0x10000000;

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        private delegate void EventRecordCallback(IntPtr eventRecord);

        private static readonly EventRecordCallback Callback =
            new EventRecordCallback(IgnoreEvent);

        [DllImport("sechost.dll", EntryPoint = "OpenTraceW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern ulong OpenTraceSechost(IntPtr logfile);

        [DllImport("sechost.dll", EntryPoint = "CloseTrace", SetLastError = true)]
        private static extern uint CloseTraceSechost(ulong traceHandle);

        [DllImport("advapi32.dll", EntryPoint = "OpenTraceW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern ulong OpenTraceAdvapi(IntPtr logfile);

        [DllImport("advapi32.dll", EntryPoint = "CloseTrace", SetLastError = true)]
        private static extern uint CloseTraceAdvapi(ulong traceHandle);

        private static void IgnoreEvent(IntPtr eventRecord) { }

        private static bool IsInvalidTraceHandle(ulong handle)
        {
            return IntPtr.Size == 8
                ? handle == UInt64.MaxValue
                : handle == UInt32.MaxValue;
        }

        private static uint ReadUInt32(IntPtr address, int offset)
        {
            return unchecked((uint)Marshal.ReadInt32(address, offset));
        }

        private static ulong OpenTrace(IntPtr logfile, out bool usedSechost, out int errorCode)
        {
            try
            {
                ulong handle = OpenTraceSechost(logfile);
                errorCode = Marshal.GetLastWin32Error();
                usedSechost = true;
                return handle;
            }
            catch (DllNotFoundException) { }
            catch (EntryPointNotFoundException) { }

            ulong fallback = OpenTraceAdvapi(logfile);
            errorCode = Marshal.GetLastWin32Error();
            usedSechost = false;
            return fallback;
        }

        public static StorageEtlHeaderSnapshot Read(string path)
        {
            string fullPath = Path.GetFullPath(path);
            if (!File.Exists(fullPath))
                throw new FileNotFoundException("ETL file was not found.", fullPath);

            bool is64Bit = IntPtr.Size == 8;
            int eventTraceLogfileSize = is64Bit ? 448 : 408;
            int logfileHeaderOffset = is64Bit ? 120 : 108;
            int processTraceModeOffset = is64Bit ? 28 : 20;
            int eventRecordCallbackOffset = is64Bit ? 424 : 396;
            int buffersLostOffset = is64Bit ? 276 : 268;

            IntPtr logfile = IntPtr.Zero;
            IntPtr pathPointer = IntPtr.Zero;
            ulong traceHandle = 0;
            bool traceOpened = false;
            bool usedSechost = false;

            try
            {
                logfile = Marshal.AllocHGlobal(eventTraceLogfileSize);
                Marshal.Copy(new byte[eventTraceLogfileSize], 0, logfile, eventTraceLogfileSize);
                pathPointer = Marshal.StringToHGlobalUni(fullPath);
                Marshal.WriteIntPtr(logfile, 0, pathPointer);
                Marshal.WriteInt32(logfile, processTraceModeOffset, unchecked((int)ProcessTraceModeEventRecord));
                Marshal.WriteIntPtr(logfile, eventRecordCallbackOffset, Marshal.GetFunctionPointerForDelegate(Callback));

                int openError;
                traceHandle = OpenTrace(logfile, out usedSechost, out openError);
                if (IsInvalidTraceHandle(traceHandle))
                    throw new Win32Exception(openError, "OpenTraceW could not open the ETL file.");
                traceOpened = true;

                StorageEtlHeaderSnapshot result = new StorageEtlHeaderSnapshot();
                result.BufferSize = ReadUInt32(logfile, logfileHeaderOffset + 0);
                result.NumberOfProcessors = ReadUInt32(logfile, logfileHeaderOffset + 12);
                result.MaximumFileSize = ReadUInt32(logfile, logfileHeaderOffset + 28);
                result.LogFileMode = ReadUInt32(logfile, logfileHeaderOffset + 32);
                result.BuffersWritten = ReadUInt32(logfile, logfileHeaderOffset + 36);
                result.PointerSize = ReadUInt32(logfile, logfileHeaderOffset + 44);
                result.EventsLost = ReadUInt32(logfile, logfileHeaderOffset + 48);
                result.BuffersLost = ReadUInt32(logfile, logfileHeaderOffset + buffersLostOffset);

                if (result.BufferSize == 0 || result.NumberOfProcessors == 0)
                    throw new InvalidDataException("TRACE_LOGFILE_HEADER has invalid buffer/processor metadata.");
                if (result.PointerSize != 4 && result.PointerSize != 8)
                    throw new InvalidDataException("TRACE_LOGFILE_HEADER has invalid pointer size.");

                uint closeResult = usedSechost ? CloseTraceSechost(traceHandle) : CloseTraceAdvapi(traceHandle);
                traceOpened = false;
                if (closeResult != 0)
                    throw new Win32Exception(unchecked((int)closeResult), "CloseTrace could not close the ETL handle.");

                return result;
            }
            finally
            {
                if (traceOpened)
                {
                    try
                    {
                        if (usedSechost) CloseTraceSechost(traceHandle);
                        else CloseTraceAdvapi(traceHandle);
                    }
                    catch { }
                }
                if (pathPointer != IntPtr.Zero) Marshal.FreeHGlobal(pathPointer);
                if (logfile != IntPtr.Zero) Marshal.FreeHGlobal(logfile);
                GC.KeepAlive(Callback);
            }
        }
    }
}
'@

    Add-Type -TypeDefinition $typeDefinition -Language CSharp -ErrorAction Stop
}

function Write-NxbStorageAccountingJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object]$InputObject
    )

    [IO.File]::WriteAllText(
        $Path,
        (($InputObject | ConvertTo-Json -Depth 32) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

if ($env:OS -cne 'Windows_NT') {
    throw 'Storage ETL header accounting requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Storage ETL header accounting must run in PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}
$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'Storage ETL header accounting requires a clean exact-head worktree.'
}

$captureFull = [IO.Path]::GetFullPath($CaptureReceiptPath)
$etlFull = [IO.Path]::GetFullPath($EtlPath)
$outputFull = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $outputFull) {
    throw "OutputPath already exists: $outputFull"
}
[IO.Directory]::CreateDirectory((Split-Path -Parent $outputFull)) | Out-Null

$capture = Get-Content -LiteralPath $captureFull -Raw | ConvertFrom-Json
if ([string]$capture.status -cne 'passed') {
    throw "Capture receipt status is not passed: $($capture.status)"
}
if ([string]$capture.profile.file_mode -cne 'Circular') {
    throw "Storage capture is not Circular file mode: $($capture.profile.file_mode)"
}
$capacityMiB = [int64]$capture.profile.maximum_file_size_mib
if ($capacityMiB -le 0) {
    throw 'Capture receipt maximum_file_size_mib is invalid.'
}

$etlItem = Get-Item -LiteralPath $etlFull -Force
if (($etlItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Storage ETL cannot be a reparse point.'
}
$etlLength = [int64]$etlItem.Length
$etlSha256 = (Get-FileHash -LiteralPath $etlFull -Algorithm SHA256).Hash.ToLowerInvariant()
if ($null -ne $capture.evidence.etl_sha256 -and
    -not [string]::IsNullOrWhiteSpace([string]$capture.evidence.etl_sha256) -and
    [string]$capture.evidence.etl_sha256 -cne $etlSha256) {
    throw 'Capture receipt ETL SHA-256 does not match the real ETL.'
}

$header = if ($null -ne $HeaderProvider) {
    & $HeaderProvider $etlFull
}
else {
    Initialize-NxbStorageEtlHeaderReader
    [Nxb.StorageEtlHeaderReader]::Read($etlFull)
}

$bufferSize = [uint64]$header.BufferSize
$processorCount = [uint64]$header.NumberOfProcessors
$maximumFileSize = [uint64]$header.MaximumFileSize
$logFileMode = [uint64]$header.LogFileMode
$buffersWritten = [uint64]$header.BuffersWritten
$pointerSize = [uint64]$header.PointerSize
$eventsLost = [uint64]$header.EventsLost
$buffersLost = [uint64]$header.BuffersLost

if ($bufferSize -eq 0 -or $processorCount -eq 0) {
    throw 'Native ETL header returned invalid buffer/processor metadata.'
}
if ($pointerSize -notin @(4, 8)) {
    throw 'Native ETL header returned invalid pointer-size metadata.'
}

$totalLoss = [uint64]($eventsLost + $buffersLost)
$traceLossState = if ($totalLoss -eq 0) { 'none' } else { 'present' }
$traceLossClassification = if ($totalLoss -eq 0) {
    'no_native_loss_reported'
}
else {
    'native_loss_observed'
}

$capacityBytes = [int64]($capacityMiB * 1MB)
$utilizationRatio = [double]$etlLength / [double]$capacityBytes
$riskReasons = [Collections.Generic.List[string]]::new()
if ($utilizationRatio -ge 0.9) {
    $riskReasons.Add('capacity_threshold_reached')
}
if ($etlLength -gt $capacityBytes) {
    $riskReasons.Add('etl_length_exceeds_declared_capacity')
}
$circularRisk = if ($riskReasons.Count -gt 0) { 'risk_observed' } else { 'no_risk_observed' }

$result = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    head_sha = $currentHead
    capture_head_sha = [string]$capture.head_sha
    captured_utc = [DateTime]::UtcNow.ToString('o')
    etl = [ordered]@{
        path = $etlFull
        sha256 = $etlSha256
        length = $etlLength
    }
    profile = [ordered]@{
        sha256 = [string]$capture.profile.sha256
        file_mode = [string]$capture.profile.file_mode
        maximum_file_size_mib = $capacityMiB
        capacity_bytes = $capacityBytes
    }
    native_header = [ordered]@{
        source = 'OpenTraceW/TRACE_LOGFILE_HEADER'
        buffer_size_kib = $bufferSize
        processor_count = $processorCount
        maximum_file_size_raw = $maximumFileSize
        log_file_mode_raw = $logFileMode
        buffers_written = $buffersWritten
        pointer_size = $pointerSize
        events_lost = $eventsLost
        buffers_lost = $buffersLost
    }
    trace_loss = [ordered]@{
        state = $traceLossState
        classification = $traceLossClassification
        total_reported_loss = $totalLoss
        applicable_counter_count = 2
        measured_counter_count = 2
    }
    circular = [ordered]@{
        overwrite_state = 'unknown'
        risk_classification = $circularRisk
        utilization_ratio = $utilizationRatio
        risk_threshold_ratio = 0.9
        risk_reasons = @($riskReasons)
    }
    claims = [ordered]@{
        trace_loss_absence = $false
        circular_overwrite_absence = $false
        capture_completeness = 'not_claimed'
    }
}

Write-NxbStorageAccountingJson -Path $outputFull -InputObject $result

Write-Information -MessageData "Storage native ETL accounting written: $outputFull" -InformationAction Continue
Write-Information -MessageData "Events Lost: $eventsLost" -InformationAction Continue
Write-Information -MessageData "Buffers Lost: $buffersLost" -InformationAction Continue
Write-Information -MessageData "Buffers Written: $buffersWritten" -InformationAction Continue
Write-Information -MessageData "Trace loss classification: $traceLossClassification" -InformationAction Continue
Write-Information -MessageData "Circular risk classification: $circularRisk" -InformationAction Continue
Write-Information -MessageData "Circular overwrite absence claimed: False" -InformationAction Continue

if ($PassThru) {
    return $result
}
