#!/usr/bin/env python3
"""Validate NXB storage ETL summary evidence."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable

from jsonschema import Draft202012Validator, FormatChecker


class ValidationFailure(ValueError):
    """Raised when schema or semantic validation fails."""


EVENT_KEYS = (
    "disk_read",
    "disk_write",
    "disk_flush",
    "file_read",
    "file_write",
    "file_flush",
    "file_create",
    "file_close",
    "file_delete",
    "file_rename",
    "split_io",
)

METRIC_KEYS = (
    "queue_depth",
    "queue_latency_us",
    "service_time_us",
    "throughput_bytes_per_second",
    "iops",
)


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
            f"Invalid JSON in {path}: line {exc.lineno}, "
            f"column {exc.colno}: {exc.msg}"
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
    errors = sorted(
        validator.iter_errors(document),
        key=lambda error: list(error.path),
    )
    if errors:
        rendered = [
            f"{format_json_path(error.absolute_path)}: {error.message}"
            for error in errors
        ]
        raise ValidationFailure(
            "Schema validation failed:\n" + "\n".join(rendered)
        )


def parse_time(value: str, label: str) -> datetime:
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as exc:
        raise ValidationFailure(
            f"{label} is not a valid ISO-8601 date-time"
        ) from exc
    require(parsed.tzinfo is not None, f"{label} must include a UTC offset")
    return parsed


def measured(entry: dict[str, Any]) -> bool:
    return entry["status"] == "measured"


def validate_statistics(stats: dict[str, Any], label: str) -> None:
    minimum = float(stats["min"])
    median = float(stats["median"])
    mean = float(stats["mean"])
    maximum = float(stats["max"])
    require(minimum <= median <= maximum, f"{label} median is outside min/max")
    require(minimum <= mean <= maximum, f"{label} mean is outside min/max")
    require(int(stats["samples"]) >= 1, f"{label}.samples must be positive")


def validate_event_entry(
    entry: dict[str, Any],
    label: str,
    aggregate: bool,
) -> None:
    if measured(entry):
        require(entry["count"] is not None, f"{label}.count is required")
        require(entry["source"] is not None, f"{label}.source is required")
        require(entry["reason"] is None, f"{label}.reason must be null")
        if entry["latency_us"] is not None:
            validate_statistics(entry["latency_us"], f"{label}.latency_us")
        if aggregate:
            require(
                entry["unattributed_count"] is not None,
                f"{label}.unattributed_count is required",
            )
            require(
                int(entry["unattributed_count"]) <= int(entry["count"]),
                f"{label}.unattributed_count cannot exceed count",
            )
    else:
        require(entry["count"] is None, f"{label}.count must be null")
        require(entry["bytes"] is None, f"{label}.bytes must be null")
        require(entry["latency_us"] is None, f"{label}.latency_us must be null")
        require(
            isinstance(entry["reason"], str) and bool(entry["reason"].strip()),
            f"{label}.reason is required",
        )
        if aggregate:
            require(
                entry["unattributed_count"] is None,
                f"{label}.unattributed_count must be null",
            )


def validate_identity(document: dict[str, Any]) -> None:
    expected_relative = f"experiments/{document['experiment_id']}"
    require(
        document["experiment_relative_path"] == expected_relative,
        f"experiment_relative_path must be '{expected_relative}'",
    )

    trace_start = parse_time(document["trace_start_utc"], "trace_start_utc")
    trace_end = parse_time(document["trace_end_utc"], "trace_end_utc")
    require(trace_start <= trace_end, "trace_start_utc is after trace_end_utc")

    target_start = parse_time(
        document["target"]["process_start_utc"],
        "target.process_start_utc",
    )
    require(target_start <= trace_end, "target process started after trace end")


def validate_processes(document: dict[str, Any]) -> None:
    target = document["target"]
    target_key = (
        int(target["process_id"]),
        target["process_start_utc"],
        target["image_sha256"],
    )
    seen: set[tuple[int, str | None, str | None]] = set()
    target_matches = 0

    for index, process in enumerate(document["processes"]):
        label = f"processes[{index}]"
        key = (
            int(process["process_id"]),
            process["process_start_utc"],
            process["image_sha256"],
        )
        require(key not in seen, f"duplicate process identity at {label}")
        seen.add(key)

        if process["identity_status"] == "complete":
            require(
                process["process_start_utc"] is not None,
                f"{label}.process_start_utc is required for complete identity",
            )
            require(
                process["image_sha256"] is not None,
                f"{label}.image_sha256 is required for complete identity",
            )
        else:
            require(not process["is_target"], f"{label} target identity cannot be partial")

        is_target_identity = key == target_key
        require(
            bool(process["is_target"]) is is_target_identity,
            f"{label}.is_target is inconsistent with target identity",
        )
        if is_target_identity:
            target_matches += 1

        for name in EVENT_KEYS:
            validate_event_entry(
                process["events"][name],
                f"{label}.events.{name}",
                aggregate=False,
            )

    require(target_matches == 1, "exactly one process must match target identity")


def validate_aggregates(document: dict[str, Any]) -> None:
    unsupported = set(document["quality"]["unsupported_event_types"])

    for name in EVENT_KEYS:
        aggregate = document["events"][name]
        label = f"events.{name}"
        validate_event_entry(aggregate, label, aggregate=True)

        require(
            (aggregate["status"] == "unsupported") == (name in unsupported),
            f"{label} unsupported status/list mismatch",
        )

        if not measured(aggregate):
            continue

        process_entries = [process["events"][name] for process in document["processes"]]
        measured_counts = [
            int(entry["count"]) for entry in process_entries if measured(entry)
        ]
        attributed = sum(measured_counts)
        unattributed = int(aggregate["unattributed_count"])

        if aggregate["attribution"] == "complete":
            require(
                all(measured(entry) for entry in process_entries),
                f"{label} complete attribution requires measured process entries",
            )
            require(
                attributed + unattributed == int(aggregate["count"]),
                f"{label} complete attribution count mismatch",
            )
        elif aggregate["attribution"] == "partial":
            require(
                attributed + unattributed <= int(aggregate["count"]),
                f"{label} partial attribution exceeds aggregate count",
            )
        else:
            require(
                attributed == 0,
                f"{label} attribution=none cannot have measured process counts",
            )


def validate_metrics(document: dict[str, Any]) -> None:
    unsupported = set(document["quality"]["unsupported_metrics"])

    for name in METRIC_KEYS:
        entry = document["metrics"][name]
        label = f"metrics.{name}"
        require(
            (entry["status"] == "unsupported") == (name in unsupported),
            f"{label} unsupported status/list mismatch",
        )
        if measured(entry):
            require(entry["statistics"] is not None, f"{label}.statistics is required")
            require(entry["source"] is not None, f"{label}.source is required")
            require(entry["reason"] is None, f"{label}.reason must be null")
            validate_statistics(entry["statistics"], f"{label}.statistics")
        else:
            require(entry["statistics"] is None, f"{label}.statistics must be null")
            require(
                isinstance(entry["reason"], str) and bool(entry["reason"].strip()),
                f"{label}.reason is required",
            )


def validate_summary(document: dict[str, Any]) -> None:
    events = document["events"]
    metrics = document["metrics"]
    summary = document["summary"]

    require(
        int(summary["process_count"]) == len(document["processes"]),
        "summary.process_count mismatch",
    )
    require(
        int(summary["measured_event_class_count"])
        == sum(1 for name in EVENT_KEYS if measured(events[name])),
        "summary.measured_event_class_count mismatch",
    )
    require(
        int(summary["failed_event_class_count"])
        == sum(1 for name in EVENT_KEYS if events[name]["status"] == "failed"),
        "summary.failed_event_class_count mismatch",
    )
    require(
        int(summary["measured_metric_count"])
        == sum(1 for name in METRIC_KEYS if measured(metrics[name])),
        "summary.measured_metric_count mismatch",
    )
    require(
        int(summary["failed_metric_count"])
        == sum(1 for name in METRIC_KEYS if metrics[name]["status"] == "failed"),
        "summary.failed_metric_count mismatch",
    )

    if summary["evidence_completeness"] == "complete":
        require(
            all(measured(events[name]) for name in EVENT_KEYS),
            "complete evidence requires all event classes measured",
        )
        require(
            all(measured(metrics[name]) for name in METRIC_KEYS),
            "complete evidence requires all metrics measured",
        )
        require(
            document["quality"]["parser_completeness"] == "complete",
            "complete evidence requires complete parser coverage",
        )
        require(
            document["quality"]["trace_loss"] == "none",
            "complete evidence requires trace_loss=none",
        )


def validate_claims(document: dict[str, Any]) -> None:
    claims = document["claims"]
    require(claims["queue_depth_semantics"] is False, "queue depth claim must remain false")
    require(claims["queue_latency_semantics"] is False, "queue latency claim must remain false")
    require(claims["service_time_semantics"] is False, "service time claim must remain false")
    require(
        claims["throughput_representativeness"] is False,
        "throughput representativeness claim must remain false",
    )
    require(
        claims["iops_representativeness"] is False,
        "IOPS representativeness claim must remain false",
    )
    require(
        claims["trace_completeness"] == "not_claimed",
        "trace completeness must remain not_claimed",
    )


def validate_document(document: dict[str, Any]) -> None:
    validate_identity(document)
    validate_processes(document)
    validate_aggregates(document)
    validate_metrics(document)
    validate_summary(document)
    validate_claims(document)


def main() -> int:
    args = parse_args()
    try:
        schema = load_json(args.schema)
        document = load_json(args.manifest)
        validate_schema(schema, document)
        validate_document(document)
    except ValidationFailure as exc:
        print(f"storage ETL summary validation failed: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:  # fail closed for unexpected validator errors
        print(f"storage ETL summary validator error: {exc}", file=sys.stderr)
        return 2

    print("storage ETL summary validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
