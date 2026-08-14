# NXB v1 CI hosted closure

Phase 7 successor branch: `release/nxb-v1.0.0-ci`.

Native-certified predecessor:

```text
certified/nxb-v1-cli
e665e8c27cb085853d23c8804ffaa97a19807eb9
```

This document records the hosted-safe GitHub Actions closure reached before trusted native/Portable certification. It does not certify Phase 7, move a certified pointer, merge a branch, create a tag, sign a production release, or authorize a production update.

## Sixth hosted discovery - Windows PowerShell 5.1 runtime partition

The predecessor hosted repair head was:

```text
b7397c693072bba0c5b8bdfc6cc5167764912789
```

Pull-request workflow run:

```text
31695887036
```

Retained diagnostics:

```text
artifact id       9179471293
artifact digest   sha256:26172625cc18dc862204bff0a732ece78bb64f004de83c9634f99394f959b139
PS7 total         893
PS7 passed        893
PS7 failed        0
PS7 skipped       0
PS5.1 total       893
PS5.1 passed      887
PS5.1 failed      6
PS5.1 skipped     0
```

The PowerShell 7 surface was completely green. All six visible failures occurred only under Windows PowerShell 5.1 because the affected tests invoked authorities that explicitly require PowerShell 7:

- all six tests in `MemoryDownstreamReplay.Tests.ps1` exercise `Invoke-NxbMemoryDownstreamReplay.ps1`;
- the measured workload test in `MemoryOverheadCalibration.Tests.ps1` exercises `Invoke-NxbMeasuredMemoryWorkload.ps1`.

The visible six failures were not the full defect. One negative test in the memory downstream replay contract used generic `Should -Throw` for source adapter provenance drift. Under Windows PowerShell 5.1, the authority's PowerShell-7 runtime guard threw before the intended provenance boundary and the generic negative assertion therefore passed for the wrong reason.

That made the unpartitioned matrix capable of a false PASS in a runtime-incompatible negative test.

## NXB-ERR-047 - runtime-incompatible negative test can false-pass

Class: observed-hosted / cross-runtime test-partition fail-open.

Failure shape:

1. a test invokes an authority with a stricter runtime requirement than the test runner;
2. the authority fails at its runtime guard before reaching the behavior the test intends to validate;
3. a broad or generic negative assertion accepts that unrelated exception;
4. the test is reported as passed even though the intended negative boundary was never exercised.

This is distinct from a normal runtime incompatibility. The security/correctness problem is the false-positive test result produced by an unrelated early exception.

Repair contract:

- preserve the complete PowerShell 7 test surface and require `FailedCount = 0`, `SkippedCount = 0`, and `NotRunCount = 0`;
- tag only the seven runtime-incompatible `It` blocks with the explicit `PS7Only` tag;
- fail closed unless the source inventory contains exactly seven `PS7Only` tests;
- run Windows PowerShell 5.1 with Pester `Filter.ExcludeTag = PS7Only`;
- require Windows PowerShell 5.1 discovery cardinality to remain equal to the PowerShell 7 total;
- require exactly seven Windows PowerShell 5.1 `NotRun` tests, zero failures, and zero skips;
- require Windows PowerShell 5.1 passed count to equal total minus the exact seven excluded tests;
- bind the exact runtime-partition contract into the 17-test CI contract;
- independently recompute the `PS7Only` source cardinality in `tools/validate_v1_ci.py`;
- record PS7/PS5.1 pass, total, NotRun, excluded tag, and expected-excluded cardinality in the hosted receipt;
- do not weaken or remove the PowerShell 7 runtime guards from the underlying authorities.

The repair prevents a generic `Should -Throw` from manufacturing a Windows PowerShell 5.1 pass for a behavior that can only be reached under PowerShell 7.

## Exact hosted-safe closure

The repaired exact hosted head was:

```text
ecbe25ffddfc2d6cee848918f88915cfbe960ca6
```

Pull-request workflow run:

```text
31696826464
```

Hosted artifact:

```text
artifact id       9179863085
artifact name     nxb-v1-hosted-validation-ecbe25ffddfc2d6cee848918f88915cfbe960ca6
artifact digest   sha256:c76b8a4fadf92d84dd59cde3db37b5e5e8f2634432d09cd56f573f76fd932445
```

The exact run closed the GitHub-hosted boundary as follows:

```text
nxb-v1 / hosted-contract          PASS
nxb-v1 / signed-release-verify    PASS
nxb-v1 / native-wpt               SKIPPED (required for pull_request)
nxb-v1 / release-candidate        PASS
independent CI workflow validator PASS
```

The retained hosted receipt binds:

```text
status                         passed
authority                      nxb-v1-ci-hosted-v1
head_sha                       ecbe25ffddfc2d6cee848918f88915cfbe960ca6
Pester                         5.7.1
PSScriptAnalyzer               1.25.0
Python                         3.12.10
PyYAML                         6.0.3
jsonschema                     4.26.0
repository-root variables      18
PSScriptAnalyzer findings      0
Python files compiled          35
PS7 passed / total / NotRun    893 / 893 / 0
PS5.1 passed / total / NotRun  886 / 893 / 7
PS5.1 excluded tag             PS7Only
PS5.1 expected excluded        7
public repository guard        true
repository smoke               true
production release updated     false
```

The retained Pester XML independently contains zero PS7 failures/skips and zero PS5.1 failures/skips. The Windows PowerShell 5.1 exclusion is structural and exact, not a generic skip-on-error escape hatch.

## Hosted boundary after closure

The hosted-safe Phase 7 boundary now proves:

- exact candidate checkout on GitHub-hosted `windows-2022`;
- read-only top-level repository permission;
- exact-SHA pinned external Actions;
- pinned hosted dependency versions;
- public-repository and repository-smoke validation;
- repo-wide PSScriptAnalyzer with zero findings;
- Python syntax compilation across the hosted tool surface;
- full PowerShell 7 Pester with no skipped or excluded tests;
- exact Windows PowerShell 5.1-compatible Pester partition with no failures or skips;
- independent workflow/policy validation;
- certification-safe signed-release verification with no production signer claim and no production release mutation;
- native WPT execution remaining unavailable to pull-request events.

## Remaining Phase 7 boundary

Hosted closure alone is not Phase 7 certification.

Before any certified pointer may move, the exact successor head still requires the separately gated trusted native/Portable authority, including the self-hosted Windows WPT boundary, exact-head evidence, retained receipt/review artifacts, and independent artifact replay/audit. The pull request must remain draft and unmerged until that closure is complete.
