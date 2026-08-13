# NXB v1 CI pre-native hardening

Phase 7 successor branch: `release/nxb-v1.0.0-ci`.

Native-certified predecessor:

```text
certified/nxb-v1-cli
e665e8c27cb085853d23c8804ffaa97a19807eb9
```

No Phase 7 CI Portable or native CI authority had been issued when the findings below were discovered. The certified CLI predecessor is unchanged.

## ERR-015 recurrence - interpolated expected-source literal

The first 17-test CI contract used double-quoted source assertions containing the literal PowerShell token `$repositoryRoot`:

```text
Join-Path $repositoryRoot 'tools'
Join-Path $repositoryRoot 'tests'
```

PowerShell would expand `$repositoryRoot` while evaluating the test instead of comparing the intended source literal. This is the existing NXB-ERR-015 class; no new error ID is allocated.

Repair:

- encode the expected source shapes as single-quoted literals with embedded quote escaping;
- preserve the literal `$repositoryRoot` token;
- keep the CI Pester contract at exactly 17 tests.

## ERR-029 recurrence - YAML expression representation drift

The first independent CI validator compared the parsed release-candidate job `if` field to the bare string `always()`. The workflow source intentionally carries the GitHub expression `${{ always() }}`. Depending on representation, exact bare-string equality can reject semantically correct workflow source.

This is existing NXB-ERR-029 source/contract drift; no new error ID is allocated.

Repair:

- bind the validator to the stable semantic token `always()` inside the parsed `if` field rather than one incidental wrapper representation;
- retain exact aggregate `needs` membership and all child-result fail-closed checks.

## NXB-ERR-044 - delegated result field typo can fail open

Class: pre-native / delegated authority result-schema drift.

The initial signed-release CI lane checked:

```text
$result.actual_release_signed
```

The native-certified production-signing authority actually returns:

```text
actual_production_release_signed
```

Without StrictMode, a missing PowerShell property evaluates to `$null`; casting that value to boolean yields `false`. Therefore the incorrect field name could silently satisfy a production-boundary assertion instead of failing closed.

Repair contract:

- enable StrictMode in the signed-release verification step;
- access the delegated PassThru object through `PSObject.Properties`;
- require both `production_signer_claimed` and `actual_production_release_signed` properties to exist;
- fail closed if either required property is absent;
- require both property values to be exactly false before hosted CI may pass;
- regression-lock the exact property names in both Pester and the independent Python validator;
- never provision, reference, or expose production private signing material in hosted CI.

## Current pre-native CI boundary

```text
workflow jobs                 4
hosted check                  nxb-v1 / hosted-contract
signed verification check     nxb-v1 / signed-release-verify
native WPT check              nxb-v1 / native-wpt
aggregate check               nxb-v1 / release-candidate
CI Pester contract            17 tests
independent validator         12 requirements + 8 negatives
native WPT trigger            manual workflow_dispatch only
native runner                 self-hosted Windows X64 nxb-native wpt
workflow permission           contents: read
production private key        forbidden
production release mutation   false
```

These repairs are pre-native hardening only. They do not certify Phase 7. The CI successor remains uncertified until hosted GitHub Actions checks execute successfully on the exact candidate, the trusted self-hosted/native boundary is validated separately, and a Portable Windows CI authority plus independent artifact audit closes the frozen head.
