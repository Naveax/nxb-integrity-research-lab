#!/usr/bin/env python3
from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, Set

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


def event_id_key(item: Dict[str, Any]) -> str:
    return f"{item.get('provider_name')}|{item.get('log_name')}|{int(item.get('id', -1))}"


def event_shape_key(item: Dict[str, Any]) -> str:
    return "|".join(
        str(value)
        for value in (
            item.get("provider_name"), item.get("log_name"), int(item.get("id", -1)),
            int(item.get("version", -1)), int(item.get("level", -1)),
            int(item.get("task", -1)), int(item.get("opcode", -1)),
        )
    )


def shape_set(items: Any, key_function: Callable[[Dict[str, Any]], str], label: str) -> Set[str]:
    if not isinstance(items, list):
        fail(f"{label} must be an array")
    result: Set[str] = set()
    for item in items:
        if not isinstance(item, dict):
            fail(f"{label} contains a non-object")
        if item.get("fixture_identity_matched") is not True:
            fail(f"{label} contains an event not bound to the fixture identity")
        result.add(key_function(item))
    return result


def require_declared_set(mapping: Dict[str, Any], key: str, expected: Iterable[str]) -> None:
    value = mapping.get(key)
    if not isinstance(value, list):
        fail(f"pnp repeated mapping {key} must be an array")
    observed = {str(item) for item in value}
    expected_set = set(expected)
    if observed != expected_set:
        fail(f"pnp repeated mapping {key} does not match independently recomputed intersection")


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
        idle = item.get("idle_event_shapes")
        if not isinstance(idle, list) or len(idle) != 0:
            fail("pnp matched idle window contains fixture-identity events")

    create_id_a = shape_set(repeats[0].get("create_event_shapes"), event_id_key, "pnp create A")
    create_id_b = shape_set(repeats[1].get("create_event_shapes"), event_id_key, "pnp create B")
    remove_id_a = shape_set(repeats[0].get("remove_event_shapes"), event_id_key, "pnp remove A")
    remove_id_b = shape_set(repeats[1].get("remove_event_shapes"), event_id_key, "pnp remove B")
    create_shape_a = shape_set(repeats[0].get("create_event_shapes"), event_shape_key, "pnp create-shape A")
    create_shape_b = shape_set(repeats[1].get("create_event_shapes"), event_shape_key, "pnp create-shape B")
    remove_shape_a = shape_set(repeats[0].get("remove_event_shapes"), event_shape_key, "pnp remove-shape A")
    remove_shape_b = shape_set(repeats[1].get("remove_event_shapes"), event_shape_key, "pnp remove-shape B")

    common_create_id = create_id_a & create_id_b
    common_remove_id = remove_id_a & remove_id_b
    common_create_shape = create_shape_a & create_shape_b
    common_remove_shape = remove_shape_a & remove_shape_b
    if not common_create_id or not common_remove_id or not common_create_shape or not common_remove_shape:
        fail("pnp/event independent A/B intersections are empty")

    negative = document.get("negative_controls") or {}
    if negative.get("matched_idle_windows") != 2 or negative.get("fixture_identity_events_in_idle_windows") != 0:
        fail("pnp matched idle controls failed")
    if negative.get("passed") is not True:
        fail("pnp negative controls are not passed")
    if require_bool(document.get("cleanup_verified"), "pnp.cleanup_verified") is not True:
        fail("pnp cleanup was not verified")

    mapping = document.get("repeated_event_mapping")
    if not isinstance(mapping, dict):
        fail("pnp repeated event mapping is missing")
    expected_counts = {
        "common_create_provider_log_id_count": len(common_create_id),
        "common_remove_provider_log_id_count": len(common_remove_id),
        "common_create_full_shape_count": len(common_create_shape),
        "common_remove_full_shape_count": len(common_remove_shape),
    }
    for key, expected_count in expected_counts.items():
        if mapping.get(key) != expected_count:
            fail(f"pnp {key} does not match independent recomputation")
    require_declared_set(mapping, "common_create_provider_log_ids", common_create_id)
    require_declared_set(mapping, "common_remove_provider_log_ids", common_remove_id)
    require_declared_set(mapping, "common_create_full_shapes", common_create_shape)
    require_declared_set(mapping, "common_remove_full_shapes", common_remove_shape)

    claims = document.get("claims") or {}
    result = {
        "pnp_lifecycle_semantics": require_bool(claims.get("pnp_lifecycle_semantics"), "pnp claim"),
        "event_id_semantics": require_bool(claims.get("event_id_semantics"), "event id claim"),
        "event_task_opcode_semantics": require_bool(claims.get("event_task_opcode_semantics"), "event task/opcode claim"),
    }
    if not all(result.values()):
        fail("one or more PnP/event claims are not validated")
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
        bus = item.get("bus")
        device = item.get("device")
        function = item.get("function")
        if not isinstance(bus, int) or not 0 <= bus <= 255:
            fail("pcie stable mapping bus is invalid")
        if not isinstance(device, int) or not 0 <= device <= 31:
            fail("pcie stable mapping device is invalid")
        if not isinstance(function, int) or not 0 <= function <= 7:
            fail("pcie stable mapping function is invalid")
        expected_bdf = f"{bus:02x}:{device:02x}.{function:x}"
        if item.get("bdf") != expected_bdf:
            fail("pcie BDF string does not match independently formatted bus/device/function")

    negative = document.get("negative_controls")
    if not isinstance(negative, dict):
        fail("pcie negative control object is missing")
    expected_count = len(mappings)
    if negative.get("synthetic_mismatched_tuple_count") != expected_count:
        fail("pcie negative-control count does not match stable mappings")
    if negative.get("rejected_count") != expected_count or negative.get("passed") is not True:
        fail("pcie mismatched tuple negative controls did not all reject")
    controls = negative.get("controls")
    if not isinstance(controls, list) or len(controls) != expected_count:
        fail("pcie negative-control detail count mismatch")
    if any(item.get("mismatch_rejected") is not True for item in controls):
        fail("pcie contains an accepted deliberately wrong tuple")

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


def expect_rejection(validator: Callable[[Dict[str, Any]], Dict[str, bool]], document: Dict[str, Any], label: str) -> bool:
    try:
        validator(document)
    except SystemExit:
        return True
    fail(f"negative control was accepted: {label}")
    return False


def validate_fail_closed_controls(documents: Dict[str, Dict[str, Any]]) -> Dict[str, bool]:
    result: Dict[str, bool] = {}

    pnp_lifecycle = copy.deepcopy(documents["pnp"])
    pnp_lifecycle["repeats"][0]["direct_state"]["create_present_observed"] = False
    result["pnp_lifecycle_semantics"] = expect_rejection(validate_pnp, pnp_lifecycle, "pnp direct-state mutation")

    event_id = copy.deepcopy(documents["pnp"])
    event_id["repeated_event_mapping"]["common_create_provider_log_id_count"] = 0
    result["event_id_semantics"] = expect_rejection(validate_pnp, event_id, "event-id mapping mutation")

    event_shape = copy.deepcopy(documents["pnp"])
    event_shape["repeated_event_mapping"]["common_create_full_shape_count"] = 0
    result["event_task_opcode_semantics"] = expect_rejection(validate_pnp, event_shape, "event-shape mapping mutation")

    pcie = copy.deepcopy(documents["pcie"])
    pcie["negative_controls"]["passed"] = False
    result["pcie_bdf_semantics"] = expect_rejection(validate_pcie, pcie, "pcie mismatch-control mutation")

    power = copy.deepcopy(documents["power_firmware"])
    power["power"]["repeats"][0]["original_scheme_restored"] = False
    result["power_causality"] = expect_rejection(validate_power_firmware, power, "power restore mutation")

    firmware = copy.deepcopy(documents["power_firmware"])
    firmware["firmware"]["host_firmware_changed"] = True
    result["firmware_causality"] = expect_rejection(validate_power_firmware, firmware, "firmware host-boundary mutation")

    root_cause = copy.deepcopy(documents["root_trace"])
    root_cause["controls"]["selective_interventions_passed"] = False
    result["root_cause_validated"] = expect_rejection(validate_root_trace, root_cause, "root-cause intervention mutation")

    trace = copy.deepcopy(documents["root_trace"])
    trace["trace"]["events_lost"] = 1
    result["continuous_trace_completeness"] = expect_rejection(validate_root_trace, trace, "trace-loss mutation")

    if set(result) != set(CLAIMS) or not all(result.values()):
        fail("independent fail-closed negative-control matrix did not reach 8/8")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description="Independently validate NXB IRL-006 Part 2 semantic experiments.")
    parser.add_argument("--pnp", type=Path, required=True)
    parser.add_argument("--pcie", type=Path, required=True)
    parser.add_argument("--power-firmware", type=Path, required=True)
    parser.add_argument("--root-trace", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    paths = {
        "pnp": args.pnp.resolve(),
        "pcie": args.pcie.resolve(),
        "power_firmware": args.power_firmware.resolve(),
        "root_trace": args.root_trace.resolve(),
    }
    for label, path in paths.items():
        if not path.is_file():
            fail(f"{label} input is missing: {path}")
    if args.output.exists():
        fail(f"output already exists: {args.output}")

    documents = {label: load_json(path) for label, path in paths.items()}
    matrix: Dict[str, bool] = {}
    matrix.update(validate_pnp(documents["pnp"]))
    matrix.update(validate_pcie(documents["pcie"]))
    matrix.update(validate_power_firmware(documents["power_firmware"]))
    matrix.update(validate_root_trace(documents["root_trace"]))

    if set(matrix) != set(CLAIMS):
        fail(f"claim matrix mismatch: observed={sorted(matrix)} expected={sorted(CLAIMS)}")
    validated = [name for name in CLAIMS if matrix[name] is True]
    if len(validated) != 8:
        fail(f"semantic hardening did not reach 8/8: {len(validated)}/8")

    negative_controls = validate_fail_closed_controls(documents)
    result: Dict[str, Any] = {
        "schema_version": 1,
        "status": "passed",
        "requested": 8,
        "validated": 8,
        "claims": {name: matrix[name] for name in CLAIMS},
        "negative_control_rejections": {name: negative_controls[name] for name in CLAIMS},
        "negative_controls_validated": 8,
        "inputs": {
            label: {"sha256": file_sha256(path), "file_name": path.name}
            for label, path in sorted(paths.items())
        },
        "scope_boundary": "bounded-owned-experiments-only",
        "generalized_system_semantics_claimed": False,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    print("NXB semantic hardening validation passed: requested=8 validated=8 negative_controls=8/8")


if __name__ == "__main__":
    main()
