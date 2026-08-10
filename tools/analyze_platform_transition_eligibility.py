#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

EXPECTED_SCENARIOS = [
    "idle_pnp_a",
    "pnp_rescan_a",
    "idle_pnp_b",
    "pnp_rescan_b",
    "idle_power_a",
    "power_transition_a",
    "idle_power_b",
    "power_transition_b",
]
FORBIDDEN_KEYS = {
    "message",
    "xml",
    "payload",
    "properties",
    "event_data",
    "user_data",
    "raw_event",
    "raw_message",
    "raw_xml",
}


class ValidationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def sha256_json(value: Any) -> str:
    return hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    require(isinstance(value, dict), "root must be object")
    return value


def walk(value: Any, path: str = "$"):
    yield path, value
    if isinstance(value, dict):
        for key, child in value.items():
            yield from walk(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from walk(child, f"{path}[{index}]")


def validate_no_raw_content(value: dict[str, Any]) -> None:
    for path, node in walk(value):
        if isinstance(node, dict):
            for key in node:
                require(key.lower() not in FORBIDDEN_KEYS, f"forbidden raw event field: {path}.{key}")


def shape_key(provider: str, log_name: str, shape: dict[str, Any]) -> tuple[Any, ...]:
    return (
        provider,
        log_name,
        int(shape["id"]),
        int(shape["version"]),
        str(shape["level"]),
        str(shape["task"]),
        str(shape["opcode"]),
    )


def scenario_counts(scenario: dict[str, Any]) -> dict[tuple[Any, ...], int]:
    counts: dict[tuple[Any, ...], int] = {}
    for observation in scenario["observations"]:
        if observation["status"] != "available":
            continue
        provider = observation["provider_name"]
        log_name = observation["log_name"]
        for shape in observation["shapes"]:
            key = shape_key(provider, log_name, shape)
            counts[key] = counts.get(key, 0) + int(shape["count"])
    return counts


def key_to_record(key: tuple[Any, ...], delta_a: int, delta_b: int) -> dict[str, Any]:
    provider, log_name, event_id, version, level, task, opcode = key
    return {
        "provider_name": provider,
        "log_name": log_name,
        "id": event_id,
        "version": version,
        "level": level,
        "task": task,
        "opcode": opcode,
        "delta_a": delta_a,
        "delta_b": delta_b,
    }


def positive_delta(stimulus: dict[tuple[Any, ...], int], idle: dict[tuple[Any, ...], int]) -> dict[tuple[Any, ...], int]:
    result: dict[tuple[Any, ...], int] = {}
    for key in sorted(set(stimulus) | set(idle)):
        delta = stimulus.get(key, 0) - idle.get(key, 0)
        if delta > 0:
            result[key] = delta
    return result


def analyze_pair(scenarios: dict[str, dict[str, Any]], family: str) -> dict[str, Any]:
    if family == "pnp":
        idle_a, stim_a = "idle_pnp_a", "pnp_rescan_a"
        idle_b, stim_b = "idle_pnp_b", "pnp_rescan_b"
    elif family == "power":
        idle_a, stim_a = "idle_power_a", "power_transition_a"
        idle_b, stim_b = "idle_power_b", "power_transition_b"
    else:
        raise AssertionError(family)

    idle_a_counts = scenario_counts(scenarios[idle_a])
    stim_a_counts = scenario_counts(scenarios[stim_a])
    idle_b_counts = scenario_counts(scenarios[idle_b])
    stim_b_counts = scenario_counts(scenarios[stim_b])
    delta_a = positive_delta(stim_a_counts, idle_a_counts)
    delta_b = positive_delta(stim_b_counts, idle_b_counts)
    repeated = sorted(set(delta_a) & set(delta_b))
    candidates = [key_to_record(key, delta_a[key], delta_b[key]) for key in repeated]
    return {
        "family": family,
        "idle_a_sampled_events": sum(idle_a_counts.values()),
        "stimulus_a_sampled_events": sum(stim_a_counts.values()),
        "idle_b_sampled_events": sum(idle_b_counts.values()),
        "stimulus_b_sampled_events": sum(stim_b_counts.values()),
        "positive_delta_shape_count_a": len(delta_a),
        "positive_delta_shape_count_b": len(delta_b),
        "repeated_positive_delta_shape_count": len(candidates),
        "mapping_eligible": bool(candidates),
        "repeated_candidates": candidates,
    }


def validate_observations(value: dict[str, Any]) -> dict[str, Any]:
    require(value.get("schema_version") == 1, "schema_version must be 1")
    require(isinstance(value.get("binding_fingerprint_sha256"), str), "binding fingerprint missing")
    require(isinstance(value.get("provider_metadata_fingerprint_sha256"), str), "metadata fingerprint missing")
    contract = value.get("observation_contract")
    require(isinstance(contract, dict), "observation_contract missing")
    require(contract.get("scenario_count") == 8, "scenario_count must be 8")
    require(contract.get("pnp_stimulus") == "pnputil_scan_devices", "PnP stimulus contract mismatch")
    require(contract.get("power_stimulus") == "temporary_duplicate_activate_restore_delete", "power stimulus contract mismatch")
    require(contract.get("raw_event_message_exposed") is False, "raw message boundary violated")
    require(contract.get("raw_event_xml_exposed") is False, "raw XML boundary violated")
    require(contract.get("raw_event_payload_exposed") is False, "raw payload boundary violated")
    require(contract.get("device_disable_used") is False, "device disable boundary violated")
    require(contract.get("firmware_security_mutation_used") is False, "firmware/security boundary violated")
    require(contract.get("wpr_used") is False, "WPR boundary violated")

    scenario_list = value.get("scenarios")
    require(isinstance(scenario_list, list), "scenarios must be array")
    require([item.get("scenario_id") for item in scenario_list] == EXPECTED_SCENARIOS, "scenario order/set mismatch")
    scenarios = {item["scenario_id"]: item for item in scenario_list}

    for scenario_id, scenario in scenarios.items():
        require(scenario.get("repeat") in {"A", "B"}, f"{scenario_id}.repeat invalid")
        require(isinstance(scenario.get("start_utc"), str) and scenario["start_utc"], f"{scenario_id}.start_utc missing")
        require(isinstance(scenario.get("end_utc"), str) and scenario["end_utc"], f"{scenario_id}.end_utc missing")
        stimulus = scenario.get("stimulus")
        require(isinstance(stimulus, dict), f"{scenario_id}.stimulus missing")
        require(stimulus.get("executed") is True and stimulus.get("succeeded") is True, f"{scenario_id} stimulus did not succeed")
        if scenario["scenario_type"] == "pnp_rescan":
            require(stimulus.get("exit_code") == 0, f"{scenario_id} PnP exit code nonzero")
            require(stimulus.get("device_disable_used") is False, f"{scenario_id} device disable used")
            require(stimulus.get("device_remove_used") is False, f"{scenario_id} device remove used")
            require(stimulus.get("device_install_used") is False, f"{scenario_id} device install used")
        elif scenario["scenario_type"] == "power_transition":
            for key in ("temporary_scheme_created", "temporary_scheme_activated", "original_scheme_restored", "temporary_scheme_deleted"):
                require(stimulus.get(key) is True, f"{scenario_id}.{key} not true")
            for key in ("firmware_state_changed", "secure_boot_changed", "tpm_state_changed", "device_guard_changed"):
                require(stimulus.get(key) is False, f"{scenario_id}.{key} must be false")
        elif scenario["scenario_type"] != "idle":
            raise ValidationError(f"{scenario_id}.scenario_type invalid")

        observations = scenario.get("observations")
        require(isinstance(observations, list) and observations, f"{scenario_id}.observations empty")
        require(scenario.get("surface_count") == len(observations), f"{scenario_id}.surface_count mismatch")
        for obs_index, observation in enumerate(observations):
            path = f"{scenario_id}.observations[{obs_index}]"
            require(observation.get("status") in {"available", "unavailable"}, f"{path}.status invalid")
            require(isinstance(observation.get("provider_name"), str) and observation["provider_name"], f"{path}.provider missing")
            require(isinstance(observation.get("log_name"), str) and observation["log_name"], f"{path}.log missing")
            shapes = observation.get("shapes")
            require(isinstance(shapes, list), f"{path}.shapes invalid")
            if observation["status"] == "available":
                count = observation.get("sampled_event_count")
                require(isinstance(count, int) and count >= 0, f"{path}.sampled_event_count invalid")
                require(sum(int(shape["count"]) for shape in shapes) == count, f"{path}.shape counts mismatch")
                require(observation.get("reason") is None, f"{path}.reason must be null")
            else:
                require(observation.get("sampled_event_count") is None, f"{path}.unavailable count must be null")
                require(shapes == [], f"{path}.unavailable shapes must be empty")
                require(observation.get("reason") == "bounded_query_failed", f"{path}.reason invalid")

    claims = value.get("claims")
    require(isinstance(claims, dict), "claims missing")
    require(claims.get("controlled_stimuli_executed") is True, "controlled stimulus claim missing")
    require(claims.get("matched_idle_controls_captured") is True, "idle control claim missing")
    for key in ("event_id_semantics", "event_task_opcode_semantics", "device_lifecycle_semantics", "power_causality", "firmware_causality", "root_cause_validated"):
        require(claims.get(key) is False, f"claim unexpectedly promoted: {key}")
    require(claims.get("continuous_trace_completeness") == "not_claimed", "trace completeness promoted")
    validate_no_raw_content(value)

    pnp = analyze_pair(scenarios, "pnp")
    power = analyze_pair(scenarios, "power")
    summary = {
        "status": "passed",
        "observation_sha256": sha256_json(value),
        "binding_fingerprint_sha256": value["binding_fingerprint_sha256"],
        "provider_metadata_fingerprint_sha256": value["provider_metadata_fingerprint_sha256"],
        "scenario_count": 8,
        "pnp": pnp,
        "power": power,
        "claims": {
            "controlled_transition_observation_validated": True,
            "pnp_mapping_eligible": pnp["mapping_eligible"],
            "power_mapping_eligible": power["mapping_eligible"],
            "event_id_semantics": False,
            "event_task_opcode_semantics": False,
            "device_lifecycle_semantics": False,
            "power_causality": False,
            "firmware_causality": False,
            "root_cause_validated": False,
            "continuous_trace_completeness": "not_claimed",
        },
    }
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description="Analyze NXB SUPERBLOCK 2 controlled transition eligibility")
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        summary = validate_observations(load_json(args.input))
    except (ValidationError, ValueError, TypeError, KeyError, json.JSONDecodeError) as exc:
        print(f"NXB controlled transition analysis failed: {exc}")
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        "NXB controlled transition analysis passed: "
        f"pnp_candidates={summary['pnp']['repeated_positive_delta_shape_count']} "
        f"power_candidates={summary['power']['repeated_positive_delta_shape_count']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
