# NXB-IRL-005 — Semantic Hardening Roadmap

## Rule

A target may be requested before it is validated, but it may become `validated=true` only when a bounded, reproducible evidence gate supplies an exact receipt SHA-256 and scope.

## Target gates

### pnp_lifecycle_semantics

Required evidence:

- owned/reversible device fixture or safe virtual/devnode fixture,
- repeated add/start/stop/remove or equivalent lifecycle controls,
- before/during/after direct-state binding,
- repeated event/ETW shape mapping,
- negative controls,
- rollback/cleanup proof.

### pcie_bdf_semantics

Required evidence:

- stable mapping between sanitized device identity and bus/device/function representation,
- independent Windows property sources where available,
- repeated inventory snapshots,
- explicit unavailable handling on platforms that do not expose enough topology metadata.

### event_id_semantics

Required evidence:

- controlled stimulus,
- repeated positive event IDs,
- matched idle controls,
- provider/log binding,
- independently replayed differential analysis.

### event_task_opcode_semantics

Required evidence:

- event-ID mapping gate first,
- repeated task/opcode/level/version shapes,
- negative controls,
- independent validator that rejects unobserved task/opcode labels.

### power_causality

Required evidence:

- direct-state policy transition mapping,
- synchronized event/ETW or state response,
- repeated A/B transition controls,
- matched idle windows,
- restore/delete proof,
- bounded causality wording limited to the owned stimulus.

### firmware_causality

Required evidence:

- no unsafe firmware/security toggling merely to manufacture events,
- use a safe owned or virtualized experiment surface when available,
- before/after firmware/security binding,
- repeated controlled transition with rollback,
- otherwise remain unavailable/pending.

### root_cause_validated

Required evidence:

- anomaly/experiment identity,
- at least three correlated system domains,
- deterministic common timeline,
- candidate root-cause hypothesis,
- controlled intervention that removes/reproduces the symptom,
- repeated replay and independent validation.

### continuous_trace_completeness

Required evidence:

- bounded continuous-session definition,
- loss counters and circular-buffer accounting,
- session-start/session-stop continuity,
- rollover/overwrite detection,
- explicit observation gap accounting,
- only bounded-session completeness may be promoted; indefinite completeness is not implied.

## Adaptive control-plane use

The adaptive panel should prioritize these experiments only when the relevant trigger or operator request is active. Normal operation stays lightweight. Deep/forensic capture is bounded by policy, privacy controls, hold/cooldown, and adapter readiness.

Tracks #17.
