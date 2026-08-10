#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import Any

MODES = ["off", "minimal", "normal", "deep", "forensic"]
DOMAINS = [
    "cpu", "memory", "storage", "gpu", "network", "pnp", "pcie", "kernel",
    "registry", "power", "thermal", "firmware", "security", "correlation",
]
REQUIRED_TARGETS = {
    "pnp_lifecycle_semantics",
    "pcie_bdf_semantics",
    "event_id_semantics",
    "event_task_opcode_semantics",
    "power_causality",
    "firmware_causality",
    "root_cause_validated",
    "continuous_trace_completeness",
}
HEX64 = re.compile(r"^[0-9a-f]{64}$")


def fail(message: str) -> None:
    raise SystemExit(f"adaptive policy validation failed: {message}")


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except Exception as exc:  # noqa: BLE001
        fail(f"cannot read {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"{path} must contain one JSON object")
    return value


def canonical_sha256(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def validate_policy(policy: dict[str, Any]) -> str:
    if policy.get("schema_version") != 1:
        fail("schema_version must be 1")
    if policy.get("default_mode") not in MODES or policy.get("maximum_mode") not in MODES:
        fail("default_mode/maximum_mode is invalid")
    if MODES.index(policy["default_mode"]) > MODES.index(policy["maximum_mode"]):
        fail("default_mode exceeds maximum_mode")

    panel = policy.get("panel")
    if not isinstance(panel, dict):
        fail("panel object missing")
    if panel.get("local_only") is not True:
        fail("panel.local_only must be true")
    if panel.get("bind_address") not in {"127.0.0.1", "localhost"}:
        fail("panel bind address must be local")

    privacy = policy.get("privacy")
    if not isinstance(privacy, dict):
        fail("privacy object missing")
    if privacy.get("network_payload") and not privacy.get("payload_fields"):
        fail("network_payload requires payload_fields")

    budgets = policy.get("budgets")
    if not isinstance(budgets, dict):
        fail("budgets object missing")
    for key in (
        "max_disk_mb_per_hour", "max_event_rate_per_second", "max_session_seconds",
        "max_concurrent_domains", "pretrigger_seconds", "posttrigger_seconds",
    ):
        if not isinstance(budgets.get(key), int) or budgets[key] < 0:
            fail(f"budget {key} must be a non-negative integer")

    profiles = policy.get("mode_profiles")
    if not isinstance(profiles, dict) or set(profiles) != set(MODES):
        fail("mode_profiles must contain exactly the five modes")
    for mode in MODES:
        profile = profiles[mode]
        domains = profile.get("domains")
        if not isinstance(domains, list) or len(domains) != len(set(domains)):
            fail(f"{mode} domains must be a unique list")
        if any(domain not in DOMAINS for domain in domains):
            fail(f"{mode} contains an unknown domain")
    if profiles["off"].get("domains") != [] or profiles["off"].get("detail") != "none":
        fail("off profile must collect no domains and use detail=none")

    trigger_ids: set[str] = set()
    for trigger in policy.get("triggers", []):
        trigger_id = trigger.get("id")
        if not isinstance(trigger_id, str) or not trigger_id:
            fail("trigger id missing")
        if trigger_id in trigger_ids:
            fail(f"duplicate trigger id: {trigger_id}")
        trigger_ids.add(trigger_id)
        if trigger.get("minimum_mode") not in MODES:
            fail(f"trigger {trigger_id} has invalid minimum_mode")
        domains = trigger.get("domains")
        if not isinstance(domains, list) or not domains or len(domains) != len(set(domains)):
            fail(f"trigger {trigger_id} domains invalid")
        if any(domain not in DOMAINS for domain in domains):
            fail(f"trigger {trigger_id} contains an unknown domain")

    claims = policy.get("claim_targets")
    if not isinstance(claims, list):
        fail("claim_targets missing")
    names: set[str] = set()
    for claim in claims:
        name = claim.get("name")
        if not isinstance(name, str) or not name:
            fail("claim target name missing")
        if name in names:
            fail(f"duplicate claim target: {name}")
        names.add(name)
        if claim.get("target_requested") is not True:
            fail(f"claim target {name} must keep target_requested=true")
        validated = claim.get("validated")
        if not isinstance(validated, bool):
            fail(f"claim target {name} validated must be boolean")
        receipt = claim.get("evidence_receipt_sha256")
        scope = claim.get("scope")
        if validated:
            if not isinstance(scope, str) or not scope.strip():
                fail(f"validated claim {name} requires non-empty scope")
            if not isinstance(receipt, str) or not HEX64.fullmatch(receipt):
                fail(f"validated claim {name} requires a 64-hex evidence receipt")
        else:
            if receipt is not None:
                fail(f"unvalidated claim {name} must not carry an evidence receipt")

    missing = REQUIRED_TARGETS - names
    if missing:
        fail(f"required semantic targets missing: {sorted(missing)}")

    return canonical_sha256(policy)


def validate_plan(policy: dict[str, Any], plan: dict[str, Any]) -> None:
    if plan.get("schema_version") != 1:
        fail("plan schema_version must be 1")
    mode = plan.get("effective_mode")
    if mode not in MODES:
        fail("plan effective_mode invalid")
    if MODES.index(mode) > MODES.index(policy["maximum_mode"]):
        fail("plan exceeds policy maximum_mode")

    domains = plan.get("active_domains")
    if not isinstance(domains, list) or len(domains) != len(set(domains)):
        fail("plan active_domains must be unique")
    if any(domain not in DOMAINS for domain in domains):
        fail("plan contains an unknown domain")
    if len(domains) > policy["budgets"]["max_concurrent_domains"]:
        fail("plan exceeds max_concurrent_domains")

    budgets = plan.get("budgets")
    if not isinstance(budgets, dict):
        fail("plan budgets missing")
    if budgets.get("max_event_rate_per_second", 0) > policy["budgets"]["max_event_rate_per_second"]:
        fail("plan exceeds global event-rate budget")
    if budgets.get("max_disk_mb_per_hour", 0) > policy["budgets"]["max_disk_mb_per_hour"]:
        fail("plan exceeds global disk budget")

    privacy = plan.get("privacy")
    if not isinstance(privacy, dict):
        fail("plan privacy missing")
    for key in ("raw_identifiers", "formatted_messages", "payload_fields", "network_payload"):
        if privacy.get(key) != policy["privacy"].get(key):
            fail(f"plan privacy drift: {key}")

    claims = plan.get("claims")
    if not isinstance(claims, dict):
        fail("plan claims missing")
    pending = set(claims.get("pending", []))
    validated = set(claims.get("validated", []))
    if pending & validated:
        fail("claim cannot be both pending and validated")

    triggers = ",".join(plan.get("active_trigger_ids", []))
    reasons = ",".join(plan.get("reasons", []))
    material = "\n".join([
        "schema=1",
        f"policy_id={policy['policy_id']}",
        f"mode={mode}",
        f"detail={plan.get('detail')}",
        f"event_rate={budgets.get('max_event_rate_per_second')}",
        f"disk_mb_per_hour={budgets.get('max_disk_mb_per_hour')}",
        f"session_seconds={budgets.get('max_session_seconds')}",
        f"pretrigger_seconds={budgets.get('pretrigger_seconds')}",
        f"posttrigger_seconds={budgets.get('posttrigger_seconds')}",
        f"domains={','.join(domains)}",
        f"triggers={triggers}",
        f"reasons={reasons}",
        f"privacy_raw_identifiers={str(bool(privacy.get('raw_identifiers')))}",
        f"privacy_formatted_messages={str(bool(privacy.get('formatted_messages')))}",
        f"privacy_payload_fields={str(bool(privacy.get('payload_fields')))}",
        f"privacy_network_payload={str(bool(privacy.get('network_payload')))}",
        f"pending_claims={','.join(sorted(pending))}",
        f"validated_claims={','.join(sorted(validated))}",
    ])
    # PowerShell boolean interpolation emits True/False exactly as Python str(bool).
    expected = hashlib.sha256(material.encode("utf-8")).hexdigest()
    if plan.get("plan_fingerprint_sha256") != expected:
        fail(f"plan fingerprint mismatch: expected={expected} actual={plan.get('plan_fingerprint_sha256')}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("policy", type=Path)
    parser.add_argument("--plan", type=Path)
    args = parser.parse_args()

    policy = load_json(args.policy)
    policy_sha = validate_policy(policy)
    if args.plan:
        plan = load_json(args.plan)
        validate_plan(policy, plan)

    print(f"NXB adaptive policy validation passed: policy_sha256={policy_sha}")


if __name__ == "__main__":
    main()
