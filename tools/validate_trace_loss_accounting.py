#!/usr/bin/env python3
"""Validate NXB trace-loss and circular-overwrite accounting evidence."""

from __future__ import annotations

import argparse
import json
import math
import re
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
    tolerance = max(1e-9, abs(expected) * 1e-9)
    return math.isclose(actual, expected, rel_tol=1e-9, abs_tol=tolerance)


def validate_capture(document: dict[str, Any]) -> None:
    expected_relative = f"experiments/{document['experiment_id']}"
    require(
        document["experiment_relative_path"] == expected_relative,
        f"experiment_relative_path must be '{expected_relative}'",
    )

    capture = document["capture"]
    started = parse_utc(capture["started_utc"], "capture.started_utc")
    stopped = parse_utc(capture["stopped_utc"], "capture.stopped_utc")
    require(stopped >= started, "capture stopped before it started")

    profile = capture["profile"]
    if profile["bounded"]:
        require(
            profile["file_mode"] == "Circular",
            "bounded profile must use Circular file_mode",
        )
        require(
            profile["maximum_file_size_mib"] is not None,
            "bounded profile requires maximum_file_size_mib",
        )
    else:
        require(
            profile["maximum_file_size_mib"] is None,
            "unbounded profile cannot declare maximum_file_size_mib",
        )

    etl = capture["etl"]
    if etl["status"] == "measured":
        require(etl["sha256"] is not None, "measured ETL requires sha256")
        require(etl["length"] is not None, "measured ETL requires length")
        require(etl["reason"] is None, "measured ETL reason must be null")
    else:
        require(etl["sha256"] is None, "non-measured ETL sha256 must be null")
        require(etl["length"] is None, "non-measured ETL length must be null")
        require(
            isinstance(etl["reason"], str) and bool(etl["reason"].strip()),
            "non-measured ETL requires a reason",
        )


def validate_counter_sources(counters: dict[str, Any]) -> None:
    allowed_fields = {
        "events_lost": {"events_lost", "collector_events_lost", "dropped_event"},
        "buffers_lost": {"buffers_lost"},
        "realtime_buffers_lost": {"realtime_buffers_lost"},
    }
    source_pattern = re.compile(
        r"^(wpr_status_snapshot|xperf_tracestats):[0-9a-f]{64};field=([a-z_]+)$"
    )

    for counter_name, counter in counters.items():
        if counter["status"] != "measured":
            continue
        match = source_pattern.fullmatch(counter["source"])
        require(match is not None, f"native_counters.{counter_name}.source is not hash-bound")
        source_field = match.group(2)
        require(
            source_field in allowed_fields[counter_name],
            f"native_counters.{counter_name}.source field '{source_field}' is inconsistent",
        )


def validate_trace_loss(document: dict[str, Any]) -> bool:
    counters = document["native_counters"]
    validate_counter_sources(counters)
    trace_loss = document["trace_loss"]
    measured_values = [
        int(counter["value"])
        for counter in counters.values()
        if counter["status"] == "measured"
    ]
    measured_count = len(measured_values)
    total = sum(measured_values)

    require(
        trace_loss["measured_counter_count"] == measured_count,
        "trace_loss.measured_counter_count does not match native counters",
    )

    classification = trace_loss["classification"]
    failed_counter = any(counter["status"] == "failed" for counter in counters.values())

    if total > 0:
        expected = "native_loss_observed"
        expected_total: int | None = total
        assessed = True
    elif measured_count == len(counters):
        expected = "no_native_loss_reported"
        expected_total = 0
        assessed = True
    elif failed_counter:
        expected = "failed"
        expected_total = None
        assessed = False
    else:
        expected = "not_assessed"
        expected_total = None
        assessed = False

    require(
        classification == expected,
        f"trace_loss.classification must be '{expected}', found '{classification}'",
    )
    require(
        trace_loss["total_reported_loss"] == expected_total,
        "trace_loss.total_reported_loss is inconsistent with native counters",
    )

    if assessed:
        require(trace_loss["reason"] is None, "assessed trace_loss reason must be null")
    else:
        require(
            isinstance(trace_loss["reason"], str) and bool(trace_loss["reason"].strip()),
            "unassessed or failed trace_loss requires a reason",
        )
    return assessed


def validate_circular_overwrite(document: dict[str, Any]) -> bool:
    capture = document["capture"]
    profile = capture["profile"]
    etl = capture["etl"]
    overwrite = document["circular_overwrite"]
    classification = overwrite["classification"]

    if not profile["bounded"] or profile["file_mode"] != "Circular":
        require(classification == "not_applicable", "unbounded capture must be not_applicable")
        require(overwrite["capacity_bytes"] is None, "not_applicable capacity_bytes must be null")
        require(overwrite["final_etl_length"] is None, "not_applicable final_etl_length must be null")
        require(overwrite["utilization_ratio"] is None, "not_applicable utilization_ratio must be null")
        require(not overwrite["risk_reasons"], "not_applicable risk_reasons must be empty")
        return True

    capacity = int(profile["maximum_file_size_mib"]) * 1024 * 1024
    require(overwrite["capacity_bytes"] == capacity, "circular capacity_bytes mismatch")

    if etl["status"] != "measured":
        expected = "failed" if etl["status"] == "failed" else "not_assessed"
        require(classification == expected, f"circular_overwrite.classification must be '{expected}'")
        require(overwrite["final_etl_length"] is None, "unmeasured ETL final length must be null")
        require(overwrite["utilization_ratio"] is None, "unmeasured ETL utilization must be null")
        require(not overwrite["risk_reasons"], "unmeasured ETL risk_reasons must be empty")
        require(
            isinstance(overwrite["reason"], str) and bool(overwrite["reason"].strip()),
            "unmeasured circular accounting requires a reason",
        )
        return False

    final_length = int(etl["length"])
    expected_utilization = final_length / capacity
    require(
        overwrite["final_etl_length"] == final_length,
        "circular_overwrite.final_etl_length does not match ETL length",
    )
    require(
        overwrite["utilization_ratio"] is not None
        and close_enough(float(overwrite["utilization_ratio"]), expected_utilization),
        "circular_overwrite.utilization_ratio mismatch",
    )

    expected_reasons: list[str] = []
    if expected_utilization >= float(overwrite["risk_threshold_ratio"]):
        expected_reasons.append("capacity_threshold_reached")
    if final_length > capacity:
        expected_reasons.append("etl_length_exceeds_declared_capacity")

    provided_reasons = list(overwrite["risk_reasons"])
    require(
        sorted(provided_reasons) == sorted(expected_reasons),
        "circular_overwrite.risk_reasons are inconsistent with capacity evidence",
    )
    expected_classification = "risk_observed" if expected_reasons else "no_risk_observed"
    require(
        classification == expected_classification,
        f"circular_overwrite.classification must be '{expected_classification}'",
    )
    require(overwrite["reason"] is None, "assessed circular_overwrite reason must be null")
    return True


def validate_summary(document: dict[str, Any], trace_assessed: bool, circular_assessed: bool) -> None:
    summary = document["summary"]
    require(
        summary["trace_loss_assessed"] is trace_assessed,
        "summary.trace_loss_assessed mismatch",
    )
    require(
        summary["circular_overwrite_assessed"] is circular_assessed,
        "summary.circular_overwrite_assessed mismatch",
    )

    failed = (
        document["trace_loss"]["classification"] == "failed"
        or document["circular_overwrite"]["classification"] == "failed"
    )
    if failed:
        expected = "failed"
    elif trace_assessed and circular_assessed:
        expected = "complete"
    elif trace_assessed or circular_assessed:
        expected = "partial"
    else:
        expected = "unavailable"
    require(
        summary["evidence_completeness"] == expected,
        f"summary.evidence_completeness must be '{expected}'",
    )


def validate_semantics(document: dict[str, Any]) -> None:
    validate_capture(document)
    trace_assessed = validate_trace_loss(document)
    circular_assessed = validate_circular_overwrite(document)
    validate_summary(document, trace_assessed, circular_assessed)


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
    print(f"Trace-loss accounting valid: {args.manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
