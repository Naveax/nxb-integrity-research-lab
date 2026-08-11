#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any, Dict


def fail(message: str) -> None:
    raise SystemExit(f"semantic root/trace evidence validation failed: {message}")


def load_json(path: Path) -> Dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except Exception as exc:  # noqa: BLE001
        fail(f"cannot read {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"{path} must contain one JSON object")
    return value


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def metric(stats: Dict[str, Any], name: str) -> int:
    value = stats.get(name)
    if not isinstance(value, dict) or "value" not in value:
        fail(f"trace statistics missing {name}.value")
    try:
        return int(value["value"])
    except (TypeError, ValueError) as exc:
        fail(f"trace statistic {name}.value is invalid: {exc}")


def scenario_key(item: Dict[str, Any]) -> str:
    return f"{item.get('mode')}:{item.get('repeat')}"


def main() -> None:
    parser = argparse.ArgumentParser(description="Deep independent audit of NXB Part 2 root-cause and trace evidence.")
    parser.add_argument("--experiment", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--summary-replay", type=Path, required=True)
    parser.add_argument("--coverage", type=Path, required=True)
    parser.add_argument("--coverage-replay", type=Path, required=True)
    parser.add_argument("--events", type=Path, required=True)
    parser.add_argument("--events-replay", type=Path, required=True)
    parser.add_argument("--trace-statistics", type=Path, required=True)
    parser.add_argument("--etl", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    inputs = {
        "experiment": args.experiment.resolve(),
        "summary": args.summary.resolve(),
        "summary_replay": args.summary_replay.resolve(),
        "coverage": args.coverage.resolve(),
        "coverage_replay": args.coverage_replay.resolve(),
        "events": args.events.resolve(),
        "events_replay": args.events_replay.resolve(),
        "trace_statistics": args.trace_statistics.resolve(),
        "etl": args.etl.resolve(),
    }
    for label, path in inputs.items():
        if not path.is_file():
            fail(f"missing {label}: {path}")
    if args.output.exists():
        fail(f"output already exists: {args.output}")

    experiment = load_json(inputs["experiment"])
    summary = load_json(inputs["summary"])
    stats = load_json(inputs["trace_statistics"])
    if experiment.get("status") != "passed":
        fail("root-trace experiment status is not passed")
    if summary.get("status") != "passed":
        fail("semantic-control summary status is not passed")

    hashes = {label: sha256_file(path) for label, path in inputs.items()}
    if hashes["summary"] != hashes["summary_replay"]:
        fail("summary replay is not byte-identical")
    if hashes["coverage"] != hashes["coverage_replay"]:
        fail("coverage replay is not byte-identical")
    if hashes["events"] != hashes["events_replay"]:
        fail("normalized-event replay is not byte-identical")

    evidence = experiment.get("evidence") or {}
    if evidence.get("summary_sha256") != hashes["summary"]:
        fail("experiment summary SHA does not match the actual summary")
    if evidence.get("coverage_sha256") != hashes["coverage"]:
        fail("experiment coverage SHA does not match the actual coverage")
    if evidence.get("etl_sha256") != hashes["etl"]:
        fail("experiment ETL SHA does not match the actual ETL")

    scenarios = summary.get("scenarios")
    if not isinstance(scenarios, list) or len(scenarios) != 10:
        fail("semantic summary must contain exactly ten scenarios")
    expected_keys = {
        "all_on:A", "all_on:B", "gpu_off:A", "gpu_off:B",
        "network_off:A", "network_off:B", "kernel_off:A", "kernel_off:B",
        "minimal:A", "minimal:B",
    }
    observed_keys = {scenario_key(item) for item in scenarios}
    if observed_keys != expected_keys:
        fail(f"scenario matrix mismatch: observed={sorted(observed_keys)}")
    if any(int((item.get("target") or {}).get("row_count", 0)) <= 0 for item in scenarios):
        fail("one or more scenarios have zero target rows")

    all_on = sorted((item for item in scenarios if item.get("mode") == "all_on"), key=lambda item: item.get("repeat"))
    if len(all_on) != 2:
        fail("root-cause audit requires exactly two all_on repeats")
    all_on_domain_counts: Dict[str, Dict[str, int]] = {}
    for item in all_on:
        repeat = str(item.get("repeat"))
        counts = (item.get("target") or {}).get("domain_counts") or {}
        selected = {name: int(counts.get(name, 0)) for name in ("gpu", "network", "kernel_lifecycle")}
        if any(value <= 0 for value in selected.values()):
            fail(f"all_on repeat {repeat} does not contain the three-domain signature")
        all_on_domain_counts[repeat] = selected

    differential = summary.get("differential") or {}
    gpu = differential.get("gpu") or {}
    network = differential.get("network") or {}
    kernel = differential.get("kernel") or {}
    if gpu.get("controlled_present_count_mapping_validated") is not True:
        fail("GPU controlled-present intervention did not validate")
    if network.get("controlled_network_activity_mapping_validated") is not True:
        fail("network controlled-activity intervention did not validate")
    kernel_rows = kernel.get("explicit_stimulus_differential")
    if not isinstance(kernel_rows, list) or len(kernel_rows) != 2:
        fail("kernel intervention requires two repeated differential rows")
    kernel_result = []
    for row in kernel_rows:
        registry_reduced = int(row.get("all_on_registry_rows", 0)) > int(row.get("kernel_off_registry_rows", 0))
        thread_reduced = int(row.get("all_on_thread_rows", 0)) > int(row.get("kernel_off_thread_rows", 0))
        if not (registry_reduced or thread_reduced):
            fail(f"kernel intervention failed for repeat {row.get('repeat')}")
        kernel_result.append({
            "repeat": row.get("repeat"),
            "registry_reduced": registry_reduced,
            "thread_reduced": thread_reduced,
        })

    events_lost = metric(stats, "events_lost")
    buffers_lost = metric(stats, "buffers_lost")
    buffers_written = metric(stats, "buffers_written")
    if events_lost != 0 or buffers_lost != 0 or buffers_written < 1:
        fail(f"native trace-loss gate failed: events={events_lost} buffers={buffers_lost} written={buffers_written}")

    trace = experiment.get("trace") or {}
    if trace.get("logging_contract") != "sequential_file_bounded_v1":
        fail("experiment is not bound to the sequential file logging contract")
    if trace.get("maximum_file_size_mib") != 512:
        fail("unexpected sequential capacity")
    etl_size = inputs["etl"].stat().st_size
    if etl_size >= 512 * 1024 * 1024:
        fail(f"ETL reached/exceeded the conservative 512 MiB capacity boundary: {etl_size}")
    if int(trace.get("etl_length_bytes", -1)) != etl_size:
        fail("experiment ETL length does not match the actual ETL")
    if trace.get("sequential_capacity_reached") is not False:
        fail("experiment reports sequential capacity reached")
    if int(trace.get("events_lost", -1)) != events_lost:
        fail("experiment EventsLost does not match independent trace statistics")
    if int(trace.get("buffers_lost", -1)) != buffers_lost:
        fail("experiment BuffersLost does not match independent trace statistics")
    if int(trace.get("buffers_written", -1)) != buffers_written:
        fail("experiment BuffersWritten does not match independent trace statistics")
    if trace.get("scenario_continuity_count") != 10 or trace.get("observation_gap_count") != 0:
        fail("experiment continuity/gap accounting failed")
    if trace.get("normalized_replay_byte_identical") is not True:
        fail("experiment reports non-identical normalized replay")

    claims = experiment.get("claims") or {}
    if claims.get("root_cause_validated") is not True or claims.get("continuous_trace_completeness") is not True:
        fail("experiment did not promote both bounded root/trace claims")
    if claims.get("generalized_root_cause_claimed") is not False:
        fail("experiment overclaims generalized root cause")
    if claims.get("unbounded_trace_completeness_claimed") is not False:
        fail("experiment overclaims unbounded trace completeness")

    result = {
        "schema_version": 1,
        "status": "passed",
        "root_cause_validated": True,
        "continuous_trace_completeness": True,
        "scenario_count": 10,
        "all_on_domain_counts": all_on_domain_counts,
        "kernel_interventions": kernel_result,
        "events_lost": events_lost,
        "buffers_lost": buffers_lost,
        "buffers_written": buffers_written,
        "etl_length_bytes": etl_size,
        "replay_byte_identical": True,
        "inputs": {label: {"file_name": path.name, "sha256": hashes[label]} for label, path in sorted(inputs.items())},
        "scope_boundary": "bounded-owned-repeated-superblock-control-session",
        "generalized_root_cause_claimed": False,
        "unbounded_trace_completeness_claimed": False,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    print("NXB deep root/trace evidence validation passed")


if __name__ == "__main__":
    main()
