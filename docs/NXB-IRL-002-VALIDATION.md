# NXB-IRL-002 Validation Record

## Scope

This record tracks the closeout validation for the deterministic experiment lifecycle block.

## Required gates

- [ ] PowerShell parser clean for all scripts and tests.
- [ ] PSScriptAnalyzer clean at Error and Warning severity.
- [ ] Repository smoke validation clean.
- [ ] PowerShell 7 Pester suite clean.
- [ ] Windows PowerShell 5.1 Pester suite clean.
- [ ] WPR executable-unavailable path fails visibly.
- [ ] WPR start failure preserves `prepared` state.
- [ ] WPR stop failure preserves `recording` state.
- [ ] WPR success without ETL is rejected.
- [ ] Synthetic WPR success reaches `stopped` deterministically.
- [ ] Untracked synthetic blocked artifacts are rejected by policy.
- [ ] Reparse points inside the evidence tree are rejected.
- [ ] Finalization remains idempotent.
- [ ] One-byte evidence modification remains detectable.

## Pull request

Draft PR `#3` contains the closeout implementation. It must remain draft until every GitHub Actions job is visible and successful.

## Result

Status: `PENDING CI`

Do not mark NXB-IRL-002 complete or close issue `#1` until the required gates above are backed by inspected Windows Actions results.
