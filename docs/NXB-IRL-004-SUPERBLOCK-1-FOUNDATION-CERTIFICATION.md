# NXB-IRL-004 SUPERBLOCK 1 — Native foundation certification

## Status

```text
PASS
```

Exact validated head:

```text
6e167e363d09ffc610d6c03fcbbb6f6d6f9083c9
```

Native Windows exact-head validation is authoritative. GitHub Actions remain intentionally disabled.

## Combined static and dual-runtime gate

```text
PowerShell 7 Pester:          24/24
Windows PowerShell 5.1:      24/24
PSScriptAnalyzer findings:   0
certification runner parser: PASS
capability/event integration: PASS
semantic claims enabled:     false
```

The aggregate gate is composed of three 8-test contracts:

```text
GPU provider inventory:       8/8 + 8/8
GPU provider metadata:        8/8 + 8/8
remaining provider inventory: 8/8 + 8/8
```

## Real GPU provider inventory

```text
display adapters:             3
GPU/graphics providers:       15
GPU/graphics event channels:  18
```

## Real repaired GPU provider metadata

```text
Microsoft-Windows-DxgKrnl
GUID observed:          true
keyword rows:           38
publisher metadata:     measured
keyword contamination: false

Microsoft-Windows-DXGI
GUID observed:          true
keyword rows:           5
publisher metadata:     measured
keyword contamination: false
```

The metadata parser remains section-bounded and rejects executable/path contamination. Keyword identity is observed host metadata; event-ID, payload, timing, queue and present semantics remain unpromoted.

Observed DxgKrnl keyword identities include the bounded capture candidates used by the next profile batch:

```text
0x0000000000008000 GPUScheduler
0x0000000000010000 DxgKrnl
0x0000000008000000 Present
```

Observed DXGI candidate:

```text
0x0000000000000002 Events
```

## Real remaining-provider inventory

```text
network providers:          50
kernel lifecycle providers: 155
device/driver providers:    67
power/thermal providers:    17
```

These are candidate identity inventories only. They do not establish provider keyword masks, event IDs, connection/latency semantics, lifecycle semantics, or representative power/thermal behavior.

## Full-system capability snapshot

Schema validation passed for the real snapshot.

Required capability domains:

```text
gpu:             available
network:         available
bus_and_devices: available
firmware:        available
security:        available
power:           available
```

```text
capability collection errors: 0
```

## Review evidence

Local run root:

```text
C:\Users\navea\Downloads\nxb-superblock1-foundation-6e167e363d09-20260809-004522
```

Bounded receipt:

```text
review\superblock1-foundation-certification-receipt.json
SHA256 a6426be30020a267a39332313e724eddd435979861ba0e66b6aa7c715b568a66
```

Bounded review ZIP:

```text
superblock1-foundation-certification-review.zip
SHA256 0bc8dd7fd9b0968ad3e55ccaf3dad94bd87bf6641c2a8d267bc39aaddb9d9d8a
```

Raw inventory and capability JSON remain local under `raw-local` and are not promoted into the review ZIP.

## Conservative boundary

```text
keyword_semantics_validated:         false
event_ids_validated:                 false
present_semantics:                   false
submission_semantics:                false
gpu_queue_semantics:                 false
network_connection_semantics:        false
network_latency_semantics:           false
device_lifecycle_semantics:          false
kernel_lifecycle_semantics:          false
power_thermal_representative:        false
firmware_security_effect_semantics:  false
trace_completeness:                  not_claimed
```

## Next batch

The foundation gate is closed. The next implementation batch may now author bounded capture/adaptor components from the certified observations.

GPU has sufficient observed keyword identity to author the first bounded WPR profile. Network/kernel candidate identities still require bounded provider metadata probing before keyword-filtered WPR profiles are promoted. Device/power/firmware work can reuse the existing capability snapshot contract and add normalization/adaptor logic without inventing event semantics.
