# NXB-IRL-004 SUPERBLOCK 1 — Downstream Native Validation

## Status

`VALIDATED — NORMALIZATION / STRUCTURAL REPLAY CLOSED`

- PR: `#12`
- Native validated downstream implementation head: `7fd766d15faa9b2ca0197edf342a0f794f4d1f0b`
- Canonical capture source head: `57dd8a466509bd390b94ad8426b2af6dd56c1687`
- Authority: exact-head native Windows validation
- Downstream review ZIP SHA-256: `b5009e314aeed4f20e4daec951ea661255c094638bab697cf5c3aaf0fde13480`
- Downstream transcript SHA-256: `11de450f6ef22b4b4f134f1b62239546d5ea574afe7b61c23a7b0a3b50793620`

## Static gate

```text
PowerShell 7 Pester:            10/10
Windows PowerShell 5.1 Pester: 10/10
PSScriptAnalyzer:               0
Python syntax:                  PASS
canonical source hash binding:  PASS
```

## Canonical input identity

```text
capture source head: 57dd8a466509bd390b94ad8426b2af6dd56c1687
ETL SHA-256:         85c33dace6439b564703a84e96e4497cce7d10e55854e831973e4ed4ffee43ee
xperf dumper SHA-256:c86beeec04a04e03cb7e6d683e01db5c3f7efbd1d26fca0cf5669684df19789d
header SHA-256:      704e5900a9c0478cccc25748d64f94682949d953b99c3c3dff3789fc2b2628c4
```

The capture source remains native-loss-free for the measured ETL header counters (`EventsLost=0`, `BuffersLost=0`). Trace completeness remains `not_claimed`.

## Real full-row normalization

```text
source data rows:              270331
recognized candidate rows:     188505
normalized rows:               188505
unresolved schema rows:             0
source malformed fragments:         5
recognized malformed rows:          0
recognized header shapes:       73/126
target PID rows:                 6395
```

Every structurally recognized candidate row was preserved in the normalized event stream.

### Domain counts

```text
GPU:                575
Network:            203
Kernel lifecycle: 187727
```

### Family counts

```text
GPU
  dxgi_present:             178
  dxgi_present_mpo:          85
  dxgi_frame_statistics:    268
  dxgi_profile:              42
  dxgi_factory:               2

Network
  tcp:                      133
  udp:                       18
  dns:                        6
  network_interface:         46

Kernel lifecycle
  process:                  728
  thread:                 12081
  image:                 111553
  registry:               63365
```

## Opaque-tail preservation

Real xperf rows demonstrated that some process/thread rundown rows and two DNS rows contain non-empty trailing fields that are not named by the active textual header.

```text
opaque-tail rows:        12136
opaque-tail field count: 12434
```

The downstream normalizer preserves these values under ordinal structural names such as `__xperf_opaque_tail_001`. It never discards them and never assigns semantic names to them.

Claims:

```text
nonempty_extra_columns_discarded:           false
nonempty_extra_columns_preserved_as_opaque: true
opaque_tail_semantics_resolved:             false
```

Raw opaque values remain in the local normalized JSONL only.

## Deterministic full-row replay

```text
normalized events SHA-256: 269d93e00411d78e15ebfb2c4c5a6568b36addb78238d57d7809184a1a420f89
coverage SHA-256:          5756530354f42fb0be9741de7bd6119649a02a4a17505e75658663f8e36ce3aa
normalized-event replay:  byte-identical
coverage replay:          byte-identical
```

## Review evidence boundary

The bounded downstream review ZIP contains only:

- downstream certification receipt;
- coverage counts;
- schema diagnostics;
- structural semantics-boundary receipt.

It excludes raw ETL, full xperf dumper, normalized JSONL rows, IP addresses, ports, registry paths, image paths, DNS payload values, and opaque-tail values.

## Claims remaining intentionally unpromoted

```text
structural_event_name_mapping:       true
active_header_structural_binding:    true
opaque_tail_preservation:            true
keyword_semantics_validated:         false
event_ids_validated:                 false
timestamp_unit_resolved:             false
present_semantics:                   false
gpu_queue_semantics:                 false
network_connection_semantics:        false
network_latency_semantics:           false
kernel_lifecycle_semantics:          false
trace_completeness:                  not_claimed
```

## Next wide gate

The parser/schema layer is closed. The next batch consumes the exact normalized-event SHA above and builds deterministic structural correlation without converting raw timestamps into time units:

- DXGI Present start/stop structural pairing;
- TCP/DNS structural flow/activity grouping;
- process/thread/image lifecycle structural pairing;
- registry activity attribution;
- exact PID/TID cross-domain attribution;
- target-PID cross-domain sequence adjacency;
- deterministic correlation replay;
- bounded aggregate review evidence with raw identifiers excluded.

No latency, queue, present-success, TCP-session, kernel-lifecycle, or root-cause semantic claim is promoted merely because structural correlation succeeds.
