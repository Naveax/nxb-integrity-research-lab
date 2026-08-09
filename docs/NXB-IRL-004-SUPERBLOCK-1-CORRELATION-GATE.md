# NXB-IRL-004 SUPERBLOCK 1 — Correlation Gate

## Status

`NATIVE REPO-OWNED CORRELATION GATE: PASSED`

Canonical source:

```text
capture head:    57dd8a466509bd390b94ad8426b2af6dd56c1687
normalizer head: 7fd766d15faa9b2ca0197edf342a0f794f4d1f0b
normalized rows: 188505
normalized SHA:  269d93e00411d78e15ebfb2c4c5a6568b36addb78238d57d7809184a1a420f89
coverage SHA:    5756530354f42fb0be9741de7bd6119649a02a4a17505e75658663f8e36ce3aa
target PID:      26928
```

Native exact-head correlation implementation:

```text
8bb94d10b4a74629668ddee2ad2fe378f8928999
```

Native result:

```text
PowerShell 7:               10/10
Windows PowerShell 5.1:    10/10
PSScriptAnalyzer:          0 findings
Python syntax:             PASS
canonical source SHA:      PASS
normalized rows consumed:  188505
structural pair records:   24241
target PID rows:           6395
three-domain PID count:    0
pair-record replay:        byte-identical
summary replay:            byte-identical
review ZIP SHA-256:
6697c15afc7eefec460b6ae436bb0aee41c2052caabbe980d38ff618f71a1d76
```

The repo-owned certification completed and emitted its bounded review ZIP. Portable V1 then failed only while rendering its final console summary. `target_pid.domain_counts` is intentionally sparse; on the real target PID the `gpu` property was absent, and direct `.gpu` access under `Set-StrictMode -Version Latest` raised `PropertyNotFoundStrict` / `ParentContainsErrorRecordException`.

This was a portable presentation-layer defect. It did not invalidate the analyzer, replay, bounded receipt, or review ZIP.

## PowerShell hardening contract

Portable wrappers must treat JSON aggregate maps as sparse unless the schema explicitly guarantees fixed keys.

The hardened portable contract is:

- all nested result reads use a StrictMode-safe property accessor;
- required certification fields must exist and match expected values;
- missing required fields produce explicit controlled errors rather than property-access exceptions;
- optional aggregate counts default to `0` only for display;
- a missing optional count can never turn an already-passed repo-owned certification into a wrapper failure;
- review ZIP SHA-256 is recomputed and compared with the repo-owned result;
- an already-completed exact-head result may be reused when its head, source identity, replay flags, receipt status, and review ZIP hash all validate;
- otherwise the wrapper reruns the repo-owned correlation gate.

## Structural correlation layers

### DXGI

The gate structurally pairs event-name start/stop observations for:

- `Microsoft-Windows-DXGI/Present/win:Start` / `win:Stop`;
- `PresentMultiplaneOverlay` start/stop.

Keys use exact PID plus named present identifiers such as swap-chain fields when present. If no named present identifier exists, PID-only grouping is recorded explicitly as the weaker structural basis.

The pair record stores only sequence indices and a SHA-256 correlation key. Sequence delta is an event-order distance, not a time duration.

### Kernel lifecycle

Structural start/end pairing is attempted for:

- process `P-Start` / `P-End`;
- process rundown `P-DCStart` / `P-DCEnd`;
- thread `T-Start` / `T-End`;
- thread rundown `T-DCStart` / `T-DCEnd`;
- image `I-Start` / `I-End`;
- image rundown `I-DCStart` / `I-DCEnd`.

Process keys use PID, thread keys use PID/TID when available, and image keys use PID plus a hashed named image identifier when available.

### Network / DNS / Registry

TCP rows are grouped by PID plus hashed named address/port fields. DNS rows are grouped by PID plus hashed named query/server/interface/address fields. Registry activity is grouped by PID plus hashed named key/KCB/path fields.

No raw address, port, DNS value, registry path, or group key hash is admitted to bounded review evidence.

### Cross-domain attribution

The gate counts exact PID and PID/TID identities across normalized domains. GPU/network target-PID rows may be compared with the nearest same-PID kernel event by sequence index. Distances remain unitless sequence adjacency and are not temporal or causal evidence.

## Determinism

The same normalized event stream is analyzed twice. Both must be byte-identical:

```text
local structural-pair JSONL
aggregate correlation summary JSON
```

## Claims

The gate may certify:

```text
sequence_order_correlation:          true
exact_pid_attribution:               true
exact_tid_attribution_when_present:  true
hashed_identifier_grouping:          true
structural_start_stop_pairing:       true
```

It must keep the following false or unclaimed:

```text
timestamp_unit_resolved:              false
sequence_delta_is_time:               false
present_pairing_semantics:            false
present_success_semantics:            false
gpu_queue_semantics:                  false
tcp_connection_lifecycle_validated:   false
network_connection_semantics:         false
network_latency_semantics:            false
dns_payload_semantics:                false
kernel_lifecycle_semantics:           false
registry_operation_semantics:         false
causal_relationship_validated:        false
root_cause_validated:                 false
trace_completeness:                   not_claimed
```

A later controlled multi-domain fixture is required before root-cause semantics can be promoted.
