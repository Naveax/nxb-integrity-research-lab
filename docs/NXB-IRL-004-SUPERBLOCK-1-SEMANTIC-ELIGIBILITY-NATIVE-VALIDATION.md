# NXB IRL-004 — SUPERBLOCK 1 semantic-eligibility native validation

## Status

`VALIDATED — ROUND 1 CLOSED`

Canonical exact head:

```text
2230864433890c2992b59088fe1af3db0c635808
```

Authority: native elevated PowerShell 7 on the real Windows host. GitHub Actions remain intentionally disabled.

## Static / native gate

```text
PowerShell 7 fixture contract:   15/15
Windows PowerShell 5.1:          15/15
PSScriptAnalyzer findings:       0
native x64 fixture build:        PASS
fixture executable SHA-256:      765ec168c756e1a72a41adee31c7e5ebacb29d4911eb5a70f111618128ef523b
```

## Controlled fixture

```text
fixture PID:                     18188
hardware D3D11 device:           true
WARP fallback:                   false
Present attempted/succeeded:     128 / 128
localhost DNS executed:          true
loopback TCP completed:          true
loopback bytes sent/received:    65536 / 65536
external network used:           false
registry read executed:          true
registry write executed:         false
temporary-file roundtrip:        true
worker created/joined:           true / true
```

## Trace quality

```text
EventsLost:                      0
BuffersLost:                     0
BuffersWritten:                  140
circular_overwrite:              unknown
trace_completeness:              not_claimed
```

## Fresh normalization

```text
source rows:                     306801
recognized candidates:           218028
normalized rows:                 218028
unresolved schema rows:          0
recognized malformed rows:       0
recognized header shapes:        81 / 134
opaque-tail rows:                12883
opaque-tail fields:              13181
fixture PID rows:                6114
normalization replay:            byte-identical
normalized events SHA-256:       9ba908b547a71edf82d1e265270d578442f0ac25726b15b7345f71b3b4b9ede6
coverage SHA-256:                 b99418c17640cbe76e8fe8f2a31d337e41fd2f31956edf6209a0c3399ff78756
```

## Same-PID three-domain result

```text
fixture PID GPU rows:             283
fixture PID network rows:          10
fixture PID kernel rows:          5821
three-domain PID count:              1
multi-domain PID count:              19
```

Target fixture families:

```text
gpu:dxgi_present:                256
gpu:dxgi_profile:                 25
gpu:dxgi_factory:                  1
gpu:dxgi_other:                    1
network:dns:                        2
network:tcp:                        8
kernel_lifecycle:image:           408
kernel_lifecycle:process:           3
kernel_lifecycle:registry:       5348
kernel_lifecycle:thread:           62
```

The controlled fixture executed exactly 128 successful `Present(0,0)` calls while the exact fixture PID had 256 structurally normalized DXGI Present rows. This is a measured Round-2 hypothesis only; it does not by itself promote Present event mapping or Present success semantics.

## Correlation replay

```text
structural pair records:          24401
pair-record SHA-256:              d2d17f91688f0af47e4413f076f214537bdf280ebfa28e77e75ad42aa1ade367
summary SHA-256:                  94dd5dc81303de6b6a166c6ed4aee41da536dd74080f79c061125b98c3706868
correlation replay:               byte-identical
```

DXGI Present structural pairing remains unvalidated because current start/stop rows expose asymmetric key material; field names and ON/OFF controls must be measured before any pairing rule is promoted.

## Bounded review evidence

Canonical review ZIP SHA-256:

```text
97922ba500a0f66d34a8b8cbda54b34aa7e871af3e3d68d81255bcd8bd39a150
```

The ZIP contains only six bounded JSON files:

```text
superblock1-semantic-correlation-summary.json
superblock1-semantic-coverage.json
superblock1-semantic-eligibility-certification-receipt.json
superblock1-semantic-fixture-receipt.json
superblock1-semantic-header-inventory.json
superblock1-semantic-trace-quality.json
```

Raw ETL, full xperf dumper, normalized rows, pair-record rows, executable/object files and WPR status remain local-only.

## Claims established by Round 1

```text
controlled_fixture_executed = true
exact_fixture_pid_attribution = true
same_pid_three_domain_observability = true
semantic_eligibility_established = true
```

The following remain false/unclaimed:

```text
timestamp_unit_resolved
present_event_mapping_validated
present_pairing_semantics
present_success_semantics
gpu_queue_semantics
tcp_connection_lifecycle_validated
network_connection_semantics
network_latency_semantics
kernel_lifecycle_semantics
registry_operation_semantics
causal_relationship_validated
root_cause_validated
trace_completeness = not_claimed
circular_overwrite = unknown
```

## Next gate

Round 2 uses repeated controlled ON/OFF captures to test stimulus-specific observability without relying on event names alone. GPU, network and explicit-kernel controls remain separate, and any promoted claim must survive both repetitions and its negative control.
