# NXB-IRL-004 SUPERBLOCK 1 — Capture/adaptor batch

## Status

`IMPLEMENTED — NATIVE CERTIFICATION REQUIRED`

This batch follows the certified SUPERBLOCK foundation and the certified bounded GPU WPR profile.

## Certified GPU profile input

Exact native profile certification head:

```text
5d0615426bc6b9f706e2ee3175945021c1b8e6b1
```

Observed result:

```text
PowerShell 7 Pester:           8/8
Windows PowerShell 5.1:        8/8
PSScriptAnalyzer:              0
native wpr.exe profile parse:  PASS
File/Memory variants:          PASS
profile SHA256:                0f55539dcf19f333f74e79d59ab6cff64a18a4a861a5c6738e1c15cbef1c7fdb
real GPU capture:              false
semantic claims:               false
trace completeness:            not_claimed
```

## Selected provider metadata scope

Provider identities were selected only from the certified real-host remaining-provider inventory.

Network:

```text
Microsoft-Windows-Kernel-Network
{7dd42a49-5329-4832-8dfd-43d979153a88}

Microsoft-Windows-Winsock-AFD
{e53c6823-7bb8-44bb-90dc-3f86090d48a6}

Microsoft-Windows-DNS-Client
{1c95126e-7eea-49a9-a3fe-a378b03ddb4d}
```

Kernel lifecycle:

```text
Microsoft-Windows-Kernel-Process
{22fb2cd6-0e7b-422b-a0c7-2fad1fd0e716}

Microsoft-Windows-Kernel-Registry
{70eb4f03-c1de-4f73-a051-33d13d5413bd}

Microsoft-Windows-Kernel-PnP
{9c205a39-1250-487d-abd7-e831c6290539}
```

The native metadata probe records provider GUID evidence, section-bounded keyword metadata where available, publisher metadata status and output hashes. An absent keyword section is represented as `unavailable`; it is not treated as a zero-valued semantic observation.

No trace session is started by this probe.

## Capability adapter

The adapter reuses the existing `system-capabilities.json` snapshot and produces a bounded normalization layer for:

```text
network
device_driver
firmware
security
power
```

It preserves machine identity and source SHA-256 for later correlation, but does not emit raw MAC addresses, serial numbers or active power-scheme text.

Unavailable/missing counts remain `null`, never synthesized as zero.

The in-memory `domains` member is explicitly a `PSCustomObject`, matching the certification runner's property-addressable contract. The adapter contract executes a real synthetic fixture and verifies both in-memory `PSObject.Properties` access and JSON round-trip shape under both PowerShell runtimes.

## Static gate

The selected-provider contract contains 9 tests and the capability-adapter contract contains 8 tests. Both execute under PowerShell 7 and Windows PowerShell 5.1:

```text
selected provider metadata:  9/9
capability adapter:           8/8
```

Aggregate target:

```text
PowerShell 7:               17/17
Windows PowerShell 5.1:     17/17
PSScriptAnalyzer:           0
certification runner parse: PASS
certification analyzer:     PASS
```

The local runner requires an explicit expected count for each suite and derives aggregate totals from the actual returned summaries. This prevents a stale hard-coded aggregate from masking future test-count changes.

## Native certification history

### Attempt 1 — static assertion/count repair

Exact head:

```text
4009663f3ea17b4d49a30952ffa88fee7190a0d9
```

The gate stopped in the PowerShell 7 selected-provider Pester suite before any real provider metadata collection. Two identity assertions used:

```powershell
Should -Match [regex]::Escape($name)
```

Pester treated `[regex]::Escape` as the match pattern. The repaired contract evaluates the expression first:

```powershell
Should -Match ([regex]::Escape($name))
```

That run also exposed that the selected-provider suite contains 9 tests rather than 8. The runner and certification receipt contract were repaired to use 9 + 8 = 17 tests per runtime.

No real `logman`/`wevtutil` provider probe, capability snapshot, adapter output or ETL capture was promoted from attempt 1.

### Attempt 2 — real metadata reached; adapter object-shape repair

Exact head:

```text
bd637b589b159bb8f1501cbb43ffbfbb28c6c292
```

Static validation passed completely:

```text
PowerShell 7:               17/17
Windows PowerShell 5.1:     17/17
PSScriptAnalyzer:           0
certification parser/analyzer: PASS
```

The run then reached real host metadata collection and observed measured keyword tables for all six selected providers:

```text
Microsoft-Windows-Kernel-Network:   3 rows
Microsoft-Windows-Winsock-AFD:     10 rows
Microsoft-Windows-DNS-Client:      20 rows
Microsoft-Windows-Kernel-Process:  12 rows
Microsoft-Windows-Kernel-Registry: 17 rows
Microsoft-Windows-Kernel-PnP:      25 rows
```

Publisher metadata was measured and the expected GUID was observed for all six providers. A fresh full-system capability snapshot was also produced and passed JSON Schema validation, and the capability adapter wrote its raw-local JSON.

The run stopped at the certification runner's in-memory domain-presence guard. Root cause: the adapter returned `domains` as an `[ordered]` dictionary while the runner intentionally checked `domains.PSObject.Properties[...]` as a property-addressable object. Serialization was valid, but the in-memory object contract was mismatched.

Repair:

```powershell
domains = [pscustomobject][ordered]@{ ... }
```

The existing 8th adapter test now executes a real synthetic fixture, verifies property-addressable `network`/`device_driver` members in memory, verifies the serialized JSON round trip, and verifies overwrite fail-closed behavior. Test count therefore remains 8 and aggregate remains 17/17 per runtime.

Attempt 2 is valuable native observation, but the full capture/adaptor batch remains uncertified until the repaired exact head completes the bounded receipt/ZIP gate.

## Native certification

Repo-owned runner:

```text
scripts/Invoke-NxbSuperblock1CaptureAdapterCertification.ps1
```

One exact-head native run performs:

```text
combined dual-runtime static gate
-> six selected network/kernel metadata probes
-> fresh full-system capability snapshot
-> JSON Schema validation
-> device/power/firmware capability adapter
-> bounded sanitized receipt + review ZIP
```

Raw provider metadata, capability JSON and adapter JSON remain local-only.

## Decision gate after native evidence

Keyword-filtered network/kernel WPR profiles may be authored only for providers whose exact host metadata is measured by the completed certification. Provider existence alone is insufficient.

## Conservative boundary

```text
keyword_semantics_validated:         false
event_ids_validated:                 false
network_connection_semantics:        false
network_latency_semantics:           false
kernel_lifecycle_semantics:          false
device_lifecycle_semantics:          false
power_thermal_representative:        false
firmware_security_effect_semantics:  false
real_etl_capture_executed:           false
trace_completeness:                  not_claimed
```
