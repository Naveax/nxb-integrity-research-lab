# NXB-IRL-005 — Adaptive Observability + Semantic Hardening

## Purpose

NXB-IRL-004 completed the full-system observability fabric and bounded platform-binding validation. NXB-IRL-005 is the follow-up hardening track.

Its two goals are deliberately separated:

1. **adaptive observability** — do not continuously collect maximum-detail telemetry when it is not useful;
2. **semantic promotion** — move conservative claims from `false` to `true` only when repeated controlled evidence proves the declared scope.

The design therefore treats logging level and claim truth as independent state machines.

## Adaptive capture model

Every domain has one of four effective levels:

```text
off      = control-plane receipts only
baseline = low-overhead identity, health, counters and loss accounting
focused  = temporary structural telemetry for relevant domains
forensic = short bounded high-detail capture for owned targets / explicit investigations
```

The default policy is `baseline`.

Escalation is signal-driven. Examples:

```text
manual_focus
manual_forensic
frame_latency_spike
device_transition
power_transition
error_burst
semantic_calibration
```

Each rule declares:

```text
signal -> affected domains -> requested level -> TTL -> priority
```

The planner clamps the request to each domain's configured minimum/maximum level and then applies the global elevated-domain budget.

## Budget model

Default limits:

```text
max elevated domains: 4
max capture duration:  300 s
cooldown:              30 s
max review evidence:   64 MiB
```

If more domains request focused/forensic capture than the budget permits, the highest-priority domains remain elevated and the rest are explicitly marked `budget_suppressed=true`.

No silent over-budget capture is allowed.

## High-value retention

The system always retains bounded structural records that are likely to matter later:

```text
control_plane_transition
capture_receipt
hash_manifest
loss_accounting
anomaly_summary
claim_evidence
error_boundary
```

Defaults remain conservative:

```text
raw_payload_default          = false
hash_raw_identifiers         = true
redact_messages_by_default   = true
```

Raw payload is only eligible at `forensic` level and still remains subject to the adapter-specific evidence boundary.

## Local panel

`New-NxbAdaptiveObservabilityPanel.ps1` produces a self-contained local HTML panel.

It shows:

- current capture level for every domain;
- requested level;
- why the level changed;
- TTL / expiry;
- budget suppression;
- raw-payload eligibility;
- related semantic claim targets;
- current and desired claim states;
- evidence gates required for promotion.

The panel is intentionally **read-only**. It does not expose an HTTP listener and cannot silently start capture or mutate the host.

Policy JSON and repo-owned scripts remain the authority.

## Control-plane execution

`Invoke-NxbAdaptiveObservabilityControlPlane.ps1` performs:

```text
policy + claim-target validation
-> deterministic plan
-> independent Python plan validation
-> local HTML panel
-> hash-bound control-plane receipt
```

The foundation controller explicitly records:

```text
capture_adapters_executed = false
```

Capture adapters will be connected only after the planner/panel contract is native validated.

## Claim promotion discipline

`config/semantic-claim-targets.json` records both:

```text
current_state
desired_state
```

The desired state for the remaining hardening claims is `true`, but the current state remains `false` until evidence gates pass.

Targets:

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

## Promotion order

Recommended order is based on evidence feasibility and host risk.

### Phase A — read-only / low-risk

```text
pcie_bdf_semantics
event_id_semantics
event_task_opcode_semantics
```

These should be attempted first using cross-source metadata, repeated controls and independent validators.

### Phase B — reversible controlled state

```text
power_causality
pnp_lifecycle_semantics
```

Power uses an owned temporary policy and mandatory rollback.

PnP lifecycle requires an owned or isolated device fixture; normal host device disable/remove operations are not an acceptable shortcut.

### Phase C — bounded causal fixture

```text
root_cause_validated
continuous_trace_completeness
```

Root-cause promotion is scoped to owned controlled fixtures.

Trace completeness is scoped to a **declared observation interval**, never to an infinite/global claim.

### Phase D — isolated reboot-capable environment

```text
firmware_causality
```

This claim is high risk and must not be proven by casually changing Secure Boot, TPM, VBS/HVCI or firmware state on the normal host. It requires an isolated/disposable or snapshot-restorable environment and explicit reboot-boundary evidence.

## Current foundation files

```text
schemas/adaptive-observability-policy.schema.json
config/adaptive-observability.default.json
config/semantic-claim-targets.json
examples/adaptive-observability-signals.sample.json
scripts/Get-NxbAdaptiveObservabilityPlan.ps1
scripts/New-NxbAdaptiveObservabilityPanel.ps1
scripts/Invoke-NxbAdaptiveObservabilityControlPlane.ps1
tools/validate_adaptive_observability.py
tests/AdaptiveObservabilityControl.Tests.ps1
```

## Foundation acceptance

Before any adapter is connected:

```text
PowerShell 7 Pester:      20/20
Windows PowerShell 5.1:  20/20
PSScriptAnalyzer:         0
Python syntax:            PASS
independent policy check: PASS
independent plan check:   PASS
panel generated:          PASS
receipt hashes:           PASS
capture adapters run:     false
```

After this foundation passes natively, the next implementation slice is the first semantic promotion batch:

```text
PCIe BDF cross-source calibration
provider event-ID/task/opcode metadata calibration
adaptive focused capture hooks for those calibration windows
```
