#!/usr/bin/env python3
"""Build a conservative storage ETL summary from normalized xperf storage rows."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

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

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9._:-]+$")


class SummaryFailure(ValueError):
    """Raised when summary generation must fail closed."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SummaryFailure(message)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--event-export", required=True, type=Path)
    parser.add_argument("--bridge-manifest", required=True, type=Path)
    parser.add_argument("--capture-receipt", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--adapter-sha256", required=True)
    parser.add_argument("--experiment-id", required=True)
    parser.add_argument("--max-process-count", type=int, default=4096)
    return parser.parse_args()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_json(path: Path, label: str) -> dict[str, Any]:
    require(path.is_file(), f"{label} not found: {path}")
    try:
        with path.open("r", encoding="utf-8-sig") as handle:
            document = json.load(handle)
    except json.JSONDecodeError as exc:
        raise SummaryFailure(
            f"Invalid {label} JSON at line {exc.lineno}, column {exc.colno}: {exc.msg}"
        ) from exc
    require(isinstance(document, dict), f"{label} must be a JSON object")
    return document


def parse_optional_nonnegative_int(value: str, label: str) -> int | None:
    text = value.strip()
    if not text:
        return None
    try:
        parsed = int(text, 10)
    except ValueError as exc:
        raise SummaryFailure(f"Invalid {label}: {value}") from exc
    require(parsed >= 0, f"Invalid {label}: {value}")
    return parsed


def measured_source(adapter_sha256: str) -> dict[str, Any]:
    return {
        "collector": "ConvertFrom-NxbStorageEventExport.ps1",
        "kind": "etw_summary",
        "provenance_sha256": adapter_sha256,
    }


def not_assessed_event(reason: str, aggregate: bool) -> dict[str, Any]:
    result: dict[str, Any] = {
        "status": "not_assessed",
        "count": None,
        "bytes": None,
        "latency_us": None,
        "source": None,
        "reason": reason,
    }
    if aggregate:
        result["unattributed_count"] = None
        result["attribution"] = "none"
    return result


def measured_event(
    count: int,
    byte_total: int | None,
    source: dict[str, Any],
    *,
    aggregate: bool,
    unattributed_count: int = 0,
    attribution: str = "complete",
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "status": "measured",
        "count": count,
        "bytes": byte_total,
        "latency_us": None,
        "source": source,
        "reason": None,
    }
    if aggregate:
        result["unattributed_count"] = unattributed_count
        result["attribution"] = attribution
    return result


def build_summary(args: argparse.Namespace) -> dict[str, Any]:
    require(args.event_export.is_file(), f"event export not found: {args.event_export}")
    require(args.max_process_count >= 1, "max-process-count must be positive")
    require(SHA256_RE.fullmatch(args.adapter_sha256) is not None, "adapter-sha256 must be lowercase SHA-256")
    require(IDENTIFIER_RE.fullmatch(args.experiment_id) is not None, "experiment-id is invalid")
    require(len(args.experiment_id) <= 128, "experiment-id is too long")
    require(not args.output.exists(), f"output already exists: {args.output}")

    bridge = load_json(args.bridge_manifest, "bridge manifest")
    capture = load_json(args.capture_receipt, "capture receipt")

    event_export_sha256 = sha256_file(args.event_export)
    require(bridge.get("schema_version") == 1, "bridge manifest schema_version must be 1")
    require(bridge.get("source_format") == "xperf_storage_dumper_text_v1", "unexpected bridge source_format")
    require(bridge.get("normalized_csv_sha256") == event_export_sha256, "bridge manifest normalized CSV hash mismatch")
    require(bridge.get("parser_completeness") == "partial", "bridge parser_completeness must remain partial")
    require(bridge.get("timing", {}).get("normalized_duration_us_available") is False, "bridge must not expose normalized duration_us")

    require(capture.get("status") == "passed", "capture receipt status must be passed")
    evidence = capture.get("evidence", {})
    require(bridge.get("input_sha256") == evidence.get("dumper_sha256"), "capture dumper hash does not match bridge input hash")

    profile = capture.get("profile", {})
    workload = capture.get("workload", {})
    quality = capture.get("trace_quality", {})
    for label, value in (
        ("capture boot_id", capture.get("boot_id")),
        ("capture ETL SHA-256", evidence.get("etl_sha256")),
        ("capture profile SHA-256", profile.get("sha256")),
        ("target image SHA-256", workload.get("image_sha256")),
    ):
        require(isinstance(value, str) and SHA256_RE.fullmatch(value) is not None, f"{label} is invalid")

    target_pid = workload.get("process_id")
    require(isinstance(target_pid, int) and target_pid > 0, "target process_id is invalid")
    require(isinstance(workload.get("process_start_utc"), str), "target process_start_utc is missing")
    require(isinstance(capture.get("trace_started_utc"), str), "trace_started_utc is missing")
    require(isinstance(capture.get("trace_stopped_utc"), str), "trace_stopped_utc is missing")

    trace_loss = quality.get("trace_loss")
    circular_overwrite = quality.get("circular_overwrite")
    require(trace_loss in {"none", "present", "unknown"}, "capture trace_loss is invalid")
    require(circular_overwrite in {"none", "possible", "confirmed", "unknown"}, "capture circular_overwrite is invalid")

    event_counts: dict[str, int] = defaultdict(int)
    event_bytes: dict[str, int] = defaultdict(int)
    event_bytes_complete: dict[str, bool] = defaultdict(lambda: True)
    event_unattributed: dict[str, int] = defaultdict(int)
    process_counts: dict[int, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    process_bytes: dict[int, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    process_bytes_complete: dict[int, dict[str, bool]] = defaultdict(lambda: defaultdict(lambda: True))
    positive_processes: set[int] = set()
    row_count = 0

    with args.event_export.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        required_columns = {
            "event_type",
            "process_id",
            "transfer_bytes",
        }
        require(reader.fieldnames is not None, "event export has no header")
        require(required_columns.issubset(set(reader.fieldnames)), "event export header is missing required columns")

        for row_number, row in enumerate(reader, start=2):
            row_count += 1
            event_type = (row.get("event_type") or "").strip()
            require(event_type in EVENT_KEYS, f"unknown event_type at CSV row {row_number}: {event_type}")
            process_id = parse_optional_nonnegative_int(row.get("process_id") or "", f"process_id at row {row_number}")
            transfer_bytes = parse_optional_nonnegative_int(row.get("transfer_bytes") or "", f"transfer_bytes at row {row_number}")

            event_counts[event_type] += 1
            if transfer_bytes is None:
                event_bytes_complete[event_type] = False
            else:
                event_bytes[event_type] += transfer_bytes

            if process_id is None or process_id == 0:
                event_unattributed[event_type] += 1
                continue

            positive_processes.add(process_id)
            require(len(positive_processes) <= args.max_process_count, f"process count exceeds max-process-count={args.max_process_count}")
            process_counts[process_id][event_type] += 1
            if transfer_bytes is None:
                process_bytes_complete[process_id][event_type] = False
            else:
                process_bytes[process_id][event_type] += transfer_bytes

    require(row_count > 0, "event export contains no rows")
    require(row_count == int(bridge.get("normalized_event_count", -1)), "bridge normalized_event_count does not match CSV row count")
    require(target_pid in positive_processes, "target process has no attributed normalized rows")

    source = measured_source(args.adapter_sha256)
    process_ids = sorted(positive_processes)
    process_documents: list[dict[str, Any]] = []

    for process_id in process_ids:
        is_target = process_id == target_pid
        process_events: dict[str, Any] = {}
        for event_type in EVENT_KEYS:
            count = process_counts[process_id].get(event_type, 0)
            if count == 0:
                process_events[event_type] = not_assessed_event(
                    "No normalized rows for this process/event class; absence is not interpreted as zero.",
                    aggregate=False,
                )
            else:
                byte_total = (
                    process_bytes[process_id].get(event_type, 0)
                    if process_bytes_complete[process_id].get(event_type, True)
                    else None
                )
                process_events[event_type] = measured_event(count, byte_total, source, aggregate=False)

        process_documents.append(
            {
                "process_id": process_id,
                "process_start_utc": workload["process_start_utc"] if is_target else None,
                "image_sha256": workload["image_sha256"] if is_target else None,
                "identity_status": "complete" if is_target else "partial",
                "is_target": is_target,
                "events": process_events,
            }
        )

    aggregate_events: dict[str, Any] = {}
    for event_type in EVENT_KEYS:
        count = event_counts.get(event_type, 0)
        if count == 0:
            aggregate_events[event_type] = not_assessed_event(
                "No normalized rows observed for this event class; absence is not interpreted as zero.",
                aggregate=True,
            )
            continue

        unattributed = event_unattributed.get(event_type, 0)
        processes_with_event = sum(
            1 for process_id in process_ids if process_counts[process_id].get(event_type, 0) > 0
        )
        if processes_with_event == 0:
            attribution = "none"
        elif unattributed == 0 and processes_with_event == len(process_ids):
            attribution = "complete"
        else:
            attribution = "partial"

        byte_total = event_bytes.get(event_type, 0) if event_bytes_complete.get(event_type, True) else None
        aggregate_events[event_type] = measured_event(
            count,
            byte_total,
            source,
            aggregate=True,
            unattributed_count=unattributed,
            attribution=attribution,
        )

    metrics = {
        name: {
            "status": "not_assessed",
            "statistics": None,
            "source": None,
            "reason": "Native timing/queue semantics remain unresolved in the validated raw bridge.",
        }
        for name in METRIC_KEYS
    }

    measured_event_count = sum(1 for name in EVENT_KEYS if aggregate_events[name]["status"] == "measured")

    document = {
        "schema_version": 1,
        "summary_id": f"{args.experiment_id}.storage",
        "experiment_id": args.experiment_id,
        "experiment_relative_path": f"experiments/{args.experiment_id}",
        "machine_id": str(capture.get("machine_id")),
        "boot_id": capture["boot_id"],
        "trace_sha256": evidence["etl_sha256"],
        "profile_sha256": profile["sha256"],
        "event_export_sha256": event_export_sha256,
        "adapter_sha256": args.adapter_sha256,
        "source_format": "nxb_storage_event_export_v1",
        "trace_start_utc": capture["trace_started_utc"],
        "trace_end_utc": capture["trace_stopped_utc"],
        "target": {
            "process_id": target_pid,
            "process_start_utc": workload["process_start_utc"],
            "image_sha256": workload["image_sha256"],
        },
        "quality": {
            "trace_loss": trace_loss,
            "circular_overwrite": circular_overwrite,
            "parser_completeness": "partial",
            "unsupported_event_types": [],
            "unsupported_metrics": [],
        },
        "events": aggregate_events,
        "metrics": metrics,
        "processes": process_documents,
        "summary": {
            "process_count": len(process_documents),
            "measured_event_class_count": measured_event_count,
            "failed_event_class_count": 0,
            "measured_metric_count": 0,
            "failed_metric_count": 0,
            "evidence_completeness": "partial",
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
    return document


def main() -> int:
    args = parse_args()
    try:
        document = build_summary(args)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("x", encoding="utf-8", newline="") as handle:
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write("\n")
    except SummaryFailure as exc:
        print(f"storage summary generation failed: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:
        print(f"storage summary adapter error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
