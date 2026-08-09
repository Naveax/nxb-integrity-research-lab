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

Canonical native correlation **code** head:

```text
8bb94d10b4a74629668ddee2ad2fe378f8928999
```

Later branch commits only document the already-observed portable wrapper issue and its hardening; they do not change the correlation analyzer/certification code represented by the canonical code head above.

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

## Hardened portable V2

V2 removes direct optional nested-property dereferences. All result/JSON traversal goes through StrictMode-safe accessors.

Hardening covers:

```text
StrictMode missing-property access
sparse PSCustomObject and IDictionary traversal
null nested values
string-vs-boolean conversion (including "False")
numeric conversion failures
missing/stale evidence roots
multiple success-output objects
review ZIP existence + SHA drift
missing critical fields
optional count presentation
```

Before touching evidence, V2 self-tests:

```text
sparse PSCustomObject missing GPU count -> 0
existing kernel count -> preserved
nested ordered dictionary -> traversed
string "False" -> false
missing nested path -> requested default
```

Reuse-first flow:

1. search for the already-completed exact-head correlation output from V1;
2. validate implementation head, capture/normalizer heads, normalized-event SHA, normalized rows, target-PID rows, pair count, replay flags, conservative claim boundary, and review ZIP SHA;
3. if all checks match, reuse the completed native pass and render the hardened summary only;
4. otherwise clone the canonical code head and rerun the repo-owned correlation certification.

Required fields never silently default. Missing required fields raise explicit controlled errors. Optional aggregate counts may default to zero for presentation only.

## Structural correlation layers

The gate covers structural DXGI Present/MPO start-stop pairing, process/thread/image lifecycle and rundown pairing, hashed TCP/DNS/registry grouping, exact PID/TID attribution, target-PID sequence adjacency, and byte-identical pair/summary replay.

Raw addresses, ports, DNS values, registry paths, normalized rows, and pair-key hashes remain local.

## Claims

May be certified:

```text
sequence_order_correlation:          true
exact_pid_attribution:               true
exact_tid_attribution_when_present:  true
hashed_identifier_grouping:          true
structural_start_stop_pairing:       true
```

Must remain false/unclaimed:

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
