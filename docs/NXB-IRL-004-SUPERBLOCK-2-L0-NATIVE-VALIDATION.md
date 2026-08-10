# NXB-IRL-004 — SUPERBLOCK 2 L0 Native Validation

## Status

`VALIDATED — EXACT-HEAD NATIVE WINDOWS EVIDENCE`

Canonical runtime/test head:

```text
4ea3343b24d041cb417e110565230c5a19bd1773
```

Native authority environment:

```text
host:       NAVEAX
OS:         Microsoft Windows 10.0.22631
PowerShell: 7.6.4
```

## Static/native gate

```text
PowerShell 7 Pester:       20/20
Windows PowerShell 5.1:   20/20
PSScriptAnalyzer findings: 0
Python syntax:             PASS
```

Both V2 snapshots passed the independent Python validator.

## Stable platform binding

```text
binding fingerprint SHA256:
491e6797eeb1aa1d2b66d1b5d90e3087c52d68cedeae529b75d054f673ea01b7

snapshot A fingerprint: identical
snapshot B fingerprint: identical
machine identity:       stable
boot identity:          stable
canonicalization:       V2 / array cardinality preserved
```

The two bounded snapshots differed only in `captured_utc`. Stable binding material remained identical.

## Measured host inventory

```text
PnP devices:            210
PCI-classified devices: 40
signed-driver records:  212
system-driver records:  455
PCI enrichment:         40 attempted / 40 succeeded / 0 failed
```

No PCIe BDF semantic claim is promoted by the observed bus/address properties.

## Platform event-source availability

All eight planned L1 provider surfaces were available on the native host:

```text
Microsoft-Windows-CodeIntegrity
  GUID: 4ee76bd8-3cf4-44a0-a0ac-3937643e37a3
  logs: Operational, Verbose

Microsoft-Windows-DeviceGuard
  GUID: f717d024-f5b4-4f03-9ab9-331b2dc38ffb
  logs: Operational, Verbose

Microsoft-Windows-Kernel-Boot
  GUID: 15ca44ff-4d7a-4baa-bba5-0998955e531e
  logs: Analytic, Operational, System

Microsoft-Windows-Kernel-PnP
  GUID: 9c205a39-1250-487d-abd7-e831c6290539
  logs: Boot Diagnostic, Configuration, Configuration Diagnostic,
        Device Enumeration Diagnostic, Device Management,
        Driver Diagnostic, Driver Watchdog, System

Microsoft-Windows-Kernel-Power
  GUID: 331c3b3a-2005-44c2-ac5e-77220c37d6b4
  logs: Diagnostic, Thermal-Diagnostic, Thermal-Operational, System

Microsoft-Windows-Kernel-Processor-Power
  GUID: 0f67e49f-fe51-4e9f-b490-6f2948cc6027
  logs: Diagnostic, System

Microsoft-Windows-UserPnp
  GUID: 96f4a050-7e31-453c-88be-9634f4e02139
  logs: ActionCenter, DeviceInstall, DeviceMetadata/Debug,
        Performance, SchedulerOperations, System

Microsoft-Windows-WHEA-Logger
  GUID: c26c4f3c-3f66-4e99-8f8a-39405cfed220
  logs: System
```

Provider availability is discovery evidence only. It does not establish event-ID semantics, lifecycle semantics, timing semantics, causality, or trace completeness.

## Firmware / security surfaces

```text
Secure Boot:       available
TPM:               available
Device Guard/VBS:  available
boot configuration: available
battery surface:   available
ACPI thermal zones: unavailable
```

The ACPI thermal-zone query returned a capability failure and is recorded as unavailable. No zero-temperature or representative-thermal value is synthesized.

## Evidence hashes

```text
certification receipt SHA256:
8a36b5d3adf1835b662142b9bd4050e0b9572199c54e1a9bdf9064b8bd4983d5

review ZIP SHA256:
6cb9ddfcd607b8aa98c7f7667201b21611bef2d86147146cce9cc39235083a2b

snapshot A SHA256:
4cbac05a406d1a7340f235c24d7521f439850502279eca64d16ee9245280c7b0

snapshot B SHA256:
ac73eae2c320b034b3fc5eb8ad6a10d40b93cc892b74768fdc1d5e60e6c97be5

validation A/B SHA256:
1af3d38cd384e49a4658717948ef850f5e67ce5b566ceedb5d3de520216ee6fc
```

Independent review-boundary audit found exactly five bounded JSON entries and no ETL, EXE, OBJ, PDB, JSONL, raw machine identifier, raw PnP identifier, or serial-number leakage.

## Claim boundary after L0

Promoted:

```text
stable_platform_binding_fingerprint:        true
sanitized_device_driver_inventory:          true
sanitized_power_firmware_security_snapshot: true
platform_event_source_inventory:            true
```

Still false/unclaimed:

```text
pcie_bdf_semantics:             false
device_lifecycle_semantics:     false
thermal_representativeness:     false
power_causality:                false
firmware_causality:             false
root_cause_validated:           false
continuous_trace_completeness:  not_claimed
```

## L1 consequence

Because all eight planned event providers are available, L1 proceeds with read-only provider metadata enumeration plus bounded recent-event baseline collection. Controlled device/power transitions remain a later gate after real event IDs/tasks/opcodes/keywords are measured. Firmware/security state will not be toggled merely to manufacture events.
