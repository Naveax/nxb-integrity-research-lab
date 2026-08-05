# NXB-IRL-004 — Paired Collector Overhead Validation Record

## Status

`PASSED — EXACT IMPLEMENTATION HEAD VALIDATED ON WINDOWS`

- Issue: `#2`
- Pull request: `#7`
- Branch: `nxb-irl-004-overhead-calibration`
- Validated implementation head: `76c2d9cbc6d52c7025664bc06a108fa44d3457f4`
- Started UTC: `2026-08-05T13:07:32.5722334Z`
- Stopped UTC: `2026-08-05T13:23:06.3401047Z`
- Summary status: `passed`

GitHub Actions remain intentionally disabled. Validation was performed by `scripts/Invoke-NxbLocalValidation.ps1` from an elevated PowerShell 7 shell on Windows.

## Protocol

```text
repetition_count: 3
warmup_count:     1
ordering:          alternating_control_first
iterations:        1000
seed:              73
```

## Required gates

| Gate | Result |
|---|---|
| Public repository content | passed — 87 files inspected |
| Native WPR profile parser | passed |
| PSScriptAnalyzer | passed — 0 findings |
| Repository smoke | passed |
| PowerShell 7 Pester | passed — 98/98 |
| Windows PowerShell 5.1 Pester | passed — 98/98 |
| Native paired WPR calibration | passed — 3/3 pairs, 1 warmup |

No required gate was skipped. The summary recorded identical `head_sha` and `expected_head_sha` values.

## Artifact hashes

```text
review ZIP:
  e85f8d608584739f3c358a857dc3fb62321c633b8acd0cc0e1f3ff7e438a95a9
validation-summary.json:
  7181ca1b60a791897092287d5813426b33329da8a3fe42b53fbd22d23b529458
pester-pwsh.xml:
  f1a66db85cb8e7cf846005612f54f90f819e8702ca3d2c1eff95b1dc58eedd9a
pester-ps51.xml:
  801d3bf2dc62a6bd29a8544d5e58045ab2ad7d3ed0556a40a2d90839d4a01a10
native-calibration.json:
  2846ed8357da9efd4f3cb983290614d7d3a98418873f8f0843181519ac5f2aac
```

## Native calibration summary

All control and capture arms completed with exit code `0`, no timeout, matching deterministic workload checksums and measured process/ETL evidence.

```text
duration delta percent:
  minimum: 1.1435305347
  median:  7.2567224905
  mean:    7.5017585758
  maximum: 14.1050227023

CPU-time delta percent:
  minimum: -19.6969696970
  median:   18.6046511628
  mean:      6.7280924035
  maximum:  21.2765957447

peak working-set delta percent:
  minimum: -2.9968595783
  median:   2.3414541663
  mean:     0.7223278802
  maximum:  2.8223890526

peak private-bytes delta percent:
  minimum: -1.1351495726
  median:   0.0669164882
  mean:    -0.3159439155
  maximum:  0.1204013378
```

`threshold_policy.status` remains `not_declared`. This run validates the mechanism; it does not establish a representative production threshold or trace-completeness claim.

## Closeout boundary

The exact implementation head above is the head that passed every required Windows gate. Later commits in this PR are limited to validation and handoff documentation. The authoritative closeout head is recorded in PR metadata and verified by comparing it with the validated implementation head before merge.
