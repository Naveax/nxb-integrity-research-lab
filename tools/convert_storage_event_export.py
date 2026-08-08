#!/usr/bin/env python3
"""Convert a normalized NXB storage event export into conservative summary evidence."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

EVENT_TYPES = (
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
BYTE_EVENT_TYPES = {
    "disk_read",
    "disk_write",
    "file_read",
    "file_write",
}
METRIC_TYPES = (
    "queue_depth",
    "queue_latency_us",
    "service_time_us",
    "throughput_bytes_per_second",
    "iops",
)
EXPECTED_HEADER = [
    "event_type",
    "timestamp_raw",
    "process_id",
    "thread_id",
    "disk_number",
    "file_key",
    "path",
    "offset_bytes",
    "transfer_bytes",
    "duration_raw",
    "disk_service_time_raw",
    "result_raw",
]


class ConversionFailure(ValueError):
    """Raised when storage summary conversion must fail closed."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--experiment-id", required=True)
    parser.add_argument("--machine-id", required=True)
    parser.add_argument("--boot-id", required=True)
    parser.add_argument("--trace-sha256", required=True)
    parser.add_argument("--profile-sha256", required=True)
    parser.add_argument("--adapter-sha256", required=True)
    parser.add_argument("--trace-start-utc", required=True)
    parser.add_argument("--trace-end-utc", required=True)
    parser.add_argument("--target-process-id", required=True, type=int)
    parser.add_argument("--target-process-start-utc", required=True)
    parser.add_argument("--target-image-sha256", required=True)
    parser.add_argument("--covered-event-type", action="append", required=True)
    parser.add_argument(
        "--trace-loss",
        choices=("none", "present", "unknown"),
        required=True,
    )
    parser.add_argument(
        "--circular-overwrite",
        choices=("none", "possible", "confirmed", "unknown"),
        required=True,
    )
    parser.add_argument(
        "--parser-completeness",
        choices=("complete", "partial", "failed"),
        required=True,
    )
    parser.add_argument("--max-event-count", type=int, default=1_000_000)
    return parser.parse_args()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ConversionFailure(message)


def parse_utc(value: str, label: str) -> datetime:
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as exc:
        raise ConversionFailure(f"Invalid {label}: {value}") from exc
    require(parsed.tzinfo is not None, f"{label} must include a UTC offset")
    return parsed.astimezone(timezone.utc)


def format_utc(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def parse_optional_non_negative_int(value: str, label: str) -> int | None:
    text = value.strip()
    if not text:
        return None
    try:
        parsed = int(text, 10)
    except ValueError as exc:
        raise ConversionFailure(f"Invalid {label}: {value}") from exc
    require(parsed >= 0, f"Invalid {label}: {value}")
    return parsed


def source(adapter_sha256: str) -> dict[str, str]:
    return {
        "collector": "ConvertFrom-NxbStorageEventExport.ps1",
        "kind": "etw_summary",
        "provenance_sha256": adapter_sha256,
    }


def attribution(count: int, unattributed_count: int) -> str:
    if count == 0 or unattributed_count == 0:
        return "complete"
    if unattributed_count == count:
        return "none"
    return "partial"


def measured_process(
    count: int,
    byte_count: int | None,
    adapter_sha256: str,
) -> dict[str, Any]:
    return {
        "status": "measured",
        "count": count,
        "bytes": byte_count,
        "latency_us": None,
        "source": source(adapter_sha256),
        "reason": None,
    }


def unmeasured_process(reason: str) -> dict[str, Any]:
    return {
        "status": "not_assessed",
        "count": None,
        "bytes": None,
        "latency_us": None,
        "source": None,
        "reason": reason,
    }


def measured_aggregate(
    count: int,
    byte_count: int | None,
    unattributed_count: int,
    adapter_sha256: str,
) -> dict[str, Any]:
    return {
        "status": "measured",
        "count": count,
        "bytes": byte_count,
        "latency_us": None,
        "unattributed_count": unattributed_count,
        "attribution": attribution(count, unattributed_count),
        "source": source(adapter_sha256),
        "reason": None,
    }


def unmeasured_aggregate(reason: str) -> dict[str, Any]:
    return {
        "status": "not_assessed",
        "count": None,
        "bytes": None,
        "latency_us": None,
        "unattributed_count": None,
        "attribution": "none",
        "source": None,
        "reason": reason,
    }


def unmeasured_metric(reason: str) -> dict[str, Any]:
    return {
        "status": "not_assessed",
        "statistics": None,
        "source": None,
        "reason": reason,
    }


def load_rows(
    path: Path,
    covered: set[str],
    max_event_count: int,
) -> list[dict[str, Any]]:
    require(path.is_file(), f"Storage event export not found: {path}")
    require(max_event_count > 0, "MaxEventCount must be positive")

    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        require(
            reader.fieldnames == EXPECTED_HEADER,
            "Storage event export header mismatch. Expected: "
            + ",".join(EXPECTED_HEADER),
        )
        for source_row in reader:
            require(
                len(rows) < max_event_count,
                f"Storage event export exceeds MaxEventCount: > {max_event_count}",
            )
            event_type = str(source_row["event_type"] or "").strip()
            require(event_type in EVENT_TYPES, f"Unsupported storage event_type: {event_type}")
            require(
                event_type in covered,
                f"Event type is not declared in CoveredEventType: {event_type}",
            )
            timestamp_raw = str(source_row["timestamp_raw"] or "").strip()
            require(bool(timestamp_raw), "timestamp_raw is required for every normalized row")

            process_id = parse_optional_non_negative_int(
                str(source_row["process_id"] or ""),
                "process_id",
            )
            thread_id = parse_optional_non_negative_int(
                str(source_row["thread_id"] or ""),
                "thread_id",
            )
            disk_number = parse_optional_non_negative_int(
                str(source_row["disk_number"] or ""),
                "disk_number",
            )
            offset_bytes = parse_optional_non_negative_int(
                str(source_row["offset_bytes"] or ""),
                "offset_bytes",
            )
            transfer_bytes = parse_optional_non_negative_int(
                str(source_row["transfer_bytes"] or ""),
                "transfer_bytes",
            )

            rows.append(
                {
                    "event_type": event_type,
                    "timestamp_raw": timestamp_raw,
                    "process_id": process_id,
                    "thread_id": thread_id,
                    "disk_number": disk_number,
                    "file_key": str(source_row["file_key"] or "").strip() or None,
                    "path": str(source_row["path"] or "").strip() or None,
                    "offset_bytes": offset_bytes,
                    "transfer_bytes": transfer_bytes,
                }
            )
    return rows


def byte_total_or_none(rows: list[dict[str, Any]], event_type: str) -> int | None:
    if event_type not in BYTE_EVENT_TYPES:
        return None
    if not rows:
        return 0
    if any(row["transfer_bytes"] is None for row in rows):
        return None
    return sum(int(row["transfer_bytes"]) for row in rows)


def build_document(args: argparse.Namespace) -> dict[str, Any]:
    trace_start = parse_utc(args.trace_start_utc, "trace_start_utc")
    trace_end = parse_utc(args.trace_end_utc, "trace_end_utc")
    target_start = parse_utc(
        args.target_process_start_utc,
        "target_process_start_utc",
    )
    require(trace_start <= trace_end, "TraceStartUtc cannot be after TraceEndUtc")
    require(target_start <= trace_end, "TargetProcessStartUtc cannot be after TraceEndUtc")
    require(args.target_process_id > 0, "TargetProcessId must be positive")

    covered = set(args.covered_event_type)
    require(covered, "CoveredEventType cannot be empty")
    require(
        covered.issubset(EVENT_TYPES),
        "CoveredEventType contains an unsupported storage event type",
    )

    rows = load_rows(args.input, covered, args.max_event_count)
    rows_by_event: dict[str, list[dict[str, Any]]] = defaultdict(list)
    rows_by_process: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        rows_by_event[str(row["event_type"])].append(row)
        if row["process_id"] is not None and int(row["process_id"]) > 0:
            rows_by_process[int(row["process_id"])].append(row)

    process_ids = sorted(set(rows_by_process) | {args.target_process_id})
    require(len(process_ids) <= 4096, "Process count exceeds storage summary schema limit")

    processes: list[dict[str, Any]] = []
    for process_id in process_ids:
        process_rows = rows_by_process.get(process_id, [])
        process_events: dict[str, dict[str, Any]] = {}
        for event_type in EVENT_TYPES:
            if event_type in covered:
                matches = [row for row in process_rows if row["event_type"] == event_type]
                process_events[event_type] = measured_process(
                    len(matches),
                    byte_total_or_none(matches, event_type),
                    args.adapter_sha256,
                )
            else:
                process_events[event_type] = unmeasured_process(
                    "Event class was not established as covered by the real storage bridge."
                )

        is_target = process_id == args.target_process_id
        processes.append(
            {
                "process_id": process_id,
                "process_start_utc": format_utc(target_start) if is_target else None,
                "image_sha256": args.target_image_sha256 if is_target else None,
                "identity_status": "complete" if is_target else "partial",
                "is_target": is_target,
                "events": process_events,
            }
        )

    aggregate_events: dict[str, dict[str, Any]] = {}
    for event_type in EVENT_TYPES:
        if event_type in covered:
            matches = rows_by_event.get(event_type, [])
            unattributed = sum(1 for row in matches if row["process_id"] is None)
            aggregate_events[event_type] = measured_aggregate(
                len(matches),
                byte_total_or_none(matches, event_type),
                unattributed,
                args.adapter_sha256,
            )
        else:
            aggregate_events[event_type] = unmeasured_aggregate(
                "Event class was not established as covered by the real storage bridge."
            )

    metrics = {
        name: unmeasured_metric(
            "Timing units, queue semantics and representativeness are not validated in storage adapter v1."
        )
        for name in METRIC_TYPES
    }

    measured_event_count = sum(
        1 for name in EVENT_TYPES if aggregate_events[name]["status"] == "measured"
    )
    failed_event_count = sum(
        1 for name in EVENT_TYPES if aggregate_events[name]["status"] == "failed"
    )
    measured_metric_count = 0
    failed_metric_count = 0

    if failed_event_count > 0:
        evidence_completeness = "failed"
    elif measured_event_count > 0:
        evidence_completeness = "partial"
    else:
        evidence_completeness = "unavailable"

    event_export_sha256 = sha256_file(args.input)
    summary_seed = (
        args.experiment_id
        + args.trace_sha256
        + event_export_sha256
        + args.adapter_sha256
    )

    return {
        "schema_version": 1,
        "summary_id": "storage-etl-summary-"
        + hashlib.sha256(summary_seed.encode("utf-8")).hexdigest()[:32],
        "experiment_id": args.experiment_id,
        "experiment_relative_path": f"experiments/{args.experiment_id}",
        "machine_id": args.machine_id,
        "boot_id": args.boot_id,
        "trace_sha256": args.trace_sha256,
        "profile_sha256": args.profile_sha256,
        "event_export_sha256": event_export_sha256,
        "adapter_sha256": args.adapter_sha256,
        "source_format": "nxb_storage_event_export_v1",
        "trace_start_utc": format_utc(trace_start),
        "trace_end_utc": format_utc(trace_end),
        "target": {
            "process_id": args.target_process_id,
            "process_start_utc": format_utc(target_start),
            "image_sha256": args.target_image_sha256,
        },
        "quality": {
            "trace_loss": args.trace_loss,
            "circular_overwrite": args.circular_overwrite,
            "parser_completeness": args.parser_completeness,
            "unsupported_event_types": [],
            "unsupported_metrics": [],
        },
        "events": aggregate_events,
        "metrics": metrics,
        "processes": processes,
        "summary": {
            "process_count": len(processes),
            "measured_event_class_count": measured_event_count,
            "failed_event_class_count": failed_event_count,
            "measured_metric_count": measured_metric_count,
            "failed_metric_count": failed_metric_count,
            "evidence_completeness": evidence_completeness,
        },
        "claims": {
            "queue_depth_semantics": False,
            "queue_latency_semantics": False,
            "service_time_semantics": False,
            "throughput_representativeness": False,
            "iops_representativeness": False,
            "trace_completeness": "not_claimed",
        },
    }


def main() -> int:
    args = parse_args()
    try:
        document = build_document(args)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("w", encoding="utf-8", newline="") as handle:
            json.dump(document, handle, indent=2, sort_keys=False)
            handle.write("\n")
    except ConversionFailure as exc:
        print(f"storage event export conversion failed: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:
        print(f"storage event export converter error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
