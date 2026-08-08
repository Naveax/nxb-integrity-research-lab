# NXB-IRL-004 SUPERBLOCK 1 — Remaining observability domains

## Objective

Complete the remaining NXB-IRL-004 domain foundations as one coordinated workstream instead of independent micro-PRs.

Domains:

- GPU / DXGKRNL / present
- network / NDIS / connection
- device / driver / PCIe / PnP
- kernel / service / driver lifecycle
- power / frequency / thermal
- firmware / boot / security state

GitHub Actions remain intentionally disabled. Native Windows exact-head validation is authoritative.

## Reused foundation

The existing full-system capability contract already contains:

```text
gpu
network
bus_and_devices
firmware
security
power
```

Canonical files:

```text
schemas/system-capabilities.schema.json
scripts/Get-SystemCapabilities.ps1
scripts/Test-SystemCapabilities.ps1
schemas/observability-event.schema.json
```

This SUPERBLOCK does not duplicate those inventories. It adds provider/event-source discovery and later bounded capture adapters on top of the existing contracts.

## GPU work absorbed from PR #11

Existing validated provider discovery and repaired metadata probe are preserved in this branch:

```text
scripts/Invoke-NxbGpuProviderInventory.ps1
scripts/Invoke-NxbGpuProviderInventoryLocalValidation.ps1
scripts/Invoke-NxbGpuProviderMetadataProbe.ps1
scripts/Invoke-NxbGpuProviderMetadataProbeLocalValidation.ps1
tests/GpuProviderInventory.Tests.ps1
tests/GpuProviderMetadataProbe.Tests.ps1
```

Canonical GPU validation records:

```text
docs/NXB-IRL-004-GPU-PROVIDER-DISCOVERY-VALIDATION.md
docs/NXB-IRL-004-GPU-PROVIDER-METADATA-VALIDATION.md
```

The promoted native metadata run used the repaired `section-v1` parser and observed:

```text
DxgKrnl keyword rows: 38
DXGI keyword rows:    5
contamination:        false / false
```

The metadata result validates host-observed provider identity and keyword metadata only. Event IDs, payload contracts, present semantics, queue semantics and GPU execution timing remain unvalidated.

## New remaining-provider foundation

```text
scripts/Invoke-NxbRemainingProviderInventory.ps1
scripts/Invoke-NxbRemainingProviderInventoryLocalValidation.ps1
tests/RemainingProviderInventory.Tests.ps1
scripts/Invoke-NxbSuperblock1FoundationLocalValidation.ps1
scripts/Invoke-NxbSuperblock1FoundationCertification.ps1
```

Provider identity candidates are discovered from `logman query providers`; event-channel candidates are discovered from `wevtutil el`. Emitted candidate sets are bounded.

Candidate groups:

```text
network:          NDIS / TCPIP / Winsock / DNS / HTTP / WebIO
kernel_lifecycle: kernel / process / thread / image / registry / service / driver
device_driver:    PnP / PCI / device / driver / WHEA / IOMMU / DMA
power_thermal:    power / thermal / energy / battery / ACPI
```

Discovery proves identity/existence only. It does not validate provider keyword masks, event IDs or payload semantics.

## Combined local gate

`Invoke-NxbSuperblock1FoundationLocalValidation.ps1` executes three contract validators on one exact clean head and also parser/analyzer-gates the native certification wrapper:

```text
GPU provider inventory:       PS7 8/8 + PS5.1 8/8
GPU provider metadata:        PS7 8/8 + PS5.1 8/8
remaining provider inventory: PS7 8/8 + PS5.1 8/8
certification wrapper:        parser PASS + analyzer PASS
```

Target aggregate:

```text
PowerShell 7:               24/24
Windows PowerShell 5.1:     24/24
PSScriptAnalyzer:           0
certification runner parse: PASS
capability domain binding:  PASS
normalized event domains:   PASS
```

## Native certification gate

The repo-owned runner is:

```text
scripts/Invoke-NxbSuperblock1FoundationCertification.ps1
```

One portable exact-head Windows run performs:

1. combined local contract validation;
2. real GPU provider inventory;
3. real repaired GPU metadata probe;
4. real remaining-provider inventory;
5. real full-system capability snapshot;
6. system-capability JSON Schema validation;
7. bounded review evidence packaging.

Raw inventories and the full capability JSON remain under the local `raw-local` output directory. The review ZIP contains only a bounded receipt with counts, statuses and SHA-256 hashes. The runner re-opens the ZIP and fails if raw evidence leaked into it.

Only after that result is inspected will capture profiles be authored.

## Next implementation batch after certification

The next code batch will author bounded profiles/adapters from observed provider metadata:

- `NxbGpuDxgkrnlPresent`
- minimal network/NDIS profile
- kernel lifecycle profile or provider set
- device/power/firmware snapshot adapters

The exact provider keywords/event IDs must come from native evidence rather than memory or guesses.

## Conservative claim boundary

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

Missing, unsupported, unavailable and unassessed observations are never synthesized as zero.
