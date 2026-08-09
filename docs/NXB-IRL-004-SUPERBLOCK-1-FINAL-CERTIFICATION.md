# NXB-IRL-004 — SUPERBLOCK 1 Final Calibration and Claim Audit

## Status

`IMPLEMENTED — NATIVE EXACT-HEAD WINDOWS VALIDATION PENDING`

This is the compressed Round 3 closeout gate for SUPERBLOCK 1. It binds the already validated controlled semantic evidence to a fresh paired collector-overhead calibration and emits a conservative final claim matrix.

GitHub Actions remain intentionally disabled. Native Windows exact-head execution is authoritative.

## Canonical predecessor chain

Foundation / real capture:

```text
head:       57dd8a466509bd390b94ad8426b2af6dd56c1687
review ZIP: 4dbbf73c58d6bb241e3dfb91fb859eb6b4550ef40359f246aa4bfa939a035bf5
```

Downstream normalization:

```text
head:       7fd766d15faa9b2ca0197edf342a0f794f4d1f0b
review ZIP: b5009e314aeed4f20e4daec951ea661255c094638bab697cf5c3aaf0fde13480
```

Structural correlation:

```text
head:       8bb94d10b4a74629668ddee2ad2fe378f8928999
review ZIP: 6697c15afc7eefec460b6ae436bb0aee41c2052caabbe980d38ff618f71a1d76
```

Round 1 controlled same-PID semantic eligibility:

```text
head:       2230864433890c2992b59088fe1af3db0c635808
review ZIP: 97922ba500a0f66d34a8b8cbda54b34aa7e871af3e3d68d81255bcd8bd39a150
```

Round 2 repeated ON/OFF semantic controls:

```text
head:                 36d962b7c6d42aef6c5034fc42705a78b2ee8bc4
review ZIP:           c7dc5f723af5ea28903efc04a7f45391d7856f06f3d87f43ddc0627bcfafb98a
semantic summary:     4f4a55c34469dafcfde14f8fc9ae21efedf6457e19f26674bf25a4ff31eae20c
PS7 / PS5.1:          18/18 + 18/18
PSScriptAnalyzer:     0
EventsLost/BuffersLost: 0 / 0
normalized rows:      278917
normalization replay: byte-identical
analysis replay:      byte-identical
```

Round 2 validated the bounded controlled mappings only:

```text
controlled_present_count_mapping_validated: true
controlled_network_activity_mapping_validated: true
present_field_shape_asymmetry_reproduced: true
exact_named_present_pairing_eligible: false
```

It did not promote Present pairing/success semantics, TCP lifecycle/latency semantics, kernel/registry semantics, timestamp units, causality or root cause.

## Round 3 paired-overhead protocol

Repository runner:

```text
scripts/Invoke-NxbSuperblock1FinalCertification.ps1
```

Static contract:

```text
tests/Superblock1FinalCalibration.Tests.ps1
```

The protocol reuses the repository's established paired-calibration discipline rather than inventing a new acceptance threshold:

- same machine identity,
- same boot identity,
- same active Windows power policy,
- the exact same native `all_on` fixture in control and instrumented arms,
- one warmup pair,
- four measured pairs,
- alternating control-first / instrumented-first ordering,
- bounded process duration, CPU, working-set and private-byte observations,
- per-instrumented-arm ETL loss accounting,
- exact native fixture receipt validation,
- no external network,
- no registry writes,
- pre-existing WPR sessions never auto-cancelled.

Measured ordering:

```text
pair 1: control -> instrumented
pair 2: instrumented -> control
pair 3: control -> instrumented
pair 4: instrumented -> control
```

Every measured instrumented arm must report:

```text
EventsLost = 0
BuffersLost = 0
BuffersWritten > 0
```

The runner reports the median duration delta, median duration overhead percentage, median CPU delta, median peak working-set delta and median peak private-byte delta.

## Threshold policy

The final gate deliberately retains:

```text
threshold_policy.status: not_declared
representative_benchmark: false
```

The four-pair run is bounded calibration evidence. It is not a production performance SLA, representative benchmark or universal acceptable-overhead threshold.

## Final claim matrix

A successful native Round 3 run may retain/promote only the bounded evidence already established by the chain:

```text
controlled_fixture_process: true
exact_fixture_pid_attribution: true
exact_pid_three_domain_observability: true
controlled_present_count_mapping_validated: true
controlled_network_activity_mapping_validated: true
deterministic_normalization_replay: true
deterministic_correlation_replay: true
repeated_control_analysis_replay: true
bounded_paired_overhead_measured: true
```

The following remain explicitly withheld:

```text
present_event_mapping_generalized: false
present_pairing_semantics: false
present_success_semantics: false
gpu_queue_semantics: false
tcp_connection_lifecycle_validated: false
network_connection_semantics: false
network_latency_semantics: false
dns_payload_semantics: false
kernel_lifecycle_semantics: false
registry_operation_semantics: false
timestamp_unit_resolved: false
causal_relationship_validated: false
root_cause_validated: false
circular_overwrite_absence: false
trace_completeness: not_claimed
```

The kernel/registry boundary is intentional. Round 2's `kernel_off` fixture-PID kernel counts remained close to `all_on`, so the explicit fixture kernel stimulus is not isolated strongly enough to promote kernel-event semantics.

The Present pairing boundary is also intentional. Round 2 reproduced asymmetric Present Start/Stop field shapes and exact named identifier pairing remained ineligible.

## Evidence boundary

Raw per-arm ETLs, native fixture executable/build outputs and fixture receipts remain under `raw-local` only.

The final bounded review ZIP contains only aggregate calibration, final claim matrix and final certification receipt JSON. Its archive audit rejects ETL, executable/object/PDB, fixture receipt, xperf, normalized-event, manifest and WPRP payloads.

## Completion rule

SUPERBLOCK 1 closes when the exact implementation head passes native Windows Round 3 with:

```text
PS7 final contract:      18/18
PS5.1 final contract:    18/18
PSScriptAnalyzer:        0 findings
Round 1 review binding:  exact SHA-256 PASS
Round 2 review binding:  exact SHA-256 PASS
warmup pairs:            1
measured pairs:          4
loss-free measured arms: 4/4
threshold policy:        not_declared
claim audit:             conservative PASS
review boundary audit:   PASS
```

Round 4 exists only for a concrete native-Windows residual discovered by this final run. It is not a scheduled extra round.

PR #12 remains draft/open. No merge is implied or requested by this gate.
