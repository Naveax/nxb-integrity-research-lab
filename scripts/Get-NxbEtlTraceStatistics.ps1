[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [string]$XperfExecutablePath,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [string]$ReportPath,

    [Parameter(DontShow)]
    [scriptblock]$EtlHeaderRecordProvider,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force

function Get-NxbTraceStatisticValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$LabelPatterns
    )

    foreach ($labelPattern in $LabelPatterns) {
        $pattern = '(?i)^\s*' + $labelPattern + '\s*[:=]\s*([0-9][0-9,]*)\s*$'
        foreach ($line in $Lines) {
            $match = [regex]::Match([string]$line, $pattern)
            if ($match.Success) {
                return [uint64]$match.Groups[1].Value.Replace(',', '')
            }
        }
    }
    return $null
}

function Initialize-NxbEtwTraceLogfileHeaderReader {
    [CmdletBinding()]
    param()

    if ($null -ne ('Nxb.EtwTraceLogfileHeaderReader' -as [type])) {
        return
    }

    $typeDefinition = @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;

namespace Nxb
{
    public sealed class EtwTraceLogfileHeaderSnapshot
    {
        public uint BufferSize;
        public uint NumberOfProcessors;
        public uint MaximumFileSize;
        public uint LogFileMode;
        public uint BuffersWritten;
        public uint PointerSize;
        public uint EventsLost;
        public uint BuffersLost;
        public int ConsumerPointerSize;
        public int EventTraceLogfileSize;
        public int LogfileHeaderOffset;
    }

    public static class EtwTraceLogfileHeaderReader
    {
        private const uint ProcessTraceModeEventRecord = 0x10000000;

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        private delegate void EventRecordCallback(IntPtr eventRecord);

        private static readonly EventRecordCallback Callback =
            new EventRecordCallback(IgnoreEvent);

        [DllImport(
            "sechost.dll",
            EntryPoint = "OpenTraceW",
            CharSet = CharSet.Unicode,
            SetLastError = true)]
        private static extern ulong OpenTraceSechost(IntPtr logfile);

        [DllImport(
            "sechost.dll",
            EntryPoint = "CloseTrace",
            SetLastError = true)]
        private static extern uint CloseTraceSechost(ulong traceHandle);

        [DllImport(
            "advapi32.dll",
            EntryPoint = "OpenTraceW",
            CharSet = CharSet.Unicode,
            SetLastError = true)]
        private static extern ulong OpenTraceAdvapi(IntPtr logfile);

        [DllImport(
            "advapi32.dll",
            EntryPoint = "CloseTrace",
            SetLastError = true)]
        private static extern uint CloseTraceAdvapi(ulong traceHandle);

        private static void IgnoreEvent(IntPtr eventRecord)
        {
        }

        private static bool IsInvalidTraceHandle(ulong handle)
        {
            if (IntPtr.Size == 8)
            {
                return handle == UInt64.MaxValue;
            }

            return handle == UInt32.MaxValue;
        }

        private static uint ReadUInt32(IntPtr address, int offset)
        {
            return unchecked((uint)Marshal.ReadInt32(address, offset));
        }

        private static ulong OpenTrace(
            IntPtr logfile,
            out bool usedSechost,
            out int errorCode)
        {
            ulong handle;

            try
            {
                handle = OpenTraceSechost(logfile);
                errorCode = Marshal.GetLastWin32Error();
                usedSechost = true;
                return handle;
            }
            catch (DllNotFoundException)
            {
            }
            catch (EntryPointNotFoundException)
            {
            }

            handle = OpenTraceAdvapi(logfile);
            errorCode = Marshal.GetLastWin32Error();
            usedSechost = false;
            return handle;
        }

        public static EtwTraceLogfileHeaderSnapshot Read(string path)
        {
            if (String.IsNullOrWhiteSpace(path))
            {
                throw new ArgumentException(
                    "ETL path cannot be empty.",
                    "path");
            }

            string fullPath = Path.GetFullPath(path);
            if (!File.Exists(fullPath))
            {
                throw new FileNotFoundException(
                    "ETL file was not found.",
                    fullPath);
            }

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
                byte[] zeroes = new byte[eventTraceLogfileSize];
                Marshal.Copy(
                    zeroes,
                    0,
                    logfile,
                    eventTraceLogfileSize);

                pathPointer = Marshal.StringToHGlobalUni(fullPath);
                Marshal.WriteIntPtr(logfile, 0, pathPointer);
                Marshal.WriteInt32(
                    logfile,
                    processTraceModeOffset,
                    unchecked((int)ProcessTraceModeEventRecord));
                Marshal.WriteIntPtr(
                    logfile,
                    eventRecordCallbackOffset,
                    Marshal.GetFunctionPointerForDelegate(Callback));

                int openError;
                traceHandle = OpenTrace(
                    logfile,
                    out usedSechost,
                    out openError);
                if (IsInvalidTraceHandle(traceHandle))
                {
                    throw new Win32Exception(
                        openError,
                        "OpenTraceW could not open the ETL file.");
                }
                traceOpened = true;

                uint bufferSize = ReadUInt32(
                    logfile,
                    logfileHeaderOffset + 0);
                uint numberOfProcessors = ReadUInt32(
                    logfile,
                    logfileHeaderOffset + 12);
                uint maximumFileSize = ReadUInt32(
                    logfile,
                    logfileHeaderOffset + 28);
                uint logFileMode = ReadUInt32(
                    logfile,
                    logfileHeaderOffset + 32);
                uint buffersWritten = ReadUInt32(
                    logfile,
                    logfileHeaderOffset + 36);
                uint pointerSize = ReadUInt32(
                    logfile,
                    logfileHeaderOffset + 44);
                uint eventsLost = ReadUInt32(
                    logfile,
                    logfileHeaderOffset + 48);
                uint buffersLost = ReadUInt32(
                    logfile,
                    logfileHeaderOffset + buffersLostOffset);

                if (bufferSize == 0 || numberOfProcessors == 0)
                {
                    throw new InvalidDataException(
                        "TRACE_LOGFILE_HEADER has invalid buffer or processor metadata.");
                }
                if (pointerSize != 4 && pointerSize != 8)
                {
                    throw new InvalidDataException(
                        "TRACE_LOGFILE_HEADER has an invalid pointer-size marker.");
                }

                EtwTraceLogfileHeaderSnapshot result =
                    new EtwTraceLogfileHeaderSnapshot();
                result.BufferSize = bufferSize;
                result.NumberOfProcessors = numberOfProcessors;
                result.MaximumFileSize = maximumFileSize;
                result.LogFileMode = logFileMode;
                result.BuffersWritten = buffersWritten;
                result.PointerSize = pointerSize;
                result.EventsLost = eventsLost;
                result.BuffersLost = buffersLost;
                result.ConsumerPointerSize = IntPtr.Size;
                result.EventTraceLogfileSize = eventTraceLogfileSize;
                result.LogfileHeaderOffset = logfileHeaderOffset;

                uint closeResult = usedSechost
                    ? CloseTraceSechost(traceHandle)
                    : CloseTraceAdvapi(traceHandle);
                traceOpened = false;
                if (closeResult != 0)
                {
                    throw new Win32Exception(
                        unchecked((int)closeResult),
                        "CloseTrace could not close the ETL trace handle.");
                }

                return result;
            }
            finally
            {
                if (traceOpened)
                {
                    try
                    {
                        if (usedSechost)
                        {
                            CloseTraceSechost(traceHandle);
                        }
                        else
                        {
                            CloseTraceAdvapi(traceHandle);
                        }
                    }
                    catch
                    {
                    }
                }

                if (pathPointer != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(pathPointer);
                }
                if (logfile != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(logfile);
                }

                GC.KeepAlive(Callback);
            }
        }
    }
}
'@

    Add-Type `
        -TypeDefinition $typeDefinition `
        -Language CSharp `
        -ErrorAction Stop
}

function Get-NxbEtlHeaderSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-f]{64}$')]
        [string]$EtlSha256,

        [Parameter()]
        [AllowNull()]
        [scriptblock]$RecordProvider
    )

    $eventId = 0
    $providerName = $null
    $propertyCount = 21
    $readerName = $null
    $bufferSize = $null
    $processorCount = $null
    $maximumFileSize = $null
    $logFileMode = $null
    $buffersWritten = $null
    $pointerSize = $null
    $eventsLost = $null
    $buffersLost = $null
    $consumerPointerSize = [IntPtr]::Size
    $eventTraceLogfileSize = $null
    $logfileHeaderOffset = $null

    if ($null -ne $RecordProvider) {
        $records = @(& $RecordProvider $Path)
        foreach ($record in $records) {
            $properties = @($record.Properties)
            if ([int]$record.Id -ne 0 -or $properties.Count -lt 21) {
                continue
            }

            try {
                $bufferSize = [uint64]$properties[0].Value
                $processorCount = [uint64]$properties[3].Value
                $maximumFileSize = [uint64]$properties[6].Value
                $logFileMode = [uint64]$properties[7].Value
                $buffersWritten = [uint64]$properties[8].Value
                $pointerSize = [uint64]$properties[10].Value
                $eventsLost = [uint64]$properties[11].Value
                $buffersLost = [uint64]$properties[20].Value
            }
            catch {
                continue
            }

            $providerName = [string]$record.ProviderName
            $propertyCount = $properties.Count
            $readerName = 'injected-record-provider'
            break
        }
    }
    else {
        Initialize-NxbEtwTraceLogfileHeaderReader
        try {
            $nativeHeader = [Nxb.EtwTraceLogfileHeaderReader]::Read($Path)
        }
        catch {
            throw "OpenTraceW TRACE_LOGFILE_HEADER okuması başarısız: $($_.Exception.Message)"
        }

        $bufferSize = [uint64]$nativeHeader.BufferSize
        $processorCount = [uint64]$nativeHeader.NumberOfProcessors
        $maximumFileSize = [uint64]$nativeHeader.MaximumFileSize
        $logFileMode = [uint64]$nativeHeader.LogFileMode
        $buffersWritten = [uint64]$nativeHeader.BuffersWritten
        $pointerSize = [uint64]$nativeHeader.PointerSize
        $eventsLost = [uint64]$nativeHeader.EventsLost
        $buffersLost = [uint64]$nativeHeader.BuffersLost
        $consumerPointerSize = [int]$nativeHeader.ConsumerPointerSize
        $eventTraceLogfileSize = [int]$nativeHeader.EventTraceLogfileSize
        $logfileHeaderOffset = [int]$nativeHeader.LogfileHeaderOffset
        $providerName = 'OpenTraceW/TRACE_LOGFILE_HEADER'
        $readerName = 'OpenTraceW'
    }

    if ($null -eq $bufferSize -or
        $null -eq $processorCount -or
        $null -eq $buffersWritten -or
        $null -eq $eventsLost -or
        $null -eq $buffersLost) {
        throw 'ETL TRACE_LOGFILE_HEADER veya gerekli native sayaç alanları bulunamadı.'
    }
    if ($bufferSize -eq 0 -or $processorCount -eq 0) {
        throw 'ETL TRACE_LOGFILE_HEADER temel metadata alanları geçersiz.'
    }

    $material = [ordered]@{
        schema_version = 1
        etl_sha256 = $EtlSha256
        reader = $readerName
        event_id = $eventId
        provider_name = $providerName
        property_count = $propertyCount
        buffer_size = $bufferSize
        processor_count = $processorCount
        maximum_file_size = $maximumFileSize
        log_file_mode = $logFileMode
        buffers_written = $buffersWritten
        trace_pointer_size = $pointerSize
        consumer_pointer_size = $consumerPointerSize
        event_trace_logfile_size = $eventTraceLogfileSize
        logfile_header_offset = $logfileHeaderOffset
        events_lost = $eventsLost
        buffers_lost = $buffersLost
    }
    $snapshotJson = $material | ConvertTo-Json -Depth 16 -Compress
    $snapshotSha = [Security.Cryptography.SHA256]::Create()
    try {
        $snapshotHash = ([BitConverter]::ToString(
            $snapshotSha.ComputeHash(
                [Text.Encoding]::UTF8.GetBytes($snapshotJson)
            )
        )).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $snapshotSha.Dispose()
    }

    return [pscustomobject]@{
        SnapshotSha256 = $snapshotHash
        EventsLost = $eventsLost
        BuffersLost = $buffersLost
        BuffersWritten = $buffersWritten
        Material = [pscustomobject]$material
    }
}

function Get-NxbStatisticEvidence {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Source,

        [Parameter(Mandatory)]
        [ValidateSet('measured', 'unsupported', 'unavailable', 'failed')]
        [string]$FallbackStatus,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FallbackReason
    )

    if ($null -ne $Value) {
        return [ordered]@{
            status = 'measured'
            value = [uint64]$Value
            source = $Source
            reason = $null
        }
    }

    return [ordered]@{
        status = $FallbackStatus
        value = $null
        source = if ($FallbackStatus -eq 'unavailable') { $Source } else { $null }
        reason = $FallbackReason
    }
}

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
[void](Test-NxbPathSafety -Path $experimentFull -RootPath $experimentFull)
$etlPath = Join-Path $experimentFull 'traces\performance.etl'
if (-not (Test-Path -LiteralPath $etlPath -PathType Leaf)) {
    throw "ETL bulunamadı: $etlPath"
}
[void](Test-NxbPathSafety -Path $etlPath -RootPath $experimentFull)
$etlSha256 = (Get-FileHash -LiteralPath $etlPath -Algorithm SHA256).Hash.ToLowerInvariant()

$analysisRoot = Join-Path $experimentFull 'analysis'
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $analysisRoot 'etl-trace-statistics.json'
}
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $analysisRoot 'xperf-tracestats.txt'
}
$outputFull = Get-NxbFullPath -Path $OutputPath
$reportFull = Get-NxbFullPath -Path $ReportPath
[void](Get-NxbRelativePath -BasePath $experimentFull -ChildPath $outputFull)
[void](Get-NxbRelativePath -BasePath $experimentFull -ChildPath $reportFull)
if ($outputFull.Equals($reportFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ETL statistics JSON ve xperf rapor yolları aynı olamaz.'
}
foreach ($path in @($outputFull, $reportFull)) {
    if (Test-Path -LiteralPath $path) {
        throw "ETL trace statistics çıktısı zaten var: $path"
    }
    $parent = Split-Path -Parent $path
    if (Test-Path -LiteralPath $parent -PathType Container) {
        [void](Test-NxbPathSafety -Path $parent -RootPath $experimentFull)
    }
}

if (-not $PSCmdlet.ShouldProcess(
    $experimentFull,
    'Collect and write post-stop ETL trace statistics'
)) {
    return
}

if (-not (Test-Path -LiteralPath $analysisRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $analysisRoot -Force | Out-Null
}
[void](Test-NxbPathSafety -Path $analysisRoot -RootPath $experimentFull)

$xperfPath = $null
$resolveFailure = $null
try {
    $xperfPath = Resolve-NxbExecutablePath `
        -Name 'xperf.exe' `
        -ExplicitPath $XperfExecutablePath
}
catch {
    $resolveFailure = $_.Exception.Message
}

$xperfArguments = @(
    '-i', $etlPath,
    '-o', $reportFull,
    '-a', 'tracestats',
    '-timespan'
)
$xperfExitCode = $null
$commandOutput = @()
if ($null -ne $xperfPath) {
    $previousErrorActionPreference = $ErrorActionPreference
    $nativePreferenceVariable = Get-Variable `
        -Name PSNativeCommandUseErrorActionPreference `
        -ErrorAction SilentlyContinue
    $nativePreferenceAvailable = $null -ne $nativePreferenceVariable
    $previousNativePreference = if ($nativePreferenceAvailable) {
        [bool]$nativePreferenceVariable.Value
    }
    else {
        $null
    }

    try {
        $ErrorActionPreference = 'Continue'
        if ($nativePreferenceAvailable) {
            Set-Variable `
                -Name PSNativeCommandUseErrorActionPreference `
                -Value $false `
                -Scope Local
        }
        $commandOutput = @(& $xperfPath @xperfArguments 2>&1)
        $xperfExitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($nativePreferenceAvailable) {
            Set-Variable `
                -Name PSNativeCommandUseErrorActionPreference `
                -Value $previousNativePreference `
                -Scope Local
        }
    }
}

$reportLines = if (Test-Path -LiteralPath $reportFull -PathType Leaf) {
    @(Get-Content -LiteralPath $reportFull)
}
else {
    @()
}
$combinedLines = @(
    @($commandOutput | ForEach-Object { [string]$_ })
    $reportLines
)
$combinedText = $combinedLines -join [Environment]::NewLine
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $xperfStatisticsHash = ([BitConverter]::ToString(
        $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($combinedText))
    )).Replace('-', '').ToLowerInvariant()
}
finally {
    $sha.Dispose()
}

$xperfEventsLost = Get-NxbTraceStatisticValue `
    -Lines $combinedLines `
    -LabelPatterns @('Events\s+Lost', 'Lost\s+Events')
$xperfBuffersLost = Get-NxbTraceStatisticValue `
    -Lines $combinedLines `
    -LabelPatterns @('Buffers\s+Lost', 'Lost\s+Buffers')
$xperfBuffersWritten = Get-NxbTraceStatisticValue `
    -Lines $combinedLines `
    -LabelPatterns @('Buffers\s+Written', 'Written\s+Buffers')
$xperfComplete = (
    $null -ne $xperfEventsLost -and
    $null -ne $xperfBuffersLost -and
    $null -ne $xperfBuffersWritten
)

$headerSnapshot = $null
$headerFailure = $null
if (-not $xperfComplete) {
    try {
        $headerSnapshot = Get-NxbEtlHeaderSnapshot `
            -Path $etlPath `
            -EtlSha256 $etlSha256 `
            -RecordProvider $EtlHeaderRecordProvider
    }
    catch {
        $headerFailure = $_.Exception.Message
    }
}

if ($null -ne $headerSnapshot) {
    $eventsLostValue = [uint64]$headerSnapshot.EventsLost
    $buffersLostValue = [uint64]$headerSnapshot.BuffersLost
    $buffersWrittenValue = [uint64]$headerSnapshot.BuffersWritten
    $statisticsHash = [string]$headerSnapshot.SnapshotSha256
    $source = "etl_header_snapshot:$statisticsHash"
    $status = 'measured'
    $adapterExitCode = 0
    $fallbackStatus = 'unavailable'
    $fallbackReason = 'ETL TRACE_LOGFILE_HEADER alanında bu sayaç bulunamadı.'
    $command = [ordered]@{
        executable = if ($null -eq $EtlHeaderRecordProvider) {
            'OpenTraceW'
        }
        else {
            'injected-etl-header-reader'
        }
        arguments = if ($null -eq $EtlHeaderRecordProvider) {
            @('-LogFileName', $etlPath)
        }
        else {
            @('-Path', $etlPath)
        }
    }
    $counterSource = 'etl_header_snapshot'
}
else {
    $eventsLostValue = $xperfEventsLost
    $buffersLostValue = $xperfBuffersLost
    $buffersWrittenValue = $xperfBuffersWritten
    $statisticsHash = $xperfStatisticsHash
    $source = "xperf_tracestats:$statisticsHash"
    $command = [ordered]@{
        executable = $xperfPath
        arguments = $xperfArguments
    }
    $counterSource = 'xperf_tracestats'

    if ($null -eq $xperfPath) {
        $fallbackStatus = 'unsupported'
        $fallbackReason = (
            "xperf.exe kullanılamıyor: $resolveFailure; " +
            "ETL header fallback başarısız: $headerFailure"
        )
        $status = 'unsupported'
        $adapterExitCode = $null
    }
    elseif ($xperfExitCode -ne 0) {
        $fallbackStatus = 'failed'
        $fallbackReason = (
            "xperf tracestats başarısız oldu (exit $xperfExitCode); " +
            "ETL header fallback başarısız: $headerFailure"
        )
        $status = 'failed'
        $adapterExitCode = $xperfExitCode
    }
    elseif ($null -eq $eventsLostValue -and
        $null -eq $buffersLostValue -and
        $null -eq $buffersWrittenValue) {
        $fallbackStatus = 'unavailable'
        $fallbackReason = (
            'xperf tracestats çıktısında beklenen trace-header sayaçları bulunamadı; ' +
            "ETL header fallback başarısız: $headerFailure"
        )
        $status = 'unavailable'
        $adapterExitCode = 0
    }
    else {
        $fallbackStatus = 'unavailable'
        $fallbackReason = 'Bu sayaç xperf tracestats çıktısında bulunamadı.'
        $status = 'measured'
        $adapterExitCode = 0
    }
}

$statistics = [ordered]@{
    schema_version = 1
    captured_utc = [DateTime]::UtcNow.ToString('o')
    experiment_id = [string](Split-Path -Leaf $experimentFull)
    status = $status
    counter_source = $counterSource
    command = $command
    exit_code = $adapterExitCode
    statistics_sha256 = $statisticsHash
    etl_sha256 = $etlSha256
    xperf = [ordered]@{
        executable = $xperfPath
        arguments = $xperfArguments
        exit_code = $xperfExitCode
        statistics_sha256 = $xperfStatisticsHash
        report_path = $reportFull
    }
    etl_header = if ($null -eq $headerSnapshot) {
        [ordered]@{
            status = 'unavailable'
            snapshot_sha256 = $null
            reason = $headerFailure
        }
    }
    else {
        [ordered]@{
            status = 'measured'
            snapshot_sha256 = [string]$headerSnapshot.SnapshotSha256
            material = $headerSnapshot.Material
            reason = $null
        }
    }
    events_lost = Get-NxbStatisticEvidence `
        -Value $eventsLostValue `
        -Source "$source;field=events_lost" `
        -FallbackStatus $fallbackStatus `
        -FallbackReason $fallbackReason
    buffers_lost = Get-NxbStatisticEvidence `
        -Value $buffersLostValue `
        -Source "$source;field=buffers_lost" `
        -FallbackStatus $fallbackStatus `
        -FallbackReason $fallbackReason
    buffers_written = Get-NxbStatisticEvidence `
        -Value $buffersWrittenValue `
        -Source "$source;field=buffers_written" `
        -FallbackStatus $fallbackStatus `
        -FallbackReason $fallbackReason
    realtime_buffers_lost = [ordered]@{
        status = 'not_applicable'
        value = $null
        source = $null
        reason = 'File-mode ETL gerçek zamanlı consumer teslimatı kullanmıyor.'
    }
}

Write-NxbJsonAtomic -Path $outputFull -InputObject $statistics -Depth 20

if ($PassThru) {
    return [pscustomobject]$statistics
}
Write-Output $outputFull
