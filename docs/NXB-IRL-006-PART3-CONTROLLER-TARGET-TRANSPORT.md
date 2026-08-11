# NXB IRL-006 Part 3 — Controller/Target Transport

## Objective

Part 3 establishes and certifies the bounded controller/target transport contract required by the NXB production roadmap. The certification scope is intentionally local and synthetic: a controller process and a separately hosted target process communicate over a real TCP loopback channel while authentication, sequencing, queue pressure, local spooling, process interruption, recovery, and emergency-stop behavior are exercised under controlled failure injection.

Part 3 is not a claim that production credential provisioning, remote network trust, or internet transport policy is complete. The certification key in the Part 3 config is a deterministic test key used only to validate the protocol implementation. `production_secret_claimed` remains `false`.

## Required transport properties

The Part 3 authority requires all nine roadmap properties:

1. authenticated channel
2. monotonic sequence
3. duplicate detection
4. packet/event loss detection
5. bounded queue
6. backpressure
7. local spool
8. emergency stop
9. interrupted-transfer recovery

No property is promoted from source inspection alone. The native experiment and independent validator must both pass.

## Protocol

The certification protocol is `newline-json-hmac-sha256-v1` over a TCP listener restricted to `127.0.0.1`.

Each frame binds the following canonical material:

- schema version
- session identifier
- sender role (`controller` or `target`)
- monotonically tracked sequence number
- frame kind
- SHA-256 of the payload JSON
- base64 representation of the payload JSON

The authentication tag is HMAC-SHA256 over this canonical material. Controller requests and target responses are both authenticated. The review evidence contains the deterministic synthetic protocol transcript but does not expose the certification key itself.

## Sequence semantics

Authentication is evaluated before request-sequence classification.

For an authenticated controller request:

- `sequence < next_expected_sequence` is a duplicate and is rejected without advancing the request sequence.
- `sequence > next_expected_sequence` is an observed gap and is rejected without advancing the request sequence.
- only `sequence == next_expected_sequence` is eligible to advance.

Target responses have a separate monotonically increasing response sequence. The independent Python validator recomputes authentication and independently walks both request and response sequence state from the transcript.

## Bounded queue and backpressure

The certification contract uses:

- maximum queue depth: 8 frames
- high watermark: 6 frames
- low watermark: 2 frames

When the high watermark is reached the target returns authenticated backpressure state. The controller stops feeding new pending synthetic events directly and writes the remainder to the bounded local spool. The experiment must finish with zero target queue-overflow events and an observed maximum queue depth no greater than the configured maximum.

## Local spool

The controller spool is a bounded local JSONL file with independent record and byte ceilings. A replay cursor records how many spooled records have been acknowledged.

The native experiment requires:

- at least one pending event is spooled,
- the spool stays inside both budgets,
- every spooled event is replayed after queue drainage,
- the cursor reaches the total record count,
- authenticated replay transcript labels independently account for every spooled event,
- the spool file is removed after successful replay and cleanup is verified.

The spool itself is local working evidence and is not packaged into the final review ZIP.

## Interrupted-transfer recovery

The target persists its checkpoint state atomically through a temporary file followed by replacement of the canonical state file.

After the configured twelfth accepted logical event, the native experiment:

1. closes the controller connection,
2. forcibly terminates the first target PowerShell process,
3. starts a new target process against the same state directory,
4. requires target generation to advance from 1 to 2,
5. compares the recovered request and response sequence checkpoints with the controller's current state,
6. reconnects over a new loopback socket,
7. sends an authenticated `resume` frame,
8. continues replay from the persisted controller spool cursor.

This is a real process interruption, not a simulated boolean restart.

## Emergency stop

After every configured synthetic event has been accepted, the controller sends an authenticated `emergency_stop` frame. The target must arm the stop state and advance that control message normally.

The controller then sends an otherwise valid authenticated event at the next expected sequence. The target must reject it as `emergency_stop_active` without advancing the request sequence. An authenticated `shutdown` frame using that still-current sequence is then allowed to terminate the certification target cleanly.

## Independent validation

`tools/validate_controller_target_transport.py` independently verifies:

- every expected-valid controller request HMAC,
- the deliberately invalid request HMAC,
- every target response HMAC,
- request sequence semantics,
- response sequence continuity,
- accepted event count,
- duplicate and gap controls,
- queue bounds and backpressure,
- spool accounting and authenticated replay labels,
- generation-two restart/resume evidence,
- emergency-stop denial,
- final target counters and shutdown state.

It also requires nine fail-closed evidence mutations. Authentication-specific mutations intentionally retain invalid HMAC. Sequence and emergency-stop semantic mutations are re-signed with the certification key so those negative controls must fail for their intended semantic reason rather than merely failing authentication.

## Inherited authority

Part 3 is not independent from the previous production-roadmap block. The repo-owned Part 3 certifier re-runs:

`scripts/Invoke-NxbSemanticHardeningCertificationV2.ps1`

on the same exact Part 3 Git head and requires inherited Part 2 semantic hardening to return `requested=8 / validated=8` before the transport experiment can be certified.

This also means the Part 2 `NXB-ERR-024` repair is naturally re-tested during the eventual Part 3 native authority run.

## Known-error discipline

Part 3 inherits `NXB-ERR-001` through `NXB-ERR-024`.

The machine signature set extends the applicable generic rules to `scripts/*NxbControllerTarget*.ps1` and `tests/ControllerTarget*.Tests.ps1`. In particular:

- ERR-015 covers literal source assertions in the Part 3 Pester contract.
- ERR-022 covers the Part 3 native stderr-capture helper.
- ERR-024 covers any reintroduction of the invalid `claim_targets.PSObject.Properties` JSON-array projection.

Pre-final review also replaced the state-changing helper name `Start-NxbTransportTargetProcess` with `Invoke-NxbTransportTargetProcessStart` rather than suppressing the PSScriptAnalyzer ShouldProcess rule.

## Review evidence

The final Part 3 review ZIP is deliberately JSON-only and contains exactly:

- `controller-target-transport-experiment.json`
- `controller-target-transport-validation.json`
- `known-error-scan.json`
- `controller-target-transport-certification-receipt.json`

Target state, local spool, spool cursor, ready documents, and other raw-local working artifacts remain outside the review ZIP.

## Repo-owned authority

Top Part 3 gate:

`scripts/Invoke-NxbControllerTargetTransportCertification.ps1`

Target chain:

```text
exact clean head
→ parser + PSScriptAnalyzer + Python syntax
→ exact-tree known-error scan
→ Part 3 PS7 + PS5.1 source contract
→ inherited Part 2 native re-certification on the same exact head
→ real loopback controller/target experiment
→ target process interruption + durable recovery
→ independent 9/9 transport validation
→ independent negative controls 9/9
→ bounded JSON-only review ZIP
→ final exact-tree zero-error scan
```

A Part 3 Git head is not native certified until a real Windows run completes this entire chain.
