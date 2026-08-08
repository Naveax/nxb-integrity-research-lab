# NXB-IRL-004 — Storage, File-System and I/O Queue Plan

## Status

`IN PROGRESS — PROFILE FOUNDATION`

- Tracking issue: `#2`
- Base: `main`
- Branch: `nxb-irl-004-storage-io-queue`
- Parent memory block: merged PR `#9`

GitHub Actions remain intentionally disabled repository-wide. Native validation will run locally on real Windows.

## Objective

Add a bounded storage-observability domain that can correlate disk and file-system activity with the existing experiment, machine, boot, process and thread identity contracts without modifying user data outside an explicitly created temporary fixture.

The domain must distinguish what was actually measured from what is unavailable, unsupported or not yet assessed.

## Initial WPR profile contract

Profile name:

```text
NxbStorageIOQueue
```

Minimal system keywords:

```text
DiskIO
DiskIOInitialization
FileIO
FileIOInit
Filename
Loader
ProcessThread
SplitIO
```

Initial stackwalk set:

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

The profile will expose File and Memory logging variants. The File variant remains bounded with an explicit circular maximum size; the Memory variant exists for native profile compatibility/testing and is not the canonical long-running capture path.

## Evidence boundary

The first normalized storage contract is expected to represent, only when supported by real captured events:

```text
storage_read
storage_write
storage_flush
file_read
file_write
file_create
file_delete
file_rename
file_flush
split_io
```

Candidate fields include:

- timestamp and duration when directly derivable,
- process/thread attribution,
- disk/volume/device identity when exposed,
- file identity/path only from captured kernel evidence,
- offset and transfer size when exposed,
- operation/result state when exposed,
- queue/dispatch/service timing only after real event-header semantics are verified.

No queue depth, queue latency, service time, throughput or IOPS value is synthesized from incomplete event coverage.

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

- [ ] Add bounded `NxbStorageIOQueue` WPR profile.
- [ ] Add safe XML/profile semantic validator.
- [ ] Add adversarial profile tests.
- [ ] Pass PowerShell 7 validation.
- [ ] Pass Windows PowerShell 5.1 validation.
- [ ] Pass native `wpr.exe -profiles` parsing.

### Slice 2 — storage evidence contract

- [ ] Define normalized storage event contract.
- [ ] Define aggregate/per-process storage summary schema.
- [ ] Preserve explicit measured/unsupported/unavailable/failed/not-assessed states.
- [ ] Bind summary to experiment/machine/boot/profile/ETL/adapter identity.

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

The next mandatory gate is the **bounded storage WPR profile plus strict repository validator**. Do not build the ETL parser before native WPR profile parsing succeeds.

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
