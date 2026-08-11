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

Each frame binds schema version, session identifier, sender role, sequence number, frame kind, payload SHA-256, and the base64 payload representation. The authentication tag is HMAC-SHA256 over canonical frame material. Controller requests and target responses are both authenticated. PowerShell verification uses fixed-time byte comparison and preserves `byte[]` cardinality explicitly; the independent Python validator recomputes HMAC separately.

## Sequence and durability semantics

Authentication is evaluated before request-sequence classification.

- `sequence < next_expected_sequence` is a duplicate and is rejected without advancing request state.
- `sequence > next_expected_sequence` is a gap and is rejected without advancing request state.
- only `sequence == next_expected_sequence` is eligible to advance.

Target responses have a separate monotonically increasing sequence. Before an ACK or REJECT becomes visible on the socket, the target advances its response sequence and atomically checkpoints the complete request/queue/counter/stop state. This durable-before-wire ordering makes the process-kill recovery test meaningful.

## Bounded queue, backpressure and spool

The certification contract uses maximum queue depth 8, high watermark 6, and low watermark 2. Reaching the high watermark produces authenticated backpressure. The controller stops feeding pending events directly and writes the remainder to a bounded local JSONL spool with both record and byte ceilings. Every spooled event must later be replayed, its cursor must reach the total count, authenticated transcript labels must independently account for every replay, and the local spool must be deleted after success.

## Interrupted-transfer recovery

After the configured twelfth accepted logical event, the experiment closes the controller connection, forcibly terminates the target PowerShell process, starts generation two against the same state directory, requires exact request/response checkpoint recovery, reconnects, sends an authenticated `resume`, and continues replay from the persisted controller spool cursor.

This is a real process interruption, not a simulated restart flag.

## Emergency stop

After all configured synthetic events are accepted, an authenticated `emergency_stop` is armed. A later otherwise-valid authenticated event at the next expected sequence must be rejected as `emergency_stop_active` without advancing request state. The still-current sequence is then used for authenticated shutdown.

## Independent transport validation

`tools/validate_controller_target_transport.py` independently verifies request/response HMACs, payload hashes, request sequence semantics, response sequence continuity, event accounting, queue/backpressure state, spool replay labels, generation-two recovery, and emergency-stop behavior.

It also requires nine fail-closed evidence mutations. Semantic sequence/emergency-stop mutations are re-signed so rejection must occur for the intended semantic reason rather than because authentication was accidentally broken.

## Inherited Part 2 authority

Part 3 re-runs `scripts/Invoke-NxbSemanticHardeningCertificationV2.ps1` on the same exact Part 3 Git head and requires inherited semantic hardening to return `requested=8 / validated=8` before the transport experiment can be certified.

### Portable V1 native failure

Part 3 Portable V1 was frozen at:

```text
f0e6f66aee676dd703089d2705fe856ab8a1db6b
```

The native Windows run passed the exact-head gate, Part 3 static/source gates, inherited Part 1, and the full IRL-005 V5 chain. It then failed inside inherited Part 2 when the PnP semantic experiment attempted the owned fixture lifecycle.

The failure exposed `NXB-ERR-025`: the host preflight treated `CfgMgr32.dll` file presence as proof that the Software Device lifecycle was executable, but the real `SwDeviceCreate` callback failed with `0x8007007E`. The same transcript also showed the optional `Win32_PnPEntity` CIM surface returning `Not supported`.

### V2 PnP capability repair

V2 replaces that shallow authority with one shared repo-owned native fixture implementation:

- primary backend: Software Device API (`SwDeviceCreate` / `SwDeviceClose`),
- fallback only for the bounded unavailable-surface class: SetupAPI root-enumerated owned synthetic device,
- present-state probe: `CM_Locate_DevNode(..., CM_LOCATE_DEVNODE_NORMAL)`, not CIM,
- preflight must execute create → present → remove → absent before PASS,
- SetupAPI cleanup uses `DiUninstallDevice` with `NeedReboot` captured; any required reboot blocks certification,
- cleanup is bounded and independently checked for absence,
- only sanitized HRESULT material is recorded; localized error text stays outside review evidence,
- create/remove event evidence uses bounded polling rather than a single fixed sleep.

No physical PnP device is selected, disabled, removed, or reconfigured by this fixture.

## Known-error discipline

Part 3 now inherits `NXB-ERR-001` through `NXB-ERR-025`. The active machine-signature set contains 14 statically detectable rules. In addition to the earlier transport protections, ERR-025 rejects both the old file-only Software Device capability assignment and `Get-CimInstance Win32_PnPEntity` in the native semantic PnP path.

The ledger contract remains 12 tests on both PowerShell runtimes; Part 2 semantic-hardening contract remains 12 tests; Part 3 transport contract remains 16 tests. Test-count drift is not used as a substitute for broader assertions.

## Review evidence

The final Part 3 review ZIP remains JSON-only and contains exactly:

- `controller-target-transport-experiment.json`
- `controller-target-transport-validation.json`
- `known-error-scan.json`
- `controller-target-transport-certification-receipt.json`

Raw target state, local spool, cursor, readiness files, Part 2 raw native evidence, and other working artifacts stay outside the Part 3 review ZIP.

## Repo-owned authority

Top gate:

`scripts/Invoke-NxbControllerTargetTransportCertification.ps1`

Authority chain:

```text
exact clean head
→ parser + PSScriptAnalyzer + Python syntax
→ exact-tree known-error scan through ERR-025
→ Part 3 PS7 + PS5.1 16-test source contract
→ inherited Part 2 native re-certification on the same exact head
→ exact PnP lifecycle capability probe and cleanup
→ inherited Part 2 requested=8 / validated=8
→ real loopback controller/target experiment
→ target process interruption + durable recovery
→ independent transport 9/9
→ independent negative controls 9/9
→ bounded JSON-only review ZIP
→ final exact-tree zero-error scan
```

A Part 3 Git head is not native certified until a real Windows run completes this entire chain.
