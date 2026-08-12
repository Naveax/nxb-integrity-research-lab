# NXB v1 Release-Layer Known Errors

This ledger applies only to post-certification NXB v1 successor layers. It does not mutate the native-certified Parts 1-10 known-error authority.

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

## Production Signing Portable V1 — existing ERR-007 and ERR-014 reused

**Native discovery:** Production Signing Portable V1 at exact head `d1469719e2cc399fa1ac02ff4984534c4d2cb784` on Windows 10.0.19045 / PowerShell 7.6.3.

The run passed exact-head clone and the external signing fast gates (`18` source tests, ERR-036, private-key boundary, Python syntax). It stopped in the first repo-owned production-signing authority stage because PSScriptAnalyzer reported exactly four findings:

- `PSUseDeclaredVarsMoreThanAssignments` for `$ps7Contract`.
- `PSUseDeclaredVarsMoreThanAssignments` for `$ps51Contract`.
- `PSUseShouldProcessForStateChangingFunctions` for `New-NxbV1CertificationSigner`.
- `PSUseShouldProcessForStateChangingFunctions` for `New-NxbV1SignedReleaseEnvelope`.

No new error ID is allocated. The two classes are already defined by the native-certified base ledger:

- **NXB-ERR-007:** `New-*` helper without ShouldProcess. For these in-memory construction helpers the repair is to use approved non-mutating verbs instead of pretending that an external system mutation occurs.
- **NXB-ERR-014:** assigned-but-unused analyzer state. The dual-runtime Pester result objects must be consumed in the receipt/result rather than replaced by hard-coded `18/18` strings.

### Signing successor repair contract

- `Get-NxbV1CertificationSigner` replaces the old `New-*` signer helper.
- `ConvertTo-NxbV1SignedReleaseEnvelope` replaces the old `New-*` envelope helper.
- PS7 and PS5.1 summaries are calculated from the actual Pester result objects and bound into certification evidence.
- A signing-successor machine signature set carries ERR-007 and ERR-014 without changing the certified release-integration ERR-036 rule count.
- The production-signing Pester contract remains exactly 18 tests.
- The review closure includes a dedicated `signing-known-error-scan.json` receipt.

The V1 failure occurred before dual-runtime signing tests, real-file fixture signing, RSA replay, adversarial controls, or review packaging executed. Therefore none of those later production-signing layers are considered native-certified by this run.
