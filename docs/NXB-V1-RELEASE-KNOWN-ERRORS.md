# NXB v1 Release-Layer Known Errors

This ledger applies only to the post-certification `release/nxb-v1.0.0-prep` successor layer. It does not mutate the native-certified Parts 1-10 known-error authority.

## NXB-ERR-036 — bare typed member expression in command argument mode

**Class:** PowerShell command argument parsing / release review packaging.

**Native discovery:** Release Integration Portable V1 at exact head `b735fca79c32de9a1044255040abe75002194c80`.

The run passed exact-head clone, external release-boundary gates, parser/analyzer/scanner gates, PS7 + Windows PowerShell 5.1 release contracts, fail-closed preflight, and independent Python `10/10 + 6/6` replay. It failed only while copying the five JSON review members.

The failing form was conceptually:

```powershell
Join-Path $reviewRoot [string]$entry.Key
```

In command argument mode the bare cast/member expression was not treated as the intended expression, producing a malformed path containing the cast/enumerator representation.

### Repair contract

- Convert enumerator key/value into explicit local scalar variables before command invocation.
- Pass the already-normalized scalar name to `Join-Path`.
- Keep the five-member JSON-only review closure unchanged.
- Add a release-layer machine signature that rejects the recurring `Join-Path <root> [type]$object.Member` shape.
- Keep the existing 16-test release integration contract count unchanged while adding ERR-036 regression coverage.

### Safety boundary

This failure occurred after all security/integration validation gates. No merge, tag, push, `main` update, production signer claim, or certified runtime mutation occurred.
