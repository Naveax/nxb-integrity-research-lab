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

## NXB-ERR-037 — assignment to readonly PowerShell platform automatic variable

**Class:** PSScriptAnalyzer / PowerShell 6+ readonly automatic platform state.

**Native discovery:** Installer Portable V1 at exact head `24e445f4bcdbdccd8a92c23605913d5c6aa93a67` on Windows 10.0.19045 / PowerShell 7.6.3.

The run passed exact-head clone and all external installer fast gates (`22` source tests, four installer successor rules, ERR-004/007/018/036, path-boundary checks, sentinel binding, and Python syntax). It stopped in the first repo-owned installer authority stage because PSScriptAnalyzer reported exactly one finding in `Test-NxbV1InstallerHost.ps1`: assignment to `$isWindows`, which resolves case-insensitively to the readonly `$IsWindows` automatic variable in PowerShell 6 and newer.

### Repair contract

- Use a semantic local such as `$windowsHost`; never assign `$IsWindows`, `$IsLinux`, `$IsMacOS`, or `$IsCoreCLR`.
- Carry an installer-successor machine signature that rejects assignments to those readonly platform automatic variables across the active installer PowerShell surface.
- Extend the existing release ERR-036 scanner across installer files instead of duplicating ERR-036 inside the installer-successor rule set.
- Keep the installer-successor scanner at four rules: ERR-004, ERR-007, ERR-018, and ERR-037.
- Keep the installer Pester contract exactly 22 tests while adding ERR-037 behavioral/source regression coverage.
- In the same repair sweep, precompute the host receipt status string before object construction so the host surface also remains inside existing ERR-018 PS5.1 compatibility discipline.

### Native scope of the failed run

Installer Portable V1 failed before dual-runtime installer Pester execution, host lifecycle execution, package manifest generation, Stage/Install/Corrupt/Repair/Uninstall, independent Python replay, or review ZIP packaging. None of those later installer layers are considered native-certified by this V1 run.

## Signed staged update pre-native sweep — existing ERR-014 and ERR-029 reused

Before publishing Update Portable V1, the successor source sweep found two existing classes:

- **NXB-ERR-014:** the certification fixture assigned `$nativeRelative` inside the signed-artifact loop without consuming it. The repair uses that native relative path to resolve the real package artifact and recompute its byte count and SHA-256 before adding it to the signed envelope, eliminating the analyzer warning while strengthening byte authority.
- **NXB-ERR-029:** the 24-test source contract still expected stale prose (`An update is already staged.`), while the implementation intentionally rejects equal/older staged sequences and permits explicit supersession by a newer signed sequence. The test is rebound to those stable behaviors instead of weakening the implementation.

The cleanup `finally` around the certification signer was also reviewed. It is entered only after the signer assignment succeeds, so no new cleanup/StrictMode error class is allocated. No Update Portable V1 had been issued at the time of this sweep.