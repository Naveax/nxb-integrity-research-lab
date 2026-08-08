# NXB-IRL-004 — Storage Block C+D Validation

## Status

`VALIDATED`

Implementation / validation head:

```text
693ecd9011b6abf389364ff906f4f5cc0155d2d6
```

Preserved canonical Block A+B evidence head:

```text
9653f874760fa20112db6ff5d84dfa414eb65b11
```

The C+D run reused the preserved Block A+B local raw evidence. It did not perform a new WPR capture.

## Block C — deterministic replay

Repository-native replay preflight:

```text
PowerShell 7 Pester:       6/6
Windows PowerShell 5.1:    6/6
PSScriptAnalyzer:          0 findings
byte-identical required:   true
semantic-only sufficient:  false
```

Real replay result:

```text
normalized_event_count:          35989
normalized CSV byte-identical:   true
bridge manifest byte-identical:  true
summary byte-identical:          true
source/replay summary SHA-256:   9515b1c2d322a557571a9aee018797167fe099c5c1aab62bc26c72b6bf01d4b2
measured event classes:          10
measured metrics:                0
split_io:                        not_assessed
parser completeness:             partial
evidence completeness:           partial
trace_loss:                      none
circular_overwrite:              unknown
```

The first C+D attempt exposed a deterministic-replay orchestration defect: the real-summary runner regenerated a different `experiment_id`, which changed `summary_id` and therefore the summary bytes without changing event/accounting semantics. The fix added optional `-ExperimentId` support to the real-summary runner and made downstream replay preserve the source summary `experiment_id`. Regression coverage remains in the six-test downstream replay suite.

## Native ETL header accounting

Local validation:

```text
PowerShell 7 Pester:       7/7
Windows PowerShell 5.1:    7/7
PSScriptAnalyzer:          0 findings
native header source:      OpenTraceW / TRACE_LOGFILE_HEADER
```

Real canonical ETL accounting:

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

`no_risk_observed` is a capacity-risk classification only. It is not converted into a circular-overwrite absence claim.

## Block D — timing / queue structural investigation

The validated native headers contain the required DiskIO init/completion families and IRP identifiers. Structural pairing was measured without promoting unresolved timing or queue semantics.

Aggregate result:

```text
completion rows with IRP:       486
matched init/completion pairs:  256
completion pairing coverage:    0.5267489711934157
target-associated pairs:        16
all required headers observed:  true
```

Per family:

```text
DiskReadInit  ↔ DiskRead
  init:                    39
  completion:              147
  matched:                 39
  unmatched init:          0
  unmatched completion:    108
  completion coverage:     0.2653061224489796
  target-associated:       5

DiskWriteInit ↔ DiskWrite
  init:                    172
  completion:              293
  matched:                 172
  unmatched init:          0
  unmatched completion:    121
  completion coverage:     0.5870307167235495
  target-associated:       10

DiskFlushInit ↔ DiskFlush
  init:                    45
  completion:              46
  matched:                 45
  unmatched init:          0
  unmatched completion:    1
  completion coverage:     0.9782608695652174
  target-associated:       1
```

For all three families:

- negative timestamp-delta count was zero;
- reused-IRP candidate count was zero;
- raw init-to-completion timestamp deltas were observable;
- `ElapsedTime` was observable;
- `DiskSvcTime` was observable;
- no directly validated queue-depth field was observed;
- textual timing units remain unresolved.

The raw distributions are retained only as unit-unresolved evidence. They are not promoted to microseconds or to queue/service-time metrics.

## Conservative boundary retained

```text
queue_depth_semantics:            false
queue_latency_semantics:          false
service_time_semantics:           false
throughput_representativeness:    false
iops_representativeness:          false
trace_completeness:               not_claimed
```

## Review evidence

```text
review ZIP SHA-256:
a6f7070c4820df1d42155b3f5376f30d6cbaa149b630d7eb862d9c79bd4bccbd

timing/queue investigation SHA-256:
d42c789bc3e9ddbdd0cb3f2a2b5566be79de235887791c8bd7ed333603d561a0

ETL accounting SHA-256:
de608ef06b0f66f3b77569cb3c6d33b6d60a6b24d89d48dc919fc691b8346338
```

The review ZIP contains only bounded JSON evidence. It excludes raw ETL, full xperf dumper, normalized CSV, raw event rows, file paths and IRP values.

## Next gate

Storage Slice 6 remains: paired control/capture overhead calibration followed by final storage closeout. Timing/queue/service-time/representative throughput/IOPS must remain unassessed unless a later independent contract resolves those semantics.