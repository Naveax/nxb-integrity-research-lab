# NXB-IRL-004 — Paired Collector Overhead Calibration

## Status

`IMPLEMENTED — DUAL-RUNTIME AND CONTROLLED LIVE VALIDATION PENDING`

Tracking issue: `#2`

Draft pull request: `#7`

Preceding capture-profile merge: `#6` / `04214ac4e27a1b35e4327392480c2f89e9caaddc`

## Objective

Measure the cost attributable to the bounded CPU/scheduler WPR profile using paired control and capture trials on the same machine, boot identity, power policy and deterministic workload.

This block does not declare an acceptable overhead threshold. Missing measurements are not converted to zero, and an ETL file is not treated as proof of trace completeness.

## Implemented components

Evidence contract:

```text
schemas/collector-overhead-calibration.schema.json
scripts/Test-CollectorOverheadCalibration.ps1
tools/validate_overhead_calibration.py
tests/fixtures/collector-overhead-calibration.valid.json
```

Controlled workload and independent sampler:

```text
tools/Invoke-NxbCpuWorkload.ps1
scripts/Invoke-NxbMeasuredWorkload.ps1
```

Power-policy and paired-run orchestration:

```text
scripts/Get-NxbActivePowerPolicy.ps1
scripts/Invoke-CollectorOverheadCalibration.ps1
```

Tests:

```text
tests/CollectorOverheadCalibration.Tests.ps1
tests/CpuWorkload.Tests.ps1
tests/MeasuredWorkload.Tests.ps1
tests/CollectorOverheadRunner.Tests.ps1
```

Repository smoke validates the JSON Schema, deterministic fixture and cross-field semantic contract without starting a real WPR session.

## Measurement-state contract

Every optional measurement is explicitly classified as:

```text
measured
unsupported
failed
```

A measured value contains a numeric value and unit. An unsupported or failed value contains:

- `value: null`,
- the intended unit,
- a non-empty reason.

Unavailable process metrics, failed ETL finalization and unavailable counters are never represented as zero.

## Identity and lifecycle binding

The parent calibration record binds:

- parent experiment ID and repository-relative experiment path,
- machine ID,
- boot ID,
- canonical power-policy fingerprint,
- canonical workload fingerprint,
- deterministic ordering,
- bounded repetition and warmup counts.

Every control, capture and warmup arm receives a separate lifecycle experiment. The semantic validator requires:

```text
experiment_relative_path == experiments/<experiment_id>
```

Child experiment IDs must be unique and must not equal the parent experiment ID. Machine and boot identity are collected for every child and compared with the parent before the workload runs.

## Power-policy contract

`scripts/Get-NxbActivePowerPolicy.ps1` resolves `powercfg.exe`, parses the active scheme GUID and records command provenance. The paired runner hashes canonical power-policy JSON and verifies the fingerprint:

- before each warmup,
- after each warmup,
- before each control/capture arm,
- after each control/capture arm.

A policy change invalidates the arm. Successful child experiments are not finalized until the post-arm policy check completes.

## Workload contract

`tools/Invoke-NxbCpuWorkload.ps1`:

- operates on an in-memory 4096-byte buffer,
- executes a deterministic SHA-256 chain,
- accepts bounded iteration and seed values,
- writes one atomic JSON result,
- refuses to overwrite an existing result,
- produces the same checksum for identical parameters.

`scripts/Invoke-NxbMeasuredWorkload.ps1` executes the workload in a separate PowerShell process and records:

- wall-clock duration,
- process exit code,
- timeout state,
- workload checksum,
- CPU time,
- sampled peak working set,
- sampled peak private bytes,
- stdout/stderr,
- workload file SHA-256, length and repository path,
- child PowerShell executable provenance.

The process timeout is bounded, and timed-out teardown receives a second five-second bound.

## Paired protocol

Supported deterministic orderings:

```text
alternating_control_first
alternating_capture_first
control_then_capture
capture_then_control
```

The schema supports up to 100 pairs. The current command limits one invocation to 20 pairs and five warmups to keep operator runs bounded.

Example:

```powershell
./scripts/Invoke-CollectorOverheadCalibration.ps1 `
  -ExperimentPath <prepared-parent-experiment> `
  -RepetitionCount 3 `
  -WarmupCount 1 `
  -Ordering alternating_control_first `
  -Iterations 1000 `
  -Confirm:$false
```

The runner creates:

```text
analysis/collector-overhead-warmups.json
analysis/collector-overhead-calibration.json
```

Each control and capture arm has its own experiment directory under the same lab root.

## Capture-arm behavior

The capture arm records:

- WPR start latency,
- measured workload evidence,
- WPR stop/finalization latency,
- ETL path, SHA-256 and byte length,
- effective ETL byte rate,
- profile-provenance SHA-256.

WPR stop is attempted after the workload regardless of workload success. If stop/finalization fails, the runner attempts explicit `wpr.exe -cancel`, marks the child experiment failed and preserves failed-pair evidence.

A failed pair does not produce measured workload-overhead deltas. The parent calibration evidence may still be finalized and validated, after which the command returns failure so automation cannot mistake partial evidence for a successful calibration.

## Delta and distribution contract

For a successful pair:

```text
absolute = capture - control
relative_percent = absolute / control * 100
```

A zero control denominator cannot produce a measured relative delta.

Per-pair values cover:

- workload duration,
- process CPU time,
- peak working set,
- peak private bytes.

Summary distributions contain count, minimum, median, arithmetic mean and maximum. The Python semantic validator recomputes pair deltas and summary statistics instead of trusting submitted values.

## ETL byte-rate contract

For a successful measured pair:

```text
effective_bytes_per_second = etl.length / (capture.duration_ms / 1000)
```

This describes effective ETL growth during the workload arm. It is not a storage-latency measurement and does not certify absence of dropped events or circular overwrite.

## Threshold policy

The schema requires:

```json
{
  "status": "not_declared",
  "reason": "..."
}
```

A `passed`, `failed`, `acceptable` or similar threshold verdict is rejected. Thresholds require representative measured evidence across multiple machines and workloads.

## Adversarial coverage

The current matrix covers:

- canonical power-policy and workload fingerprint changes,
- parent or child experiment-path substitution,
- duplicate child experiment IDs,
- boot-identity substitution,
- ordinal gaps and deterministic ordering violations,
- control/capture checksum mismatch,
- incorrect absolute and relative delta math,
- incorrect ETL effective byte rate,
- inconsistent summary counters or statistics,
- undeclared capture-arm properties,
- threshold verdict injection,
- workload nonzero exit,
- workload timeout and bounded teardown,
- external workload-script rejection,
- successful fake-WPR paired lifecycle,
- WPR stop failure, explicit cancel and preserved failed-pair evidence.

## Remaining validation and follow-up

Not yet claimed:

- manually executed full Pester results on PowerShell 7,
- manually executed full Pester results on Windows PowerShell 5.1,
- zero-finding PSScriptAnalyzer result for the exact final head,
- a controlled live run using native `wpr.exe`,
- representative measured overhead results,
- acceptable overhead thresholds,
- trace-loss accounting,
- partial-run resume after host interruption.

## GitHub Actions policy

GitHub Actions are intentionally disabled repository-wide. This PR must not add workflow files or claim exact-head hosted validation.

Validation records must distinguish:

- static source review,
- schema and semantic fixture validation,
- PowerShell 7 tests,
- Windows PowerShell 5.1 tests,
- controlled fake-WPR lifecycle tests,
- controlled native-WPR calibration evidence.
