# NXB-IRL-004 — SUPERBLOCK 2 L2 Native Validation

## Status

`VALIDATED — ZERO-SIGNAL ON L1-READABLE TRANSITION SURFACES`

Canonical runtime/test head:

```text
ff8bd98ba5c6aa1d223561546f362ebc215640dd
```

Canonical predecessor L1 review ZIP SHA256:

```text
f612b0e07348b883ffb0b84035de87942f7a67eb9fc1e9bb46f05b2b9dc788e5
```

## Native authority

```text
PowerShell 7 contract:          20/20
Windows PowerShell 5.1:        20/20
PSScriptAnalyzer findings:      0
scenario count:                 8
PnP rescan repeats:             2/2 successful
power transition repeats:       2/2 successful
analysis replay:                byte-identical
```

## Controlled stimuli

PnP:

```text
pnputil /scan-devices
```

No device disable, remove, install or driver mutation was used.

Power:

```text
capture exact active scheme
create owned duplicate
activate owned duplicate
restore original
verify original active
remove owned duplicate
```

Both repeats reported temporary scheme created/activated, original scheme restored and owned temporary scheme deleted. Firmware, Secure Boot, TPM and Device Guard were not changed.

## Measured transition surfaces

PnP surfaces inherited from L1:

```text
Microsoft-Windows-Kernel-PnP / Configuration
Microsoft-Windows-Kernel-PnP / Device Management
Microsoft-Windows-Kernel-PnP / System
Microsoft-Windows-UserPnp / DeviceInstall
```

Power surfaces inherited from L1:

```text
Microsoft-Windows-Kernel-Power / System
Microsoft-Windows-Kernel-Processor-Power / System
```

All selected surfaces were queryable during all eight scenarios. Every matched idle and stimulus window returned measured `sampled_event_count = 0` on these surfaces.

Therefore:

```text
pnp repeated positive-delta shapes:   0
pnp mapping eligible:                 false
power repeated positive-delta shapes: 0
power mapping eligible:               false
```

This is a measured zero-signal result, not an unavailable result.

## Evidence

```text
observation SHA256:
7d543225012bb0359e1eee0b6f0cfeafdfd74939509e388f065070902ad5625b

analysis SHA256:
aca05cae552e76d24d19bb7f1752b4858dc0c871ac62d514510b74f4771ebb78

receipt SHA256:
96dac40e4be8eee6e17800df7c5f6c2d4e6fd69205961fe5e8dd98fa9a1140bd

review ZIP SHA256:
d9c355d631bfa7b9248309bedd8e47d4b46b4b35b162ac3a6a7374dc354efaa4
```

Independent review audit found exactly three bounded JSON files and no ETL, EVTX, XML, JSONL, raw event payload or native artifact.

## Claim boundary

Validated:

```text
controlled_pnp_rescan_execution:        true
controlled_power_transition_execution:  true
original_power_scheme_restoration:      true
owned_temporary_scheme_cleanup:         true
differential_analysis_replay:           true
```

Still false/unclaimed:

```text
pnp_mapping_eligible:               false
power_mapping_eligible:             false
event_id_semantics:                 false
device_lifecycle_semantics:         false
power_causality:                    false
firmware_causality:                 false
root_cause_validated:               false
continuous_trace_completeness:      not_claimed
```

## Consequence

L3 must not infer semantics from the L1 historical IDs or merely increase the same six surface windows. It must first broaden transition-surface discovery using Windows provider metadata, then repeat the same matched idle/stimulus A/B protocol over the newly discovered provider/log pairs.
