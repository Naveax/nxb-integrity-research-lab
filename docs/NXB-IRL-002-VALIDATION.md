# NXB-IRL-002 Validation Record

## Scope

This record tracks the closeout validation for the deterministic experiment lifecycle block.

## Implemented validation coverage

- [x] WPR executable-unavailable test.
- [x] Existing-session cancellation failure test.
- [x] WPR start nonzero-exit test.
- [x] WPR stop nonzero-exit test.
- [x] Successful stop without ETL fail-closed test.
- [x] Synthetic successful WPR lifecycle test.
- [x] Untracked synthetic blocked-artifact test.
- [x] Reparse-point/junction adversarial test.
- [x] Canonical evidence ordering test.
- [x] Finalization idempotency test.
- [x] One-byte evidence modification test.
- [x] Interrupted recording recovery test.
- [x] Manifest Draft 2020-12 validation.
- [x] PowerShell 5.1 and PowerShell 7 workflow matrix.
- [x] Manual `workflow_dispatch` trigger definition.

## Repository Actions configuration

Repository owner confirmed on 2026-08-04 that:

- Actions are enabled,
- all actions and reusable workflows are allowed,
- full-length SHA pinning is not required,
- the default workflow token is read-only for repository contents and packages,
- GitHub Actions cannot create or approve pull requests.

This commit intentionally retriggers the pull-request validation workflow after those settings were saved.

## Required execution gates

- [ ] GitHub Actions run is visible.
- [ ] PowerShell parser is clean for all scripts and tests.
- [ ] PSScriptAnalyzer is clean at Error and Warning severity.
- [ ] Repository smoke validation succeeds.
- [ ] PowerShell 7 Pester suite succeeds.
- [ ] Windows PowerShell 5.1 Pester suite succeeds.
- [ ] Every job log is inspected.
- [ ] Any discovered failure is repaired and re-run.

## Expected lifecycle assertions

The Windows test run must demonstrate that:

- missing WPR leaves the experiment `prepared`,
- failed existing-session cancellation starts no new trace,
- failed WPR start leaves the experiment `prepared`,
- failed WPR stop preserves `recording` for recovery,
- successful stop without ETL marks manifest and session `failed`,
- successful synthetic capture reaches `stopped`,
- untracked blocked artifacts are rejected,
- reparse points are rejected before traversal descends,
- second finalization changes no bytes,
- a one-byte evidence change is detected.

## Pull request

Draft PR `#3` contains the closeout implementation. It must remain draft until every required execution gate is backed by inspected Windows Actions results.

## Current result

Status: `PENDING WINDOWS CI`

Observed limitation before Actions were enabled:

- GitHub connector queries returned no workflow runs or status checks for the PR head or merge ref.
- The execution environment has no authenticated GitHub CLI.
- The execution environment has no local Windows PowerShell or PowerShell 7 runtime.

No CI success is claimed until the retriggered run and every job log are inspected. Do not mark NXB-IRL-002 complete, merge PR #3, or close issue #1 until the required execution gates above are satisfied.
