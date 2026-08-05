# NXB-IRL-004 — Minimal CPU and Scheduler Capture Profile

## Status

`IMPLEMENTED — FINAL WINDOWS VALIDATION PENDING`

Tracking issue: `#2`

Draft pull request: `#6`

This document defines the first executable block of the full-system observability fabric. It records what the profile captures, how it is bounded, how provenance is preserved and which overhead/loss measurements remain explicitly unimplemented.

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

The memory variant exists to satisfy the WPR profile-pair contract. `Start-PerformanceTrace.ps1` currently selects the bounded File variant.

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

## Native and repository validation

The profile is checked by two independent layers:

1. `scripts/Test-WprProfile.ps1`
   - repository containment,
   - reparse-point rejection,
   - DTD prohibition and disabled XML resolver,
   - exact collectors, provider, keywords, stacks and variants,
   - exact file-size and buffer bounds.

2. Windows CI native parser
   - `wpr.exe -profiles <profile>` must succeed,
   - `NxbMinimalCpuScheduler` must be enumerated by WPR.

Repository smoke validation executes the deterministic profile contract without starting a real trace.

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
5. `performance.etl.json` records the profile, provenance, seal and integrity result.
6. A mismatch transitions the experiment and session to `failed` rather than silently producing `stopped` success.

This is integrity and reproducibility evidence; it is not a trusted-signature mechanism.

## Adversarial coverage

The current test matrix covers:

- missing WPR executable,
- existing-session cancellation failure,
- WPR start failure,
- WPR stop failure,
- success exit without an ETL,
- unacknowledged built-in `GeneralProfile`,
- exact bounded-profile WPR arguments,
- Windows CRLF argument-log behavior,
- repository-external profile path,
- reparse-point profile path,
- DTD/XXE-bearing XML,
- changed keyword set,
- changed or unbounded file collector,
- missing matching memory variant,
- modified sealed session provenance,
- teardown-first preservation of ETL and metadata on provenance failure.

## Collector overhead: not yet measured

The following values are **not implemented or validated by this block**:

- CPU cost attributable to WPR/ETW collection,
- additional committed or working-set memory,
- ETL write throughput and storage latency impact,
- scheduler perturbation caused by stack walking,
- start and stop latency distributions,
- workload performance delta between tracing and control runs,
- acceptable overhead thresholds.

A later NXB-IRL-004 block must use paired control/capture trials on the same machine, boot identity, power policy and workload fixture. It must record at minimum:

- workload identity and parameters,
- control-run duration and result,
- capture-run duration and result,
- WPR start latency,
- WPR stop/finalization latency,
- ETL byte length,
- effective ETL byte rate,
- collector CPU and memory observations from an independent measurement path,
- absolute and relative workload deltas,
- repetition count and distribution summary.

No overhead threshold is declared in this PR. Thresholds require measured evidence and must not be inferred from the 512 MiB file bound.

## Trace loss: not yet measured

The following values are also **not implemented or validated by this block**:

- lost ETW events,
- lost buffers,
- provider-specific drop counts,
- stack-walk loss or unavailable stacks,
- circular overwrite amount,
- earliest retained timestamp after circular overwrite,
- completeness of every requested event class.

A later block must extract trace-session statistics from a documented Windows ETW/WPR analysis path and bind them to the experiment evidence store. Required output must distinguish:

```text
complete
loss_detected
statistics_unavailable
analysis_failed
```

`statistics_unavailable` must not be treated as `complete`.

The loss record must include:

- ETL SHA-256 and length,
- profile-provenance SHA-256,
- trace start and stop timestamps,
- observed first and last event timestamps where available,
- event/buffer loss counters where available,
- circular-overwrite evidence where available,
- analysis tool provenance,
- explicit uncertainty or unsupported fields.

## Current completion boundary

This block establishes:

- a native-parser-valid minimal CPU/scheduler WPR profile,
- bounded file-mode growth,
- explicit unbounded legacy opt-in,
- deterministic profile selection and provenance,
- profile-to-ETL metadata binding,
- teardown-first fail-closed provenance enforcement,
- dual-runtime adversarial tests,
- repository smoke integration.

It does **not** establish:

- ETL event extraction,
- cross-domain correlation,
- overhead calibration,
- trace-loss accounting,
- capture completeness certification,
- CPU bottleneck conclusions.

## Validation gate

Before this block can be considered merge-ready, the exact final head must pass and have complete logs inspected for:

- native WPR profile parsing,
- public repository content guard,
- zero PSScriptAnalyzer Error/Warning findings,
- repository smoke validation,
- PowerShell 7 Pester matrix,
- Windows PowerShell 5.1 Pester matrix.
