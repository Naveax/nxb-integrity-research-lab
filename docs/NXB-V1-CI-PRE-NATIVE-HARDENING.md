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

## First hosted Actions run - existing ERR-029 reused for inherited parser literal drift

**Hosted discovery:** pull-request workflow run `31680814048` at exact Phase 7 head:

```text
de81904da85b09e55c25b1aeaf919420f6781f79
```

The run established several CI boundaries before the failure:

- exact candidate checkout succeeded;
- pinned checkout/setup-python actions resolved by exact SHA;
- `contents: read` was the effective token permission;
- `nxb-v1 / signed-release-verify` completed successfully;
- `nxb-v1 / native-wpt` was correctly skipped for the pull-request event;
- `nxb-v1 / hosted-contract` reached the repo-owned hosted validation authority.

The hosted authority passed the public-repository guard and then `Test-Repository.ps1` found a pre-existing parser error in `tests/PlatformTransitionSurfaceDiscovery.Tests.ps1`. The fingerprint-contract test encoded embedded PowerShell double quotes with C-style `\"` escaping inside a PowerShell double-quoted string. PowerShell does not use backslash as its quote escape, so the source failed to parse at the expected tab-literal assertions.

The same defective test bytes were already present in the native-certified CLI predecessor `e665e8c27cb085853d23c8804ffaa97a19807eb9`; Phase 7 did not introduce them. Earlier successor authorities parsed only their bounded active surfaces, while the new hosted lane intentionally runs the repository-wide syntax gate and therefore exposed the latent defect.

No new error ID is allocated. This is another **NXB-ERR-029** source-literal/source-contract escaping drift, consistent with the earlier Part 2 source-literal escaping recurrence.

Repair:

- preserve the five intended fingerprint source assertions;
- express the embedded source snippets as valid PowerShell single-quoted literals, doubling embedded single quotes while leaving the literal backtick-tab source text intact;
- do not modify the fingerprint producer or canonical contract;
- rerun the exact repo-wide hosted syntax gate on the successor head.

The failed hosted run did not execute the independent CI validator or the release-candidate aggregate. It does not certify Phase 7.

## NXB-ERR-045 - incomplete hosted Python dependency closure

Class: observed-hosted / repo-wide validator dependency bootstrap.

**Hosted discovery:** pull-request workflow run `31681102775` at exact Phase 7 head:

```text
bd499a6984f54c841c48b1c064d1c8307f6062e6
```

This run proved the inherited ERR-029 parser repair: the hosted lane passed public-repository content validation, repo-wide PowerShell syntax validation, bounded WPR profile contract parsing, and JSON discovery before entering the repository smoke validator chain. `nxb-v1 / signed-release-verify` again completed successfully, and `nxb-v1 / native-wpt` remained correctly skipped for the pull-request event.

The hosted lane then failed when `Test-CollectorOverheadCalibration.ps1` invoked `tools/validate_overhead_calibration.py` and Python reported:

```text
ModuleNotFoundError: No module named 'jsonschema'
```

The workflow had pinned and installed PyYAML for the new CI workflow validator but had not modeled the existing repo-wide schema-validator dependency closure. `py_compile` alone is not an import/dependency authority and could not prove runtime import availability.

No existing NXB error class covers incomplete hosted dependency closure, so **NXB-ERR-045** is allocated.

Repair contract:

- pin the hosted Python dependencies required by the combined existing/new validator surface in `nxb-v1-ci-policy.json`;
- retain PyYAML `6.0.3` and add jsonschema `4.26.0`;
- install both exact versions in the hosted workflow bootstrap;
- execute an explicit hosted import/version preflight before repository smoke validation;
- bind the exact dependency versions into the 17-test CI contract and independent validator;
- discover `NXB_[A-Z0-9_]+_REPOSITORY_ROOT` variables from test source and bind them to the exact checkout root before the full PS7/PS5.1 Pester matrix so successor test roots are inherited deterministically by child PowerShell;
- keep independent validator cardinality `12 requirements + 8 negatives` and CI Pester cardinality `17` unchanged.

The failed run stopped before repo-wide analyzer/Pester execution, independent CI validation, and the release-candidate aggregate. It does not certify Phase 7.

## Third hosted Actions run - existing ERR-021 and ERR-014 reused for repo-wide analyzer findings

**Hosted discovery:** pull-request workflow run `31681838569` at exact Phase 7 head:

```text
a1cf317f32640c1aa17aafe4bb9f72b0c715e55f
```

This run proved the ERR-045 dependency closure: the pinned PyYAML/jsonschema bootstrap and import/version probe passed, the public-repository guard passed, and `Test-Repository.ps1` completed with `Repository validation passed.` The signed-release verification lane completed successfully for a third run, while the self-hosted native WPT lane remained correctly skipped for the pull-request event.

The hosted lane then reached the intended repo-wide PSScriptAnalyzer gate and reported exactly five inherited findings:

```text
Invoke-NxbStorageProfileLocalValidation.ps1:158
PSAvoidAssignmentToAutomaticVariable
$profile assignment

Invoke-NxbSuperblock1SemanticEligibilityCertification.ps1:190
PSAvoidAssignmentToAutomaticVariable
$profile assignment

Invoke-NxbSuperblock2DirectStateTransitionCertification.ps1:155
PSUseDeclaredVarsMoreThanAssignments
$ps7 assigned but not consumed

Invoke-NxbSuperblock2DirectStateTransitionCertification.ps1:156
PSUseDeclaredVarsMoreThanAssignments
$ps51 assigned but not consumed

Invoke-NxbSuperblock2TransitionSurfaceDiscoveryCertification.ps1:202
PSUseDeclaredVarsMoreThanAssignments
$analysisB assigned but not consumed
```

No new error IDs are allocated. The two automatic-variable findings are the existing **NXB-ERR-021** class. A same-class repository code sweep found the two implementation assignments above as the active `$profile =` instances; other search hits are regression/ledger text. The three unused-state findings are the existing **NXB-ERR-014** class.

Repair:

- rename storage validation `$profile` to semantic `$storageProfile` and preserve the emitted `profile` evidence property;
- rename semantic eligibility `$profile` to `$captureProfile` and preserve the exact WPR profile reference behavior;
- consume L4 PS7/PS5.1 Pester summaries in the certification receipt/result instead of hard-coded `20/20` strings;
- execute the second deterministic L3 analysis replay for its output file without retaining an unused `$analysisB` object; byte-identical replay hash validation remains unchanged;
- do not suppress PSScriptAnalyzer rules or narrow the repo-wide analyzer surface.

The failed run did not reach full PS7/PS5.1 Pester execution, independent CI validation, or the release-candidate aggregate. It does not certify Phase 7.

## Current pre-native CI boundary

```text
workflow jobs                 4
hosted check                  nxb-v1 / hosted-contract
signed verification check     nxb-v1 / signed-release-verify
native WPT check              nxb-v1 / native-wpt
aggregate check               nxb-v1 / release-candidate
CI Pester contract            17 tests
independent validator         12 requirements + 8 negatives
hosted Python deps            PyYAML 6.0.3 + jsonschema 4.26.0
native WPT trigger            manual workflow_dispatch only
native runner                 self-hosted Windows X64 nxb-native wpt
workflow permission           contents: read
production private key        forbidden
production release mutation   false
```

These repairs are pre-native hardening only. They do not certify Phase 7. The CI successor remains uncertified until hosted GitHub Actions checks execute successfully on the exact candidate, the trusted self-hosted/native boundary is validated separately, and a Portable Windows CI authority plus independent artifact audit closes the frozen head.
