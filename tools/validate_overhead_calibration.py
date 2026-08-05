#!/usr/bin/env python3
"""Validate NXB paired collector-overhead calibration evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import statistics
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable

from jsonschema import Draft202012Validator, FormatChecker


class ValidationFailure(ValueError):
    """Raised when schema or semantic validation fails."""


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


def canonical_sha256(value: Any) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


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


def close_enough(actual: float, expected: float) -> bool:
    tolerance = max(1e-6, abs(expected) * 1e-6)
    return math.isclose(actual, expected, rel_tol=1e-6, abs_tol=tolerance)


def measured_value(measurement: dict[str, Any], label: str) -> float:
    require(measurement["status"] == "measured", f"{label} must be measured")
    return float(measurement["value"])


def require_unit(measurement: dict[str, Any], unit: str, label: str) -> None:
    require(
        measurement["unit"] == unit,
        f"{label}.unit must be '{unit}', found '{measurement['unit']}'",
    )


def failed_measurement(unit: str) -> dict[str, Any]:
    return {
        "status": "failed",
        "value": None,
        "unit": unit,
        "reason": "arm failed",
    }


def arm_metric(arm: dict[str, Any], metric_name: str, unit: str) -> dict[str, Any]:
    if arm["status"] != "measured":
        return failed_measurement(unit)
    return arm["process_metrics"][metric_name]


def validate_experiment_binding(
    experiment_id: str,
    relative_path: str,
    label: str,
    seen_ids: set[str],
) -> None:
    expected = f"experiments/{experiment_id}"
    require(relative_path == expected, f"{label}.experiment_relative_path must be '{expected}'")
    require(experiment_id not in seen_ids, f"duplicate lifecycle experiment_id: {experiment_id}")
    seen_ids.add(experiment_id)


def validate_arm(arm: dict[str, Any], label: str) -> None:
    started = parse_utc(arm["started_utc"], f"{label}.started_utc")
    stopped = parse_utc(arm["stopped_utc"], f"{label}.stopped_utc")
    require(stopped >= started, f"{label} stopped before it started")
    elapsed_ms = (stopped - started).total_seconds() * 1000.0
    require(
        abs(float(arm["duration_ms"]) - elapsed_ms) <= max(2000.0, elapsed_ms * 0.05),
        f"{label}.duration_ms is inconsistent with timestamps",
    )
    if arm["status"] == "measured":
        require(not arm["timed_out"], f"{label} cannot be measured after timeout")
        require(arm["exit_code"] == 0, f"{label} measured status requires exit_code 0")


def expected_first_arm(ordering: str, ordinal: int) -> str:
    if ordering == "control_then_capture":
        return "control"
    if ordering == "capture_then_control":
        return "capture"
    if ordering == "alternating_control_first":
        return "control" if ordinal % 2 else "capture"
    if ordering == "alternating_capture_first":
        return "capture" if ordinal % 2 else "control"
    raise ValidationFailure(f"Unsupported ordering: {ordering}")


def validate_delta(
    control: dict[str, Any],
    capture: dict[str, Any],
    absolute: dict[str, Any],
    relative: dict[str, Any],
    source_unit: str,
    absolute_unit: str,
    label: str,
) -> float | None:
    require_unit(absolute, absolute_unit, f"{label}.absolute")
    require_unit(relative, "percent", f"{label}.relative")

    if control["status"] != "measured" or capture["status"] != "measured":
        require(
            absolute["status"] != "measured" and relative["status"] != "measured",
            f"{label} cannot be measured when an arm or source metric failed",
        )
        return None

    require_unit(control, source_unit, f"{label}.control")
    require_unit(capture, source_unit, f"{label}.capture")
    control_value = float(control["value"])
    capture_value = float(capture["value"])
    expected_absolute = capture_value - control_value
    actual_absolute = measured_value(absolute, f"{label}.absolute")
    require(
        close_enough(actual_absolute, expected_absolute),
        f"{label}.absolute value mismatch: expected {expected_absolute}, found {actual_absolute}",
    )

    if control_value == 0:
        require(relative["status"] != "measured", f"{label}.relative has zero denominator")
        return None

    expected_relative = expected_absolute / control_value * 100.0
    actual_relative = measured_value(relative, f"{label}.relative")
    require(
        close_enough(actual_relative, expected_relative),
        f"{label}.relative value mismatch: expected {expected_relative}, found {actual_relative}",
    )
    return actual_relative


def validate_pair_deltas(pair: dict[str, Any], label: str) -> dict[str, float | None]:
    control = pair["control"]
    capture = pair["capture"]
    deltas = pair["deltas"]

    control_duration = (
        {"status": "measured", "value": control["duration_ms"], "unit": "ms", "reason": None}
        if control["status"] == "measured"
        else failed_measurement("ms")
    )
    capture_duration = (
        {"status": "measured", "value": capture["duration_ms"], "unit": "ms", "reason": None}
        if capture["status"] == "measured"
        else failed_measurement("ms")
    )

    values: dict[str, float | None] = {}
    values["duration"] = validate_delta(
        control_duration,
        capture_duration,
        deltas["duration_absolute_ms"],
        deltas["duration_relative_percent"],
        "ms",
        "ms",
        f"{label}.duration",
    )

    metric_map = {
        "cpu_time": ("cpu_time_ms", "cpu_time_absolute_ms", "cpu_time_relative_percent", "ms"),
        "peak_working_set": (
            "peak_working_set_bytes",
            "peak_working_set_absolute_bytes",
            "peak_working_set_relative_percent",
            "bytes",
        ),
        "peak_private_bytes": (
            "peak_private_bytes",
            "peak_private_bytes_absolute_bytes",
            "peak_private_bytes_relative_percent",
            "bytes",
        ),
    }
    for result_name, (metric_name, absolute_name, relative_name, unit) in metric_map.items():
        values[result_name] = validate_delta(
            arm_metric(control, metric_name, unit),
            arm_metric(capture, metric_name, unit),
            deltas[absolute_name],
            deltas[relative_name],
            unit,
            unit,
            f"{label}.{result_name}",
        )
    return values


def validate_distribution(
    distribution: dict[str, Any],
    values: list[float],
    label: str,
) -> None:
    require(distribution["unit"] == "percent", f"{label}.unit must be 'percent'")
    if not values:
        require(distribution["status"] != "measured", f"{label} has no measured values")
        require(distribution["count"] == 0, f"{label}.count must be 0")
        return

    require(distribution["status"] == "measured", f"{label} must be measured")
    require(distribution["count"] == len(values), f"{label}.count mismatch")
    expected = {
        "minimum": min(values),
        "median": statistics.median(values),
        "mean": statistics.fmean(values),
        "maximum": max(values),
    }
    for field, expected_value in expected.items():
        actual = float(distribution[field])
        require(
            close_enough(actual, expected_value),
            f"{label}.{field} mismatch: expected {expected_value}, found {actual}",
        )


def validate_semantics(document: dict[str, Any]) -> None:
    require(
        document["power_policy_fingerprint"] == canonical_sha256(document["power_policy"]),
        "power_policy_fingerprint does not match canonical power_policy JSON",
    )
    require(
        document["workload_fingerprint"] == canonical_sha256(document["workload"]),
        "workload_fingerprint does not match canonical workload JSON",
    )
    expected_parent_path = f"experiments/{document['experiment_id']}"
    require(
        document["experiment_relative_path"] == expected_parent_path,
        f"experiment_relative_path must be '{expected_parent_path}'",
    )

    pairs = document["pairs"]
    require(len(pairs) == document["protocol"]["repetition_count"], "pairs count must equal repetition_count")
    require(document["summary"]["pair_count"] == len(pairs), "summary.pair_count mismatch")

    seen_pair_ids: set[str] = set()
    seen_experiment_ids: set[str] = {document["experiment_id"]}
    successful_pairs = 0
    relative_values: dict[str, list[float]] = {
        "duration": [],
        "cpu_time": [],
        "peak_working_set": [],
        "peak_private_bytes": [],
    }

    for index, pair in enumerate(pairs, start=1):
        label = f"pairs[{index - 1}]"
        require(pair["ordinal"] == index, f"{label}.ordinal must be {index}")
        require(pair["pair_id"] not in seen_pair_ids, f"duplicate pair_id: {pair['pair_id']}")
        seen_pair_ids.add(pair["pair_id"])
        require(pair["machine_id"] == document["machine_id"], f"{label}.machine_id mismatch")
        require(pair["boot_id"] == document["boot_id"], f"{label}.boot_id mismatch")
        require(
            pair["power_policy_fingerprint"] == document["power_policy_fingerprint"],
            f"{label}.power_policy_fingerprint mismatch",
        )
        require(
            pair["workload_fingerprint"] == document["workload_fingerprint"],
            f"{label}.workload_fingerprint mismatch",
        )
        require(
            pair["first_arm"] == expected_first_arm(document["protocol"]["ordering"], index),
            f"{label}.first_arm violates deterministic ordering",
        )

        for arm_name in ("control", "capture"):
            arm = pair[arm_name]
            arm_label = f"{label}.{arm_name}"
            validate_experiment_binding(
                arm["experiment_id"],
                arm["experiment_relative_path"],
                arm_label,
                seen_experiment_ids,
            )
            validate_arm(arm, arm_label)

        control_result = pair["control"]["result"]
        capture_result = pair["capture"]["result"]
        if control_result["status"] == "measured" and capture_result["status"] == "measured":
            require(control_result["unit"] == capture_result["unit"], f"{label} result units differ")
            require(control_result["value"] == capture_result["value"], f"{label} control/capture workload results differ")

        require_unit(pair["capture"]["wpr_start_latency_ms"], "ms", f"{label}.capture.wpr_start_latency_ms")
        require_unit(pair["capture"]["wpr_stop_latency_ms"], "ms", f"{label}.capture.wpr_stop_latency_ms")

        pair_success = (
            pair["control"]["status"] == "measured"
            and pair["capture"]["status"] == "measured"
            and pair["capture"]["etl"]["status"] == "measured"
        )
        if pair_success:
            successful_pairs += 1
            etl = pair["capture"]["etl"]
            duration_seconds = float(pair["capture"]["duration_ms"]) / 1000.0
            require(duration_seconds > 0, f"{label}.capture duration must be positive")
            expected_rate = float(etl["length"]) / duration_seconds
            require(
                close_enough(float(etl["effective_bytes_per_second"]), expected_rate),
                f"{label}.capture.etl.effective_bytes_per_second mismatch",
            )

        pair_values = validate_pair_deltas(pair, label)
        for name, value in pair_values.items():
            if value is not None:
                relative_values[name].append(value)

    summary = document["summary"]
    failed_pairs = len(pairs) - successful_pairs
    require(summary["successful_pair_count"] == successful_pairs, "successful_pair_count mismatch")
    require(summary["failed_pair_count"] == failed_pairs, "failed_pair_count mismatch")
    require(
        summary["successful_pair_count"] + summary["failed_pair_count"] == summary["pair_count"],
        "summary pair counters are inconsistent",
    )
    validate_distribution(summary["duration_delta_percent"], relative_values["duration"], "summary.duration_delta_percent")
    validate_distribution(summary["cpu_time_delta_percent"], relative_values["cpu_time"], "summary.cpu_time_delta_percent")
    validate_distribution(
        summary["peak_working_set_delta_percent"],
        relative_values["peak_working_set"],
        "summary.peak_working_set_delta_percent",
    )
    validate_distribution(
        summary["peak_private_bytes_delta_percent"],
        relative_values["peak_private_bytes"],
        "summary.peak_private_bytes_delta_percent",
    )


def main() -> int:
    args = parse_args()
    try:
        schema = load_json(args.schema)
        document = load_json(args.manifest)
        validate_schema(schema, document)
        validate_semantics(document)
    except (ValidationFailure, ValueError, TypeError) as exc:
        print(str(exc), file=sys.stderr)
        return 1

    print(f"Collector overhead calibration valid: {args.manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
