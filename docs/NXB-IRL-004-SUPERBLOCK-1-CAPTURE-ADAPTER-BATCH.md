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

## Static gate

Two 8-test contracts execute under both PowerShell runtimes:

```text
selected provider metadata:  8/8
capability adapter:           8/8
```

Aggregate target:

```text
PowerShell 7:               16/16
Windows PowerShell 5.1:     16/16
PSScriptAnalyzer:           0
certification runner parse: PASS
certification analyzer:     PASS
```

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

Keyword-filtered network/kernel WPR profiles may be authored only for providers whose exact host metadata is measured by this certification. Provider existence alone is insufficient.

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
