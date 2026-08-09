#!/usr/bin/env python3
import argparse
import hashlib
import json
from collections import Counter, defaultdict
from pathlib import Path


def canonical_json(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def read_events(path: Path):
    events = []
    expected = 0
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            text = line.strip()
            if not text:
                continue
            event = json.loads(text)
            sequence = int(event.get("sequence_index"))
            if sequence != expected:
                raise SystemExit(
                    f"non-contiguous sequence at line {line_number}: expected={expected} actual={sequence}"
                )
            expected += 1
            events.append(event)
    if not events:
        raise SystemExit("normalized event input is empty")
    return events


def named_present_fields(event):
    fields = event.get("fields") or {}
    selected = []
    for name in sorted(fields, key=lambda value: value.casefold()):
        lower = name.casefold()
        if name.startswith("__xperf_opaque_tail_"):
            continue
        if any(token in lower for token in ("swapchain", "presentid", "hwnd")):
            selected.append(name)
    return selected


def shape_signature(event):
    fields = event.get("fields") or {}
    names = sorted(
        name
        for name in fields
        if not name.startswith("__xperf_opaque_tail_")
    )
    payload = canonical_json(names).encode("utf-8")
    return hashlib.sha256(payload).hexdigest(), names


def summarize_scenario(events, scenario):
    fixture = load_json(Path(scenario["fixture_receipt_path"]))
    if fixture.get("status") != "passed":
        raise SystemExit(f"fixture receipt is not passed: {scenario['id']}")
    if fixture.get("mode") != scenario["mode"]:
        raise SystemExit(f"fixture mode mismatch: {scenario['id']}")
    pid = int(fixture.get("pid"))
    target = [event for event in events if event.get("process_id") == pid]

    domain_counts = Counter(str(event.get("domain")) for event in target)
    family_counts = Counter(
        f"{event.get('domain')}:{event.get('event_family')}" for event in target
    )
    event_counts = Counter(str(event.get("source_event_name")) for event in target)

    present_start_name = "Microsoft-Windows-DXGI/Present/win:Start"
    present_stop_name = "Microsoft-Windows-DXGI/Present/win:Stop"
    present_starts = [event for event in target if event.get("source_event_name") == present_start_name]
    present_stops = [event for event in target if event.get("source_event_name") == present_stop_name]

    start_shapes = Counter()
    stop_shapes = Counter()
    shape_names = {}
    for event in present_starts:
        signature, names = shape_signature(event)
        start_shapes[signature] += 1
        shape_names[signature] = names
    for event in present_stops:
        signature, names = shape_signature(event)
        stop_shapes[signature] += 1
        shape_names[signature] = names

    start_named_rows = sum(1 for event in present_starts if named_present_fields(event))
    stop_named_rows = sum(1 for event in present_stops if named_present_fields(event))
    start_named_fields = sorted({name for event in present_starts for name in named_present_fields(event)})
    stop_named_fields = sorted({name for event in present_stops for name in named_present_fields(event)})

    return {
        "id": scenario["id"],
        "mode": scenario["mode"],
        "repeat": scenario["repeat"],
        "pid": pid,
        "fixture": {
            "stimulus_enabled": fixture.get("stimulus_enabled"),
            "gpu": fixture.get("gpu"),
            "network": fixture.get("network"),
            "kernel_stimulus": fixture.get("kernel_stimulus"),
        },
        "target": {
            "row_count": len(target),
            "domain_counts": dict(sorted(domain_counts.items())),
            "family_counts": dict(sorted(family_counts.items())),
            "event_name_counts": dict(sorted(event_counts.items())),
        },
        "present_shape": {
            "start_rows": len(present_starts),
            "stop_rows": len(present_stops),
            "start_rows_with_named_identifier_fields": start_named_rows,
            "stop_rows_with_named_identifier_fields": stop_named_rows,
            "start_named_identifier_field_names": start_named_fields,
            "stop_named_identifier_field_names": stop_named_fields,
            "start_shape_counts": dict(sorted(start_shapes.items())),
            "stop_shape_counts": dict(sorted(stop_shapes.items())),
            "shape_field_names": {key: shape_names[key] for key in sorted(shape_names)},
        },
        "review_policy": {
            "raw_field_values_included": False,
            "field_names_reviewable": True,
            "aggregate_counts_reviewable": True,
        },
    }


def require_scenario_map(scenarios):
    expected = {
        "all_on": {"A", "B"},
        "gpu_off": {"A", "B"},
        "network_off": {"A", "B"},
        "kernel_off": {"A", "B"},
        "minimal": {"A", "B"},
    }
    observed = defaultdict(set)
    for scenario in scenarios:
        observed[scenario["mode"]].add(scenario["repeat"])
    if dict(observed) != expected:
        raise SystemExit(f"scenario matrix mismatch: observed={dict(observed)} expected={expected}")


def mode_rows(summaries, mode):
    return sorted(
        (item for item in summaries if item["mode"] == mode),
        key=lambda item: item["repeat"],
    )


def family_count(item, name):
    return int(item["target"]["family_counts"].get(name, 0))


def event_count(item, name):
    return int(item["target"]["event_name_counts"].get(name, 0))


def stimulus_bool(item, group, key):
    return bool(item["fixture"][group].get(key, False))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--source-head", required=True)
    parser.add_argument("--experiment-id", required=True)
    args = parser.parse_args()

    input_path = Path(args.input).resolve()
    manifest_path = Path(args.manifest).resolve()
    output_path = Path(args.output).resolve()
    if not input_path.is_file() or not manifest_path.is_file():
        raise SystemExit("required input or manifest is missing")
    if output_path.exists():
        raise SystemExit(f"output already exists: {output_path}")

    manifest = load_json(manifest_path)
    scenarios = manifest.get("scenarios") or []
    require_scenario_map(scenarios)
    events = read_events(input_path)
    summaries = [summarize_scenario(events, scenario) for scenario in scenarios]

    present_start = "Microsoft-Windows-DXGI/Present/win:Start"
    present_stop = "Microsoft-Windows-DXGI/Present/win:Stop"

    all_on = mode_rows(summaries, "all_on")
    gpu_off = mode_rows(summaries, "gpu_off")
    network_off = mode_rows(summaries, "network_off")
    kernel_off = mode_rows(summaries, "kernel_off")
    minimal = mode_rows(summaries, "minimal")

    gpu_positive = all(
        stimulus_bool(item, "gpu", "hardware_device_created")
        and int(item["fixture"]["gpu"].get("present_calls_attempted", 0)) == 128
        and int(item["fixture"]["gpu"].get("present_calls_succeeded", 0)) == 128
        and event_count(item, present_start) == 128
        and event_count(item, present_stop) == 128
        for item in all_on + network_off
    )
    gpu_negative = all(
        event_count(item, present_start) == 0 and event_count(item, present_stop) == 0
        for item in gpu_off + minimal
    )

    network_positive = all(
        bool(item["fixture"]["network"].get("dns_lookup_executed"))
        and bool(item["fixture"]["network"].get("loopback_completed"))
        and int(item["fixture"]["network"].get("bytes_sent", 0)) == 65536
        and int(item["fixture"]["network"].get("bytes_received", 0)) == 65536
        and family_count(item, "network:dns") > 0
        and family_count(item, "network:tcp") > 0
        for item in all_on + gpu_off + kernel_off
    )
    network_negative = all(
        family_count(item, "network:dns") == 0 and family_count(item, "network:tcp") == 0
        for item in network_off + minimal
    )

    minimal_gpu_network_absent = all(
        family_count(item, "gpu:dxgi_present") == 0
        and family_count(item, "network:dns") == 0
        and family_count(item, "network:tcp") == 0
        for item in minimal
    )

    enabled_present_rows = all_on + network_off
    present_shape_asymmetry = all(
        int(item["present_shape"]["start_rows_with_named_identifier_fields"]) == 128
        and int(item["present_shape"]["stop_rows_with_named_identifier_fields"]) == 0
        for item in enabled_present_rows
    )
    shared_named_fields = sorted(
        set.intersection(
            *[
                set(item["present_shape"]["start_named_identifier_field_names"])
                & set(item["present_shape"]["stop_named_identifier_field_names"])
                for item in enabled_present_rows
            ]
        ) if enabled_present_rows else set()
    )
    exact_identifier_pairing_eligible = bool(shared_named_fields)

    kernel_differential = []
    for enabled, disabled in zip(all_on, kernel_off):
        kernel_differential.append({
            "repeat": enabled["repeat"],
            "all_on_registry_rows": family_count(enabled, "kernel_lifecycle:registry"),
            "kernel_off_registry_rows": family_count(disabled, "kernel_lifecycle:registry"),
            "all_on_thread_rows": family_count(enabled, "kernel_lifecycle:thread"),
            "kernel_off_thread_rows": family_count(disabled, "kernel_lifecycle:thread"),
        })

    controlled_present_mapping = gpu_positive and gpu_negative and minimal_gpu_network_absent
    controlled_network_mapping = network_positive and network_negative and minimal_gpu_network_absent
    status = "passed" if controlled_present_mapping and controlled_network_mapping else "failed"

    summary = {
        "schema_version": 1,
        "status": status,
        "source": {
            "head_sha": args.source_head.lower(),
            "experiment_id": args.experiment_id,
            "normalized_events_sha256": sha256_file(input_path),
            "normalized_event_rows": len(events),
            "manifest_sha256": sha256_file(manifest_path),
        },
        "scenarios": summaries,
        "differential": {
            "gpu": {
                "positive_control_passed": gpu_positive,
                "negative_control_passed": gpu_negative,
                "controlled_present_count_mapping_validated": controlled_present_mapping,
                "expected_present_calls_per_enabled_fixture": 128,
                "expected_present_start_rows_per_enabled_fixture": 128,
                "expected_present_stop_rows_per_enabled_fixture": 128,
            },
            "network": {
                "positive_control_passed": network_positive,
                "negative_control_passed": network_negative,
                "controlled_network_activity_mapping_validated": controlled_network_mapping,
            },
            "kernel": {
                "explicit_stimulus_differential": kernel_differential,
                "registry_operation_semantics_validated": False,
                "thread_lifecycle_semantics_validated": False,
            },
            "present_pairing_eligibility": {
                "field_shape_asymmetry_reproduced": present_shape_asymmetry,
                "shared_named_identifier_fields": shared_named_fields,
                "exact_named_identifier_pairing_eligible": exact_identifier_pairing_eligible,
                "pid_sequence_pairing_candidate": controlled_present_mapping,
                "pairing_semantics_validated": False,
                "sequence_delta_is_time": False,
            },
        },
        "claims": {
            "controlled_present_count_mapping_validated": controlled_present_mapping,
            "controlled_network_activity_mapping_validated": controlled_network_mapping,
            "present_event_mapping_generalized": False,
            "present_pairing_semantics": False,
            "present_success_semantics": False,
            "tcp_connection_lifecycle_validated": False,
            "network_latency_semantics": False,
            "kernel_lifecycle_semantics": False,
            "registry_operation_semantics": False,
            "timestamp_unit_resolved": False,
            "causal_relationship_validated": False,
            "root_cause_validated": False,
            "trace_completeness": "not_claimed",
        },
        "review_policy": {
            "raw_normalized_rows_reviewable": False,
            "raw_field_values_reviewable": False,
            "fixture_pid_values_reviewable": True,
            "field_names_reviewable": True,
            "aggregate_counts_reviewable": True,
        },
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(canonical_json(summary) + "\n", encoding="utf-8")
    if status != "passed":
        raise SystemExit("semantic control differential acceptance failed")


if __name__ == "__main__":
    main()
