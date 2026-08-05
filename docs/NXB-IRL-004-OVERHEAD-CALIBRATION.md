# NXB-IRL-004 — Paired Collector Overhead Calibration

## Status

`IN PROGRESS — EVIDENCE CONTRACT AND CONTROLLED WORKLOAD IMPLEMENTED`

Tracking issue: `#2`

Draft pull request: `#7`

Preceding capture-profile merge: `#6` / `04214ac4e27a1b35e4327392480c2f89e9caaddc`

## Objective

Measure the performance cost attributable to the bounded CPU/scheduler WPR profile using paired control and capture trials on the same machine, boot identity, power policy and deterministic workload.

This block does not declare an acceptable overhead threshold. It first establishes evidence that can support a later threshold decision without treating missing measurements as zero or treating an ETL file as proof of completeness.

## Implemented evidence contract

Schema:

```text
schemas/collector-overhead-calibration.schema.json
```

Validator wrapper:

```text
scripts/Test-CollectorOverheadCalibration.ps1
```

Semantic validator:

```text
tools/validate_overhead_calibration.py
```

Deterministic valid fixture:

```text
tests/fixtures/collector-overhead-calibration.valid.json
```

Adversarial tests:

```text
tests/CollectorOverheadCalibration.Tests.ps1
```

Repository smoke validates both the JSON Schema and cross-field semantic contract.

## Measurement-state contract

Every optional measurement is represented explicitly as one of:

```text
measured
unsupported
failed
```

A `measured` value must include a numeric value and unit.

An `unsupported` or `failed` value must contain:

- `value: null`
- the intended unit
- a non-empty reason

Missing process metrics, failed ETL finalization or unavailable counters are never converted to zero.

## Identity binding

The calibration record binds:

- parent experiment ID,
- machine ID,
- boot ID,
- canonical power-policy fingerprint,
- canonical workload fingerprint,
- deterministic trial ordering,
- bounded repetition count.

Each pair repeats the machine, boot, power-policy and workload fingerprints. The semantic validator rejects any mismatch.

Power-policy and workload fingerprints use canonical UTF-8 JSON with:

- lexicographically sorted object keys,
- no insignificant whitespace,
- SHA-256 lowercase hex output.

## Protocol contract

Supported deterministic orderings:

```text
alternating_control_first
alternating_capture_first
control_then_capture
capture_then_control
```

The validator enforces:

- `pairs.Count == protocol.repetition_count`,
- ordinal sequence starts at 1 and contains no gaps,
- pair IDs are unique,
- each pair follows the selected first-arm ordering,
- all pair identity fields match the top-level calibration identity.

Current schema bounds:

```text
repetition_count: 1..100
warmup_count:     0..20
cooldown_seconds: 0..3600
timeout_seconds:  1..86400
```

## Arm evidence

Both control and capture arms record:

- status,
- start and stop UTC,
- wall-clock duration,
- process exit code,
- timeout state,
- workload result,
- process CPU time,
- peak working set,
- peak private bytes,
- diagnostics.

The capture arm additionally records:

- WPR start latency,
- WPR stop/finalization latency,
- ETL path,
- ETL SHA-256,
- ETL byte length,
- effective ETL byte rate,
- profile-provenance SHA-256.

The semantic validator rejects a measured arm that timed out or returned a nonzero exit code.

## Delta and distribution contract

Per-pair deltas cover:

- absolute workload-duration delta,
- relative workload-duration delta,
- absolute and relative CPU-time delta,
- absolute and relative peak-working-set delta,
- absolute and relative peak-private-bytes delta.

For measured source values:

```text
absolute = capture - control
relative_percent = absolute / control * 100
```

A zero control denominator cannot produce a measured relative delta.

Summary distributions contain:

- count,
- minimum,
- median,
- arithmetic mean,
- maximum,
- unit,
- explicit status and reason.

The semantic validator recomputes pair deltas and summary distributions rather than trusting submitted values.

## ETL byte-rate contract

For a successful measured pair:

```text
effective_bytes_per_second = etl.length / (capture.duration_ms / 1000)
```

This value describes effective ETL growth during the measured workload arm. It is not a disk-latency measurement and does not certify that no circular overwrite or event loss occurred.

## Threshold policy

The schema requires:

```json
{
  "status": "not_declared",
  "reason": "..."
}
```

A `passed`, `failed`, `acceptable` or similar threshold verdict is rejected by schema validation.

Thresholds may be proposed only after measured repetitions exist across representative machines and workloads.

## Controlled workload

Implemented fixture:

```text
tools/Invoke-NxbCpuWorkload.ps1
```

The fixture:

- operates only on an in-memory 4096-byte buffer,
- executes a deterministic SHA-256 chain,
- accepts bounded iteration and seed values,
- writes one atomic JSON result,
- refuses to overwrite an existing result file,
- produces the same checksum for the same parameters.

It is a calibration workload, not a real-world performance conclusion.

Tests:

```text
tests/CpuWorkload.Tests.ps1
```

## Adversarial validation

The current test matrix rejects:

- changed canonical power-policy content,
- changed canonical workload parameters,
- pair boot-identity substitution,
- ordinal gaps,
- deterministic ordering violations,
- incorrect absolute or relative delta math,
- incorrect ETL byte rate,
- inconsistent summary pair counters,
- changed distribution statistics,
- undeclared capture-arm properties,
- threshold verdicts.

## Remaining implementation

The following are not yet claimed:

- paired control/capture execution orchestration,
- separate lifecycle experiment per arm,
- independent process sampling loop,
- WPR teardown across every failure path in the calibration runner,
- warmup execution and cooldown enforcement,
- partial-run recovery and resume,
- final evidence-store record integration,
- measured overhead results.

## GitHub Actions policy

GitHub Actions are intentionally disabled repository-wide. This PR must not reintroduce workflow files or claim exact-head hosted validation.

Validation evidence for this block must distinguish:

- static source review,
- manually executed PowerShell 7 tests,
- manually executed Windows PowerShell 5.1 tests,
- schema/semantic fixture validation,
- controlled live calibration evidence.
