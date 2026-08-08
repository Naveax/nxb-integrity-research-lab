# NXB-IRL-004 Storage Summary Adapter Validation

## Canonical implementation / validation head

```text
fc1f8754a10c9a26ea5a3419369d55e6c76dc5fa
```

## Environment

- Windows native validation
- PowerShell 7.6.4
- Windows PowerShell 5.1
- Git exact-head clean clone
- Python converter + semantic validator

## Repository-native validation

```text
PowerShell 7 Pester:             9/9
Windows PowerShell 5.1 Pester:  9/9
PSScriptAnalyzer findings:       0
Python converter/validator:      py_compile PASS
```

## Canonical real-input evidence

```text
source capture head:             c4e6b8cc435fe700acfa0a5d17c50684a00052d3
raw-bridge implementation head:  fdf0506eda29918077ff7aec3923ab98dcb56d87
normalized event export SHA-256: 6dc452450a85cb0a1680fb4cbba2eeb09052a504a9c4cd56a96b264214c2883e
bridge manifest SHA-256:          06fdb9501a1c2f6e6026a9be9ecd614a65229a54e08372569e02505528d7589f
normalized source events:        58669
target PID:                      8444
target normalized rows:          19427
summary SHA-256:                 e3e2dfb01e8d0dafc50b8580a4f3691b871bf550dcb000ac45a53e36299c54b7
adapter SHA-256:                 1ba71848e82f9668a6d2b98391cd6f020fcaa3ea17ddee48f4a0ae253934fa1c
```

Observed event counts:

```text
disk_flush             6
disk_read             18
disk_write           209
file_close          2421
file_create         2860
file_delete            5
file_flush             2
file_read            192
file_rename             3
file_write          52953
```

Ten event classes were observed and measured. `split_io` was not observed and remains `not_assessed`; it is not synthesized as measured zero.

The summary contains 23 process summaries. The target process identity is complete and the target summary accounts for 19427 normalized rows.

## Evidence quality / claim boundary

```text
trace_loss:                         none
circular_overwrite:                 unknown
parser_completeness:                partial
evidence_completeness:              partial
queue_depth_semantics:              false
queue_latency_semantics:            false
service_time_semantics:             false
throughput_representativeness:      false
iops_representativeness:            false
trace_completeness:                 not_claimed
```

`ElapsedTime` and `DiskSvcTime` remain unit-unresolved raw evidence and are not converted into `latency_us` or service-time metrics.

## Provenance rule

`adapter_sha256` binds both the PowerShell wrapper and the Python converter. A converter change therefore changes adapter provenance.

## Closeout

The storage summary-adapter slice is validated and closed at the implementation head above. Subsequent documentation-only commits do not retroactively claim runtime revalidation unless explicitly recorded.
