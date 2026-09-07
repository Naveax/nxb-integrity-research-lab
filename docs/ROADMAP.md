# Roadmap

Kanonik devralma kaydı: [`HANDOFF.md`](HANDOFF.md)

Kanonik uçtan uca planın tarihsel temeli: [`MASTER_PLAN.md`](MASTER_PLAN.md)

Tam sistem gözlem mimarisi: [`FULL_SYSTEM_OBSERVABILITY.md`](FULL_SYSTEM_OBSERVABILITY.md)

## Current authority block

### Issue #26 — bounded pre-trigger / post-trigger capture primitives

Durum: `IMPLEMENTED — HOSTED ADMITTED — TRUSTED NATIVE AUTHORITY PENDING`

Active PR: `#48 — NXB runtime: bounded pre-trigger / post-trigger capture primitives`

Current exact tuple:

```text
base/main  1dc42289d587a8f06a5eca39b45142b5bcc565af
head       f661af3e98031f3da1a7fc4bc693e6d8b39a551d
tree       2cfe8ef95515ff1f02ec50915c79c3e5fc4894fb
preview    024a334fd36f68bd8ffa15e03e4cbe1410b55bae  # ephemeral
```

Hosted authority:

```text
NXB v1 CI #119
run id       33079363219
attempt      1
conclusion   SUCCESS
artifact id  9649653921
SHA-256      a67f059842ccb54002fb322234a62bfe0a279289c1abce95c6a9d33f7b911b76
```

Closed current-head gates:

- [x] bounded 64 MiB Memory-WPR pre-trigger primitive
- [x] exact-head/session/policy state binding
- [x] requested/effective/observed pre/post duration accounting
- [x] monotonic hard/post deadlines
- [x] overlapping-trigger coalescing
- [x] bounded trigger-storm rejection
- [x] emergency/budget/disk-pressure termination
- [x] bounded trigger history
- [x] honest per-domain accounting
- [x] trace-loss and circular-overwrite accounting retained
- [x] ETL SHA-256 retained without publishing raw ETL in review evidence
- [x] exact native review cardinality `8`
- [x] post-run exact-head + clean-worktree verification before evidence upload
- [x] native Python `3.12.10` binding
- [x] completed state -> exact capture receipt SHA-256 binding
- [x] hosted PS7 `915/915`
- [x] hosted PS5.1 `908/915` + exactly seven `PS7Only`
- [x] analyzer findings `0`
- [x] known-error findings `0`
- [x] independent validator `13/13 + 8/8`
- [x] hosted artifact independently re-hashed and admitted
- [x] physical preflight / one-dispatch / postflight / independent-audit contracts defined

Remaining authority gates:

- [ ] trusted elevated physical Windows preflight PASS
- [ ] exact-head native lock acquired atomically
- [ ] exactly one `workflow_dispatch(run_native=true)`
- [ ] resolved native run SUCCESS without duplicate redispatch
- [ ] same-process runner/runtime continuity PASS
- [ ] exact runtime-ledger freeze
- [ ] exact 11-file outer / 8-entry inner native evidence audit
- [ ] real bounded Memory-WPR smoke evidence PASS
- [ ] `post_run_repository_integrity_valid=true`
- [ ] `state_evidence_sha256 == receipt_sha256`
- [ ] native run/job/artifact/digest authority frozen in Issue #26
- [ ] fresh final main/head/tree/merge-preview CAS
- [ ] PR #48 Ready transition
- [ ] merge by merge commit only with expected-head CAS
- [ ] published-main ancestry/tree verification
- [ ] Issue #26 closure
- [ ] native lock release after publication verification

Canonical physical execution precedence: Issue #26 comment `5440464799` v4.1.

```text
5440410030  physical preflight bundle v4.0
5440426680  exact-head one-dispatch operator v4.1
5440443895  post-run continuity + runtime-ledger freeze v4.1
5440455610  independent native admission v4.0
```

2026-09-07 continuation revalidation: Issue #26 comment `5566587788`.

## Parallel planning block

### Issue #49 — v1.1 compatibility, endurance and repository enforcement backlog

Durum: `PLANNING / SOURCE-ARCHAEOLOGY ONLY — IMPLEMENTATION BLOCKED BY #26`

The v1.1 lane starts only from the post-#26 admitted `main`.

Planning already closed:

- [x] compatibility policy/cell model
- [x] stable first-wave cell IDs
- [x] environment fingerprint contract
- [x] canonical JSON/SHA-256 cross-runtime profile
- [x] Python transitive hash-lock model
- [x] PowerShell portable-runtime/module hash-lock model
- [x] Windows build-family/GAC servicing-floor model
- [x] WPT/ADK paired-toolchain servicing provenance model
- [x] hosted vs trusted-native responsibility split
- [x] deterministic dispatch identity and no-duplicate protocol
- [x] exact six-entry compatibility artifact contract
- [x] successor/predecessor test-discovery isolation under `validation/v11/`
- [x] V11 package/state namespace and predecessor migration/rollback semantics
- [x] bounded 1h/6h/24h endurance model
- [x] durable lifecycle transaction/reconciliation design
- [x] default-branch trusted dispatcher + detached candidate model
- [x] disposable/JIT and session-scoped native-runner lifecycle models
- [x] dedicated native-admission integration provenance model
- [x] repository-protection rollback/break-glass design

Intentionally unresolved until #26 publication:

- [ ] exact predecessor `main` SHA/tree

Implementation and certification backlog after #26:

1. V11.A0 claim-free compatibility substrate seed.
2. V11.A1/V11.B first dispatchable trusted Windows baseline + bounded 1h authority.
3. Expand exactly one compatibility axis at a time.
4. Durable cross-directory lifecycle transaction journal + startup reconciliation.
5. Clean-host elevated PerMachine managed-root lifecycle.
6. Existing-PerMachine signed updater Apply/Rollback/reboot/disk-pressure lifecycle.
7. Queue/network interruption authority for update/release paths.
8. Promote admitted classes from 1h -> 6h -> 24h without increasing per-cycle limits.
9. Dry-run dedicated native-admission integration on a disposable target.
10. Enable `main` protection only after independent settings audit proves the flow cannot deadlock trusted-native release authority.

## Repository enforcement target

Current `main` remains unprotected. This is tracked debt, not an invitation to enable protection prematurely.

Future ordinary PR required checks are expected to include:

- `nxb-v1 / hosted-contract`
- `nxb-v1 / signed-release-verify`
- `nxb-v1 / release-candidate`

Do **not** treat the current manual-only `nxb-v1 / native-wpt` job as a normal required PR check. The planned exact-head native proof is a separate `nxb-native-admission / exact-head` context emitted by a dedicated minimal integration whose credential is unavailable to candidate-controlled workflows.

Protection enablement remains blocked until a disposable-target dry-run and independent settings receipt pass.

## Compatibility/endurance target inventory

Planning targets remain unadmitted until dedicated evidence exists:

- Windows 10 22H2 legacy/ESU retained-compatibility decision
- Windows 11 25H2 primary x64 GAC baseline
- Windows 11 24H2 retained-support cell
- Windows 11 23H2 Enterprise/Education retained cell if intentionally supported
- Windows 11 26H1 / Arm64 separate support decision
- PowerShell 7.6 LTS primary cell
- PowerShell 7.5 Stable compatibility cell
- PowerShell 7.4 previous-LTS compatibility cell while vendor-supported
- Python 3.12.10 predecessor replay
- Python 3.13.x intermediate compatibility
- Python 3.14.x current-feature compatibility
- serviced WPT/ADK baseline with exact paired WPR/Xperf identity
- clean-host PerMachine lifecycle
- existing-PerMachine update/rollback lifecycle
- reboot recovery
- disk-pressure recovery
- queue saturation
- network interruption
- bounded 1h / 6h / 24h endurance

A target is not considered supported merely because a historical run happened on a vaguely similar host. Compatibility claims require exact environment fingerprints and current authority evidence.

## Historical completed authority line

The repository contains the completed v1.0.0 -> v1.0.1 production authority chain, including:

- IRL-006 Parts 1-10 native-certified implementation lineage;
- release integration;
- production signing authority;
- installer/package authority;
- signed staged update/rollback authority;
- production CLI authority;
- CI/native authority automation;
- v1.0.1 successor transition and release publication;
- post-release CLI status authority.

Historical exact-tree pointers and published release evidence remain immutable. Current successor work does not retroactively rewrite their test counts, native review cardinalities, signatures or receipts.

## Documentation sequencing

The previous `ROADMAP.md` and `HANDOFF.md` had remained frozen around PR #8 / Issue #2 and were no longer usable as current continuation records.

While Issue #26 is open, documentation cleanup must remain on a separate branch and must not advance `main`; otherwise PR #48's base/merge-preview would change and exact-head certification would become stale for no runtime reason.

After #26 publication, refresh any pending documentation branch from the new admitted `main` before merging it.

## Public repository boundary

Never commit raw ETL, packet captures, dumps, protected binaries, drivers, private keys, PFX/P12 files, credentials, tokens, undisclosed findings or other sensitive evidence bytes.

## Continuation order

1. Read `docs/HANDOFF.md`.
2. Re-read Issue #26 and PR #48 live state.
3. Reconfirm `main`, candidate head/tree and exact-head workflow-dispatch inventory.
4. If an equivalent native run already exists, follow its run ID; do not redispatch.
5. If no run exists, the next authority is the trusted physical v4.1 chain, not a connector-generated substitute.
6. Keep Issue #49 implementation blocked until #26 is merged and published-main verified.
