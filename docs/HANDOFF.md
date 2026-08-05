# Project Handoff

Bu dosya yeni sohbetlerde projenin kaldığı yeri hızlıca bulmak için kanonik devralma kaydıdır.

## Repository

- Repository: `Naveax/nxb-integrity-research-lab`
- Default branch: `main`
- Visibility: public
- Completed issue: `#1 — NXB-IRL-002`
- Active closeout issue: `#4 — NXB-IRL-003 — Evidence integrity store`
- Prepared next issue: `#2 — NXB-IRL-004 — Full-system observability fabric`
- Merged PR: `#3 — NXB-IRL-002: close deterministic lifecycle validation gaps`
- Active draft PR: `#5 — NXB-IRL-003: deterministic evidence integrity store`
- Active branch: `nxb-irl-003-evidence-integrity-store`

## Current objective

`NXB-IRL-003` implementation and adversarial test scope are complete. The implementation head passed all Windows, analyzer and repository-smoke gates. Remaining work is documentation-head validation, PR/issue evidence update, exact-head squash merge and issue closure.

After merge, begin `NXB-IRL-004` from issue `#2`.

## Canonical project direction

The platform is a full-system observability and evidence system for authorized security and performance research across CPU, scheduler, memory, GPU, storage, network, devices, drivers, kernel lifecycle, power, firmware and boot security.

Required references:

1. `docs/MASTER_PLAN.md`
2. `docs/FULL_SYSTEM_OBSERVABILITY.md`
3. `docs/ROADMAP.md`
4. `docs/NXB-IRL-002-VALIDATION.md`
5. `docs/NXB-IRL-003-EVIDENCE-STORE.md`
6. `docs/NXB-IRL-003-VALIDATION.md`
7. issue `#4`
8. draft PR `#5`
9. issue `#2`

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

### NXB-IRL-003 — Evidence integrity store

Status: `IMPLEMENTATION COMPLETE — PR CLOSEOUT`

#### Canonical identity and schemas

- Draft 2020-12 record, chain-head and bundle-manifest schemas,
- tool provenance and clock-offset payload schemas,
- ordinal case-sensitive canonical JSON,
- array-order preservation,
- JSON escaping and invalid-surrogate rejection,
- integer-only hash-bearing values,
- normalized UTC timestamp handling,
- UTF-8 without BOM SHA-256,
- root-only self-hash exclusions,
- atomic canonical JSON writes.

#### Append-only evidence chain

- exclusive append lock,
- staged schema validation before final append,
- fixed-width record filenames,
- payload, record and previous-record hashes,
- experiment/machine/boot/session identity binding,
- deterministic chain-head,
- raw digest-concatenation chain hash,
- independent chain verification.

#### Tool provenance and clock evidence

- executable path/hash/length/version provenance,
- redacted argument-envelope digest without raw arguments,
- explicit zero versus absent exit-code handling,
- independent executable verification,
- four-timestamp midpoint clock-offset calculation,
- independent arithmetic verification.

#### Deterministic offline bundles

- deterministic record and selected-file inventories,
- canonical relative paths,
- byte length and SHA-256 binding,
- mandatory chain-head,
- complete offline verification without network access,
- bundle comparison semantics,
- traversal, duplicate, case-collision, truncation and reparse rejection.

#### Detached local signing

- `scripts/Add-EvidenceBundleSignature.ps1`,
- `scripts/Test-EvidenceBundleSignature.ps1`,
- RSA SHA-256 PKCS#1 v1.5 detached signatures,
- unsigned bundle identity preserved across signing,
- PFX private key used locally only,
- public CER/PFX verification,
- safe prospective output-path validation,
- rollback on failed signature/manifest commit,
- `unsigned`, `present_unverified` and `valid` states,
- missing, modified and wrong-certificate signatures rejected.

#### Adversarial coverage

- exact one-byte record modification,
- record deletion and sequence gaps,
- record reordering,
- previous-record mismatch,
- cross-experiment record substitution,
- machine, boot and session identity substitution,
- tool binary mutation,
- clock arithmetic tamper,
- bundle truncation and selected-file mutation,
- traversal, case-collision and reparse-point paths,
- missing, modified and wrong-certificate signatures,
- unverified `valid` signature state.

## Validated implementation evidence

Validated implementation head:

```text
77c90ea00eb63a64791d0d418999dd5a8abb78a0
```

Validate run `#162`, run ID `30980814078`:

- PowerShell 7 job `92224628625`: 63 passed, 0 failed,
- Windows PowerShell 5.1 job `92224628713`: 63 passed, 0 failed,
- static job `92224628723`: public guard, zero PSScriptAnalyzer findings and repository smoke success.

Canonical record: `docs/NXB-IRL-003-VALIDATION.md`.

The final documentation-only head must pass the same three jobs before merge. Record that exact final head/run/job evidence in PR `#5` and issue `#4`; do not modify validation documents afterward solely to embed the final metadata.

## Remaining NXB-IRL-003 sequence

1. Resolve PR `#5` latest documentation head and Validate run.
2. Confirm all three jobs are green and inspect every complete log.
3. Update PR `#5` body with exact final head/run/job evidence and completed checklist.
4. Update issue `#4` acceptance checklist and add closeout evidence.
5. Mark PR `#5` ready.
6. Squash merge using the exact validated head.
7. Close issue `#4` as completed.
8. Begin `NXB-IRL-004 — Full-system observability fabric` from issue `#2`.

## Public repository boundary

Never commit raw ETL, packet captures, dumps, protected binaries, drivers, private keys, PFX files, credentials, tokens or undisclosed findings.

## Continuation prompt

```text
Inspect Naveax/nxb-integrity-research-lab.
Read docs/HANDOFF.md, docs/MASTER_PLAN.md, docs/NXB-IRL-003-EVIDENCE-STORE.md and docs/NXB-IRL-003-VALIDATION.md.
Resolve draft PR #5 current head and latest Validate run.
Inspect all three final documentation-head job logs.
If every gate is green, update PR #5 and issue #4 with exact final evidence, mark the PR ready, squash merge using expected-head locking, close issue #4 and begin NXB-IRL-004 from issue #2.
```
