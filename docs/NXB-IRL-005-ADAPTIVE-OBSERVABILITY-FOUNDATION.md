# NXB-IRL-005 — Adaptive Observability Control Plane

## Status

`IMPLEMENTED — NATIVE EXACT-HEAD VALIDATION NEXT`

Predecessor:

```text
NXB-IRL-004 main merge:
9488d75f703692c501a70a73111d88ee93ff42eb
```

## Objective

Keep normal observability lightweight and selectively escalate collection depth when an anomaly, controlled experiment, domain-state change, trace-loss condition, or explicit operator request makes deeper evidence useful.

The control plane does not equate feature presence with semantic validation. All semantic-hardening targets remain evidence-gated.

## Logging modes

```text
off
minimal
normal
deep
forensic
```

Default mode is `minimal`; maximum mode is `forensic`.

Global bounds include disk/hour, event rate, session duration, concurrent domain count, pre-trigger window and post-trigger window.

Raw identifiers, formatted event messages, payload fields and network payloads are disabled by default.

## Adaptive trigger state

Trigger evaluation is stateful:

```text
signal match
 -> activate trigger
 -> minimum hold window
 -> deactivation after hold expires
 -> cooldown window
 -> eligible for reactivation
```

State is evaluated deterministically with injectable UTC time in the test contract. A stateless current-signal evaluation cannot bypass cooldown while trigger-state authority is present.

## Local operator panel

The operator surface is localhost-only.

```text
bind: 127.0.0.1 / localhost only
mode override: bounded by policy maximum
TTL: bounded by manual_override_max_seconds
automatic fallback: override removed after expiry
mutation protection: per-process 256-bit token
```

Mutating endpoints require `X-NXB-Panel-Token`. The token is injected only into the served local HTML and is not returned by status/health responses or written to review evidence.

## Capture manifest

Resolved plans are mapped to repo-owned capture primitives through:

```text
config/adaptive-observability-domain-map.json
scripts/Resolve-NxbAdaptiveCaptureManifest.ps1
tools/validate_adaptive_capture_manifest.py
```

Each active domain is surfaced as:

```text
ready       -> required repo-owned assets exist
pending     -> semantic adapter intentionally not yet certified
unavailable -> required repo asset is missing
```

The local panel shows adapter kind, runtime surface, selected assets, readiness and reason. Missing/pending adapters are never silently treated as ready.

## Semantic-hardening targets

All eight requested targets are present with:

```text
target_requested = true
validated = false
```

until an evidence receipt and bounded scope exist:

```text
pnp_lifecycle_semantics
pcie_bdf_semantics
event_id_semantics
event_task_opcode_semantics
power_causality
firmware_causality
root_cause_validated
continuous_trace_completeness
```

A validated claim requires a non-empty scope plus a SHA-256 evidence receipt.

## V4 native gate

Expected authority:

```text
PowerShell 7:             48/48
Windows PowerShell 5.1:   48/48
PSScriptAnalyzer:          0
Python policy validator:   PASS
Python manifest validator: PASS
empty-plan replay:         byte-identical
stateful hold/cooldown:    PASS
panel mutation token:      PASS
root-cause capture map:    8 bounded domains
unavailable root-cause:    0
```

The review ZIP remains JSON-only and excludes ETL/EVTX/XML/JSONL/native binaries, raw PnP identifiers and panel mutation tokens.

Tracks #17.
