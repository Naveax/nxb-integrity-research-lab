# NXB-IRL-006 Part 1 — Semantic Evidence Authority

## Purpose

Part 1 establishes the authority boundary that every semantic-hardening claim must cross before `validated=true` is permitted.

The eight inherited claim targets are:

1. `pnp_lifecycle_semantics`
2. `pcie_bdf_semantics`
3. `event_id_semantics`
4. `event_task_opcode_semantics`
5. `power_causality`
6. `firmware_causality`
7. `root_cause_validated`
8. `continuous_trace_completeness`

This part does **not** prevalidate any of those claims. It defines and certifies the receipt/evidence contract used by the following semantic experiments.

## Frozen predecessor

NXB-IRL-005 native-certified authority:

```text
9eed0c356a881da098dbb3ab7638481465d6140d
```

The certified predecessor is preserved separately from IRL-006 development. IRL-006 starts from the merge that contains that exact certified commit in its ancestry.

## Receipt boundary

A semantic receipt contains exact bindings for:

- repository identity,
- exact Git head,
- adaptive policy SHA-256,
- machine identity SHA-256,
- bounded capture scope,
- capture source kind,
- bounded session duration,
- evidence artifact count,
- artifact-index SHA-256,
- negative-control result,
- cleanup verification,
- independent-validation result,
- validator identity/version/implementation SHA-256,
- explicit limitations,
- canonical semantic fingerprint.

The exact serialized receipt is additionally bound by its file SHA-256 when a claim is promoted in the adaptive policy.

## Promotion rule

`status=validated` is promotable only when all of the following are true:

- the receipt repository matches the expected repository exactly,
- the receipt exact head matches the expected authority exactly,
- the policy SHA-256 matches the expected policy exactly,
- the machine binding matches when a machine is required,
- capture start/end form a positive bounded interval,
- the observed interval does not exceed `bounded_session_seconds`,
- at least one evidence artifact exists,
- negative controls passed,
- cleanup was verified,
- independent validation passed,
- the canonical receipt fingerprint recomputes exactly.

A structurally valid `failed` or `unavailable` receipt may be retained as evidence, but it is never promotable.

## Canonical fingerprint

The canonical fingerprint deliberately excludes timestamp string rendering. Timestamps are still parsed and bounded, while the serialized receipt file SHA-256 binds their exact bytes.

This separation avoids cross-runtime fingerprint drift from PowerShell JSON DateTime materialization while retaining tamper evidence for the complete receipt.

Canonical material is a fixed-order LF-separated record containing:

```text
schema
receipt_id
claim_name
status
repository
exact_head
policy_sha256
machine_id_sha256
scope_sha256
source_kind
bounded_session_seconds
artifact_count
artifact_index_sha256
negative_controls_passed
cleanup_verified
independent_validation_passed
validator_name
validator_version
validator_implementation_sha256
limitations_sha256
```

No locale-sensitive diagnostic text participates in canonical material.

## Independent validation

Two validators implement the same contract independently:

- `scripts/Test-NxbSemanticEvidenceReceipt.ps1`
- `tools/validate_semantic_evidence_receipt.py`

The PowerShell implementation is required to work under PowerShell 7 and Windows PowerShell 5.1. The Python implementation is the independent reference validator and does not depend on PowerShell parsing behavior.

## Adversarial contract

`tests/SemanticEvidenceAuthority.Tests.ps1` contains 18 tests covering:

- repo-owned authority components,
- schema claim/status lock,
- valid PowerShell validation,
- independent Python parity,
- unexpected property rejection,
- cross-head/stale receipt rejection,
- policy mismatch rejection,
- optional machine-binding rejection,
- unknown claim rejection,
- zero-artifact promotion rejection,
- negative-control requirement,
- cleanup requirement,
- independent-validation requirement,
- reversed capture interval rejection,
- duration-bound rejection,
- fingerprint tamper rejection,
- failed receipt non-promotion,
- unavailable receipt non-promotion.

## Certification order

`scripts/Invoke-NxbSemanticEvidenceAuthorityCertification.ps1` executes:

1. exact-head and clean-worktree verification,
2. PowerShell parser + PSScriptAnalyzer + JSON/Python syntax preflight,
3. inherited exact-tree known-error scan,
4. PowerShell 7 semantic contract `18/18`,
5. Windows PowerShell 5.1 semantic contract `18/18`,
6. independent Python fixture validation,
7. inherited IRL-005 V5 certification on the same exact Part 1 head,
8. bounded JSON-only review evidence and final receipt.

Part 1 is complete only when the native authority proves all of the above at one exact head.

## Handoff to Part 2

Part 2 consumes this authority to execute the eight real semantic evidence gates. No claim is promoted merely because its experiment code exists. Promotion requires a receipt that passes this Part 1 authority and whose exact file SHA-256 is bound into the claim target.
