# NXB-IRL-004 — Storage, File-System and I/O Queue Plan

## Status

`IN PROGRESS — PROFILE VALIDATED — EVIDENCE CONTRACT ACTIVE`

- Tracking issue: `#2`
- Base: `main`
- Branch: `nxb-irl-004-storage-io-queue`
- Parent memory block: merged PR `#9`
- Validated storage profile head: `d88cf5c8c28e4bc63598ca28f221d66896daadc2`
- Profile validation record: `docs/NXB-IRL-004-STORAGE-PROFILE-VALIDATION.md`

GitHub Actions remain intentionally disabled repository-wide. Native validation runs locally on real Windows.

## Objective

Add a bounded storage-observability domain that can correlate disk and file-system activity with the existing experiment, machine, boot, process and thread identity contracts without modifying user data outside an explicitly created temporary fixture.

The domain must distinguish what was actually measured from what is unavailable, unsupported or not yet assessed.

## Validated WPR profile contract

Profile name:

```text
NxbStorageIOQueue
```

Validated system keywords:

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
DiskReadInit
DiskWriteInit
DiskFlushInit
FileCreate
FileRead
FileWrite
FileFlush
FileDelete
FileRename
FileClose
SplitIO
```

The profile exposes File and Memory logging variants. The File variant is bounded to 512 MiB circular output with 1024 KiB buffers and 64 buffers. `KernelQueue` is deliberately excluded because scheduler queue semantics are not storage-device queue semantics.

The native Windows parser corrected the draft keyword name `DiskIOInitialization` to the accepted WPR keyword `DiskIOInit` before canonical validation.

## Storage evidence contract

The first storage summary schema separates event evidence from higher-level performance metrics.

Event classes:

```text
disk_read
disk_write
disk_flush
file_read
file_write
file_flush
file_create
file_close
file_delete
file_rename
split_io
```

Performance metrics are separate evidence objects:

```text
queue_depth
queue_latency_us
service_time_us
throughput_bytes_per_second
iops
```

Every event/metric uses an explicit status model:

```text
measured
unsupported
unavailable
failed
not_assessed
```

No queue depth, queue latency, service time, throughput or IOPS value is synthesized from event presence alone. In schema version 1, semantic claims for those metrics remain false until real ETL field semantics are established in a later validated slice.

The summary binds experiment, machine/boot, target process identity, trace/profile/export/adapter hashes, trace time range, trace-loss/circular-overwrite state, aggregate/per-process events, metric evidence and conservative claims.

## Bounded fixture

The native fixture will operate only inside its own temporary directory and will have hard limits.

Planned upper bounds:

```text
temporary file size: <= 128 MiB
sequential write:    bounded
sequential read:     bounded
random I/O region:   bounded to the fixture file
flush count:         bounded
duration:            bounded
cleanup:             mandatory for owned fixture files
```

The fixture must not enumerate or modify arbitrary user documents, benchmark unrelated drives, fill the disk, disable caching globally, issue destructive storage commands, or change filesystem/device configuration.

## Trace-quality integration

Storage capture must reuse the existing trace-loss/circular-capacity evidence contract.

Required principles:

- missing counters never imply zero;
- native loss is reported separately from storage-domain completeness;
- circular-buffer pressure is not proof of overwrite absence;
- raw ETL remains local;
- normalized/review evidence is bounded;
- exact-head provenance is mandatory for native validation.

## Vertical slices

### Slice 1 — profile foundation

- [x] Add bounded `NxbStorageIOQueue` WPR profile.
- [x] Add safe XML/profile semantic validator.
- [x] Add adversarial profile tests.
- [x] Pass PowerShell 7 validation — 10/10.
- [x] Pass Windows PowerShell 5.1 validation — 10/10.
- [x] Pass native `wpr.exe -profiles` parsing.
- [x] Record canonical exact-head profile validation.

### Slice 2 — storage evidence contract

- [x] Define aggregate/per-process storage summary schema.
- [x] Separate storage event classes from higher-level queue/performance metrics.
- [x] Preserve explicit measured/unsupported/unavailable/failed/not-assessed states.
- [x] Bind summary to experiment/machine/boot/profile/ETL/export/adapter identity.
- [x] Add fail-closed semantic validator.
- [x] Add canonical synthetic fixture.
- [x] Add adversarial Pester contract tests.
- [ ] Pass exact-head PowerShell/Python/schema validation on real Windows.
- [ ] Record canonical evidence-contract validation.

### Slice 3 — ETL/xperf adapter

- [ ] Capture real disk/file event headers.
- [ ] Add streaming normalization for observed headers.
- [ ] Add read/write/flush byte and duration semantics only when directly supported.
- [ ] Add disk/file attribution quality accounting.
- [ ] Add fail-closed duplicate/alias handling.

### Slice 4 — bounded real workload and capture

- [ ] Add temporary storage fixture with strict size/time limits.
- [ ] Run elevated exact-head WPR capture on real Windows.
- [ ] Produce ETL locally.
- [ ] Normalize real storage events.
- [ ] Produce downstream summary in the same exact-head run.
- [ ] Preserve raw ETL locally only.

### Slice 5 — deterministic replay

- [ ] Preserve bounded normalized event export.
- [ ] Replay through repository-native adapter.
- [ ] Require source/replay summary equivalence.
- [ ] Fail closed on adapter or provenance drift.

### Slice 6 — overhead calibration and closeout

- [ ] Run paired control/capture storage fixture calibration.
- [ ] Measure collector effect on fixture duration/throughput and process metrics.
- [ ] Keep production threshold policy `not_declared` until representative evidence exists.
- [ ] Record trace-loss and circular-capacity boundary.
- [ ] Write canonical storage closeout record.

## Immediate next gate

The next mandatory gate is exact-head validation of the **storage ETL evidence contract**: JSON Schema, Python semantic validator, PowerShell wrapper, canonical fixture and adversarial Pester suite.

Do not build the real ETL parser until that contract passes. Do not upgrade queue/performance metrics from `not_assessed` before real Windows ETL headers establish their semantics.

## Completion gate

The storage block is complete only when:

- profile validation is green on supported PowerShell runtimes and native WPR;
- a bounded owned fixture produces real storage ETL;
- real headers have been inspected before normalized semantics are claimed;
- source and replay summaries are provenance-bound;
- overhead is measured by paired control/capture trials;
- raw ETL remains local;
- unsupported evidence is explicit;
- trace completeness is never claimed without direct proof.
