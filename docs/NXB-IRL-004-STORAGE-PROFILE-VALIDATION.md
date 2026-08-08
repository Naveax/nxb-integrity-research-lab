# NXB-IRL-004 Storage Profile Validation

## Status

`PASSED — REAL WINDOWS PROFILE FOUNDATION VALIDATED`

Validated exact implementation head:

```text
d88cf5c8c28e4bc63598ca28f221d66896daadc2
```

Profile SHA-256:

```text
5ef91311d5c56b39b455714922d5dab3eabf1c0580ed0f8bce607790b8d6c97e
```

Branch:

```text
nxb-irl-004-storage-io-queue
```

## Native Windows validation

The exact-head validation was executed locally on real Windows with PowerShell 7.6.4 and Windows PowerShell 5.1.

Results:

```text
PowerShell parser:            PASS
PSScriptAnalyzer:             0 Warning/Error findings
PowerShell 7 Pester:          10/10 passed
Windows PowerShell 5.1:       10/10 passed
Native wpr.exe profile parse: PASS
```

No GitHub Actions result is used as validation authority; repository workflows remain intentionally disabled.

## Validated bounded collector contract

```text
profile:               NxbStorageIOQueue
buffer_size_kib:       1024
buffers:               64
maximum_file_size_mib: 512
file_mode:             Circular
logging_variants:      Verbose.File + Verbose.Memory
KernelQueue enabled:   false
```

Validated kernel keyword set:

```text
DiskIO
DiskIOInit
FileIO
FileIOInit
Filename
Loader
ProcessThread
SplitIO
```

Validated stackwalk set:

```text
DiskFlushInit
DiskReadInit
DiskWriteInit
FileClose
FileCreate
FileDelete
FileFlush
FileRead
FileRename
FileWrite
SplitIO
```

## Validation corrections discovered on Windows

Two pre-native issues were corrected before this canonical pass:

1. `PSUseBOMForUnicodeEncodedFile` required UTF-8 BOM for the non-ASCII PowerShell validator/test sources. The repair changed only the encoding marker and preserved payload bytes.
2. Native `wpr.exe` rejected the draft keyword `DiskIOInitialization`. The Windows WPR schema exposed the accepted keyword `DiskIOInit`; the profile, validator and tests were updated atomically to that native spelling.

The canonical head above includes both corrections.

## Evidence boundary

This validation proves the bounded WPR profile contract and native profile parse only. It does **not** yet prove storage event payload semantics.

Until a real ETL is captured and its event/header fields are inspected, the following remain unclaimed:

```text
queue_depth:                 not_assessed
queue_latency:               not_assessed
service_time:                not_assessed
throughput:                  not_assessed
IOPS:                        not_assessed
trace_completeness:          not_claimed
storage_queue_semantics:     not_claimed
```

`KernelQueue` remains deliberately excluded because scheduler/kernel queue semantics must not be relabeled as storage-device queue semantics.

## Next gate

Proceed to the storage event/summary evidence contract. The contract must represent measured, unsupported, unavailable, failed and not-assessed evidence explicitly and must never synthesize missing event classes or metrics as zero.
