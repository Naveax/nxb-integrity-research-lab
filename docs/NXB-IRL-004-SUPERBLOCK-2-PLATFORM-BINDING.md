# NXB-IRL-004 — SUPERBLOCK 2 Platform Binding

## Status

`IMPLEMENTED — NATIVE EXACT-HEAD VALIDATION NEXT`

- Tracking issue: `#2`
- Parent workstream: PR `#12`, SUPERBLOCK 1 closed/validated
- Branch: `nxb-irl-004-superblock2-platform-binding`
- GitHub Actions: intentionally disabled repository-wide
- Authority: native exact-head Windows validation

## Objective

Close the remaining full-system L0 platform context required by Issue #2 before adding deeper device/power/firmware event traces:

```text
B — PCIe / PnP / device / driver binding
P — power / frequency / thermal snapshot
F — firmware / boot / security binding
```

The existing general capability collector already exposes coarse versions of several of these surfaces. SUPERBLOCK 2 does not duplicate that collector and call the duplication progress. It adds a sanitized, independently validated, stable binding contract suitable for experiment provenance.

## Implemented components

```text
schemas/platform-binding-snapshot.schema.json
scripts/Get-NxbPlatformBindingSnapshot.ps1
scripts/Test-NxbPlatformBindingSnapshot.ps1
tools/validate_platform_binding_snapshot.py
tests/PlatformBindingSnapshot.Tests.ps1
scripts/Invoke-NxbSuperblock2PlatformBindingCertification.ps1
```

## Sanitization boundary

Reviewable snapshots do not expose:

- raw machine UUID/computer name,
- raw PnP instance IDs,
- BIOS/baseboard serial numbers,
- raw location paths,
- raw BCD output.

Stable identifiers are represented with SHA-256 where binding is required. The independent Python validator recursively scans the snapshot for forbidden raw identifier keys and common raw PnP identifier patterns.

## Stable binding material

The binding fingerprint is independently recomputed from:

```text
identity
bindings.devices
bindings.power
bindings.firmware_security
event_sources
```

Volatile state is explicitly excluded:

```text
processor current clock
battery state
thermal zones / exposed temperatures
```

The native gate captures two snapshots and requires identical:

```text
machine_id_sha256
boot_utc
binding_fingerprint_sha256
```

A changed stable fingerprint is a validation failure. Volatile values may change without invalidating the binding.

## Device / driver contract

Snapshot evidence includes, where available:

- PnP entity inventory,
- hashed PnP instance identity,
- class/manufacturer/service/status,
- ConfigManager problem counts,
- PCI classification,
- observed `DEVPKEY_Device_BusNumber`, `DEVPKEY_Device_Address`, location info and hashed location paths,
- signed-driver version/provider/INF/signature state,
- bounded system-driver inventory.

Observed bus/address metadata does not promote PCIe BDF semantics. Device lifecycle semantics also remain false until controlled event evidence exists.

## Event-source discovery

The L0 gate inventories availability and attached logs for exactly these platform event providers:

```text
Microsoft-Windows-Kernel-PnP
Microsoft-Windows-UserPnp
Microsoft-Windows-WHEA-Logger
Microsoft-Windows-Kernel-Power
Microsoft-Windows-Kernel-Processor-Power
Microsoft-Windows-Kernel-Boot
Microsoft-Windows-CodeIntegrity
Microsoft-Windows-DeviceGuard
```

Provider availability is discovery evidence for later L1/L2 work; absence of a provider is not synthesized as zero events.

## Power / thermal contract

Stable binding includes the canonical active Windows power-scheme GUID.

Volatile evidence includes:

- processor current/max clock metadata exposed by `Win32_Processor`,
- battery state exposed by `Win32_Battery`,
- ACPI thermal-zone temperatures exposed by `MSAcpi_ThermalZoneTemperature`.

Thermal zones may be unavailable on desktop firmware. An unavailable thermal surface is recorded as unavailable, not as `0 °C`. Any exposed ACPI temperature is still not claimed representative of CPU/GPU/package temperature.

## Firmware / security contract

The snapshot records explicit availability/state for:

- BIOS and baseboard identity without serials,
- Secure Boot,
- TPM,
- Device Guard / VBS numeric status fields,
- hypervisor and processor virtualization/SLAT capability,
- selected BCD state (`debug`, `testsigning`, `nointegritychecks`, `hypervisorlaunchtype`).

Raw BCD output is not retained. Only its SHA-256 plus selected state fields are emitted.

## Conservative claims

Every snapshot keeps these claims false:

```text
raw_machine_identifier_exposed:         false
raw_pnp_identifier_exposed:             false
serial_number_exposed:                  false
volatile_state_in_binding_fingerprint:  false
pcie_bdf_semantics:                     false
device_lifecycle_semantics:             false
thermal_representativeness:             false
power_causality:                        false
firmware_causality:                     false
root_cause_validated:                   false
```

A native L0 PASS may promote only the existence and stability of the sanitized binding and provider inventory. It does not claim device-event, thermal-causality or firmware-causality semantics.

## Native acceptance gate

The first native run requires:

```text
PowerShell 7 contract:         20/20
Windows PowerShell 5.1:       20/20
PSScriptAnalyzer findings:     0
Python syntax:                 PASS
schema contract:               PASS
snapshot A validation:         PASS
snapshot B validation:         PASS
machine identity stable:       true
boot identity stable:          true
binding fingerprint stable:    true
PnP inventory:                 > 0
PCI-classified inventory:      > 0
signed-driver inventory:       > 0
system-driver inventory:       > 0
available event providers:     > 0
```

Secure Boot, TPM, Device Guard, battery and thermal surfaces are capability-dependent and therefore may be explicitly unavailable without being converted to false/zero.

The bounded review ZIP contains only the two sanitized snapshots, two independent validation summaries and the certification receipt.

## Next stage after L0 validation

Measured host capabilities from this gate determine SUPERBLOCK 2 L1 event work. Provider names, event IDs, device semantics and power/thermal timing claims will not be guessed before the real host inventory is recorded.
