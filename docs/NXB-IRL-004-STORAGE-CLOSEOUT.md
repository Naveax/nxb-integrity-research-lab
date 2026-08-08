# NXB-IRL-004 Storage Observability Closeout

## Status

The bounded disk / file-system / storage-I/O observability block is complete and ready to merge through PR #10.

Native Windows exact-head validation remains authoritative. GitHub Actions remain intentionally disabled repository-wide.

## Canonical validated implementation head

```text
38f60e972016866f037b1b2c7bf64994c48963db
```

This is the exact implementation head used for the final Block E repository validation and paired overhead calibration.

## Foundation

Profile:

```text
NxbStorageIOQueue
profile SHA-256: 5ef91311d5c56b39b455714922d5dab3eabf1c0580ed0f8bce607790b8d6c97e
KernelQueue: false
keywords: DiskIO, DiskIOInit, FileIO, FileIOInit, Filename, Loader, ProcessThread, SplitIO
```

Storage-device queue semantics are not inferred from scheduler `KernelQueue`.

The normalized evidence contract preserves explicit states such as `measured`, `unsupported`, `unavailable`, `failed` and `not_assessed`; missing or unobserved data is never synthesized as zero.

## Canonical real capture and summary — Block A+B

Canonical capture/evidence head:

```text
9653f874760fa20112db6ff5d84dfa414eb65b11
```

Observed result:

```text
trace_loss:                  none
circular_overwrite:          unknown
normalized_events:           35989
target_pid:                  9896
target_summary_rows:         19485
measured_event_classes:      10
process_summaries:           26
evidence_completeness:       partial
```

Canonical hashes:

```text
storage summary:   9515b1c2d322a557571a9aee018797167fe099c5c1aab62bc26c72b6bf01d4b2
normalized CSV:    44a63003062186a0f8b9cf5d754fc644193c41f75da3db48a818c11f53ff1301
bridge manifest:   39d38c9302042aebbb6c671d86e4ef3637129bc32cac37eede31030e85a018fa
review ZIP:        77a760469b5c0093ac14b34527b6b9df29f0dbdcee40943f1274ebf64f8f8311
```

Raw ETL, the full xperf dumper and path-heavy normalized CSV remain local only.

## Deterministic replay and native trace accounting — Block C+D

Implementation / validation head:

```text
693ecd9011b6abf389364ff906f4f5cc0155d2d6
```

Deterministic replay:

```text
normalized CSV byte-identical:    true
bridge manifest byte-identical:   true
summary byte-identical:           true
source/replay summary SHA-256:     9515b1c2d322a557571a9aee018797167fe099c5c1aab62bc26c72b6bf01d4b2
```

The initial downstream-replay orchestration defect that regenerated a different `experiment_id` was corrected. Replay now preserves source summary identity and the regression is covered by the replay contract tests.

Native ETL accounting on the canonical C+D evidence:

```text
EventsLost:                     0
BuffersLost:                    0
BuffersWritten:                 63
trace-loss classification:      no_native_loss_reported
circular utilization ratio:     0.123046875
circular risk classification:   no_risk_observed
circular overwrite state:       unknown
overwrite absence claimed:      false
trace completeness:             not_claimed
```

`no_risk_observed` is a bounded capacity-risk classification only. It is not promoted to a claim that circular overwrite did not occur.

IRP init/completion structural evidence:

```text
required headers observed:       true
completion rows with IRP:        486
matched IRP pairs:               256
overall completion coverage:     0.5267489711934157
target-associated pairs:         16
```

Per family:

```text
read:   39 / 147 matched    coverage 0.2653061224489796
write: 172 / 293 matched    coverage 0.5870307167235495
flush:  45 / 46 matched     coverage 0.9782608695652174
```

Raw init-to-completion timestamp deltas, `ElapsedTime` and `DiskSvcTime` are observable, but their promoted textual timing units remain unresolved. IRP correlation is not treated as proof of storage-device queue residency or queue latency.

C+D bounded review ZIP SHA-256:

```text
a6f7070c4820df1d42155b3f5376f30d6cbaa149b630d7eb862d9c79bd4bccbd
```

## Paired overhead calibration and final gate — Block E

Final validated implementation head:

```text
38f60e972016866f037b1b2c7bf64994c48963db
```

Final repository gate:

```text
Pester:                         133/133
failed:                         0
skipped:                        0
PSScriptAnalyzer findings:      0
native WPR profile parse:       PASS
obsolete duplicate paths:      absent
```

Calibration schedule:

```text
warmup pairs:                   1
measured pairs:                 4
alternating order:              true
fixture size:                   4 MiB
block size:                     256 KiB
cache state controlled:         false
```

Measured pair results:

| Pair | Order | Control ms | Instrumented ms | Fixture overhead |
|---:|---|---:|---:|---:|
| 1 | control → instrumented | 41.033 | 43.819 | 6.789657% |
| 2 | instrumented → control | 41.904 | 43.162 | 3.002100% |
| 3 | control → instrumented | 36.715 | 41.959 | 14.282991% |
| 4 | instrumented → control | 41.918 | 44.165 | 5.360466% |

Aggregate bounded calibration:

```text
median fixture duration delta:      2.5165 ms
median fixture duration ratio:      1.060750614
median fixture overhead:            6.0750614%
median process CPU delta:            46.875 ms
median peak working-set delta:       0 bytes
instrumented native-loss-free:       4/4
production threshold policy:         not_declared
representative benchmark claimed:    false
```

Every measured instrumented pair reported:

```text
EventsLost:             0
BuffersLost:            0
circular risk:          no_risk_observed
```

The measured 6.075% median fixture overhead is a result of this bounded calibration only. It is not declared as representative production overhead and no pass/fail production threshold is derived from it.

Block E evidence hashes:

```text
storage overhead calibration: 214fe3782d8c774a5362cf99ffc4a13f97347890b6b68327629ecc3fafa5ec78
final validation receipt:     b953cf55bbc993b11aa84f30b6314df488eae7c4fa2dd3fffb42dec8455ebb17
review ZIP:                   558494372c6268eb836506e68d6f540b49a2b11aa4eefe629ad29b2b2b94ea62
```

The bounded Block E review ZIP contains only the calibration JSON, final-validation receipt and hash manifest. Calibration ETLs remain local only.

## Final claim boundary

The storage block closes with these claims intentionally disabled:

```text
queue_depth_semantics:            false
queue_latency_semantics:          false
service_time_semantics:           false
throughput_representativeness:    false
iops_representativeness:          false
trace_completeness:               not_claimed
circular_overwrite_absence:       false
```

This is the final evidence boundary, not an unfinished implementation defect. Any future promotion of those metrics requires independently validated semantics and units.

## Closeout decision

The storage domain now has:

- a bounded native WPR profile;
- safe owned-file fixture coverage;
- real elevated WPR/xperf evidence;
- normalized event and summary contracts;
- explicit attribution/completeness accounting;
- deterministic byte-identical downstream replay;
- native ETL loss/circular-risk accounting;
- structural IRP init/completion evidence;
- paired alternating overhead calibration;
- fail-closed exact-head validation and conservative evidence claims.

NXB-IRL-004 storage is therefore complete. The broader full-system observability issue remains open for GPU, network, device/driver, power/thermal, firmware/security and cross-domain correlation work.