# NXB-IRL-004 — Real Storage ETL / Xperf Header Probe Validation

## Status

`VALIDATED`

Canonical real header-probe head:

```text
c4e6b8cc435fe700acfa0a5d17c50684a00052d3
```

## Native Windows result

```text
Pester:                         11/11
PSScriptAnalyzer findings:      0
Native wpr.exe profile parse:   PASS
KernelQueue enabled:            False
Real bounded capture:           PASS
Trace loss:                     none
Circular overwrite:             unknown
Unique xperf headers:           115
Storage-candidate headers:      40
```

Bounded workload:

```text
owned temporary file: 4 MiB
block size:            256 KiB
operations:            write / durable flush / read / rename / delete
```

Raw ETL and the full xperf dumper remain local-only.

## Directly observed fields

`DiskRead` / `DiskWrite` expose:

```text
TimeStamp
Process Name ( PID)
ThreadID
CPU
IrpPtr
ByteOffset
IOSize
ElapsedTime
DiskNum
IrpFlags
DiskSvcTime
I/O Pri
VolSnap
FileObject
FileName
```

`DiskFlush` exposes:

```text
TimeStamp
Process Name ( PID)
ThreadID
CPU
IrpPtr
ElapsedTime
DiskNum
IrpFlags
DiskSvcTime
I/O Pri
```

`FileIoRead` / `FileIoWrite` expose:

```text
TimeStamp
Process Name ( PID)
ThreadID
LoggingProcessName ( PID)
LoggingThreadID
CPU
IrpPtr
FileObject
ByteOffset
Size
Flags
ExtraFlags
Priority
FileName
ParsedFlags
```

Observed file-system lifecycle headers also include `FileIoCreate`, `FileIoClose`, `FileIoFlush`, `FileIoDelete`, `FileIoRename` and `FileIoOpEnd`.

## Conservative semantic boundary

The real header evidence supports direct parsing of byte offset, transfer size, PID/TID, disk number and file object/path for the event types that expose those columns.

Timing conversion is intentionally unresolved in the next raw bridge. Xperf documentation across current and legacy references disagrees on dump timestamp units, so `TimeStamp`, `ElapsedTime` and `DiskSvcTime` are retained as raw text until unit semantics are independently locked.

The following claims remain disabled:

```text
queue_depth_semantics:            false
queue_latency_semantics:          false
service_time_semantics:           false
throughput_representativeness:    false
iops_representativeness:          false
trace_completeness:               not_claimed
```

## Next gate

Raw storage bridge implementation is now present after this validated capture. It must be validated on an exact clean implementation head and then replay the preserved local xperf dumper. The bridge is permitted to normalize only directly observed integer/identity fields while preserving timing values as raw, unit-unresolved evidence.
