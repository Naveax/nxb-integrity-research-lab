#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any, Dict, List

CLAIMS = (
    "pnp_lifecycle_semantics",
    "pcie_bdf_semantics",
    "event_id_semantics",
    "event_task_opcode_semantics",
    "power_causality",
    "firmware_causality",
    "root_cause_validated",
    "continuous_trace_completeness",
)


def fail(message: str) -> None:
    raise SystemExit(f"semantic hardening validation failed: {message}")


def load_json(path: Path) -> Dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except Exception as exc:  # noqa: BLE001
        fail(f"cannot read {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"{path} must contain one JSON object")
    return value


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_bool(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        fail(f"{label} must be boolean")
    return value


def require_status(document: Dict[str, Any], label: str) -> None:
    if document.get("schema_version") != 1:
        fail(f"{label}.schema_version must be 1")
    if document.get("status") != "passed":
        fail(f"{label}.status must be passed")


def validate_pnp(document: Dict[str, Any]) -> Dict[str, bool]:
    require_status(document, "pnp")
    repeats = document.get("repeats")
    if not isinstance(repeats, list) or len(repeats) != 2:
        fail("pnp requires exactly two repeats")
    if [item.get("repeat") for item in repeats] != ["A", "B"]:
        fail("pnp repeat ordering must be A/B")
    for item in repeats:
        direct = item.get("direct_state") or {}
        if require_bool(direct.get("create_present_observed"), "pnp.create_present_observed") is not True:
            fail("pnp create/present direct-state control failed")
        if require_bool(direct.get("close_remove_observed"), "pnp.close_remove_observed") is not True:
            fail("pnp close/remove direct-state control failed")
    negative = document.get("negative_controls") or {}
    if negative.get("matched_idle_windows") != 2 or negative.get("fixture_identity_events_in_idle_windows") != 0:
        fail("pnp matched idle controls failed")
    if require_bool(document.get("cleanup_verified"), "pnp.cleanup_verified") is not True:
        fail("pnp cleanup was not verified")
    claims = document.get("claims") or {}
    result = {
        "pnp_lifecycle_semantics": require_bool(claims.get("pnp_lifecycle_semantics"), "pnp claim"),
        "event_id_semantics": require_bool(claims.get("event_id_semantics"), "event id claim"),
        "event_task_opcode_semantics": require_bool(claims.get("event_task_opcode_semantics"), "event task/opcode claim"),
    }
    if not all(result.values()):
        fail("one or more PnP/event claims are not validated")
    mapping = document.get("repeated_event_mapping") or {}
    for key in (
        "common_create_provider_log_id_count",
        "common_remove_provider_log_id_count",
        "common_create_full_shape_count",
        "common_remove_full_shape_count",
    ):
        if not isinstance(mapping.get(key), int) or mapping[key] < 1:
            fail(f"pnp repeated event mapping missing {key}")
    return result


def validate_pcie(document: Dict[str, Any]) -> Dict[str, bool]:
    require_status(document, "pcie")
    if document.get("snapshot_count") != 3:
        fail("pcie requires exactly three snapshots")
    mappings = document.get("stable_mappings")
    if not isinstance(mappings, list) or not mappings:
        fail("pcie has no stable mapping")
    for item in mappings:
        if item.get("repeated_snapshots") != 3:
            fail("pcie mapping was not repeated three times")
        if item.get("address_decode_valid") is not True or item.get("location_path_cross_check_matches") is not True:
            fail("pcie mapping lacks address/location cross-check")
    claim = require_bool((document.get("claims") or {}).get("pcie_bdf_semantics"), "pcie claim")
    if not claim:
        fail("pcie claim is not validated")
    return {"pcie_bdf_semantics": True}


def validate_power_firmware(document: Dict[str, Any]) -> Dict[str, bool]:
    require_status(document, "power_firmware")
    power = document.get("power") or {}
    power_repeats = power.get("repeats")
    if not isinstance(power_repeats, list) or len(power_repeats) != 2:
        fail("power requires two repeats")
    for item in power_repeats:
        required = (
            "idle_control_stable",
            "temporary_scheme_created",
            "temporary_scheme_activated",
            "original_scheme_restored",
            "temporary_scheme_deleted",
            "succeeded",
        )
        if not all(item.get(key) is True for key in required):
            fail("power repeat failed transition or cleanup contract")
    if power.get("cleanup_verified") is not True:
        fail("power cleanup is not verified")

    firmware = document.get("firmware") or {}
    if firmware.get("status") != "passed":
        fail(f"firmware fixture is not passed: {firmware.get('reason')}")
    if firmware.get("generation") != 2 or firmware.get("vm_started") is not False:
        fail("firmware fixture must be an unstarted Generation 2 VM")
    if firmware.get("vhd_attached") is not False or firmware.get("network_switch_attached") is not False:
        fail("firmware fixture must have no disk or network attachment")
    if firmware.get("vm_removed") is not True or firmware.get("host_firmware_changed") is not False:
        fail("firmware cleanup/host boundary failed")
    repeats = firmware.get("repeats")
    if not isinstance(repeats, list) or len(repeats) != 2:
        fail("firmware requires two repeats")
    for item in repeats:
        if item.get("idle_control_stable") is not True or item.get("transition_observed") is not True or item.get("restored") is not True:
            fail("firmware repeat failed transition or restore contract")

    claims = document.get("claims") or {}
    power_claim = require_bool(claims.get("power_causality"), "power claim")
    firmware_claim = require_bool(claims.get("firmware_causality"), "firmware claim")
    if not power_claim or not firmware_claim:
        fail("power/firmware claims are not both validated")
    return {"power_causality": True, "firmware_causality": True}


def validate_root_trace(document: Dict[str, Any]) -> Dict[str, bool]:
    require_status(document, "root_trace")
    controls = document.get("controls") or {}
    if controls.get("scenario_count") != 10:
        fail("root/trace experiment requires ten scenarios")
    if controls.get("replay_byte_identical") is not True:
        fail("root/trace deterministic replay failed")
    if controls.get("three_domain_signature_repeated") is not True:
        fail("root cause requires repeated three-domain signature")
    if controls.get("selective_interventions_passed") is not True:
        fail("root cause selective intervention gate failed")

    trace = document.get("trace") or {}
    if trace.get("logging_contract") != "sequential_file_bounded_v1":
        fail("continuous trace requires sequential bounded file logging")
    if trace.get("events_lost") != 0 or trace.get("buffers_lost") != 0:
        fail("continuous trace native loss counters are nonzero")
    if not isinstance(trace.get("buffers_written"), int) or trace["buffers_written"] < 1:
        fail("continuous trace buffers_written must be positive")
    if trace.get("scenario_continuity_count") != 10 or trace.get("observation_gap_count") != 0:
        fail("continuous trace scenario/gap accounting failed")
    if trace.get("sequential_capacity_reached") is not False:
        fail("continuous trace sequential capacity was reached")

    claims = document.get("claims") or {}
    root_claim = require_bool(claims.get("root_cause_validated"), "root cause claim")
    trace_claim = require_bool(claims.get("continuous_trace_completeness"), "trace completeness claim")
    if not root_claim or not trace_claim:
        fail("root/trace claims are not both validated")
    return {"root_cause_validated": True, "continuous_trace_completeness": True}


def main() -> None:
    parser = argparse.ArgumentParser(description="Independently validate NXB IRL-006 Part 2 semantic experiments.")
    parser.add_argument("--pnp", type=Path, required=True)
    parser.add_argument("--pcie", type=Path, required=True)
    parser.add_argument("--power-firmware", type=Path, required=True)
    parser.add_argument("--root-trace", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    documents = {
        "pnp": args.pnp.resolve(),
        "pcie": args.pcie.resolve(),
        "power_firmware": args.power_firmware.resolve(),
        "root_trace": args.root_trace.resolve(),
    }
    for label, path in documents.items():
        if not path.is_file():
            fail(f"{label} input is missing: {path}")
    if args.output.exists():
        fail(f"output already exists: {args.output}")

    matrix: Dict[str, bool] = {}
    matrix.update(validate_pnp(load_json(documents["pnp"])))
    matrix.update(validate_pcie(load_json(documents["pcie"])))
    matrix.update(validate_power_firmware(load_json(documents["power_firmware"])))
    matrix.update(validate_root_trace(load_json(documents["root_trace"])))

    if set(matrix) != set(CLAIMS):
        fail(f"claim matrix mismatch: observed={sorted(matrix)} expected={sorted(CLAIMS)}")
    validated = [name for name in CLAIMS if matrix[name] is True]
    if len(validated) != 8:
        fail(f"semantic hardening did not reach 8/8: {len(validated)}/8")

    result: Dict[str, Any] = {
        "schema_version": 1,
        "status": "passed",
        "requested": 8,
        "validated": 8,
        "claims": {name: matrix[name] for name in CLAIMS},
        "inputs": {
            label: {"sha256": file_sha256(path), "file_name": path.name}
            for label, path in sorted(documents.items())
        },
        "scope_boundary": "bounded-owned-experiments-only",
        "generalized_system_semantics_claimed": False,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    print("NXB semantic hardening validation passed: requested=8 validated=8")


if __name__ == "__main__":
    main()
