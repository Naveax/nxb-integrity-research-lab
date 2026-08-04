# Project Handoff

Bu dosya yeni sohbetlerde projenin kaldığı yeri hızlıca bulmak için kanonik devralma kaydıdır.

## Repository

- Repository: `Naveax/nxb-integrity-research-lab`
- Default branch: `main`
- Visibility: public
- Completed issue: `#1 — NXB-IRL-002`
- Prepared observability issue: `#2 — NXB-IRL-004`
- Active issue: `#4 — NXB-IRL-003 Evidence integrity store`
- Active branch: `nxb-irl-003-evidence-integrity-store`
- Active draft PR: `#5 — NXB-IRL-003: evidence integrity store contracts`
- NXB-IRL-002 validated head: `878710229ad11c5c1b95247e304986ca4e5eda47`
- NXB-IRL-002 squash merge: `e3b3ab79ab72cafa92f2afa97895258cec912d86`

## Current objective

Implement and validate `NXB-IRL-003 — Evidence integrity store`.

Required scope:

- canonical manifest hash,
- append-only experiment chain,
- tool provenance,
- controller/target clock offset,
- machine/boot/session identity,
- offline evidence bundle,
- integrity comparison,
- optional local signature.

## Current NXB-IRL-003 progress

Completed on branch:

- [x] version-1 design contract,
- [x] canonical serialization and hashing rules,
- [x] append-only record contract,
- [x] identity-binding rules,
- [x] tool provenance requirements,
- [x] clock-offset evidence requirements,
- [x] offline bundle and signature-state rules,
- [x] `schemas/evidence-store-record.schema.json`,
- [x] `schemas/evidence-chain-head.schema.json`,
- [x] `schemas/evidence-bundle-manifest.schema.json`.

Next required implementation:

1. Shared canonical JSON serializer.
2. SHA-256 helper for canonical objects and files.
3. Schema validators for records, chain heads and bundles.
4. Append-only record creation.
5. Full chain verification.
6. Tool provenance record helper.
7. Clock-offset evidence helper.
8. Deterministic offline bundle creation.
9. Bundle verification and comparison.
10. Optional detached signing adapter.
11. Adversarial Pester tests on PowerShell 5.1 and PowerShell 7.

## NXB-IRL-003 quality gates

- identical inputs produce identical canonical hashes,
- one-byte changes are detected,
- deletion, reordering and substitution are detected,
- machine/boot/session/experiment mismatch fails closed,
- tool provenance is independently verifiable,
- offline verification requires no network,
- unsigned and invalid-signature states are unambiguous,
- PSScriptAnalyzer and repository smoke validation remain green,
- PowerShell 5.1 and PowerShell 7 jobs remain green,
- raw ETL, dumps, target binaries, keys and undisclosed findings stay outside the public repository.

## Completed blocks

### NXB-IRL-001 — Repository bootstrap

Status: `COMPLETE`.

### NXB-IRL-002 — Deterministic experiment lifecycle

Status: `COMPLETE`.

Detailed record: `docs/NXB-IRL-002-VALIDATION.md`.

Final validation:

- static analysis and repository smoke validation: green,
- PowerShell 7 lifecycle suite: green,
- Windows PowerShell 5.1 lifecycle suite: green.

## NXB-IRL-004 preparation already on main

- `docs/FULL_SYSTEM_OBSERVABILITY.md`,
- system capability schema and collector,
- capability baseline integration and tests,
- normalized observability event schema,
- machine/boot/monotonic-clock identity schema,
- observation identity collector and tests,
- issue `#2`.

## Canonical references

1. `docs/MASTER_PLAN.md`
2. `docs/NXB-IRL-003-EVIDENCE-STORE.md`
3. `docs/FULL_SYSTEM_OBSERVABILITY.md`
4. `docs/ROADMAP.md`
5. `docs/NXB-IRL-002-VALIDATION.md`
6. issue `#4`
7. draft PR `#5`

## Continuation prompt

```text
Inspect Naveax/nxb-integrity-research-lab.
Read docs/HANDOFF.md, docs/MASTER_PLAN.md and docs/NXB-IRL-003-EVIDENCE-STORE.md.
Inspect issue #4 and draft PR #5.
Continue NXB-IRL-003 from the shared canonical JSON serializer.
Keep issue #2 as the prepared NXB-IRL-004 full-system observability track.
Update HANDOFF.md and the active issue/PR after every completed block.
```
