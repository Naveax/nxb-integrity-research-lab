# NXB-IRL-004 — Minimal CPU and Scheduler Capture Profile

## Status

`IMPLEMENTED — MERGED IN PR #6`

Tracking issue: `#2`

Merged pull request: `#6`

Merge commit:

```text
04214ac4e27a1b35e4327392480c2f89e9caaddc
```

This document defines the first executable block of the full-system observability fabric. It records what the profile captures, how growth is bounded and how capture provenance is preserved.

## Objective

Provide a repository-owned Windows Performance Recorder profile for authorized CPU and scheduler investigations while preserving deterministic lifecycle state, bounded file growth and independently inspectable capture provenance.

The profile is not an ETL analysis engine and does not claim that a trace is complete merely because WPR returned success.

## Repository profile

```text
profiles/Nxb.MinimalCpuScheduler.wprp
```

Profile variants:

```text
NxbMinimalCpuScheduler.Verbose.File
NxbMinimalCpuScheduler.Verbose.Memory
```

The File and Memory variants use separate system collectors because WPR does not permit `MaximumFileSize` on a memory-mode collector.

### File collector

```text
BufferSize:       1024 KiB
Buffers:          64
MaximumFileSize:  512 MiB
FileMode:         Circular
```

### Memory collector

```text
BufferSize:       1024 KiB
Buffers:          64
MaximumFileSize:  not present
```

The memory variant satisfies the WPR profile-pair contract. `Start-PerformanceTrace.ps1` selects the bounded File variant.

## Kernel event contract

Keywords:

- `CpuConfig`
- `CSwitch`
- `DPC`
- `Interrupt`
- `KernelQueue`
- `Loader`
- `ProcessThread`
- `ReadyThread`
- `SampledProfile`
- `ThreadPriority`

Stack points:

- `CSwitch`
- `DpcExecute`
- `ImageLoad`
- `ProcessCreate`
- `ReadyThread`
- `SampledProfile`
- `ThreadCreate`
- `ThreadSetBasePriority`
- `ThreadSetPriority`

Any change to these exact sets, collector bounds or File/Memory pairing fails the repository profile validator.

## Profile validation

`scripts/Test-WprProfile.ps1` enforces:

- repository containment,
- reparse-point rejection,
- DTD prohibition and disabled XML resolver,
- exact collectors and provider,
- exact keyword and stack sets,
- exact File/Memory variants,
- exact buffer and file-size bounds.

The profile was also accepted by the native Microsoft WPR parser during PR #6 validation. Repository smoke validates the deterministic profile contract without starting a trace.

## Capture selection

Default bounded capture:

```powershell
./scripts/Start-PerformanceTrace.ps1 -ExperimentPath <experiment>
```

Explicit legacy built-in capture:

```powershell
./scripts/Start-PerformanceTrace.ps1 `
  -ExperimentPath <experiment> `
  -CaptureProfile GeneralProfile `
  -AllowUnboundedBuiltInProfile
```

`GeneralProfile` is never selected implicitly. Its file-mode growth is recorded as unbounded provenance.

## Provenance contract

At start, `trace-session.json` binds:

- profile selector,
- logging mode,
- repository-relative WPRP path,
- WPRP SHA-256 and byte length,
- detail level,
- bounded/unbounded state,
- buffer size and count,
- maximum file size and file mode,
- keyword set,
- stack set,
- canonical profile-provenance SHA-256.

At stop:

1. WPR teardown is attempted first.
2. A successful ETL is retained even when provenance verification fails.
3. The canonical provenance seal is recomputed.
4. Repository WPRP path, SHA-256 and length are revalidated.
5. `performance.etl.json` records profile provenance and integrity status.
6. A mismatch transitions the experiment and session to `failed` rather than silently producing success.

This is integrity and reproducibility evidence; it is not a trusted-signature mechanism.

## Adversarial coverage

The profile/lifecycle matrix covers:

- missing WPR executable,
- existing-session cancellation failure,
- WPR start and stop failure,
- success exit without ETL,
- unacknowledged `GeneralProfile`,
- exact bounded-profile WPR arguments,
- Windows CRLF argument-log behavior,
- repository-external and reparse-point profile paths,
- DTD/XXE-bearing XML,
- changed keyword set,
- changed or unbounded file collector,
- missing matching memory variant,
- modified sealed session provenance,
- teardown-first preservation of ETL and metadata on provenance failure.

## Collector overhead calibration

The overhead evidence contract and paired runner are implemented in draft PR #7:

```text
docs/NXB-IRL-004-OVERHEAD-CALIBRATION.md
schemas/collector-overhead-calibration.schema.json
scripts/Invoke-CollectorOverheadCalibration.ps1
```

That block adds:

- separate parent/control/capture lifecycle experiments,
- same-machine and same-boot binding,
- active power-policy fingerprinting,
- deterministic workload fingerprinting,
- bounded warmups and repetitions,
- independent process CPU/memory sampling,
- WPR start and stop latency,
- ETL length and effective byte rate,
- absolute and relative workload deltas,
- distribution summaries,
- explicit failed/unsupported measurements,
- mandatory `not_declared` threshold policy.

No native-WPR overhead result or acceptable threshold is claimed yet. Those require manual dual-runtime validation and controlled live measurement.

## Trace loss: not yet measured

Still unimplemented:

- lost ETW events,
- lost buffers,
- provider-specific drop counts,
- stack-walk loss or unavailable stacks,
- circular overwrite amount,
- earliest retained timestamp after overwrite,
- completeness of requested event classes.

A later block must classify trace-session statistics as:

```text
complete
loss_detected
statistics_unavailable
analysis_failed
```

`statistics_unavailable` must not be treated as `complete`.

The loss record must bind ETL hash/length, profile provenance, trace timestamps, available loss counters, circular-overwrite evidence, analysis-tool provenance and explicit uncertainty.

## Completion boundary

The merged profile block establishes:

- a native-parser-valid minimal CPU/scheduler WPR profile,
- bounded file-mode growth,
- explicit unbounded legacy opt-in,
- deterministic profile selection and provenance,
- profile-to-ETL metadata binding,
- teardown-first fail-closed provenance enforcement,
- dual-runtime adversarial coverage,
- repository smoke integration.

It does not establish:

- ETL event extraction,
- cross-domain correlation,
- trace-loss accounting,
- capture completeness certification,
- acceptable overhead thresholds,
- CPU bottleneck conclusions.

## Validation boundary

PR #6 recorded the actual validation boundary rather than claiming an unavailable exact-head hosted run. GitHub Actions are now intentionally disabled repository-wide. Future validation must distinguish static review, manual PowerShell 7 tests, manual Windows PowerShell 5.1 tests and controlled native-WPR evidence.
