# NXB-IRL-004 SUPERBLOCK 1 — Mega Native Validation

## Status

`VALIDATED — FOUNDATION / REAL CAPTURE / HEADER REPLAY CLOSED`

- PR: `#12`
- Native validated implementation head: `57dd8a466509bd390b94ad8426b2af6dd56c1687`
- Authority: exact-head native Windows validation
- Mega review ZIP SHA-256: `4dbbf73c58d6bb241e3dfb91fb859eb6b4550ef40359f246aa4bfa939a035bf5`
- Transcript SHA-256: `7e038c9a6ac9aade126b8386799daf3dbcd33f9e8f404c11b528c3caa3f1c726`

## Static and prerequisite gates

```text
provider enable-matrix contract:
  PowerShell 7:            8/8
  Windows PowerShell 5.1:  8/8

capture/adaptor:
  PowerShell 7:            17/17
  Windows PowerShell 5.1:  17/17
  PSScriptAnalyzer:        0

multi-domain profile:
  PowerShell 7:            10/10
  Windows PowerShell 5.1:  10/10
  PSScriptAnalyzer:        0
  native wpr.exe parse:    PASS

capture contract:
  PowerShell 7:            8/8
  Windows PowerShell 5.1:  8/8
```

Six selected network/kernel providers were re-observed with the same metadata row counts:

```text
Microsoft-Windows-Kernel-Network:   3
Microsoft-Windows-Winsock-AFD:     10
Microsoft-Windows-DNS-Client:      20
Microsoft-Windows-Kernel-Process:  12
Microsoft-Windows-Kernel-Registry: 17
Microsoft-Windows-Kernel-PnP:      25
```

Capability snapshot schema validation passed with collection error count `0`.

## Native provider enableability matrix

Eight strict single-provider WPR start probes produced measured host-specific enableability:

```text
Microsoft-Windows-DxgKrnl:         unavailable  0xc558300c
Microsoft-Windows-DXGI:            enabled
Microsoft-Windows-Kernel-Network:  unavailable  0xc558300c
Microsoft-Windows-Winsock-AFD:     unavailable  0xc558300c
Microsoft-Windows-DNS-Client:      enabled
Microsoft-Windows-Kernel-Process:  unavailable  0xc558300c
Microsoft-Windows-Kernel-Registry: unavailable  0xc558300c
Microsoft-Windows-Kernel-PnP:      unavailable  0xc558300c
```

Domain summary:

```text
GPU:               1/2 enabled
Network:           1/3 enabled
Kernel lifecycle:  0/3 enabled
Total:             2/8 enabled
```

This matrix measures only WPR startability for the exact strict probe configuration. A failed strict probe does **not** prove provider absence, event-delivery absence, or semantic absence.

## Resilient real capture

The combined profile uses `Strict=false` for event providers while preserving the separate strict matrix above. The real bounded capture succeeded.

```text
trace start:       2026-08-09T08:37:15.4992202Z
trace stop:        2026-08-09T08:37:18.6447692Z
target PID:        26928
ETL length:        33,030,144 bytes
ETL SHA-256:       85c33dace6439b564703a84e96e4497cce7d10e55854e831973e4ed4ffee43ee
xperf dumper SHA:  c86beeec04a04e03cb7e6d683e01db5c3f7efbd1d26fca0cf5669684df19789d
```

Bounded workload:

```text
loopback bytes:       65,536
external network:     false
registry read:        completed
child process exit:   0
controlled GPU load:  false
```

## Native ETL quality

```text
counter source:   etl_header_snapshot
EventsLost:       0
BuffersLost:      0
BuffersWritten:   126
buffer size:      262,144 bytes
processor count:  16
trace pointer:    8 bytes
circular overwrite: unknown
trace completeness: not_claimed
```

Native trace-loss absence is measured for the ETL header counters. Circular overwrite absence remains unclaimed.

## Observed xperf header inventory

Header inventory SHA-256:

```text
704e5900a9c0478cccc25748d64f94682949d953b99c3c3dff3789fc2b2628c4
```

Observed unique headers:

```text
total:                    126
gpu candidates:             8
network candidates:        19
kernel-lifecycle candidates:3
unclassified:              96
```

Observed GPU headers include DXGI `Present` start/stop, `PresentMultiplaneOverlay` start/stop, `GetFrameStatistics`, `Profile`, and `Factory` event shapes.

Observed network headers include DNS query/server shapes, `TcpSend`, `TcpRecv`, `TcpConnect`, `TcpDisconnect`, `TcpRetransmit`, `TcpAccept`, `TcpReconnect`, `TcpConnectFail`, TCP ACK/copy classes, `UdpSend`, `UdpRecv`, and `NetworkInterface`.

The unclassified set also contains native kernel process/thread/image/registry shapes (`P-*`, `T-*`, `I-*`, `Reg*`) that are explicitly incorporated by the downstream normalizer rather than relying on the first-pass name heuristic.

## Deterministic header replay

```text
source inventory SHA-256: 704e5900a9c0478cccc25748d64f94682949d953b99c3c3dff3789fc2b2628c4
replay inventory SHA-256: 704e5900a9c0478cccc25748d64f94682949d953b99c3c3dff3789fc2b2628c4
byte-identical:           true
header count:             126
```

## Review evidence boundary

The bounded mega review ZIP contains only provider-enable, certification, trace-quality, header-inventory, and replay receipts. Raw ETL, full xperf dumper, raw provider metadata, full capability snapshot, generated probe profiles, and raw WPR output remain local.

## Claims remaining intentionally unpromoted

```text
keyword_semantics_validated:         false
event_ids_validated:                 false
present_semantics:                   false
gpu_queue_semantics:                 false
network_connection_semantics:        false
network_latency_semantics:           false
kernel_lifecycle_semantics:          false
device_lifecycle_semantics:          false
power_thermal_representative:        false
firmware_security_effect_semantics:  false
circular_overwrite:                  unknown
trace_completeness:                  not_claimed
```

## Downstream normalization history

Attempt `5372b87cff7c4d9efea1e9d6746d4adad0d6c514` passed the dual-runtime/static gate and canonical binding, then measured:

```text
normalized rows:       176,369
unresolved rows:        12,136
```

Attempt `54de52c8db3d255988ce96e50d45bfe3287da147` added bounded diagnostics and measured all 12,136 residual rows as `active_header_nonempty_extra`. Dominant classes were thread rundown/start/end, with small process-rundown and DNS-info tails. It also measured five short xperf fragments outside the recognized-domain boundary.

The active repair is documented in:

```text
docs/NXB-IRL-004-SUPERBLOCK-1-DOWNSTREAM-OPAQUE-TAIL-REPAIR.md
```

Named header columns remain authoritative. Non-empty values beyond the active header are preserved locally as deterministic ordinal `__xperf_opaque_tail_NNN` fields, never discarded and never assigned semantics. Domain-external malformed fragments remain audit evidence; recognized malformed event rows remain fail-closed.

Current downstream acceptance requires:

```text
PowerShell 7:                 10/10
Windows PowerShell 5.1:      10/10
PSScriptAnalyzer:            0
Python syntax:               PASS
observed header shapes:      126
recognized header shapes:     73
unresolved schema rows:        0
recognized malformed rows:     0
normalized == recognized candidate rows
normalized-event replay: byte-identical
coverage replay:         byte-identical
```

After this gate passes, the next wide batch uses measured real row/family counts for DXGI Present, TCP/DNS, process/thread/image/registry correlation and semantics investigation without reopening capture foundations.
