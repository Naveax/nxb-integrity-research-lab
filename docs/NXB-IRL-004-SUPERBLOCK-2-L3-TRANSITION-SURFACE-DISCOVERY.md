# NXB-IRL-004 — SUPERBLOCK 2 L3 Transition Surface Discovery

## Status

`IMPLEMENTED — NATIVE EXACT-HEAD VALIDATION NEXT`

Runtime/test candidate:

```text
00d263c2bc6b0166f4ed4877f6cc4844269de9ff
```

Canonical L2 predecessor:

```text
runtime head:
ff8bd98ba5c6aa1d223561546f362ebc215640dd

review ZIP SHA256:
d9c355d631bfa7b9248309bedd8e47d4b46b4b35b162ac3a6a7374dc354efaa4
```

## Motivation

L2 validated both controlled stimuli but observed measured zero events on all six selected L1-readable transition surfaces. L3 therefore broadens provider/log discovery before repeating the matched-control experiment. It does not infer semantics from historical event IDs and does not merely lengthen the same six surfaces.

## Dynamic discovery

Windows provider metadata is enumerated and bounded to provider names matching structural families:

```text
PnP family:
pnp | device | setup | install

Power family:
power | energy | battery | processor
```

For each matching provider, attached logs are discovered from provider metadata and their enabled/availability state is measured.

Bounds:

```text
max providers: 64
max discovered surfaces: 128
max replay surfaces per family: 32
```

Provider and log ordering uses UTF-8 ordinal keys. String sets use `StringComparer.Ordinal`.

## Discovery fingerprint

The discovery snapshot uses an explicit cross-runtime fingerprint contract:

```text
ordinal_tsv_v1
```

The fingerprint material contains the canonical predecessor bindings plus ordered provider and surface records. Python independently rebuilds the same material and verifies SHA-256.

Two discovery snapshots are required and their discovery fingerprint must match.

## Controlled replay

Exactly the same eight scenarios are retained:

```text
idle_pnp_a
pnp_rescan_a
idle_pnp_b
pnp_rescan_b
idle_power_a
power_transition_a
idle_power_b
power_transition_b
```

PnP stimulus remains only:

```text
pnputil /scan-devices
```

Power stimulus remains an owned temporary duplicate of the exact active scheme followed by mandatory original-scheme restoration and owned duplicate deletion.

Default matched windows are 3000 ms. These windows apply to newly discovered surfaces, not merely the six L2 surfaces.

## Differential analysis

The existing independently validated structural differential analyzer is reused. For each family, mapping eligibility requires the same positive-delta provider/log/event-shape key in both A and B repeats.

A zero repeated-candidate count remains a valid measured result and does not fail certification.

## Native gate

```text
PowerShell 7 contract:               20/20
Windows PowerShell 5.1:             20/20
PSScriptAnalyzer findings:           0
Python syntax:                       PASS
canonical L2 evidence binding:       PASS
discovery A validation:              PASS
discovery B validation:              PASS
discovery fingerprint stable:        true
PnP usable discovered surfaces:      > 0
power usable discovered surfaces:    > 0
scenario count:                      8
PnP rescans:                         2/2 successful
power transitions:                   2/2 successful
original scheme restore/delete:      2/2
analysis replay:                     byte-identical
```

Reported without threshold:

```text
provider count
surface count
usable surface count
PnP repeated positive-delta shapes
PnP mapping eligibility
power repeated positive-delta shapes
power mapping eligibility
```

## Evidence boundary

Review evidence contains bounded discovery, validation, observation, analysis and receipt JSON only. ETL, EVTX, XML, JSONL, raw event messages/XML/payload and native artifacts are forbidden.

## Claim boundary

Still false/unclaimed:

```text
event_id_semantics
event_task_opcode_semantics
device_lifecycle_semantics
power_causality
firmware_causality
root_cause_validated
continuous_trace_completeness
```

Firmware/security state is never toggled merely to create events.
