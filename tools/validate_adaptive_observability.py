#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import pathlib
import sys
from typing import Any

LEVELS = ("off", "baseline", "focused", "forensic")
EXPECTED_RANKS = {"off": 0, "baseline": 1, "focused": 2, "forensic": 3}


def load_json(path: pathlib.Path) -> Any:
    with path.open("r", encoding="utf-8-sig") as handle:
        return json.load(handle)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def validate_policy(policy: dict[str, Any]) -> None:
    require(policy.get("schema_version") == 1, "policy schema_version must be 1")
    levels = policy.get("levels")
    require(isinstance(levels, dict), "policy levels must be an object")
    require(set(levels) == set(LEVELS), "policy levels must be exactly off/baseline/focused/forensic")
    for name, rank in EXPECTED_RANKS.items():
        item = levels[name]
        require(item.get("rank") == rank, f"level {name} rank must be {rank}")
        require(isinstance(item.get("raw_payload_allowed"), bool), f"level {name} raw_payload_allowed must be boolean")
    require(levels["off"]["raw_payload_allowed"] is False, "off cannot allow raw payload")
    require(levels["baseline"]["raw_payload_allowed"] is False, "baseline cannot allow raw payload")
    require(levels["focused"]["raw_payload_allowed"] is False, "focused cannot allow raw payload")

    retention = policy.get("retention")
    require(isinstance(retention, dict), "retention must be an object")
    require(retention.get("raw_payload_default") is False, "raw_payload_default must remain false")
    require(retention.get("hash_raw_identifiers") is True, "hash_raw_identifiers must remain true")
    require(retention.get("redact_messages_by_default") is True, "redact_messages_by_default must remain true")
    always_keep = retention.get("always_keep")
    require(isinstance(always_keep, list) and always_keep, "always_keep must be a non-empty list")
    for required in ("control_plane_transition", "capture_receipt", "hash_manifest", "loss_accounting", "claim_evidence"):
        require(required in always_keep, f"always_keep missing {required}")

    budgets = policy.get("budgets")
    require(isinstance(budgets, dict), "budgets must be an object")
    require(1 <= int(budgets.get("max_concurrent_elevated_domains", 0)) <= 16, "invalid elevated-domain budget")
    require(1 <= int(budgets.get("max_capture_seconds", 0)) <= 86400, "invalid capture-duration budget")
    require(int(budgets.get("max_review_bytes", 0)) >= 1024, "review byte budget too small")

    domains = policy.get("domains")
    require(isinstance(domains, dict) and domains, "domains must be a non-empty object")
    for domain_name, domain in domains.items():
        minimum = domain.get("minimum_level")
        maximum = domain.get("maximum_level")
        require(minimum in LEVELS, f"{domain_name} minimum_level invalid")
        require(maximum in LEVELS, f"{domain_name} maximum_level invalid")
        require(EXPECTED_RANKS[minimum] <= EXPECTED_RANKS[maximum], f"{domain_name} minimum_level exceeds maximum_level")
        require(isinstance(domain.get("enabled"), bool), f"{domain_name} enabled must be boolean")

    rules = policy.get("rules")
    require(isinstance(rules, list), "rules must be an array")
    seen_rule_ids: set[str] = set()
    for rule in rules:
        rule_id = rule.get("rule_id")
        require(isinstance(rule_id, str) and rule_id, "rule_id must be non-empty")
        require(rule_id not in seen_rule_ids, f"duplicate rule_id {rule_id}")
        seen_rule_ids.add(rule_id)
        require(rule.get("level") in LEVELS, f"rule {rule_id} has invalid level")
        target_domains = rule.get("domains")
        require(isinstance(target_domains, list) and target_domains, f"rule {rule_id} domains must be non-empty")
        require(len(target_domains) == len(set(target_domains)), f"rule {rule_id} domains must be unique")
        for domain_name in target_domains:
            require(domain_name in domains, f"rule {rule_id} targets unknown domain {domain_name}")
        require(int(rule.get("ttl_seconds", 0)) > 0, f"rule {rule_id} ttl_seconds must be positive")


def validate_claim_targets(document: dict[str, Any], policy: dict[str, Any]) -> None:
    require(document.get("schema_version") == 1, "claim target schema_version must be 1")
    claims = document.get("claims")
    require(isinstance(claims, list) and claims, "claims must be a non-empty array")
    domain_names = set(policy["domains"])
    seen: set[str] = set()
    for claim in claims:
        claim_id = claim.get("claim_id")
        require(isinstance(claim_id, str) and claim_id, "claim_id must be non-empty")
        require(claim_id not in seen, f"duplicate claim_id {claim_id}")
        seen.add(claim_id)
        require(claim.get("desired_state") is True, f"{claim_id} desired_state must be true")
        require(claim.get("current_state") is False, f"{claim_id} cannot be promoted before evidence gate")
        evidence = claim.get("required_evidence")
        require(isinstance(evidence, list) and len(evidence) >= 3, f"{claim_id} requires at least three evidence gates")
        adaptive_domains = claim.get("adaptive_domains")
        require(isinstance(adaptive_domains, list) and adaptive_domains, f"{claim_id} adaptive_domains missing")
        for domain_name in adaptive_domains:
            require(domain_name in domain_names, f"{claim_id} references unknown domain {domain_name}")
        if claim_id == "firmware_causality":
            require(claim.get("scope") == "isolated_reboot_capable_fixture_only", "firmware_causality must remain isolated/reboot-only")
            require(claim.get("risk_class") == "high_risk_reboot_state_changing", "firmware_causality risk class must remain high")
        if claim_id == "continuous_trace_completeness":
            require(claim.get("scope") == "declared_observation_interval", "continuous completeness must be interval-scoped")


def validate_plan(plan: dict[str, Any], policy: dict[str, Any]) -> None:
    require(plan.get("schema_version") == 1, "plan schema_version must be 1")
    require(plan.get("policy_id") == policy.get("policy_id"), "plan policy_id mismatch")
    require(plan.get("capture_strategy") == "policy_driven_adaptive", "plan capture strategy mismatch")
    domains = plan.get("domains")
    require(isinstance(domains, dict), "plan domains must be an object")
    require(set(domains) == set(policy["domains"]), "plan domain set mismatch")
    elevated_count = 0
    for domain_name, domain in domains.items():
        level = domain.get("level")
        require(level in LEVELS, f"plan {domain_name} level invalid")
        require(domain.get("rank") == EXPECTED_RANKS[level], f"plan {domain_name} rank mismatch")
        if EXPECTED_RANKS[level] >= EXPECTED_RANKS["focused"]:
            elevated_count += 1
        if level != "forensic":
            require(domain.get("raw_payload_allowed") is False, f"plan {domain_name} raw payload allowed outside forensic")
    maximum = int(policy["budgets"]["max_concurrent_elevated_domains"])
    require(elevated_count <= maximum, "plan exceeds max_concurrent_elevated_domains")


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate NXB adaptive observability policy, claim targets, and optional plan.")
    parser.add_argument("--policy", required=True, type=pathlib.Path)
    parser.add_argument("--claims", required=True, type=pathlib.Path)
    parser.add_argument("--plan", type=pathlib.Path)
    args = parser.parse_args()

    try:
        policy = load_json(args.policy)
        claims = load_json(args.claims)
        validate_policy(policy)
        validate_claim_targets(claims, policy)
        if args.plan is not None:
            validate_plan(load_json(args.plan), policy)
    except (OSError, json.JSONDecodeError, ValueError, TypeError) as exc:
        print(f"NXB adaptive observability validation failed: {exc}", file=sys.stderr)
        return 1

    suffix = " + plan" if args.plan is not None else ""
    print(f"NXB adaptive observability validation passed: domains={len(policy['domains'])} rules={len(policy['rules'])} claims={len(claims['claims'])}{suffix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
