# NXB-IRL-005 — Control Plane Status

Status: `FOUNDATION IMPLEMENTED / NATIVE V4 NEXT`

Implemented:

- five logging modes,
- bounded global capture budgets,
- privacy clamps,
- trigger priority,
- stateful hold/cooldown/de-escalation,
- localhost-only operator panel,
- bounded manual overrides with TTL,
- per-process mutation token,
- deterministic policy/plan fingerprinting,
- independent Python policy validation,
- repo-owned capture-domain map,
- ready/pending/unavailable adapter manifest,
- independent Python manifest validation,
- semantic target/evidence-receipt discipline.

Native gate target:

```text
PS7:                    48/48
PS5.1:                  48/48
PSScriptAnalyzer:       0
policy validator:       PASS
manifest validator:     PASS
hysteresis:             PASS
anti-CSRF token:        PASS
root-cause manifest:    8 domains, 0 unavailable
semantic targets:       8 requested / 0 prevalidated
```

No generalized semantic target is marked validated by this foundation alone.

Tracks #17.
