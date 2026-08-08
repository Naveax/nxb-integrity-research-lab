#!/usr/bin/env python3
"""Convert a normalized NXB memory event export into summary evidence."""

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

BASE_EVENT_TYPES = (
    "hard_fault",
    "demand_zero_fault",
    "copy_on_write_fault",
    "transition_fault",
    "guard_page_fault",
    "virtual_allocation",
    "virtual_free",
    "mapped_section_create",
    "mapped_section_delete",
)
SOFT_COMPONENTS = (
    "demand_zero_fault",
    "copy_on_write_fault",
    "transition_fault",
    "guard_page_fault",
)
ALL_EVENT_TYPES = (
    "hard_fault",
    "demand_zero_fault",
    "copy_on_write_fault",
    "transition_fault",
    "guard_page_fault",
    "soft_fault_total",
    "virtual_allocation",
    "virtual_free",
    "mapped_section_create",
    "mapped_section_delete",
)
BYTE_EVENT_TYPES = {"hard_fault", "virtual_allocation", "virtual_free"}
EXPECTED_HEADER = [
    "event_type",
    "timestamp_us",
    "process_id",
    "thread_id",
    "size_bytes",
]


class ConversionFailure(ValueError):
    """Raised when normalized event export conversion must fail closed."""


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


def source(adapter_sha256: str) -> dict[str, str]:
    return {
        "collector": "ConvertFrom-NxbMemoryEventExport.ps1",
        "kind": "etw_summary",
        "provenance_sha256": adapter_sha256,
    }


def measured_process(
    count: int,
    byte_count: int | None,
    adapter_sha256: str,
) -> dict[str, Any]:
    return {
        "status": "measured",
        "count": count,
        "bytes": byte_count,
        "source": source(adapter_sha256),
        "reason": None,
    }


def unmeasured_process(reason: str) -> dict[str, Any]:
    return {
        "status": "not_assessed",
        "count": None,
        "bytes": None,
        "source": None,
        "reason": reason,
    }


def attribution(count: int, unattributed_count: int) -> str:
    if unattributed_count == 0:
        return "complete"
    if unattributed_count == count:
        return "none"
    return "partial"


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
        "unattributed_count": None,
        "attribution": "none",
        "source": None,
        "reason": reason,
    }


def parse_non_negative_int(value: str, label: str) -> int:
    try:
        parsed = int(value, 10)
    except ValueError as exc:
        raise ConversionFailure(f"Invalid {label}: {value}") from exc
    require(parsed >= 0, f"Invalid {label}: {value}")
    return parsed


def load_rows(
    path: Path,
    covered: set[str],
    duration_us: int,
    max_event_count: int,
) -> list[dict[str, Any]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        require(
            reader.fieldnames == EXPECTED_HEADER,
            "Memory event export header mismatch. Expected: "
            + ",".join(EXPECTED_HEADER),
        )
        rows: list[dict[str, Any]] = []
        for source_row in reader:
            require(
                len(rows) < max_event_count,
                f"Memory event export exceeds MaxEventCount: > {max_event_count}",
            )
            event_type = str(source_row["event_type"])
            require(
                event_type in BASE_EVENT_TYPES,
                f"Unsupported memory event_type: {event_type}",
            )
            require(
                event_type in covered,
                f"Event type is not declared in CoveredEventType: {event_type}",
            )
            timestamp_us = parse_non_negative_int(
                str(source_row["timestamp_us"]),
                "timestamp_us",
            )
            require(
                timestamp_us <= duration_us,
                f"timestamp_us exceeds the declared trace range: {timestamp_us}",
            )
            process_id = parse_non_negative_int(
                str(source_row["process_id"]),
                "process_id",
            )
            thread_id = parse_non_negative_int(
                str(source_row["thread_id"]),
                "thread_id",
            )
            raw_size = str(source_row["size_bytes"] or "").strip()
            size_bytes = (
                parse_non_negative_int(raw_size, "size_bytes")
                if raw_size
                else None
            )
            if event_type in BYTE_EVENT_TYPES:
                require(
                    size_bytes is not None,
                    f"size_bytes is required for event_type: {event_type}",
                )
            rows.append(
                {
                    "event_type": event_type,
                    "timestamp_us": timestamp_us,
                    "process_id": process_id,
                    "thread_id": thread_id,
                    "size_bytes": size_bytes,
                }
            )
    return rows


def byte_total(rows: list[dict[str, Any]]) -> int:
    return sum(
        int(row["size_bytes"])
        for row in rows
        if row["size_bytes"] is not None
    )


def build_document(args: argparse.Namespace) -> dict[str, Any]:
    trace_start = parse_utc(args.trace_start_utc, "trace_start_utc")
    trace_end = parse_utc(args.trace_end_utc, "trace_end_utc")
    target_start = parse_utc(
        args.target_process_start_utc,
        "target_process_start_utc",
    )
    require(trace_start <= trace_end, "TraceStartUtc cannot be after TraceEndUtc.")
    require(
        target_start <= trace_end,
        "TargetProcessStartUtc cannot be after TraceEndUtc.",
    )
    require(args.target_process_id > 0, "TargetProcessId must be positive")
    require(args.max_event_count > 0, "MaxEventCount must be positive")

    covered = set(args.covered_event_type)
    require(
        covered.issubset(BASE_EVENT_TYPES),
        "CoveredEventType contains an unsupported event type",
    )
    duration_us = int((trace_end - trace_start).total_seconds() * 1_000_000)
    rows = load_rows(args.input, covered, duration_us, args.max_event_count)

    rows_by_event: dict[str, list[dict[str, Any]]] = defaultdict(list)
    rows_by_process: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        rows_by_event[str(row["event_type"])].append(row)
        if int(row["process_id"]) > 0:
            rows_by_process[int(row["process_id"])].append(row)

    process_ids = sorted(set(rows_by_process) | {args.target_process_id})
    processes: list[dict[str, Any]] = []
    for process_id in process_ids:
        process_rows = rows_by_process.get(process_id, [])
        process_events: dict[str, dict[str, Any]] = {}
        for event_type in BASE_EVENT_TYPES:
            if event_type in covered:
                matches = [
                    row
                    for row in process_rows
                    if row["event_type"] == event_type
                ]
                process_events[event_type] = measured_process(
                    len(matches),
                    byte_total(matches)
                    if event_type in BYTE_EVENT_TYPES
                    else None,
                    args.adapter_sha256,
                )
            else:
                process_events[event_type] = unmeasured_process(
                    "Event class was not declared in CoveredEventType."
                )

        if set(SOFT_COMPONENTS).issubset(covered):
            soft_count = sum(
                int(process_events[name]["count"])
                for name in SOFT_COMPONENTS
            )
            process_events["soft_fault_total"] = measured_process(
                soft_count,
                None,
                args.adapter_sha256,
            )
        else:
            process_events["soft_fault_total"] = unmeasured_process(
                "Soft-fault total requires coverage of all component classes."
            )

        ordered_process_events = {
            name: process_events[name] for name in ALL_EVENT_TYPES
        }
        is_target = process_id == args.target_process_id
        processes.append(
            {
                "process_id": process_id,
                "process_start_utc": (
                    format_utc(target_start) if is_target else None
                ),
                "image_sha256": (
                    args.target_image_sha256 if is_target else None
                ),
                "identity_status": "complete" if is_target else "partial",
                "is_target": is_target,
                "events": ordered_process_events,
            }
        )

    aggregate_events: dict[str, dict[str, Any]] = {}
    for event_type in BASE_EVENT_TYPES:
        if event_type in covered:
            matches = rows_by_event.get(event_type, [])
            unattributed_count = sum(
                1 for row in matches if int(row["process_id"]) == 0
            )
            aggregate_events[event_type] = measured_aggregate(
                len(matches),
                byte_total(matches)
                if event_type in BYTE_EVENT_TYPES
                else None,
                unattributed_count,
                args.adapter_sha256,
            )
        else:
            aggregate_events[event_type] = unmeasured_aggregate(
                "Event class was not declared in CoveredEventType."
            )

    if set(SOFT_COMPONENTS).issubset(covered):
        soft_count = sum(
            int(aggregate_events[name]["count"])
            for name in SOFT_COMPONENTS
        )
        soft_unattributed = sum(
            int(aggregate_events[name]["unattributed_count"])
            for name in SOFT_COMPONENTS
        )
        aggregate_events["soft_fault_total"] = measured_aggregate(
            soft_count,
            None,
            soft_unattributed,
            args.adapter_sha256,
        )
    else:
        aggregate_events["soft_fault_total"] = unmeasured_aggregate(
            "Soft-fault total requires coverage of all component classes."
        )

    ordered_aggregates = {
        name: aggregate_events[name] for name in ALL_EVENT_TYPES
    }
    measured_count = sum(
        1
        for entry in ordered_aggregates.values()
        if entry["status"] == "measured"
    )
    failed_count = sum(
        1
        for entry in ordered_aggregates.values()
        if entry["status"] == "failed"
    )
    parser_completeness = (
        "complete" if covered == set(BASE_EVENT_TYPES) else "partial"
    )
    if failed_count > 0:
        evidence_completeness = "failed"
    elif (
        measured_count == len(ALL_EVENT_TYPES)
        and args.trace_loss == "none"
        and args.circular_overwrite == "none"
        and parser_completeness == "complete"
    ):
        evidence_completeness = "complete"
    elif measured_count > 0:
        evidence_completeness = "partial"
    else:
        evidence_completeness = "unavailable"

    export_sha256 = sha256_file(args.input)
    summary_seed = (
        args.experiment_id
        + args.trace_sha256
        + export_sha256
        + args.adapter_sha256
    )
    return {
        "schema_version": 1,
        "summary_id": "memory-etl-summary-"
        + hashlib.sha256(summary_seed.encode("utf-8")).hexdigest()[:32],
        "experiment_id": args.experiment_id,
        "experiment_relative_path": f"experiments/{args.experiment_id}",
        "machine_id": args.machine_id,
        "boot_id": args.boot_id,
        "trace_sha256": args.trace_sha256,
        "profile_sha256": args.profile_sha256,
        "event_export_sha256": export_sha256,
        "adapter_sha256": args.adapter_sha256,
        "source_format": "nxb_memory_event_export_v1",
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
            "parser_completeness": parser_completeness,
            "unsupported_event_types": [],
        },
        "events": ordered_aggregates,
        "processes": processes,
        "summary": {
            "process_count": len(processes),
            "measured_event_class_count": measured_count,
            "failed_event_class_count": failed_count,
            "evidence_completeness": evidence_completeness,
        },
        "claims": {
            "hard_fault_absence": False,
            "soft_fault_absence": False,
            "virtual_memory_balance": False,
            "trace_completeness": "not_claimed",
        },
    }


def main() -> int:
    args = parse_args()
    try:
        document = build_document(args)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("w", encoding="utf-8", newline="\n") as handle:
            json.dump(
                document,
                handle,
                ensure_ascii=True,
                separators=(",", ":"),
            )
            handle.write("\n")
    except (ConversionFailure, OSError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
