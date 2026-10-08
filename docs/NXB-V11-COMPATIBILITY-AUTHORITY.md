# NXB V11 Compatibility Authority

> Status: claim-free A0 authority map. This document summarizes frozen Issue #49 contracts and repository schemas. It is not an executable policy override and cannot widen an allowlist, selector, support claim, or mutation permission.

## 1. Canonical predecessor

The V11 authority substrate is rooted in the published post-#26 predecessor:

```text
repository       Naveax/nxb-integrity-research-lab
main SHA         9203ab9f89ff4383832119683eb4e19df5490213
main tree SHA    241d3086e9bcb5a847445258cab25bff4fd34da8
predecessor issue 26
predecessor PR    48
```

A0 is a descendant compatibility-authority seed. It does not reinterpret the predecessor or replace frozen v1 evidence.

## 2. Machine-readable authority tokens

The hosted validator may require these exact source-contract tokens:

```text
A0_ALLOWLIST_VERSION=6
A0_ALLOWLIST_AUTHORITY_COMMENT=5426682541
A0_HOSTED_ARTIFACT_AUTHORITY=nxb-v11-a0-hosted-substrate-v1
A0_SUBSTRATE_RECEIPT_AUTHORITY=nxb-v11-a0-substrate-receipt-v1
PREDECESSOR_REPLAY_AUTHORITY=nxb-v11-predecessor-replay-v1
CENTRAL_TOOLCHAIN_AUTHORITY=nxb-v11-validation-toolchain-lock-v1
COMPATIBILITY_POLICY_AUTHORITY=nxb-v11-compatibility-policy-v1
PHYSICAL_COMPATIBILITY_CLAIMS=0
NATIVE_WPT_DISPATCH_PERFORMED=false
LIVE6_AUTHORITY_HOST=DESKTOP-ONDD84S\umut
LIVE6_DIAGNOSTIC_PROMOTION_COMMENT=6000434321
LIVE6_DIAGNOSTIC_PROMOTION_STATE=ISSUED_UNCONSUMED
LIVE6_DIAGNOSTIC_SHA256=4bf7a001ab7f161151f5b9a4feaf092c46f45acd847a7ff445476c1ccd8a099e
LIVE6_DIAGNOSTIC_RESULT_STATE=ABSENT
LIVE6_RUNTIME_PROMOTION_STATE=ABSENT
A0_REMAINING_MANDATORY_EXACT_PATHS=7
LIVE6_BLOCKER_CHECKPOINT_COMMENT=6053582069
```

These tokens are documentation assertions only. Runtime authority comes from exact source bytes, schemas, Git/GitHub metadata, external digests, and independently reconstructed evidence.

## 3. Claim-free A0 boundary

A0 may provide the trusted generic harness needed by later physical compatibility runs, but A0 itself:

- admits zero physical Windows, PowerShell, Python, WPT/ADK, lifecycle, or endurance support claims;
- performs no native WPT dispatch as part of A0 admission;
- uses no production private key or production signer;
- creates no production tag or Release;
- does not mutate repository protection/rulesets as an admission shortcut;
- cannot use documentation text as a policy override;
- cannot fill unresolved selectors with fake, all-zero, `TBD`, or placeholder hashes.

Physical support begins only after the A0 harness is admitted on default `main` and later selector-preparation/native authority is independently admitted.

## 4. A0 source scope and validation classes

Canonical changed-path authority is allowlist v6, Issue #49 comment `5426682541`. Every actual A0 changed path must resolve to exactly one primary validation class:

```text
workflow_orchestration
executable_powershell
executable_python
pester_test
strict_json_policy_or_schema
locked_dependency_manifest
logical_fixture_spec
authority_documentation
```

Zero classes or incompatible multiple classes fail closed. In particular, scripts hidden under fixture paths are not treated as inert data, and schemas/policies are not regex-scanned as though their literal patterns were executable source.

## 5. Authority and digest DAG

V11 uses one owner per byte class. Self-digests and backward references that create cycles are forbidden.

```text
raw package/runtime bytes
  -> admitted preparation/runtime receipts
  -> child lock documents
  -> external child-lock SHA-256 values
  -> central validation-toolchain lock
  -> external central-lock SHA-256
  -> compatibility policy
  -> external policy SHA-256
  -> review evidence
```

### Child ownership

- `validation/v11/locks/powershell-modules.lock.json` owns PowerShell module package, manifest, source and extracted-tree identities.
- `validation/v11/locks/validator-py312.lock`, `validator-py313.lock`, and `validator-py314.lock` own their Python wheel closures.
- Child locks contain no self digest and do not copy predecessor, preparation-receipt, central-lock, or policy digests.

### Central lock ownership

`config/nxb-v11-validation-toolchain-lock.json` is composition-only. Its schema identity is:

```text
urn:nxb:schema:nxb-v11-validation-toolchain-lock:v1
authority nxb-v11-validation-toolchain-lock-v1
```

It binds distinct external identities for the admitted PowerShell runtime receipt, trusted preparation, module child lock, selected host Python child lock, exact Action set, artifact-tree implementation, verified extraction implementation, and hosted validation runtime composition. It does not duplicate module package rows or Python wheel rows and contains no `validation_toolchain_lock_sha256` field.

### Compatibility policy ownership

`config/nxb-v11-compatibility-policy.json` selects predecessor, central lock and compatibility cells. Its schema identity is:

```text
urn:nxb:schema:nxb-v11-compatibility-policy:v1
authority nxb-v11-compatibility-policy-v1
```

The policy contains neither `policy_sha256` nor `compatibility_policy_sha256`; its complete canonical bytes are externally hashed. Package/wheel inventories remain child-owned.

## 6. Initial exact Action set

Only the frozen external Action set is admitted for initial A0:

```text
actions/checkout        3d3c42e5aac5ba805825da76410c181273ba90b1
actions/setup-python    5fda3b95a4ea91299a34e894583c3862153e4b97
actions/upload-artifact ea165f8d65b6e75b540449e92b4886f43607fa02
action_pin_set_sha256   3bd5b7957b1b599e40c5d7e7d6afebf755d2b4021d62fa316d016b4ff7eccf0b
```

Tags, branch refs, abbreviated SHAs, unlisted external Actions and external `docker://` Actions fail closed. Repo-local actions remain candidate source/tree authority rather than external pin-set entries.

## 7. Hosted/static boundary

Initial A0 hosted authority runs on explicit `windows-2022`. GitHub-hosted Windows Server evidence is static/contract evidence only; matching a Windows client build family does not make it Windows 11 support evidence.

Required hosted repository permissions are read-only:

```text
contents: read
actions: read
pull-requests: read
```

`pull_request_target` is forbidden for candidate execution. Candidate code receives no production signer/native-runner secret or repository-write authority.

## 8. A0 hosted six-entry artifact

The A0 hosted artifact authority is `nxb-v11-a0-hosted-substrate-v1` and contains exactly six flat JSON entries:

```text
compatibility-policy-summary.json
canonicalization-conformance.json
native-impact-classifier-fixtures.json
known-error-scan.json
independent-validation.json
a0-substrate-receipt.json
```

The evidence graph is acyclic:

```text
four primary documents
  -> independent-validation.json
  -> a0-substrate-receipt.json
  -> external outer ZIP digest
```

`independent-validation.json` hashes only the four primary documents and records that the later receipt and outer ZIP hashes are not yet available. The final receipt hashes the four primaries plus `independent-validation.json`. Neither terminal document contains its own digest or the outer ZIP digest.

The physical GitHub artifact name is reconstructed externally as:

```text
nxb-v11-a0-hosted-substrate-v1-{head_sha}-{run_id}-{run_attempt}
```

## 9. Frozen predecessor replay artifact

Predecessor replay is a separate exact seven-entry artifact:

```text
hosted-ci-receipt.json
known-error-scan.json
pester-ps51.xml
pester-ps7.xml
ps51-summary.json
run-ps51.ps1
predecessor-replay-receipt.json
```

The wrapper authority is `nxb-v11-predecessor-replay-v1`. It binds frozen-v1 source semantics to successor-locked acquisition without claiming historical environment byte identity.

The final predecessor partition is:

```text
PS7    916 / 916, not-run 0
PS5.1  909 / 916, exactly 7 PS7Only
```

The deterministic frozen predecessor `run-ps51.ps1` SHA-256 is:

```text
035ac21a439c448be6ad6d946bd3526162f678b1858d09562b69c5616a49397b
```

Artifact name:

```text
nxb-v11-predecessor-replay-v1-{predecessor_main_sha}-{candidate_head_sha}-{run_id}-{run_attempt}
```

## 10. Compatibility policy cells

The current policy schema recognizes the eight stable initial cells. A0 keeps physical cells `provisional-disabled` until their exact selectors are admitted. An enabled cell requires complete PowerShell, Python, module-lock and ADK/WPT selector families.

Selector rules:

- exact versions and byte identities only;
- unresolved values are omitted, never synthesized;
- module lock is referenced by path + external SHA-256;
- Python dependency lock is referenced by the exact selected child path + external SHA-256;
- later selector resolution changes policy bytes and requires fresh authority.

## 11. Execution ordering

The controlling A0 run DAG is Issue #49 comment `5427743490`:

```text
P0 prerequisites
P1 cheap GitHub run/PR guard
P2 exact candidate checkout
P3 freeze source/lock inputs
P4 prove hosted Python cache before setup-python fallback can execute
P5 activate exact validation-host Python
P6 Python B0 bootstrap
P7 exact portable PowerShell + module root
P8 Python B1 full toolchain/schema validation
P9 frozen predecessor replay
P10 current-head A0 producer evidence
P11 source integrity + immutable A0 upload
P12 fresh policy-independent validation job
P13 hosted aggregate
```

A failed phase cannot be bypassed by running later authority-producing phases.

## 12. CI deduplication

Before dispatch/rerun/retry, reconcile repository + workflow + ref + head SHA + normalized inputs. An equivalent queued, waiting, pending, requested, or in-progress run is tracked rather than duplicated. Rerun is never a polling mechanism.

Ordinary A0 pull-request validation may run once for a new exact head through the normal PR event. CI waiting does not block unrelated READY source work.

## 13. Current preparation blocker

The retained live-6 PowerShell runtime / trusted-preparation execution chain remains a separate HOLD until an exact admitted runtime-v2 receipt and successor trusted-preparation evidence exist. Therefore unresolved provenance must not be converted into committed child-lock, central-lock or final policy bytes.

The current physical-console gate is bound to `DESKTOP-ONDD84S\umut`. The exact diagnostic source SHA-256 is `4bf7a001ab7f161151f5b9a4feaf092c46f45acd847a7ff445476c1ccd8a099e`, and single-use promotion `6000434321` remains `ISSUED / UNCONSUMED`. The canonical diagnostic result, live-6 S3/S4 work roots, and runtime promotion remain absent. Current read-only prerequisite reconciliation is clean, but a legitimate elevated physical-console grant has not been admitted. Issue #49 checkpoint `6053582069` records the latest failed grant attempt without consuming the promotion.

Exactly seven mandatory A0 exact paths remain unresolved:

```text
.github/workflows/nxb-v11-compatibility.yml
config/nxb-v11-compatibility-policy.json
config/nxb-v11-validation-toolchain-lock.json
validation/v11/locks/powershell-modules.lock.json
validation/v11/locks/validator-py312.lock
validation/v11/locks/validator-py313.lock
validation/v11/locks/validator-py314.lock
```

They are intentionally ordered by authority rather than convenience: runtime-v2 admission -> fresh trusted-preparation successor -> Pester/module and Python child locks -> central validation-toolchain lock -> claim-free compatibility policy -> final workflow. A missing digest at any lower layer blocks the parent. Planning values, public candidate hashes, placeholders, `TBD`, all-zero hashes, historical receipts, or a different machine are not substitutes.

Schema and synthetic-fixture closure is allowed while this runtime evidence is absent because synthetic values are test data and make no support/admission claim. No SYSTEM, scheduled-task, token-substitution, private-desktop, alternate-host, or CI workaround may be used to turn this HOLD into runtime authority.

## 14. Non-authority rule

This document is explanatory source. If it conflicts with exact schemas, immutable source bytes, Git/GitHub metadata, or controlling Issue #49 freezes, the machine-reconstructed authority wins. Editing this file cannot make a disabled cell enabled, widen A0 scope, authorize a native dispatch, waive a digest mismatch, or permit production mutation.
