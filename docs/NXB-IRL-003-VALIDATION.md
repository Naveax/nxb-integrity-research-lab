# NXB-IRL-003 — Validation and Closeout Record

## Status

`IMPLEMENTATION COMPLETE — CODE/TEST HEAD VALIDATED`

Tracking issue: `#4`

Pull request: `#5`

Validated implementation head:

```text
77c90ea00eb63a64791d0d418999dd5a8abb78a0
```

GitHub Actions validation:

```text
Workflow: Validate
Run number: 162
Run ID: 30980814078
```

This record fixes the exact implementation and test evidence. Documentation-only closeout commits are validated again before the pull request is marked ready or merged; their final head and run identifiers are recorded in PR and issue metadata rather than changing this file again.

## Required jobs

| Job | Job ID | Result | Evidence |
|---|---:|---|---|
| Lifecycle - PowerShell 7 | `92224628625` | success | 63 passed, 0 failed, 0 skipped |
| Lifecycle - Windows PowerShell 5.1 | `92224628713` | success | 63 passed, 0 failed, 0 skipped |
| Static analysis and smoke validation | `92224628723` | success | public guard, PSScriptAnalyzer and repository smoke passed |

## Static and smoke gates

The static job completed all enforced steps:

- public repository content guard: 68 candidate files inspected,
- PowerShell syntax validation,
- JSON validation,
- canonical evidence-store JSON and SHA-256 contract validation,
- PSScriptAnalyzer: zero Error or Warning findings,
- synthetic lifecycle and observation identity,
- evidence finalization and idempotent re-finalization,
- two-record append-only evidence chain,
- chain-head verification,
- deterministic unsigned bundle creation,
- complete offline bundle verification,
- terminal result: `Repository doğrulaması başarılı.`

## Acceptance matrix

### Required scope

- [x] canonical manifest and record hashes
- [x] append-only experiment chain
- [x] immutable record identity
- [x] tool path, version, length, SHA-256 and invocation provenance
- [x] controller/target clock-offset and uncertainty evidence
- [x] experiment, machine, boot and session identity binding
- [x] deterministic offline evidence bundle manifest
- [x] independent chain, bundle, provenance, clock and signature verification
- [x] evidence-store bundle comparison
- [x] optional detached local signature

### Adversarial coverage

- [x] exact one-byte record modification
- [x] record deletion and sequence discontinuity
- [x] record reordering
- [x] record substitution from another experiment
- [x] previous-record hash mismatch after record rehashing
- [x] machine identity mismatch
- [x] boot identity mismatch
- [x] session identity mismatch
- [x] executable binary hash mismatch
- [x] clock-offset arithmetic mismatch after record rehashing
- [x] bundle inventory truncation
- [x] selected-file length or SHA-256 mismatch
- [x] traversal, case-collision and reparse-point paths
- [x] missing signature accepted only for an explicitly unsigned bundle
- [x] modified signature rejected
- [x] wrong public certificate rejected
- [x] unverified `valid` signature state rejected

## Determinism and fail-closed properties

- identical inputs produce identical canonical record, chain and bundle identities,
- object keys use ordinal case-sensitive ordering,
- array order remains hash-significant,
- hash-bearing numbers are integral,
- canonical bytes use UTF-8 without BOM,
- record creation validates staged content before atomic append,
- verification rejects modification, deletion, reordering, substitution and identity drift,
- bundle verification is offline and copies no raw evidence,
- detached signing preserves the unsigned bundle identity,
- unsigned, present-unverified, valid and invalid-signature states are unambiguous.

## Public repository boundary

The validation confirms that raw ETL, packet captures, dumps, protected binaries, target drivers, credentials, tokens, private keys, PFX files and undisclosed findings are not committed. Synthetic fixtures, schemas, verifiers, public certificates and redacted metadata remain permitted.

## Warning classification

The completed jobs emitted GitHub-hosted action runtime notices for Node.js 20 deprecation and `punycode`. These originated from `actions/checkout@v4` and `actions/setup-python@v5` being forced onto Node.js 24 by the runner. They were not PSScriptAnalyzer findings, product-code warnings or test failures.

## Merge gate

PR `#5` remains draft until the documentation-only closeout head also passes:

- Static analysis and smoke validation,
- Lifecycle - PowerShell 7,
- Lifecycle - Windows PowerShell 5.1.

After those logs are inspected, update PR `#5` and issue `#4` with the exact final head/run/job evidence, mark the PR ready and squash merge with expected-head locking.
