# NXB-IRL-004 — Memory Overhead Calibration Validation

## Status

`VALIDATED — REAL ELEVATED WINDOWS — EXACT HEAD`

Validated implementation head:

```text
dd3b8016091c40dfea6364076888f022a0d782d3
```

Branch:

```text
nxb-irl-004-memory-working-set
```

PR:

```text
#9 — stacked draft on nxb-irl-004-trace-loss-accounting
```

GitHub Actions remain intentionally disabled. This validation was performed locally on a real elevated Windows host using PowerShell 7.6.4.

## Canonical validation gates

The exact-head validator passed:

```text
PowerShell parser:                 PASS
PSScriptAnalyzer Error/Warning:   0 findings
Memory calibration Pester:        8/8 passed
Memory profile contract:          PASS
Native wpr.exe profile parse:     PASS
EvidenceStore source dependency:  PASS
Harness dependency injection:     none
```

The source-level dependency check proves that `scripts/Invoke-NxbMemoryOverheadCalibration.ps1` imports `Nxb.EvidenceStore.psm1` itself. The canonical run did not inject `Get-NxbCanonicalJsonHash` from the validator harness.

## Protocol

```text
warmups:                    1
paired repetitions:         3
ordering:                   alternating_control_first
private memory:             32 MiB
mapped file:                8 MiB
hold:                       1000 ms
sampling interval:          25 ms
cooldown:                   1 s
require same machine:       true
require same boot:          true
require same power policy:  true
require same workload:      true
threshold policy:           not_declared
```

All three pair records retained the same machine, boot, active power-policy and workload fingerprints. Control and capture arms produced the same deterministic workload checksum (`1269180`) in every pair.

## Result

```text
status:                  passed
pair_count:              3
successful_pair_count:   3
failed_pair_count:       0
threshold_policy.status: not_declared
```

Measured relative distributions:

```text
duration_delta_percent:
  minimum:  0.6021499689813224
  median:   1.700128930209937
  mean:     1.6140854567911278
  maximum:  2.539977471182124

cpu_time_delta_percent:
  minimum:  0.0
  median:   54.54545454545454
  mean:     38.18181818181818
  maximum:  60.0

peak_working_set_delta_percent:
  minimum:  0.6457094307561597
  median:   1.3916161529924016
  mean:     1.1671820617964668
  maximum:  1.4642206016408386

peak_private_bytes_delta_percent:
  minimum: -3.1654748212231834
  median:  -0.664332063034298
  mean:    -1.0375170556672548
  maximum:  0.7172557172557172
```

Per-pair capture evidence:

```text
pair 1:
  first arm:       control
  control ms:      1431.056
  capture ms:      1467.4045
  ETL bytes:       544210944
  WPR start ms:    191.4487
  WPR stop ms:     6088.8755

pair 2:
  first arm:       capture
  control ms:      1467.3421
  capture ms:      1476.1777
  ETL bytes:       543162368
  WPR start ms:    185.3811
  WPR stop ms:     6157.8494

pair 3:
  first arm:       control
  control ms:      1451.5605
  capture ms:      1476.2389
  ETL bytes:       543162368
  WPR start ms:    185.2944
  WPR stop ms:     6063.5342
```

The CPU-time percentage distribution is noisy because the bounded workload is short and absolute process CPU time is small. No production acceptance threshold is inferred from three pairs.

## Review evidence

Review archive:

```text
nxb-memory-overhead-calibration-dd3b8016091c-20260807T214351Z-review.zip
sha256: 2f0c7110fd83a0026377ac8c281a1afd38f8ae8235dc037626adefc05d8e4832
```

The archive contains only:

```text
collector-overhead-calibration.json
memory-overhead-profile-provenance.json
memory-overhead-warmups.json
observation-identity.json
```

Canonical calibration JSON:

```text
sha256: 4ecc3634218e8cecd7ebcefb478503baca6a69a6bf8912bd496e9a30ca8c73bb
```

Raw calibration ETL files remain local and are intentionally excluded from the review archive.

## Claim boundary

This validation proves that the memory capture overhead measurement mechanism works under the recorded bounded protocol. It does not establish a representative production threshold or universal overhead expectation.

The result intentionally retains:

```text
threshold_policy.status: not_declared
```

No claim is made that working set equals total scenario memory cost, that the trace is complete, or that circular overwrite is absent.