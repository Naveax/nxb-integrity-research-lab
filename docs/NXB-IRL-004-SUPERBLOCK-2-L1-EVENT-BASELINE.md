# NXB-IRL-004 — SUPERBLOCK 2 L1 Platform Event Baseline

## Status

`IMPLEMENTED — V4 NATIVE EXACT-HEAD VALIDATION NEXT`

L0 canonical predecessor:

```text
runtime head:
4ea3343b24d041cb417e110565230c5a19bd1773

L0 review ZIP SHA256:
6cb9ddfcd607b8aa98c7f7667201b21611bef2d86147146cce9cc39235083a2b

L0 binding fingerprint:
491e6797eeb1aa1d2b66d1b5d90e3087c52d68cedeae529b75d054f673ea01b7
```

## Objective

Measure the real event-definition and recent-log surfaces exposed by all eight L0-validated platform providers before introducing controlled PnP or power transitions.

L1 is read-only. It does not disable devices, install/uninstall drivers, change power plans, alter Secure Boot/TPM/VBS/Device Guard, or start WPR.

## Provider set

Exactly the eight providers measured available during L0:

```text
Microsoft-Windows-CodeIntegrity
Microsoft-Windows-DeviceGuard
Microsoft-Windows-Kernel-Boot
Microsoft-Windows-Kernel-PnP
Microsoft-Windows-Kernel-Power
Microsoft-Windows-Kernel-Processor-Power
Microsoft-Windows-UserPnp
Microsoft-Windows-WHEA-Logger
```

Provider GUIDs are independently locked by the Python validator to the L0-native values.

## Metadata inventory

For each provider the collector records only structural metadata:

```text
provider name / GUID
event ID
version
level
task
opcode
keyword display names
attached log names
```

No event message, XML, payload, EventData/UserData, or formatted description is retained.

## Bounded recent-event baseline

For each attached log:

```text
log enabled/status
record count metadata
up to 128 recent provider events
7-day lookback
aggregate structural shapes only
oldest/newest sampled timestamp
```

A structural shape is:

```text
event ID + version + level + task + opcode + count
```

Individual event records are discarded after aggregation.

Log states remain explicit:

```text
available   -> successful bounded query; sampled count may be zero
disabled    -> known disabled log; sampled count is measured zero
unavailable -> query/list failure; sampled count is null
```

Unavailable is never synthesized as zero.

## Stable metadata fingerprint

A provider-metadata fingerprint is computed from:

```text
L0 binding fingerprint
provider names / status / GUIDs
provider event definitions
attached log names
```

Recent activity is excluded from this fingerprint. Two native baselines must therefore have identical metadata fingerprints while recent sampled-event counts are allowed to differ.

The Python validator independently rebuilds and hashes the same metadata material.

## Native history

### V1

```text
head: 87250d31760a9e2564ed001ac78d2727e2356d19
PSScriptAnalyzer findings: 2
cause: unused baselineA / baselineB assignments
native collection: not reached
```

### V2

```text
head: bc4625d9dfee825d2cfd82d35d453ab9b72ab615
PS7 / PS5.1: 20/20 + 20/20
PSScriptAnalyzer: 0
L0 binding: PASS
baseline A: collected
failure: providers[4].event_definitions[150].keywords must be sorted unique
```

Root cause: PowerShell and Python string ordering semantics differed.

### V3

```text
head: 3967abab427a8892ce420bf2cc83af60989b6e53
PSScriptAnalyzer findings: 4
cause: four ordinal ordering helpers used unapproved Sort- verb
native collection: not reached
```

### V4 candidate

```text
runtime/test head:
5da20feddb654ffb5c3e94a115c376a362f37e11
```

The ordinal algorithm is unchanged. The four ordering helpers now use approved `Get-` verbs:

```text
Get-NxbPlatformEventV3OrderedDefinitionInventory
Get-NxbPlatformEventV3OrderedShapeInventory
Get-NxbPlatformEventV3OrderedLogInventory
Get-NxbPlatformEventV3OrderedProviderInventory
```

The focused ordinal test rejects the superseded `Sort-NxbPlatformEventV3` prefix.

## Cross-runtime ordering contract

```text
keywords            ordinal unique via SortedSet + StringComparer.Ordinal
event_definitions   id/version + ordinal UTF-8 level/task/opcode
shapes              id/version + ordinal UTF-8 level/task/opcode
logs                ordinal UTF-8 log_name
providers           ordinal UTF-8 provider_name
```

## Native gate

```text
PowerShell 7 contract:          28/28
Windows PowerShell 5.1:        28/28
PSScriptAnalyzer findings:      0
Python syntax:                  PASS
canonical L0 review binding:    PASS
baseline A validation:          PASS
baseline B validation:          PASS
provider count:                 exactly 8
metadata fingerprint A == B:    true
event definition inventory:     > 0
attached log inventory:         > 0
readable recent-log queries:    > 0
ordering contract:              utf8_ordinal
```

Recent sampled-event count is reported but is not required to be identical across A/B.

## Evidence boundary

The review ZIP contains only:

```text
platform-event-baseline-a.json
platform-event-baseline-b.json
platform-event-validation-a.json
platform-event-validation-b.json
platform-event-certification-receipt.json
```

Forbidden review artifacts/content include ETL, EVTX, XML, JSONL, raw-event material, message, XML, payload, Properties/EventData/UserData fields.

## Claim boundary

L1 may promote only:

```text
provider_metadata_inventory:             true
bounded_recent_event_shape_inventory:    true
provider_metadata_stable:                true
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

L1 results determine which event IDs/logs are eligible for later controlled PnP and power-transition experiments. Firmware/security state is not toggled merely to create events.
