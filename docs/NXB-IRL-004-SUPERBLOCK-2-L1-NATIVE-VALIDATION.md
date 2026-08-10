# NXB-IRL-004 — SUPERBLOCK 2 L1 Native Validation

## Status

`VALIDATED — CANONICAL NATIVE WINDOWS EVIDENCE`

Canonical runtime/test head:

```text
5da20feddb654ffb5c3e94a115c376a362f37e11
```

Environment observed by the native transcript:

```text
Windows:       Microsoft Windows 10.0.22631
PowerShell 7:  7.6.4
PSEdition:     Core
```

## Static authority

```text
PowerShell 7 core contract:       20/20
PowerShell 7 ordinal contract:     8/8
Windows PowerShell 5.1 core:      20/20
Windows PowerShell 5.1 ordinal:    8/8
PSScriptAnalyzer findings:         0
Python syntax:                     PASS
```

Combined native contract authority is therefore `28/28` on both PowerShell runtimes.

## Canonical predecessor binding

```text
L0 review ZIP SHA256:
6cb9ddfcd607b8aa98c7f7667201b21611bef2d86147146cce9cc39235083a2b

L0 binding fingerprint:
491e6797eeb1aa1d2b66d1b5d90e3087c52d68cedeae529b75d054f673ea01b7
```

The L1 certification accepted the predecessor hash/fingerprint before collecting event metadata.

## Native L1 result

```text
provider count:                    8
event definitions:                 1409
attached logs:                     28
baseline A readable log queries:   9
baseline A sampled events:         558
baseline B readable log queries:   9
baseline B sampled events:         558
provider metadata stable A/B:      true
```

Canonical provider-metadata fingerprint:

```text
540635297b3bea77ef403620309f08149fc784cb2698ac238e154ccafaa3fecc
```

The complete A/B baseline content was independently compared after the run. Aside from `captured_utc`, the two baseline JSON objects were identical.

## Measured recent structural shapes

The bounded seven-day baseline observed recent events on the following provider/log surfaces:

```text
Microsoft-Windows-CodeIntegrity/Operational
Microsoft-Windows-Kernel-Boot/Operational
System — Microsoft-Windows-Kernel-Boot
Microsoft-Windows-Kernel-PnP/Configuration
Microsoft-Windows-Kernel-PnP/Device Management
System — Microsoft-Windows-Kernel-PnP
System — Microsoft-Windows-Kernel-Power
System — Microsoft-Windows-Kernel-Processor-Power
Microsoft-Windows-UserPnp/DeviceInstall
```

Notable observed structural IDs, without semantic promotion:

```text
Kernel-PnP Configuration:       400, 410, 411, 420
Kernel-PnP Device Management:   1010
Kernel-PnP System:              219
UserPnp DeviceInstall:          8001, 8004, 8005, 8008
Kernel-Power System:            41, 109, 172, 566, 577
Kernel-Processor-Power System:  55
```

These are structural observations only. Event-ID meaning is not inferred from the numeric identifiers or localized display names.

## Query-state semantics

Some provider/log combinations returned `No events were found that match the specified selection criteria` during the bounded query. The collector handled those through its explicit unavailable path rather than synthesizing zero.

Therefore:

```text
successful query with no events -> measured zero
unavailable/failed query        -> null / unavailable
```

The distinction remains part of the evidence contract.

## Evidence

```text
receipt SHA256:
b7e041f6ac80e6097674a54227f3aae4ef835639c31dd0c3e9e060ac5d9e256a

review ZIP SHA256:
f612b0e07348b883ffb0b84035de87942f7a67eb9fc1e9bb46f05b2b9dc788e5
```

Independent review ZIP audit:

```text
entries: 5 bounded JSON files
ETL:     absent
EVTX:    absent
XML:     absent
JSONL:   absent
EXE/OBJ/PDB: absent
raw message/XML/payload/EventData/UserData tokens: absent
```

## Claim boundary after L1

Validated:

```text
provider_metadata_inventory:           true
bounded_recent_event_shape_inventory:  true
provider_metadata_stable:              true
cross_runtime_ordinal_ordering:         true
```

Still false/unclaimed:

```text
event_id_semantics:                false
event_task_opcode_semantics:       false
device_lifecycle_semantics:        false
power_causality:                   false
firmware_causality:                false
root_cause_validated:              false
continuous_trace_completeness:     not_claimed
```

## Next gate

L2 uses matched idle controls plus two bounded, reversible stimulus families:

```text
PnP:    pnputil /scan-devices
Power:  temporary duplicate power scheme -> activate -> restore original -> delete temporary scheme
```

L2 does not disable devices and does not alter firmware, Secure Boot, TPM, VBS or Device Guard state. Structural signal presence/absence is measured; event semantics are still not promoted merely because a shape appears after a stimulus.
