#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

DETAIL_WITH_DEEP = {"semantic", "payload"}
VALID_AVAILABILITY = {"ready", "pending", "unavailable"}


def fail(message: str) -> None:
    raise SystemExit(f"adaptive capture manifest validation failed: {message}")


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except Exception as exc:  # noqa: BLE001
        fail(f"cannot read {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"{path} must contain one JSON object")
    return value


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate(
    repo_root: Path,
    plan: dict[str, Any],
    domain_map: dict[str, Any],
    manifest: dict[str, Any],
) -> dict[str, Any]:
    if domain_map.get("schema_version") != 1:
        fail("domain map schema_version must be 1")
    if manifest.get("schema_version") != 1:
        fail("manifest schema_version must be 1")

    mappings = domain_map.get("domains")
    if not isinstance(mappings, list):
        fail("domain map domains must be a list")
    by_name: dict[str, dict[str, Any]] = {}
    for mapping in mappings:
        if not isinstance(mapping, dict):
            fail("domain map entry must be an object")
        name = mapping.get("name")
        if not isinstance(name, str) or not name:
            fail("domain map entry name missing")
        if name in by_name:
            fail(f"duplicate domain map entry: {name}")
        by_name[name] = mapping

    active_domains = plan.get("active_domains")
    if not isinstance(active_domains, list) or any(not isinstance(x, str) for x in active_domains):
        fail("plan active_domains invalid")
    if len(active_domains) != len(set(active_domains)):
        fail("plan active_domains must be unique")
    detail = plan.get("detail")
    if not isinstance(detail, str):
        fail("plan detail missing")

    capture = manifest.get("capture")
    if not isinstance(capture, dict):
        fail("manifest capture object missing")
    entries = capture.get("domains")
    if not isinstance(entries, list):
        fail("manifest capture.domains must be a list")
    entry_names = [entry.get("domain") for entry in entries if isinstance(entry, dict)]
    if entry_names != active_domains:
        fail(f"manifest domain order mismatch: expected={active_domains} actual={entry_names}")

    if manifest.get("policy_id") != plan.get("policy_id"):
        fail("manifest policy_id mismatch")
    if manifest.get("plan_fingerprint_sha256") != plan.get("plan_fingerprint_sha256"):
        fail("manifest plan fingerprint binding mismatch")
    if manifest.get("effective_mode") != plan.get("effective_mode"):
        fail("manifest effective_mode mismatch")
    if manifest.get("detail") != detail:
        fail("manifest detail mismatch")

    ready = pending = unavailable = 0
    for domain, entry in zip(active_domains, entries, strict=True):
        if domain not in by_name:
            fail(f"active domain missing from map: {domain}")
        mapping = by_name[domain]
        if not isinstance(entry, dict):
            fail(f"manifest entry for {domain} must be an object")

        expected_assets = list(mapping.get("base_assets") or [])
        if detail in DETAIL_WITH_DEEP:
            for asset in mapping.get("deep_assets") or []:
                if asset not in expected_assets:
                    expected_assets.append(asset)

        actual_assets = entry.get("assets")
        if not isinstance(actual_assets, list):
            fail(f"manifest assets missing for {domain}")
        actual_paths = [asset.get("path") for asset in actual_assets if isinstance(asset, dict)]
        if actual_paths != expected_assets:
            fail(f"asset selection mismatch for {domain}: expected={expected_assets} actual={actual_paths}")

        missing = 0
        for relative, asset_state in zip(expected_assets, actual_assets, strict=True):
            full = repo_root / Path(relative)
            exists = full.is_file()
            if bool(asset_state.get("repo_owned")) != exists:
                fail(f"repo_owned mismatch for {domain}:{relative}")
            if not exists:
                missing += 1

        adapter_kind = mapping.get("adapter_kind")
        if adapter_kind == "pending_semantic_adapter":
            expected_availability = "pending"
            expected_reason = "semantic_adapter_not_yet_certified"
        elif missing:
            expected_availability = "unavailable"
            expected_reason = "repo_asset_missing"
        else:
            expected_availability = "ready"
            expected_reason = "repo_assets_present"

        availability = entry.get("availability")
        if availability not in VALID_AVAILABILITY:
            fail(f"invalid availability for {domain}: {availability}")
        if availability != expected_availability:
            fail(f"availability mismatch for {domain}: expected={expected_availability} actual={availability}")
        if entry.get("reason") != expected_reason:
            fail(f"reason mismatch for {domain}")
        if entry.get("adapter_kind") != adapter_kind:
            fail(f"adapter_kind mismatch for {domain}")
        if entry.get("runtime_surface") != mapping.get("runtime_surface"):
            fail(f"runtime_surface mismatch for {domain}")
        if entry.get("requested_detail") != detail:
            fail(f"requested_detail mismatch for {domain}")

        if availability == "ready":
            ready += 1
        elif availability == "pending":
            pending += 1
        else:
            unavailable += 1

    if capture.get("domain_count") != len(entries):
        fail("domain_count mismatch")
    if capture.get("ready_count") != ready:
        fail("ready_count mismatch")
    if capture.get("pending_count") != pending:
        fail("pending_count mismatch")
    if capture.get("unavailable_count") != unavailable:
        fail("unavailable_count mismatch")

    return {
        "schema_version": 1,
        "status": "passed",
        "plan_fingerprint_sha256": plan.get("plan_fingerprint_sha256"),
        "domain_count": len(entries),
        "ready_count": ready,
        "pending_count": pending,
        "unavailable_count": unavailable,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--domain-map", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    plan = load_json(args.plan)
    domain_map = load_json(args.domain_map)
    manifest = load_json(args.manifest)
    receipt = validate(repo_root, plan, domain_map, manifest)
    receipt["manifest_sha256"] = file_sha256(args.manifest)
    receipt["domain_map_sha256"] = file_sha256(args.domain_map)

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(
        "NXB adaptive capture manifest validation passed: "
        f"domains={receipt['domain_count']} ready={receipt['ready_count']} "
        f"pending={receipt['pending_count']} unavailable={receipt['unavailable_count']}"
    )


if __name__ == "__main__":
    main()
