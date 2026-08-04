# Project Handoff

Bu dosya yeni sohbetlerde projenin kaldığı yeri hızlıca bulmak için kanonik devralma kaydıdır.

## Repository

- Repository: `Naveax/nxb-integrity-research-lab`
- Default branch: `main`
- Visibility: public
- Completed issue: `#1 — NXB-IRL-002`
- Prepared observability issue: `#2 — NXB-IRL-004`
- Active issue: `#4 — NXB-IRL-003 — Evidence integrity store`
- Merged PR: `#3 — NXB-IRL-002: close deterministic lifecycle validation gaps`
- Active draft PR: `#5 — NXB-IRL-003: deterministic evidence integrity store`
- Active branch: `nxb-irl-003-evidence-integrity-store`

## Current objective

Close `NXB-IRL-003` after final Windows CI repair. The implementation scope is now complete; remaining work is validation, documentation closeout and exact-head merge.

## Canonical project direction

The platform is a full-system observability and evidence system for authorized security and performance research across CPU, scheduler, memory, GPU, storage, network, devices, drivers, kernel lifecycle, power, firmware and boot security.

Required references:

1. `docs/MASTER_PLAN.md`
2. `docs/FULL_SYSTEM_OBSERVABILITY.md`
3. `docs/ROADMAP.md`
4. `docs/NXB-IRL-002-VALIDATION.md`
5. `docs/NXB-IRL-003-EVIDENCE-STORE.md`
6. issue `#4`
7. draft PR `#5`
8. issue `#2`

## Completed phases

### NXB-IRL-001 — Repository bootstrap

- workspace and experiment creation,
- baseline collection,
- WPR trace lifecycle,
- KDNET preparation checks,
- evidence hashing and finalization,
- public/private evidence boundary.

### NXB-IRL-002 — Deterministic experiment lifecycle

Status: `COMPLETE`

- canonical state machine,
- atomic JSON writes,
- idempotent finalization,
- evidence integrity verification,
- interrupted-experiment recovery,
- explicit failed state,
- path escape and reparse rejection,
- manifest JSON Schema validation,
- WPR failure-path matrix,
- PowerShell 5.1, PowerShell 7 and PSScriptAnalyzer validation.

Validated head: `878710229ad11c5c1b95247e304986ca4e5eda47`.

Squash merge: `e3b3ab79ab72cafa92f2afa97895258cec912d86`.

## NXB-IRL-003 implementation on draft PR #5

### Canonical identity and schemas

- Draft 2020-12 record, chain-head and bundle-manifest schemas,
- tool provenance and clock-offset payload schemas,
- ordinal case-sensitive canonical JSON,
- array-order preservation,
- JSON escaping and invalid-surrogate rejection,
- integer-only hash-bearing values,
- UTF-8 without BOM SHA-256,
- root-only self-hash exclusions,
- atomic canonical JSON writes.

### Append-only evidence chain

- exclusive append lock,
- staged schema validation before final append,
- fixed-width record filenames,
- payload, record and previous-record hashes,
- experiment/machine/boot/session identity binding,
- deterministic chain-head,
- raw digest-concatenation chain hash,
- independent chain verification.

### Tool provenance and clock evidence

- executable path/hash/length/version provenance,
- redacted argument-envelope digest without raw arguments,
- independent executable verification,
- four-timestamp midpoint clock-offset calculation,
- independent arithmetic verification.

### Deterministic offline bundles

- deterministic record and selected-file inventories,
- canonical relative paths,
- byte length and SHA-256 binding,
- mandatory chain-head,
- complete offline verification without network access,
- bundle comparison semantics,
- traversal, duplicate, case-collision, truncation and reparse rejection.

### Detached local signing

- `scripts/Add-EvidenceBundleSignature.ps1`,
- `scripts/Test-EvidenceBundleSignature.ps1`,
- RSA SHA-256 PKCS#1 v1.5 detached signatures,
- unsigned bundle identity preserved across signing,
- PFX private key used locally only,
- public CER/PFX verification,
- `unsigned`, `present_unverified` and `valid` states,
- missing, modified and wrong-certificate signatures rejected.

### Repository smoke integration

The repository smoke flow now executes:

```text
experiment lifecycle
→ observation identity
→ evidence finalization
→ evidence-store records
→ chain verification
→ deterministic unsigned bundle
→ offline verification
```

### Adversarial coverage

- canonical property and array ordering,
- one-byte payload and signature changes,
- record deletion and sequence gaps,
- identity substitution,
- tool binary mutation,
- clock arithmetic tamper,
- bundle truncation,
- traversal and case-collision,
- reparse-point path,
- missing signature,
- wrong certificate,
- unverified `valid` state.

## Current validation state

Status: `FINAL WINDOWS CI REPAIR`

The first complete static run after the four parallel implementation blocks reported eight analyzer findings:

- seven helper functions used the `New-*` verb without `ShouldProcess`,
- one synthetic PFX fixture used plaintext `ConvertTo-SecureString`.

All eight were repaired without disabling rules:

- pure helpers use `Get-*`,
- fixture helpers use `Initialize-*` or `Invoke-*`,
- SecureString test fixture is built character-by-character.

Resolve the current head and latest Validate run from PR #5; do not rely on a stale SHA stored here.

Required final jobs:

- Static analysis and repository smoke validation,
- Lifecycle — PowerShell 7,
- Lifecycle — Windows PowerShell 5.1.

PR #5 remains draft until all three jobs and logs are inspected.

## Remaining NXB-IRL-003 sequence

1. Inspect the latest Validate run.
2. Repair remaining PSScriptAnalyzer, smoke or Pester failures.
3. Add a final validation/closeout record.
4. Update issue `#4` and PR `#5` with exact run/job evidence.
5. Mark PR ready and squash merge using the exact validated head.
6. Close issue `#4`.
7. Start `NXB-IRL-004 — Full-system observability fabric` from issue `#2`.

## Public repository boundary

Never commit raw ETL, packet captures, dumps, protected binaries, drivers, private keys, PFX files, credentials, tokens or undisclosed findings.

## Continuation prompt

```text
Inspect Naveax/nxb-integrity-research-lab.
Read docs/HANDOFF.md, docs/MASTER_PLAN.md and docs/NXB-IRL-003-EVIDENCE-STORE.md.
Resolve draft PR #5 current head and latest Validate run.
Inspect every completed job log.
Repair remaining static, smoke, PowerShell 7 and Windows PowerShell 5.1 failures without weakening quality rules.
When all jobs are green, write the exact validation record, mark PR #5 ready, squash merge with exact-head locking, close issue #4 and begin NXB-IRL-004 from issue #2.
```
