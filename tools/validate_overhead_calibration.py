#!/usr/bin/env python3
"""Validate NXB paired collector-overhead calibration evidence.

This validator performs JSON Schema validation and cross-field checks that
JSON Schema cannot express, including identity binding, deterministic pair
ordering, summary counts, canonical fingerprints, and measured delta math.
"""

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
    """Raised when semantic calibration validation fails."""


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
        if isinstance(part, int):
            path += f"[{part}]"
        else:
            path += f".{part}"
    return path


def validate_schema(schema: Any, document: Any) -> None:
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    errors = sorted(validator.iter_errors(document), key=lambda item: list(item.path))
    if not errors:
        return

    rendered = [
        f"{format_json_path(error.absolute_path)}: {error.message}" for error in errors
    ]
    raise ValidationFailure("Schema validation failed:\n" + "\n".join(rendered))


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationFailure(message)


def parse_utc(value: str, label: str) -> datetime:
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as exc:
        raise ValidationFailure(f"{label} is not a valid ISO-8601 date-time: {value}") from exc
    require(parsed.tzinfo is not None, f"{label} must include a UTC offset")
    return parsed


def close_enough(actual: float, expected: float) -> bool:
    tolerance = max(1e-6, abs(expected) * 1e-6)
    return math.isclose(actual, expected, rel_tol=1e-6, abs_tol=tolerance)


def require_measured_value(measurement: dict[str, Any], label: str) -> float:
    require(measurement["status"] == "measured", f"{label} must be measured")
    return float(measurement["value"])


def verify_measurement_unit(measurement: dict[str, Any], expected: str, label: str) -> None:
    require(
        measurement["unit"] == expected,
        f"{label}.unit must be '{expected}', found '{measurement['unit']}'",
    )


def validate_arm(arm: dict[str, Any], label: str) -> None:
    started = parse_utc(arm["started_utc"], f"{label}.started_utc")
    stopped = parse_utc(arm["stopped_utc"], f"{label}.stopped_utc")
    require(stopped >= started, f"{label} stopped before it started")

    elapsed_ms = (stopped - started).total_seconds() * 1000.0
    require(
        abs(float(arm["duration_ms"]) - elapsed_ms) <= max(2000.0, elapsed_ms * 0.05),
        f"{label}.duration_ms is inconsistent with start/stop timestamps",
    )

    if arm["status"] == "measured":
        require(not arm["timed_out"], f"{label} cannot be measured after timeout")
        require(arm["exit_code"] == 0, f"{label} measured status requires exit_code 0")
    elif arm["timed_out"]:
        require(arm["status"] == "failed", f"{label} timeout must fail the arm")


def expected_first_arm(ordering: str, ordinal: int) -> str:
    if ordering == "control_then_capture":
        return "control"
    if ordering == "capture_then_control":
        return "capture"
    if ordering == "alternating_control_first":
        return "control" if ordinal % 2 == 1 else "capture"
    if ordering == "alternating_capture_first":
        return "capture" if ordinal % 2 == 1 else "control"
    raise ValidationFailure(f"Unsupported ordering: {ordering}")


def expected_delta(
    control: dict[str, Any],
    capture: dict[str, Any],
    absolute: dict[str, Any],
    relative: dict[str, Any],
    source_unit: str,
    absolute_unit: str,
    label: str,
) -> float | None:
    verify_measurement_unit(absolute, absolute_unit, f"{label}.absolute")
    verify_measurement_unit(relative, "percent", f"{label}.relative")

    sources_measured = (
        control["status"] == "measured" and capture["status"] == "measured"
    )
    if not sources_measured:
        require(
            absolute["status"] != "measured" and relative["status"] != "measured",
            f"{label} cannot be measured when a source metric is unavailable",
        )
        return None

    verify_measurement_unit(control, source_unit, f"{label}.control")
    verify_measurement_unit(capture, source_unit, f"{label}.capture")
    control_value = float(control["value"])
    capture_value = float(capture["value"])
    absolute_expected = capture_value - control_value

    absolute_actual = require_measured_value(absolute, f"{label}.absolute")
    require(
        close_enough(absolute_actual, absolute_expected),
        f"{label}.absolute value mismatch: expected {absolute_expected}, found {absolute_actual}",
    )

    if control_value == 0:
        require(
            relative["status"] != "measured",
            f"{label}.relative cannot be measured with a zero control denominator",
        )
        return None

    relative_expected = absolute_expected / control_value * 100.0
    relative_actual = require_measured_value(relative, f"{label}.relative")
    require(
        close_enough(relative_actual, relative_expected),
        f"{label}.relative value mismatch: expected {relative_expected}, found {relative_actual}",
    )
    return relative_actual


def validate_pair_deltas(pair: dict[str, Any], label: str) -> dict[str, float | None]:
    control = pair["control"]
    capture = pair["capture"]
    deltas = pair["deltas"]

    duration_control = {
        "status": "measured" if control["status"] == "measured" else "failed",
        "value": control["duration_ms"] if control["status"] == "measured" else None,
        "unit": "ms",
        "reason": None if control["status"] == "measured" else "arm failed",
    }
    duration_capture = {
        "status": "measured" if capture["status"] == "measured" else "failed",
        "value": capture["duration_ms"] if capture["status"] == "measured" else None,
        "unit": "ms",
        "reason": None if capture["status"] == "measured" else "arm failed",
    }

    values: dict[str, float | None] = {}
    values["duration"] = expected_delta(
        duration_control,
        duration_capture,
        deltas["duration_absolute_ms"],
        deltas["duration_relative_percent"],
        "ms",
        "ms",
        f"{label}.duration",
    )

    metric_map = {
        "cpu_time": (
            "cpu_time_ms",
            "cpu_time_absolute_ms",
            "cpu_time_relative_percent",
            "ms",
            "ms",
        ),
        "peak_working_set": (
            "peak_working_set_bytes",
            "peak_working_set_absolute_bytes",
            "peak_working_set_relative_percent",
            "bytes",
            "bytes",
        ),
        "peak_private_bytes": (
            "peak_private_bytes",
            "peak_private_bytes_absolute_bytes",
            "peak_private_bytes_relative_percent",
            "bytes",
            "bytes",
        ),
    }
    for output_name, (
        source_name,
        absolute_name,
        relative_name,
        source_unit,
        absolute_unit,
    ) in metric_map.items():
        values[output_name] = expected_delta(
            control["process_metrics"][source_name],
            capture["process_metrics"][source_name],
            deltas[absolute_name],
            deltas[relative_name],
            source_unit,
            absolute_unit,
            f"{label}.{output_name}",
        )

    return values


def validate_distribution(
    distribution: dict[str, Any], values: list[float], unit: str, label: str
) -> None:
    require(distribution["unit"] == unit, f"{label}.unit must be '{unit}'")
    if not values:
        require(
            distribution["status"] != "measured",
            f"{label} cannot be measured without measured pair values",
        )
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

    pairs = document["pairs"]
    repetition_count = document["protocol"]["repetition_count"]
    require(len(pairs) == repetition_count, "pairs count must equal repetition_count")
    require(document["summary"]["pair_count"] == len(pairs), "summary.pair_count mismatch")

    seen_ids: set[str] = set()
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
        require(pair["pair_id"] not in seen_ids, f"duplicate pair_id: {pair['pair_id']}")
        seen_ids.add(pair["pair_id"])

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

        validate_arm(pair["control"], f"{label}.control")
        validate_arm(pair["capture"], f"{label}.capture")
        verify_measurement_unit(
            pair["capture"]["wpr_start_latency_ms"], "ms", f"{label}.capture.wpr_start_latency_ms"
        )
        verify_measurement_unit(
            pair["capture"]["wpr_stop_latency_ms"], "ms", f"{label}.capture.wpr_stop_latency_ms"
        )

        pair_success = (
            pair["control"]["status"] == "measured"
            and pair["capture"]["status"] == "measured"
            and pair["capture"]["etl"]["status"] == "measured"
        )
        if pair_success:
            successful_pairs += 1
            etl = pair["capture"]["etl"]
            duration_seconds = float(pair["capture"]["duration_ms"]) / 1000.0
            if duration_seconds > 0:
                expected_rate = float(etl["length"]) / duration_seconds
                require(
                    close_enough(float(etl["effective_bytes_per_second"]), expected_rate),
                    f"{label}.capture.etl.effective_bytes_per_second mismatch",
                )

        delta_values = validate_pair_deltas(pair, label)
        for name, value in delta_values.items():
            if value is not None:
                relative_values[name].append(value)

    failed_pairs = len(pairs) - successful_pairs
    summary = document["summary"]
    require(summary["successful_pair_count"] == successful_pairs, "successful_pair_count mismatch")
    require(summary["failed_pair_count"] == failed_pairs, "failed_pair_count mismatch")
    require(
        summary["successful_pair_count"] + summary["failed_pair_count"] == summary["pair_count"],
        "summary pair counters are inconsistent",
    )

    validate_distribution(
        summary["duration_delta_percent"], relative_values["duration"], "percent", "summary.duration_delta_percent"
    )
    validate_distribution(
        summary["cpu_time_delta_percent"], relative_values["cpu_time"], "percent", "summary.cpu_time_delta_percent"
    )
    validate_distribution(
        summary["peak_working_set_delta_percent"],
        relative_values["peak_working_set"],
        "percent",
        "summary.peak_working_set_delta_percent",
    )
    validate_distribution(
        summary["peak_private_bytes_delta_percent"],
        relative_values["peak_private_bytes"],
        "percent",
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
