# NXB-IRL-004 SUPERBLOCK 1 — Correlation Gate

## Purpose

This gate consumes the canonical downstream normalized event stream and builds deterministic cross-domain structural correlation without reopening capture or normalization work.

Canonical source:

```text
capture head:    57dd8a466509bd390b94ad8426b2af6dd56c1687
normalizer head: 7fd766d15faa9b2ca0197edf342a0f794f4d1f0b
normalized rows: 188505
normalized SHA:  269d93e00411d78e15ebfb2c4c5a6568b36addb78238d57d7809184a1a420f89
coverage SHA:    5756530354f42fb0be9741de7bd6119649a02a4a17505e75658663f8e36ce3aa
target PID:      26928
```

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

### Network

TCP rows are grouped by PID plus hashed named address/port fields. Aggregate evidence includes observation counts and structural groups containing connect/disconnect/send/receive/retransmit event names and whether connect precedes disconnect by sequence order.

DNS rows are grouped by PID plus hashed named query/server/interface/address fields.

No raw address, port, DNS value, or group key hash is admitted to bounded review evidence.

### Registry

Registry activity is grouped by PID plus hashed named key/KCB/path fields. The review artifact contains only aggregate counts.

### Cross-domain attribution

The gate counts exact PID and PID/TID identities observed across one, two, or three normalized domains. The canonical target PID receives explicit GPU/network/kernel family counts.

GPU/network target-PID rows are also compared with the nearest same-PID kernel event by event sequence index. The resulting distance buckets are explicitly unitless sequence adjacency and are not treated as temporal or causal evidence.

## Determinism

The same normalized event stream is analyzed twice. Both must be byte-identical:

```text
local structural-pair JSONL
aggregate correlation summary JSON
```

## Review boundary

Local only:

- normalized event JSONL;
- structural pair JSONL;
- pair key hashes;
- raw identifier values.

Reviewable:

- aggregate correlation summary;
- certification receipt;
- source hashes;
- pair/group counts;
- sequence-delta aggregates;
- exact target-PID aggregate attribution.

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
