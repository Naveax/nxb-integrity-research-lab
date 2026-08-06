# NXB-IRL-004 — Memory Profile Validation Record

## Status

`IN PROGRESS — FOLLOW-UP EXACT-HEAD WINDOWS RUN REQUIRED`

- Tracking issue: `#2`
- Stacked draft pull request: `#9`
- Branch: `nxb-irl-004-memory-working-set`
- First attempted head: `df33920c9b908f90e057d1854e257a9593ef5e2b`
- Follow-up head: `e7a678d6237cecbc4c9d32940424891c713c6ce4`
- First attempt started UTC: `2026-08-06T12:13:42.6341966Z`
- First attempt stopped UTC: `2026-08-06T12:13:48.9970596Z`

GitHub Actions remain intentionally disabled. Validation is performed locally on real Windows from an elevated PowerShell 7 shell.

## First attempt result

The fresh clone and exact-head checks passed. The runner stopped before any substantive gate because the first call to `Add-NxbMemoryGate` attempted to bind an intentionally empty `List[object]` to a mandatory collection parameter that did not declare `AllowEmptyCollection`.

```text
failure_message:
  Cannot bind argument to parameter 'GateList' because it is an empty collection.

gates: []
```

This failure does not establish a parser, analyzer, native WPR or Pester result. No validation gate ran.

## Follow-up repair

The follow-up commit adds:

```powershell
[AllowEmptyCollection()]
[Collections.Generic.List[object]]$GateList
```

This permits the first gate record to populate the initially empty gate list while retaining the mandatory, strongly typed collection contract.

## Required follow-up gates

- [ ] dependency bootstrap — PowerShell 7
- [ ] dependency bootstrap — Windows PowerShell 5.1
- [ ] PowerShell parser
- [ ] PSScriptAnalyzer
- [ ] memory-profile repository smoke
- [ ] exact structural memory-profile contract
- [ ] native `wpr.exe -profiles` acceptance
- [ ] PowerShell 7 focused Pester
- [ ] Windows PowerShell 5.1 focused Pester
- [ ] summary and review ZIP inspection

No gate is accepted until the follow-up exact-head summary and review ZIP are inspected.
