# Project Handoff

Bu dosya yeni sohbetlerde projenin gerçekten kaldığı yeri bulmak için kanonik devralma kaydıdır.

> **Authority note:** Bu dosyanın güncellenmesi mevcut exact-head sertifikasyonunu değiştirmez. Runtime/release otoritesi Git commit/PR/Issue/CI kanıtlarıyla belirlenir.

## Repository

- Repository: `Naveax/nxb-integrity-research-lab`
- Default branch: `main`
- Visibility: public
- Current `main`: `1dc42289d587a8f06a5eca39b45142b5bcc565af`
- Current `main` tree: `393afa3a1cfe391a613017465778638ca46f71ea`
- Published release line: `v1.0.1`
- Canonical active runtime issue: `#26 — NXB v1.x — Bounded pre-trigger / post-trigger capture primitives`
- Canonical active PR: `#48 — NXB runtime: bounded pre-trigger / post-trigger capture primitives`
- Post-#26 planning backlog: `#49 — NXB v1.1 — compatibility, endurance and repository enforcement backlog`

GitHub Actions are **enabled and authority-bearing**. The old handoff statement that Actions must remain disabled is historical and no longer valid.

## Current exact-head runtime authority

PR `#48` remains open, draft and unmerged.

```text
base/main  1dc42289d587a8f06a5eca39b45142b5bcc565af
head       f661af3e98031f3da1a7fc4bc693e6d8b39a551d
tree       2cfe8ef95515ff1f02ec50915c79c3e5fc4894fb
preview    024a334fd36f68bd8ffa15e03e4cbe1410b55bae  # ephemeral
```

The current source implements the remaining bounded pre-trigger/post-trigger runtime primitive on top of the published v1.0.1 authority without rewriting historical release evidence.

Key runtime properties already implemented:

- bounded 64 MiB Memory-WPR pre-trigger ring;
- exact-head/session/policy-bound state;
- monotonic hard/post deadlines;
- bounded overlap coalescing and trigger-storm rejection;
- emergency, budget and disk-pressure termination;
- bounded per-domain accounting;
- retained ETL SHA-256 without retaining raw ETL in review evidence;
- native review cardinality exactly `8`;
- post-run exact-head + clean-worktree verification before native evidence upload;
- completed state `evidence_sha256` bound to the exact retained capture receipt SHA-256;
- native smoke evidence retains `state_evidence_sha256` and requires exact equality with `receipt_sha256`.

## Hosted authority

Fresh current-head hosted certification is closed:

```text
workflow      NXB v1 CI
run number    #119
run id        33079363219
attempt       1
event         pull_request
conclusion    SUCCESS
artifact id   9649653921
artifact      nxb-v1-hosted-validation-f661af3e98031f3da1a7fc4bc693e6d8b39a551d
SHA-256       a67f059842ccb54002fb322234a62bfe0a279289c1abce95c6a9d33f7b911b76
```

Independent hosted audit closed with:

- exact six safe hosted artifact entries;
- PowerShell 7 `915/915`;
- Windows PowerShell 5.1 `908/915` with exactly seven `PS7Only` exclusions;
- PSScriptAnalyzer findings `0`;
- known-error findings `0`;
- independent validator `13/13 + 8/8`;
- production mutation false.

Hosted admission freeze: Issue #26 comment `5440357764`.

## Current physical/native boundary

As of the 2026-09-07 continuation revalidation:

```text
exact-head workflow_dispatch count = 0
exact-head native authority         = none
PR #48 state                        = OPEN / DRAFT
```

Do **not** manufacture a native authority from an untrusted environment. The remaining boundary requires the trusted elevated physical Windows host, Administrator access, real WPR/Xperf, and the repository's `NXB-NATIVE-WPT` runner identity/runtime.

Canonical physical execution precedence is Issue #26 comment `5440464799` (**v4.1**):

```text
5440410030  physical preflight bundle v4.0
5440426680  exact-head one-dispatch operator v4.1
5440443895  post-run continuity + runtime-ledger freeze v4.1
5440455610  independent native admission v4.0
```

Operational rules:

1. run preflight on the trusted elevated Windows host;
2. remain in the same PowerShell 7 process;
3. acquire the exact-head native lock atomically;
4. issue exactly one `workflow_dispatch(run_native=true)`;
5. resolve and poll only that run ID;
6. never rerun or redispatch as a substitute for polling;
7. after SUCCESS, run post-run continuity/runtime-ledger freeze while the lock remains held;
8. independently audit exact 11-file outer / 8-entry inner evidence;
9. keep the lock held through final CAS, merge and published-main verification;
10. failure/cancellation/ambiguity does not authorize automatic rerun or lock release.

Continuation checkpoint comment: Issue #26 comment `5566587788`.

## Current CI contract

Workflow: `.github/workflows/nxb-v1-ci.yml`

Named checks:

- `nxb-v1 / hosted-contract`
- `nxb-v1 / signed-release-verify`
- `nxb-v1 / native-wpt`
- `nxb-v1 / release-candidate`

`native-wpt` is intentionally manual-only:

```text
github.event_name == workflow_dispatch && inputs.run_native
```

Runner labels:

```text
[self-hosted, Windows, X64, nxb-native, wpt]
```

Ordinary PR runs must not be treated as native certification merely because the native job is skipped.

## Remaining #26 gates

- [ ] trusted physical-host preflight PASS;
- [ ] exactly one exact-head native dispatch, attempt 1 unless a separately classified infrastructure failure is explicitly handled under the authority rules;
- [ ] same-process post-run runner/runtime continuity PASS;
- [ ] exact runtime ledger publication and digest reconciliation;
- [ ] exact 11-file outer / 8-entry inner native artifact independent audit;
- [ ] Python `3.12.10`, Pester `5.7.1`, PSScriptAnalyzer `1.25.0`, PyYAML `6.0.3`, jsonschema `4.26.0` bindings confirmed;
- [ ] bounded arm-gate/domain/state-to-receipt evidence confirmed;
- [ ] `post_run_repository_integrity_valid=true` confirmed;
- [ ] native run/job/artifact/digest authority frozen in Issue #26;
- [ ] fresh final main/head/tree/merge-preview CAS;
- [ ] PR #48 marked Ready only after native admission;
- [ ] merge by **merge commit only** with `expected_head_sha=f661af3e98031f3da1a7fc4bc693e6d8b39a551d`;
- [ ] published-main ancestry/tree verification;
- [ ] close #26;
- [ ] release the exact native lock only after publication verification.

Squash/rebase are not admissible for the authority merge.

## Issue #49 / v1.1 boundary

Issue `#49` is planning/source-archaeology only while #26 remains unadmitted.

Do not before #26 closes:

- create a v1.1 implementation branch;
- dispatch successor production/compatibility authority;
- enable branch protection;
- register/reconfigure successor runners;
- use a production signer;
- mutate tags/Releases;
- rewrite v1.0.0/v1.0.1 authority.

The first unresolved v1.1 design field is intentionally the exact post-#26 predecessor `main` SHA/tree.

The planned post-#26 sequence is:

1. freeze the post-#26 predecessor SHA/tree;
2. V11.A0 claim-free compatibility substrate seed;
3. V11.A1/V11.B first dispatchable trusted Windows compatibility + bounded 1h authority;
4. expand one compatibility axis at a time;
5. add durable lifecycle transaction journal/startup reconciliation;
6. certify clean-host elevated PerMachine lifecycle;
7. certify existing-PerMachine signed update/rollback/reboot/disk-pressure lifecycle;
8. extend pressure/interruption authority to update/release transport;
9. promote admitted classes from 1h -> 6h -> 24h without increasing per-cycle limits;
10. dry-run the dedicated native-admission integration and repository protection before enabling `main` enforcement.

## Repository-enforcement debt

`main` is currently unprotected. Repository-level enforcement is intentionally deferred until the dedicated native-admission integration can be dry-run safely.

Future policy must not simply mark `nxb-v1 / native-wpt` as a normal required PR check. The planned native proof is a distinct `nxb-native-admission / exact-head` context emitted only by a dedicated minimal integration whose credential is unavailable to candidate PR workflows.

## Documentation sequencing

The historical `docs/ROADMAP.md` and prior `docs/HANDOFF.md` content lagged far behind the current authority chain. Documentation-only cleanup must **not** be merged into `main` before #26 closes because advancing `main` would stale PR #48's current base/merge-preview and force avoidable recertification.

Any documentation cleanup branch prepared while #26 is open should remain draft/unmerged, then be refreshed from the post-#26 `main` before final merge.

## Public repository boundary

Never commit raw ETL, packet captures, dumps, protected binaries, drivers, private keys, PFX/P12 files, credentials, tokens, undisclosed findings, or other sensitive evidence bytes.

## Continuation prompt

```text
Continue Naveax/nxb-integrity-research-lab from Issue #26 / PR #48.
Current candidate head: f661af3e98031f3da1a7fc4bc693e6d8b39a551d.
Current candidate tree: 2cfe8ef95515ff1f02ec50915c79c3e5fc4894fb.
Current main: 1dc42289d587a8f06a5eca39b45142b5bcc565af.
Hosted authority: NXB v1 CI #119 / 33079363219 / SUCCESS.
Canonical physical precedence: Issue #26 comment 5440464799 v4.1.
Before any dispatch, prove exact-head workflow_dispatch count is still zero and run the trusted physical preflight.
Never duplicate an equivalent active Action for the same SHA/workflow/input.
Do not implement v1.1 or advance main before #26 native admission and merge publication are complete.
```
