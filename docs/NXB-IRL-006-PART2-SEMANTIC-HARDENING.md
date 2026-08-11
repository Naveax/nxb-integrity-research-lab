# NXB IRL-006 Part 2 — 8/8 Semantic Hardening

## Objective

Part 2 promotes the eight requested semantic validation targets from `0/8` to `8/8` only when bounded native experiments, independent replay, and Part 1-compatible semantic receipts all pass on one clean exact Git head.

The repository default policy intentionally remains `target_requested=true` / `validated=false`. Native promotion is represented by external evidence receipts and the final semantic hardening matrix. This avoids a circular dependency in which a receipt SHA would need to be committed into the exact head it is intended to certify.

## Claims

1. `pnp_lifecycle_semantics`
2. `pcie_bdf_semantics`
3. `event_id_semantics`
4. `event_task_opcode_semantics`
5. `power_causality`
6. `firmware_causality`
7. `root_cause_validated`
8. `continuous_trace_completeness`

Every claim is bounded to the experiment scope recorded in its receipt. Part 2 does not claim generalized operating-system, hardware, firmware, or root-cause semantics outside those controlled scopes.

## Four experiment families

### 1. Owned software-device lifecycle

Claims:

- PnP lifecycle
- event ID semantics
- event task/opcode semantics

The experiment creates two administrator-owned ephemeral Windows software devnodes with the Software Device API. It observes direct present/absent state before considering event evidence. Each devnode is removed by closing its owned software-device handle, followed by explicit cleanup verification.

The review artifact excludes raw device instance IDs, raw event payloads, and formatted event messages. Event promotion uses only the repeated sanitized tuple:

`provider / log / id / version / level / task / opcode`

Two repeated positive windows and matched idle controls are required. Physical PnP devices are not disabled, uninstalled, or removed.

### 2. Bounded PCIe inventory

Claim:

- PCIe BDF semantics

Three same-boot snapshots read `DEVPKEY_Device_BusNumber`, `DEVPKEY_Device_Address`, and `DEVPKEY_Device_LocationPaths` for PCI devices. The address value is decoded into device/function and independently cross-checked against the terminal PCI location-path tuple.

Only sanitized device identity hashes and BDF values are reviewable. Cross-boot BDF stability is explicitly not claimed.

### 3. Owned power and virtual firmware transitions

Claims:

- power causality
- firmware causality

Power causality uses two temporary copies of the currently active power scheme. Each repeat verifies idle stability, temporary creation, activation, restoration of the original scheme, deletion of the temporary scheme, and final cleanup.

Firmware causality is intentionally isolated from host firmware. It uses an ephemeral, unstarted Generation 2 Hyper-V VM with no VHD and no network switch. Secure Boot configuration is changed and restored twice, then the VM is removed. Host UEFI/Secure Boot is never modified.

If the Hyper-V management surface is unavailable, the standalone experiment reports `unavailable`. The final 8/8 certification fails closed; it does not substitute a weaker host-firmware claim.

## 4. Repeated Superblock controls + sequential WPR

Claims:

- root cause validated
- continuous trace completeness

The existing owned Superblock semantic fixture is reused for ten alternating scenarios in one fresh WPR session:

- `all_on_a`
- `gpu_off_a`
- `network_off_a`
- `kernel_off_a`
- `minimal_a`
- `minimal_b`
- `kernel_off_b`
- `network_off_b`
- `gpu_off_b`
- `all_on_b`

Part 2 uses `profiles/Nxb.SemanticHardeningSequential.wprp`, not the older circular profile. The file collectors are bounded at 512 MiB with sequential file mode so capacity exhaustion becomes a fail-closed condition rather than silent overwrite.

The trace gate requires:

- native `EventsLost = 0`
- native `BuffersLost = 0`
- `BuffersWritten > 0`
- sequential capacity not reached
- all ten scenarios represented
- zero accounted observation gaps
- byte-identical normalization replay
- byte-identical semantic-analysis replay

The root-cause gate is deliberately narrow. Both `all_on` repeats must show GPU, network, and kernel-lifecycle activity. GPU/network controlled mappings and the kernel-off intervention must reproduce the expected differential. The resulting hypothesis applies only to the owned Superblock fixture configuration.

Raw ETL, xperf dumper output, and normalized event rows remain local and are excluded from the final review ZIP.

## Independent 8/8 gate

`tools/validate_semantic_hardening.py` independently validates all four experiment JSON documents. It must return exactly:

```text
requested = 8
validated = 8
```

Only after this gate passes may the certification authority generate eight `validated` semantic receipts.

Each receipt is then independently checked by both:

- `scripts/Test-NxbSemanticEvidenceReceipt.ps1`
- `tools/validate_semantic_evidence_receipt.py`

The receipts bind the exact Git head, policy fingerprint, machine identity hash, experiment scope, evidence artifact index, independent validator implementation hash, cleanup state, negative-control state, and explicit limitations.

## Host capability preflight

The top authority runs `scripts/Test-NxbSemanticHardeningHostCapability.ps1` before the expensive inherited and trace gates. It checks the already-required local capabilities without enabling Windows features or changing host state:

- elevated PowerShell 7
- Git and Python
- WPR and xperf
- PnP property access
- Windows Software Device API DLL
- Visual C++ build tools used by the existing owned fixture
- Hyper-V management cmdlets
- running/queryable Hyper-V VM management service
- readable Kernel-PnP provider metadata

A missing prerequisite stops the certification immediately with explicit blockers. The preflight does not enable Hyper-V, start services, request a reboot, or change host firmware.

## Permanent known-error discipline

Part 2 inherits `NXB-ERR-001` through `NXB-ERR-022`.

Before the first portable authority was issued, broad shadow review already caught and repaired:

- `NXB-ERR-006`: accidental assignment to `$matches` in power-scheme GUID parsing.
- `NXB-ERR-015`: two double-quoted expected-source assertions containing PowerShell variables.
- `NXB-ERR-013`: Part 2 draft briefly contained 13 test blocks while the authority expected 12; the regression coverage was consolidated without reducing coverage and the contract remains 12/12.
- `NXB-ERR-022`: direct `powercfg` stderr merges were removed and all Part 2 power native calls now use the scoped ErrorAction native helper.

These are existing error classes, not new IDs. A genuinely new recurring native failure discovered after this point becomes `NXB-ERR-023` only after root-cause classification.

## Authority chain

Top repo-owned gate:

`scripts/Invoke-NxbSemanticHardeningCertificationV2.ps1`

Flow:

```text
exact clean head
→ top parser/analyzer
→ inherited known-error scan
→ fail-fast host capability preflight
→ Part 2 child authority
→ Part 2 parser/analyzer
→ Part 2 known-error scan
→ PS7 + PS5.1 12-test contract
→ inherited Part 1 re-certification on the same exact head
→ four bounded native experiment families
→ independent Python 8/8 replay
→ eight Part 1-compatible semantic receipts
→ PowerShell + Python receipt validation
→ JSON-only review ZIP audit
→ final known-error scan
→ requested=8 / validated=8
```

A Part 2 head is not certified until a real native run completes this entire chain.
