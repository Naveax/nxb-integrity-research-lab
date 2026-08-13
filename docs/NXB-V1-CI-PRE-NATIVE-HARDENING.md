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

## Fourth hosted Actions run - existing ERR-029 reused for CI test-cardinality drift

**Hosted discovery:** pull-request workflow run `31682765772` at exact Phase 7 head:

```text
0bcb50fc66b050a4fd79868072c33f040605cf1b
```

The hosted lane passed parser, dependency, repository-smoke, and repo-wide analyzer gates before entering the full Pester surface. The CI contract file contained `18` `It` blocks while its own cardinality assertion and the independent CI validator both required exactly `17`.

No new error ID is allocated. This is an existing **NXB-ERR-029** source/contract cardinality-drift recurrence.

Repair:

- preserve all independent-validator assertions by merging them into the existing repo-owned-component test;
- remove only the redundant standalone `It` wrapper;
- restore the exact 17-test CI contract;
- keep the independent validator at `12 requirements + 8 negatives`;
- pin `actions/upload-artifact` to exact commit `ea165f8d65b6e75b540449e92b4886f43607fa02` and retain hosted Pester diagnostics from the exact candidate run so later failures are independently inspectable.

The repair produced exact head `4695dfbbcf4381fa4b9e2cc77f301867ceea2496`. No Phase 7 certification is claimed by that repair.

## Fifth hosted Actions run - full PS7 contract sweep

**Hosted discovery:** pull-request workflow run `31690055571` at exact Phase 7 head:

```text
4695dfbbcf4381fa4b9e2cc77f301867ceea2496
```

The signed-release verification lane passed and the self-hosted native WPT lane was correctly skipped. The hosted authority reached the full PowerShell 7 Pester surface and produced retained diagnostics before stopping; Windows PowerShell 5.1 Pester was not reached.

Retained hosted diagnostic artifact:

```text
artifact id   9177139118
zip sha256    496982537350497032cab074b0717444ef0c270ecba4c23b74507d12b923a6f3
PS7 total     893
PS7 passed    874
PS7 failed    19
PS7 skipped   0
```

The complete 19-failure sweep classified the failures before repair:

- **NXB-ERR-014 x12:** `Superblock1SemanticFixture.Tests.ps1` stored repository paths as loose discovery-scope variables; the hosted Pester run scope could not consume them. Repair uses a context factory returned and consumed inside every `It`.
- **NXB-ERR-003 x1:** `SemanticHardening.Tests.ps1` built a nested SystemCollector/EventCollector inventory, allowing memory collectors through a projected `Id` match and then dereferencing `MaximumFileSize`. Repair explicitly flattens both collector inventories before filtering file collectors.
- **NXB-ERR-015 x1:** `PlatformTransitionSurfaceDiscovery.Tests.ps1` double-quoted an expected source literal containing `$_`, allowing interpolation. Repair uses a literal-safe assertion.
- **NXB-ERR-029 x4:** stale transition-analysis filenames/message, a brittle raw-artifact source assertion, stale Xperf malformed-size prose, and a stale PageFault-unmapped expectation after `DemandZeroFault` became an explicitly mapped subtype. Repairs bind current stable behavior instead of restoring obsolete implementation text.
- **NXB-ERR-046 x1:** an optional XML `Stack` attribute was dereferenced directly under StrictMode.

No production implementation behavior, WPR capture boundary, normalizer mapping policy, signing authority, or native execution gate is weakened by this sweep.

## NXB-ERR-046 - StrictMode-unsafe optional XML attribute dereference

Class: observed-hosted / XML object-shape handling under PowerShell StrictMode.

The GPU WPR profile contract intentionally permits an EventProvider to omit the optional `Stack` attribute while forbidding `Stack="true"`. The test used:

```powershell
[string]$provider.Stack | Should -Not -Be 'true'
```

Under `Set-StrictMode -Version Latest`, an absent optional XML attribute is not equivalent to a null property: direct member access throws `PropertyNotFoundException`. That turned a valid omitted attribute into a test-runtime failure.

Repair contract:

- keep StrictMode enabled;
- inspect optional XML members through `PSObject.Properties['Stack']` before reading a value;
- if the optional member exists, require its value not to enable provider-wide stacks;
- if the optional member is absent, treat absence according to the existing profile contract rather than manufacturing a required attribute;
- keep required XML attributes fail-closed;
- sweep the active test surface for the same raw optional-member dereference shape before the next hosted authority run.

The fifth hosted run is not a Phase 7 certification. A new exact successor head must pass the entire hosted PS7 and Windows PowerShell 5.1 Pester matrix, independent CI validation, signed-release verification, and later the separately gated trusted native/Portable authority before any certified pointer may move.

## NXB-ERR-045 recurrence - co-installed Pester assembly contamination

Class: observed-native / dependency-runtime assembly contamination.

Portable V1.3 on the frozen pre-native candidate `bc741eec6faf010cf31305f3ed7a014b1b6ae2d9` passed exact-head, external parser/analyzer/known-error, independent `12/12 + 8/8`, and certification-safe signed-release verification before the local replay of the repo-owned hosted authority failed at the PowerShell 7 Pester import.

A dedicated three-mode load probe preserved the co-installed local module set and proved the sequence exactly:

```text
fresh                         no Pester assembly loaded
after PSScriptAnalyzer import no Pester assembly loaded
after repository smoke        no Pester assembly loaded
after repo-wide analyzer      Pester 6.0.1.0 loaded
Pester 5.7.1 import           FileLoadException
```

The loaded assembly was the co-installed user module:

```text
Documents\PowerShell\Modules\Pester\6.0.1\bin\net8.0\Pester.dll
```

Both `Import-Module <Pester-5.7.1> -Force` and the same import without `-Force` failed because the PowerShell process already contained a different `Pester` assembly simple name. The GitHub-hosted lane had passed because its clean runner bootstrap installs only exact Pester `5.7.1`; the trusted/native boundary cannot assume that a long-lived self-hosted machine has no other Pester version installed.

This is an NXB-ERR-045 dependency-closure recurrence rather than a new class. The missing closure was runtime assembly isolation, not package availability.

Repair contract:

- keep exact Pester `5.7.1` and PSScriptAnalyzer `1.25.0`;
- do not require operators to uninstall unrelated co-installed Pester versions;
- execute repo-wide PSScriptAnalyzer in a fresh `pwsh -NoProfile` child process;
- pass the exact PSScriptAnalyzer module manifest path and repo-owned settings path into the child;
- serialize child analyzer status/findings through a bounded JSON result and fail closed on missing/malformed/nonzero output;
- require the hosted authority main process to be free of any loaded `Pester` assembly both immediately before and immediately after the isolated analyzer step;
- import exact Pester `5.7.1` only after the isolated analyzer child has exited;
- regression-lock the isolation in the existing 17-test CI contract and existing independent `12 + 8` validator without changing their cardinalities;
- preserve all known-error scanner counts, PS7/PS5.1 runtime partition counts, production safety booleans, and native review cardinality.

The old frozen head is not native-certified by the failed Portable run. A successor exact head must rerun hosted closure and then trusted native/Portable certification.
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
