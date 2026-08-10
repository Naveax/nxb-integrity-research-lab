# NXB-IRL-004 — SUPERBLOCK 2 L2 Controlled Transition Eligibility

## Status

`IMPLEMENTED — NATIVE EXACT-HEAD VALIDATION NEXT`

Canonical predecessors:

```text
L0 binding fingerprint:
491e6797eeb1aa1d2b66d1b5d90e3087c52d68cedeae529b75d054f673ea01b7

L1 runtime head:
5da20feddb654ffb5c3e94a115c376a362f37e11

L1 provider metadata fingerprint:
540635297b3bea77ef403620309f08149fc784cb2698ac238e154ccafaa3fecc

L1 review ZIP SHA256:
f612b0e07348b883ffb0b84035de87942f7a67eb9fc1e9bb46f05b2b9dc788e5
```

## Objective

Use repeated, bounded, reversible stimuli plus matched idle controls to determine whether the L1-measured PnP and power event surfaces contain stable structural event-shape deltas eligible for later semantic study.

L2 validates controlled observation and eligibility only. It does not promote event-ID meaning or general causality.

## Scenario order

Exactly eight scenarios:

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

Each stimulus therefore has an A/B repeat and a matched idle control.

## PnP stimulus

The only PnP mutation-like action is:

```text
pnputil /scan-devices
```

Explicitly forbidden:

```text
disable device
remove device
install device/driver
delete driver
```

The PnP observation surfaces are derived from L1 logs whose status was `available` for:

```text
Microsoft-Windows-Kernel-PnP
Microsoft-Windows-UserPnp
```

## Power stimulus

For each repeat:

```text
read exact active power scheme GUID
hash original GUID for review evidence
powercfg /duplicatescheme <original>
activate owned temporary duplicate
hold 500 ms
restore exact original scheme
verify original is active
delete owned temporary duplicate
```

The cleanup path is guarded by `finally`. If a temporary scheme was created and normal restoration/deletion did not complete, the runner retries restore/delete before returning.

A power stimulus is successful only if all are true:

```text
temporary scheme created
temporary scheme activated
original scheme restored
temporary scheme deleted
```

The power observation surfaces are derived from L1 `available` logs for:

```text
Microsoft-Windows-Kernel-Power
Microsoft-Windows-Kernel-Processor-Power
```

## Event observation

Each scenario records only structural aggregates:

```text
provider
log
event ID
version
level
task
opcode
count
```

Default bounds:

```text
idle window:          1500 ms
post-stimulus wait:   1500 ms
max events/log:       256
```

`NoMatchingEventsFound` is treated as a successful bounded query with measured zero. Other query failures remain `unavailable` with a null event count.

No message, XML, payload, Properties, EventData or UserData is review evidence.

## Differential eligibility analysis

For each family and repeat:

```text
positive_delta = stimulus shape count - matched idle shape count
```

Only positive deltas are retained.

A shape is `mapping_eligible` only if the same structural key has a positive delta in both A and B repeats.

```text
repeated = positive_delta_A intersection positive_delta_B
```

Zero repeated candidates is a valid measured outcome. The certification does not fail merely because a family has no repeatable signal.

## Native gate

```text
PowerShell 7 tests:               20/20
Windows PowerShell 5.1 tests:     20/20
PSScriptAnalyzer findings:        0
Python syntax:                    PASS
canonical L1 evidence binding:    PASS
scenario count:                   8
PnP rescans succeeded:            2/2
power transitions succeeded:      2/2
original power scheme restored:   2/2
temporary schemes deleted:        2/2
differential analysis replay:     byte-identical
```

Reported measurements:

```text
PnP repeated positive-delta shape count
PnP mapping eligibility
Power repeated positive-delta shape count
Power mapping eligibility
```

No minimum signal count is declared.

## Evidence boundary

Review ZIP contains only bounded JSON:

```text
platform-transition-observations.json
platform-transition-eligibility.json
platform-transition-certification-receipt.json
```

Forbidden review content/artifacts include:

```text
ETL
EVTX
XML
JSONL
raw event content
powercfg raw output
pnputil raw output
raw original power-scheme GUID
```

## Claim boundary

L2 may validate:

```text
controlled_transition_observation_validated: true
pnp_mapping_eligible: measured boolean
power_mapping_eligible: measured boolean
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

Firmware, Secure Boot, TPM, VBS and Device Guard are never toggled merely to generate evidence.
