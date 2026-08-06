#!/usr/bin/env python3
"""Validate NXB memory working-set snapshot evidence."""

from __future__ import annotations

import argparse
import json
import math
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable

from jsonschema import Draft202012Validator, FormatChecker


class ValidationFailure(ValueError):
    """Raised when schema or semantic validation fails."""


SYSTEM_UNITS = {
    "total_physical_bytes": "bytes",
    "available_physical_bytes": "bytes",
    "committed_bytes": "bytes",
    "commit_limit_bytes": "bytes",
    "system_cache_resident_bytes": "bytes",
    "paged_pool_bytes": "bytes",
    "nonpaged_pool_bytes": "bytes",
    "memory_load_percent": "percent",
}

PROCESS_UNITS = {
    "working_set_bytes": "bytes",
    "peak_working_set_bytes": "bytes",
    "private_bytes": "bytes",
    "paged_memory_bytes": "bytes",
    "peak_paged_memory_bytes": "bytes",
    "virtual_memory_bytes": "bytes",
    "peak_virtual_memory_bytes": "bytes",
    "page_fault_count": "count",
    "hard_fault_count": "count",
    "handle_count": "count",
    "thread_count": "count",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--schema", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    return parser.parse_args()


def load_json(path: Path) -> Any:
    try:
        with path.open("r", encoding="utf-8-sig") as handle:
            return json.load(handle)
    except FileNotFoundError as exc:
        raise ValidationFailure(f"JSON file not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ValidationFailure(
            f"Invalid JSON in {path}: line {exc.lineno}, column {exc.colno}: {exc.msg}"
        ) from exc


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationFailure(message)


def format_json_path(parts: Iterable[Any]) -> str:
    path = "$"
    for part in parts:
        path += f"[{part}]" if isinstance(part, int) else f".{part}"
    return path


def validate_schema(schema: Any, document: Any) -> None:
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    errors = sorted(validator.iter_errors(document), key=lambda error: list(error.path))
    if errors:
        rendered = [
            f"{format_json_path(error.absolute_path)}: {error.message}"
            for error in errors
        ]
        raise ValidationFailure("Schema validation failed:\n" + "\n".join(rendered))


def parse_utc(value: str, label: str) -> datetime:
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as exc:
        raise ValidationFailure(f"{label} is not a valid ISO-8601 date-time") from exc
    require(parsed.tzinfo is not None, f"{label} must include a UTC offset")
    return parsed


def measured_value(measurement: dict[str, Any]) -> float | None:
    if measurement["status"] != "measured":
        return None
    return float(measurement["value"])


def validate_measurement(
    measurement: dict[str, Any],
    expected_unit: str,
    label: str,
) -> None:
    require(
        measurement["unit"] == expected_unit,
        f"{label}.unit must be '{expected_unit}'",
    )
    if measurement["status"] == "measured":
        require(measurement["reason"] is None, f"{label}.reason must be null")
        require(
            isinstance(measurement["source"], str)
            and bool(measurement["source"].strip()),
            f"{label}.source is required for measured evidence",
        )
    else:
        require(measurement["value"] is None, f"{label}.value must be null")
        require(
            isinstance(measurement["reason"], str)
            and bool(measurement["reason"].strip()),
            f"{label}.reason is required for non-measured evidence",
        )


def validate_capture(document: dict[str, Any]) -> None:
    expected_relative = f"experiments/{document['experiment_id']}"
    require(
        document["experiment_relative_path"] == expected_relative,
        f"experiment_relative_path must be '{expected_relative}'",
    )

    capture = document["capture"]
    started = parse_utc(capture["started_utc"], "capture.started_utc")
    stopped = parse_utc(capture["stopped_utc"], "capture.stopped_utc")
    captured = parse_utc(document["captured_utc"], "captured_utc")
    require(stopped >= started, "capture stopped before it started")
    require(started <= captured <= stopped, "captured_utc must fall within capture window")

    expected_duration_ms = (stopped - started).total_seconds() * 1000.0
    tolerance = max(5.0, expected_duration_ms * 0.01)
    require(
        math.isclose(
            float(capture["duration_ms"]),
            expected_duration_ms,
            rel_tol=0.01,
            abs_tol=tolerance,
        ),
        "capture.duration_ms does not match started/stopped timestamps",
    )

    mode = capture["selection_mode"]
    requested = list(capture["requested_process_ids"])
    returned = [int(item["identity"]["pid"]) for item in document["processes"]]

    if mode == "system_only":
        require(not requested, "system_only capture cannot request process IDs")
        require(not returned, "system_only capture cannot contain process snapshots")
    elif mode == "system_and_explicit_processes":
        require(bool(requested), "explicit process capture requires requested_process_ids")
        require(
            sorted(requested) == sorted(returned),
            "explicit process snapshots must exactly match requested_process_ids",
        )
    else:
        require(bool(requested), "target process-tree capture requires a root process ID")
        require(
            requested[0] in returned,
            "target process-tree capture must contain the requested root process",
        )


def validate_profile(document: dict[str, Any]) -> None:
    profile = document["profile"]
    require(
        profile["reference_set_enabled"] is False,
        "minimal memory evidence cannot enable ReferenceSet",
    )


def validate_system(document: dict[str, Any]) -> tuple[int, int, bool]:
    system = document["system"]
    statuses: list[str] = []
    measured_count = 0
    for name, expected_unit in SYSTEM_UNITS.items():
        measurement = system[name]
        validate_measurement(measurement, expected_unit, f"system.{name}")
        statuses.append(measurement["status"])
        measured_count += int(measurement["status"] == "measured")

    total = measured_value(system["total_physical_bytes"])
    available = measured_value(system["available_physical_bytes"])
    if total is not None and available is not None:
        require(
            available <= total,
            "system.available_physical_bytes cannot exceed total_physical_bytes",
        )

    committed = measured_value(system["committed_bytes"])
    limit = measured_value(system["commit_limit_bytes"])
    if committed is not None and limit is not None:
        require(
            committed <= limit,
            "system.committed_bytes cannot exceed commit_limit_bytes",
        )

    load = measured_value(system["memory_load_percent"])
    if load is not None:
        require(load <= 100, "system.memory_load_percent cannot exceed 100")

    return len(SYSTEM_UNITS), measured_count, "failed" in statuses


def expected_process_status(metrics: dict[str, Any]) -> str:
    statuses = [metrics[name]["status"] for name in PROCESS_UNITS]
    if "failed" in statuses:
        return "failed"
    if all(status == "measured" for status in statuses):
        return "measured"
    return "partial"


def validate_processes(
    document: dict[str, Any],
) -> tuple[dict[str, int], int, int, bool]:
    processes = document["processes"]
    pids = [int(item["identity"]["pid"]) for item in processes]
    require(len(pids) == len(set(pids)), "process identity PID values must be unique")

    process_counts = {"measured": 0, "partial": 0, "failed": 0}
    measured_metric_count = 0
    failed_measurement = False

    for index, process in enumerate(processes):
        metrics = process["metrics"]
        for name, expected_unit in PROCESS_UNITS.items():
            measurement = metrics[name]
            validate_measurement(
                measurement,
                expected_unit,
                f"processes[{index}].metrics.{name}",
            )
            measured_metric_count += int(measurement["status"] == "measured")
            failed_measurement = failed_measurement or measurement["status"] == "failed"

        expected_status = expected_process_status(metrics)
        require(
            process["status"] == expected_status,
            f"processes[{index}].status must be '{expected_status}'",
        )
        process_counts[expected_status] += 1

        if expected_status == "measured":
            require(
                process["reason"] is None,
                f"processes[{index}].reason must be null for measured process",
            )
        else:
            require(
                isinstance(process["reason"], str)
                and bool(process["reason"].strip()),
                f"processes[{index}].reason is required for non-measured process",
            )

        current = measured_value(metrics["working_set_bytes"])
        peak = measured_value(metrics["peak_working_set_bytes"])
        if current is not None and peak is not None:
            require(
                current <= peak,
                f"processes[{index}] working_set_bytes cannot exceed peak_working_set_bytes",
            )

        current = measured_value(metrics["paged_memory_bytes"])
        peak = measured_value(metrics["peak_paged_memory_bytes"])
        if current is not None and peak is not None:
            require(
                current <= peak,
                f"processes[{index}] paged_memory_bytes cannot exceed peak_paged_memory_bytes",
            )

        current = measured_value(metrics["virtual_memory_bytes"])
        peak = measured_value(metrics["peak_virtual_memory_bytes"])
        if current is not None and peak is not None:
            require(
                current <= peak,
                f"processes[{index}] virtual_memory_bytes cannot exceed peak_virtual_memory_bytes",
            )

        hard = measured_value(metrics["hard_fault_count"])
        total_faults = measured_value(metrics["page_fault_count"])
        if hard is not None and total_faults is not None:
            require(
                hard <= total_faults,
                f"processes[{index}] hard_fault_count cannot exceed page_fault_count",
            )

    return (
        process_counts,
        len(processes) * len(PROCESS_UNITS),
        measured_metric_count,
        failed_measurement,
    )


def validate_summary(
    document: dict[str, Any],
    system_total: int,
    system_measured: int,
    system_failed: bool,
    process_counts: dict[str, int],
    process_total: int,
    process_measured: int,
    process_failed: bool,
) -> None:
    summary = document["summary"]
    process_count = len(document["processes"])

    require(summary["process_count"] == process_count, "summary.process_count mismatch")
    require(
        summary["measured_process_count"] == process_counts["measured"],
        "summary.measured_process_count mismatch",
    )
    require(
        summary["partial_process_count"] == process_counts["partial"],
        "summary.partial_process_count mismatch",
    )
    require(
        summary["failed_process_count"] == process_counts["failed"],
        "summary.failed_process_count mismatch",
    )
    require(
        summary["system_measurement_count"] == system_total,
        "summary.system_measurement_count mismatch",
    )
    require(
        summary["measured_system_measurement_count"] == system_measured,
        "summary.measured_system_measurement_count mismatch",
    )
    require(
        summary["process_measurement_count"] == process_total,
        "summary.process_measurement_count mismatch",
    )
    require(
        summary["measured_process_measurement_count"] == process_measured,
        "summary.measured_process_measurement_count mismatch",
    )

    failed = system_failed or process_failed
    all_measured = (
        system_measured == system_total
        and process_measured == process_total
        and process_counts["failed"] == 0
        and process_counts["partial"] == 0
    )
    any_measured = system_measured > 0 or process_measured > 0

    if failed:
        expected = "failed"
    elif all_measured:
        expected = "complete"
    elif any_measured:
        expected = "partial"
    else:
        expected = "unavailable"

    require(
        summary["evidence_completeness"] == expected,
        f"summary.evidence_completeness must be '{expected}'",
    )


def validate_semantics(document: dict[str, Any]) -> None:
    validate_capture(document)
    validate_profile(document)
    system_total, system_measured, system_failed = validate_system(document)
    (
        process_counts,
        process_total,
        process_measured,
        process_failed,
    ) = validate_processes(document)
    validate_summary(
        document,
        system_total,
        system_measured,
        system_failed,
        process_counts,
        process_total,
        process_measured,
        process_failed,
    )


def main() -> int:
    args = parse_args()
    try:
        schema = load_json(args.schema)
        document = load_json(args.manifest)
        validate_schema(schema, document)
        validate_semantics(document)
    except ValidationFailure as exc:
        print(str(exc), file=sys.stderr)
        return 1

    print(f"Memory working-set snapshot valid: {args.manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
