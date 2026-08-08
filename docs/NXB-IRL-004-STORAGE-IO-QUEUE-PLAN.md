# NXB-IRL-004 — Storage, File-System and I/O Queue Plan

## Status

`IN PROGRESS — BLOCKS A+B+C+D VALIDATED — FINAL OVERHEAD CALIBRATION / CLOSEOUT NEXT`

- Tracking issue: `#2`
- Base: `main`
- Branch: `nxb-irl-004-storage-io-queue`
- Parent memory block: merged PR `#9`
- GitHub Actions: intentionally disabled repository-wide
- Authority: native exact-head validation on real Windows

## Validated foundations

Storage WPR profile:

```text
canonical head: d88cf5c8c28e4bc63598ca28f221d66896daadc2
profile: NxbStorageIOQueue
file mode: Circular
maximum file size: 512 MiB
buffer size: 1024 KiB
buffers: 64
KernelQueue: false
```

Validated keywords:

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

Evidence contract head:

```text
4e72e2fdb132f06741575a83da526b6c4875e896
```

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

Higher-level metric evidence remains separate:

```text
queue_depth
queue_latency_us
service_time_us
throughput_bytes_per_second
iops
```

Missing/unobserved evidence is never synthesized as zero.

## Block A+B — canonical end-to-end capture pipeline

Validated source evidence head:

```text
9653f874760fa20112db6ff5d84dfa414eb65b11
```

Result:

```text
repository preflights:             5/5 PASS
trace_loss:                        none
circular_overwrite:                unknown
unique_xperf_headers:              115
storage_candidate_headers:         40
normalized_events:                 35989
target_pid:                        9896
target_summary_rows:               19485
measured_event_classes:            10
process_summaries:                 26
evidence_completeness:             partial
storage_summary_sha256:            9515b1c2d322a557571a9aee018797167fe099c5c1aab62bc26c72b6bf01d4b2
normalized_csv_sha256:             44a63003062186a0f8b9cf5d754fc644193c41f75da3db48a818c11f53ff1301
bridge_manifest_sha256:            39d38c9302042aebbb6c671d86e4ef3637129bc32cac37eede31030e85a018fa
```

Raw ETL, full xperf dumper and path-heavy normalized CSV stay local-only.

## Block C+D — deterministic replay + timing/queue investigation

Validated implementation head:

```text
693ecd9011b6abf389364ff906f4f5cc0155d2d6
```

Validation record:

```text
docs/NXB-IRL-004-STORAGE-BLOCK-C-D-VALIDATION.md
```

Deterministic replay:

```text
replay PS7 / PS5.1:              6/6 + 6/6
ETL accounting PS7 / PS5.1:      7/7 + 7/7
PSScriptAnalyzer:                 0
normalized CSV byte-identical:   true
bridge manifest byte-identical:  true
summary byte-identical:          true
normalized events:               35989
```

Native ETL accounting:

```text
EventsLost:                    0
BuffersLost:                   0
BuffersWritten:                63
trace-loss classification:     no_native_loss_reported
circular utilization ratio:    0.123046875
circular risk classification:  no_risk_observed
circular overwrite state:      unknown
overwrite absence claimed:     false
capture completeness:          not_claimed
```

Disk init/completion structural pairing:

```text
completion rows with IRP:       486
matched pairs:                  256
overall completion coverage:    0.5267489711934157
target-associated pairs:        16

read:   39 / 147 matched
write: 172 / 293 matched
flush:  45 / 46  matched
```

`ElapsedTime`, `DiskSvcTime` and raw init→completion timestamp deltas are observed, but their textual units are unresolved. No directly validated queue-depth field was observed. Structural IRP pairing is not promoted to queue-latency semantics.

## Vertical slices

### Slice 1 — profile foundation

- [x] Add bounded `NxbStorageIOQueue` WPR profile.
- [x] Add semantic validator and adversarial tests.
- [x] Pass PS7 and PS5.1 validation.
- [x] Pass native `wpr.exe` parsing.
- [x] Record canonical exact-head validation.

### Slice 2 — storage evidence contract

- [x] Define normalized event schema.
- [x] Define aggregate/per-process summary schema.
- [x] Separate event evidence from queue/performance metrics.
- [x] Preserve explicit measured/unsupported/unavailable/failed/not-assessed states.
- [x] Bind experiment/machine/boot/profile/ETL/export/adapter identity.
- [x] Add fail-closed validators and canonical fixtures.
- [x] Pass exact-head PowerShell/Python/schema validation.

### Slice 3 — ETL/xperf adapter

- [x] Capture and inspect real disk/file headers.
- [x] Identify native event names/columns.
- [x] Add streaming normalization for observed headers.
- [x] Add disk/file attribution and byte accounting.
- [x] Keep timing/queue semantics unassessed where units/contracts are unresolved.

### Slice 4 — bounded real workload and capture

- [x] Use owned temporary storage fixture with strict limits.
- [x] Run exact-head real WPR capture.
- [x] Produce ETL locally.
- [x] Normalize real storage events.
- [x] Produce downstream schema-valid summary.
- [x] Produce bounded review ZIP excluding raw evidence.

### Slice 5 — deterministic replay / trace-quality / semantics investigation

- [x] Replay full xperf dumper to byte-identical normalized CSV.
- [x] Replay to byte-identical bridge manifest.
- [x] Replay source summary byte-identically.
- [x] Measure native ETL EventsLost/BuffersLost.
- [x] Classify circular capacity risk without overwrite-absence claim.
- [x] Measure DiskRead/Write/Flush init-completion IRP pairing.
- [x] Preserve unresolved timing units and disabled queue/service-time claims.

### Slice 6 — overhead calibration and closeout

- [ ] Implement paired bounded control vs instrumented fixture calibration.
- [ ] Use warmup plus multiple alternating pairs.
- [ ] Measure wall-time overhead and safe process/system overhead indicators.
- [ ] Preserve native trace-loss/circular-capacity accounting for instrumented trials.
- [ ] Keep production threshold policy `not_declared` unless representative evidence supports one.
- [ ] Record exact-head calibration validation.
- [ ] Run final repository diff / duplicate / obsolete-file review.
- [ ] Write canonical storage closeout record.
- [ ] Mark Issue #2 storage item complete.
- [ ] Mark PR #10 ready only after all final gates pass.
- [ ] Merge PR #10 only after exact-head final validation.

## Final conservative claim boundary

Unless independently proven in a later contract:

```text
queue_depth_semantics:            false
queue_latency_semantics:          false
service_time_semantics:           false
throughput_representativeness:    false
iops_representativeness:          false
trace_completeness:               not_claimed
```

## Immediate next gate

The only remaining mandatory storage-development gate is **Slice 6: paired overhead calibration + final closeout**.

The calibration must not reuse uncontrolled user files and must not declare a production threshold from a single run. Control and instrumented trials must execute the same bounded owned-file workload, use an alternating order after warmup, record trial-level provenance, and fail closed on trace-loss evidence or evidence-boundary drift.

## Completion gate

Storage is complete only when paired overhead calibration is recorded, final exact-head repository validation passes, the closeout document is written, Issue #2 storage is checked off, and PR #10 is then reviewed and merged. Raw ETL remains local throughout.