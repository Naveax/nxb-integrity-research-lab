#!/usr/bin/env python3
import argparse
import csv
import hashlib
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

TCP_EVENTS = {
    "TcpSend", "TcpRecv", "TcpConnect", "TcpDisconnect", "TcpRetransmit",
    "TcpAccept", "TcpReconnect", "TcpConnectFail", "TcpCopyTcp", "TcpCopyArp",
    "TcpAckFull", "TcpAckPart", "TcpAckDup",
}
UDP_EVENTS = {"UdpSend", "UdpRecv"}


def classify_event(name: str):
    if name.startswith("Microsoft-Windows-DXGI/"):
        if "/Present/" in name:
            return "gpu", "dxgi_present"
        if "/PresentMultiplaneOverlay/" in name:
            return "gpu", "dxgi_present_mpo"
        if "/GetFrameStatistics/" in name:
            return "gpu", "dxgi_frame_statistics"
        if "/Profile/" in name:
            return "gpu", "dxgi_profile"
        if "/Factory/" in name:
            return "gpu", "dxgi_factory"
        return "gpu", "dxgi_other"
    if name.startswith("Microsoft-Windows-DNS-Client/"):
        return "network", "dns"
    if name in TCP_EVENTS:
        return "network", "tcp"
    if name in UDP_EVENTS:
        return "network", "udp"
    if name == "NetworkInterface":
        return "network", "network_interface"
    if re.fullmatch(r"P-(Start|End|DCStart|DCEnd|Zombie)", name):
        return "kernel_lifecycle", "process"
    if re.fullmatch(r"T-(Start|End|DCStart|DCEnd)", name) or name in {
        "ThreadName", "T-GUI", "GrowKernelStack"
    }:
        return "kernel_lifecycle", "thread"
    if (
        re.fullmatch(r"I-(Start|End|DCStart|DCEnd)", name)
        or name in {"ImageLoadDependence", "ImageId", "FileVersion"}
        or name.startswith("DbgId/")
    ):
        return "kernel_lifecycle", "image"
    if name.startswith("Reg"):
        return "kernel_lifecycle", "registry"
    if name in {"ProcessPerfCtr", "ProcessPerfCtrRundown"}:
        return "kernel_lifecycle", "process_perf"
    return None


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_pid(value):
    if value is None:
        return None
    match = re.search(r"\(\s*(\d+)\s*\)\s*$", value)
    if not match:
        return None
    try:
        return int(match.group(1))
    except ValueError:
        return None


def parse_int(value):
    if value is None:
        return None
    text = value.strip()
    if not text:
        return None
    try:
        return int(text, 0)
    except ValueError:
        return None


def canonical_json(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def shape_from_columns(columns, base_columns_sha256=None, opaque_tail_field_count=0):
    columns_sha = sha256_bytes(("\n".join(columns)).encode("utf-8"))
    return {
        "columns": columns,
        "columns_sha256": columns_sha,
        "base_columns_sha256": base_columns_sha256 or columns_sha,
        "opaque_tail_field_count": opaque_tail_field_count,
    }


def header_shape(row):
    return shape_from_columns([cell.strip() for cell in row[1:]])


def extend_with_opaque_tail(schema, tail_count):
    if tail_count <= 0:
        return schema
    columns = list(schema["columns"])
    columns.extend(
        f"__xperf_opaque_tail_{index:03d}"
        for index in range(1, tail_count + 1)
    )
    return shape_from_columns(
        columns,
        base_columns_sha256=schema["base_columns_sha256"],
        opaque_tail_field_count=tail_count,
    )


def resolve_schema(name, row, active_schemas, schemas):
    """Resolve a row structurally without assigning meaning to extra payload.

    xperf dumper headers are stateful. The most recently observed header for an
    event name is authoritative for named columns. Missing trailing columns are
    padded empty. Non-empty fields emitted beyond that header are preserved as
    ordinal opaque-tail fields rather than discarded or semantically guessed.
    """
    active = active_schemas.get(name)
    if active is not None:
        expected_values = len(active["columns"])
        actual_values = len(row) - 1
        if actual_values <= expected_values:
            return active, "active_header", expected_values - actual_values, 0
        extras = row[1 + expected_values :]
        if all(not value.strip() for value in extras):
            return active, "active_header_trailing_empty_extra", 0, 0
        tail_count = actual_values - expected_values
        return (
            extend_with_opaque_tail(active, tail_count),
            "active_header_opaque_tail",
            0,
            tail_count,
        )

    candidates = schemas.get(name, {}).get(len(row), [])
    if len(candidates) == 1:
        return candidates[0], "exact_length_fallback", 0, 0
    if len(candidates) == 0:
        return None, "no_active_or_exact_schema", 0, 0
    return None, "ambiguous_exact_length_schema", 0, 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--events-output", required=True)
    parser.add_argument("--coverage-output", required=True)
    parser.add_argument("--source-head", required=True)
    parser.add_argument("--experiment-id", required=True)
    parser.add_argument("--target-pid", type=int)
    args = parser.parse_args()

    input_path = Path(args.input).resolve()
    events_output = Path(args.events_output).resolve()
    coverage_output = Path(args.coverage_output).resolve()
    if not input_path.is_file():
        raise SystemExit(f"input not found: {input_path}")
    for output in (events_output, coverage_output):
        if output.exists():
            raise SystemExit(f"output already exists: {output}")
        output.parent.mkdir(parents=True, exist_ok=True)

    schemas = defaultdict(lambda: defaultdict(list))
    header_rows = 0
    source_rows = 0
    recognized_rows = 0
    unresolved_schema_rows = 0
    malformed_rows = 0
    recognized_malformed_rows = 0
    target_pid_rows = 0
    domain_counts = Counter()
    family_counts = Counter()
    event_name_counts = Counter()
    recognized_header_shapes = set()
    normalized_count = 0
    schema_resolution_counts = Counter()
    unresolved_reason_counts = Counter()
    unresolved_event_counts = Counter()
    unresolved_row_length_counts = Counter()
    recognized_malformed_event_counts = Counter()
    trailing_missing_field_rows = 0
    trailing_missing_field_count = 0
    trailing_empty_extra_rows = 0
    opaque_tail_rows = 0
    opaque_tail_field_count = 0
    opaque_tail_shape_counts = Counter()

    with input_path.open("r", encoding="utf-8-sig", errors="replace", newline="") as handle:
        reader = csv.reader(handle, skipinitialspace=True)
        for row in reader:
            if len(row) < 2 or row[1].strip() != "TimeStamp":
                continue
            name = row[0].strip()
            shape = header_shape(row)
            existing = schemas[name][len(row)]
            if not any(item["columns_sha256"] == shape["columns_sha256"] for item in existing):
                existing.append(shape)
                header_rows += 1
                if classify_event(name):
                    recognized_header_shapes.add((name, shape["columns_sha256"]))

    active_schemas = {}
    with input_path.open("r", encoding="utf-8-sig", errors="replace", newline="") as handle, events_output.open(
        "w", encoding="utf-8", newline="\n"
    ) as output_handle:
        reader = csv.reader(handle, skipinitialspace=True)
        for row in reader:
            if len(row) < 2:
                if row:
                    malformed_rows += 1
                    malformed_name = row[0].strip()
                    if classify_event(malformed_name):
                        recognized_malformed_rows += 1
                        recognized_malformed_event_counts[malformed_name] += 1
                continue
            name = row[0].strip()
            if row[1].strip() == "TimeStamp":
                active_schemas[name] = header_shape(row)
                continue
            source_rows += 1
            classification = classify_event(name)
            if classification is None:
                continue
            recognized_rows += 1

            schema, resolution, missing_trailing, opaque_tail_count = resolve_schema(
                name, row, active_schemas, schemas
            )
            schema_resolution_counts[resolution] += 1
            if schema is None:
                unresolved_schema_rows += 1
                unresolved_reason_counts[resolution] += 1
                unresolved_event_counts[name] += 1
                unresolved_row_length_counts[f"{name}|{len(row)}"] += 1
                continue

            columns = schema["columns"]
            values = list(row[1:])
            if len(values) < len(columns):
                missing = len(columns) - len(values)
                values.extend([""] * missing)
                trailing_missing_field_rows += 1
                trailing_missing_field_count += missing
            elif len(values) > len(columns):
                extras = values[len(columns):]
                if any(value.strip() for value in extras):
                    unresolved_schema_rows += 1
                    unresolved_reason_counts["post_resolution_nonempty_extra"] += 1
                    unresolved_event_counts[name] += 1
                    unresolved_row_length_counts[f"{name}|{len(row)}"] += 1
                    continue
                values = values[: len(columns)]
                trailing_empty_extra_rows += 1

            if opaque_tail_count:
                opaque_tail_rows += 1
                opaque_tail_field_count += opaque_tail_count
                opaque_tail_shape_counts[f"{name}|{len(row)}"] += 1

            fields = {
                columns[index]: values[index].strip()
                for index in range(len(columns))
            }
            domain, family = classification
            process_display = fields.get("Process Name ( PID)")
            process_id = parse_pid(process_display)
            thread_id = parse_int(fields.get("ThreadID"))
            cpu = parse_int(fields.get("CPU"))
            timestamp_raw = fields.get("TimeStamp")
            if args.target_pid is not None and process_id == args.target_pid:
                target_pid_rows += 1
            normalized_event = {
                "schema_version": 2,
                "sequence_index": normalized_count,
                "experiment_id": args.experiment_id,
                "source_head": args.source_head.lower(),
                "source_event_name": name,
                "domain": domain,
                "event_family": family,
                "columns_sha256": schema["columns_sha256"],
                "base_columns_sha256": schema["base_columns_sha256"],
                "schema_resolution": resolution,
                "trailing_missing_field_count": missing_trailing,
                "opaque_tail_field_count": opaque_tail_count,
                "timestamp_raw": timestamp_raw,
                "process_id": process_id,
                "thread_id": thread_id,
                "cpu": cpu,
                "fields": fields,
                "claims": {
                    "event_name_mapping_only": True,
                    "active_header_structural_binding": resolution.startswith("active_header"),
                    "opaque_tail_preserved_without_semantics": opaque_tail_count > 0,
                    "opaque_tail_semantics_resolved": False,
                    "timestamp_unit_resolved": False,
                    "latency_semantics": False,
                    "queue_semantics": False,
                    "present_pairing_semantics": False,
                },
            }
            output_handle.write(canonical_json(normalized_event) + "\n")
            normalized_count += 1
            domain_counts[domain] += 1
            family_counts[f"{domain}:{family}"] += 1
            event_name_counts[name] += 1

    normalized_sha = sha256_file(events_output)
    coverage = {
        "schema_version": 3,
        "status": "passed",
        "source": {
            "head_sha": args.source_head.lower(),
            "experiment_id": args.experiment_id,
            "dumper_sha256": sha256_file(input_path),
        },
        "headers": {
            "unique_observed_shapes": header_rows,
            "recognized_shapes": len(recognized_header_shapes),
        },
        "rows": {
            "source_data_rows": source_rows,
            "recognized_candidate_rows": recognized_rows,
            "normalized_rows": normalized_count,
            "unresolved_schema_rows": unresolved_schema_rows,
            "malformed_rows": malformed_rows,
            "recognized_malformed_rows": recognized_malformed_rows,
            "target_pid_rows": target_pid_rows if args.target_pid is not None else None,
        },
        "schema_resolution": {
            "resolution_counts": dict(sorted(schema_resolution_counts.items())),
            "trailing_missing_field_rows": trailing_missing_field_rows,
            "trailing_missing_field_count": trailing_missing_field_count,
            "trailing_empty_extra_rows": trailing_empty_extra_rows,
            "opaque_tail_rows": opaque_tail_rows,
            "opaque_tail_field_count": opaque_tail_field_count,
            "opaque_tail_shape_counts": dict(sorted(opaque_tail_shape_counts.items())),
            "unresolved_reason_counts": dict(sorted(unresolved_reason_counts.items())),
            "unresolved_event_counts": dict(sorted(unresolved_event_counts.items())),
            "unresolved_row_length_counts": dict(sorted(unresolved_row_length_counts.items())),
            "recognized_malformed_event_counts": dict(sorted(recognized_malformed_event_counts.items())),
            "raw_values_in_diagnostics": False,
        },
        "domain_counts": dict(sorted(domain_counts.items())),
        "family_counts": dict(sorted(family_counts.items())),
        "event_name_counts": dict(sorted(event_name_counts.items())),
        "normalized_events_sha256": normalized_sha,
        "claims": {
            "structural_event_name_mapping": True,
            "active_header_structural_binding": True,
            "trailing_missing_columns_padded_only": True,
            "nonempty_extra_columns_discarded": False,
            "nonempty_extra_columns_preserved_as_opaque": True,
            "opaque_tail_semantics_resolved": False,
            "event_ids_validated": False,
            "keyword_semantics_validated": False,
            "timestamp_unit_resolved": False,
            "present_semantics": False,
            "gpu_queue_semantics": False,
            "network_connection_semantics": False,
            "network_latency_semantics": False,
            "kernel_lifecycle_semantics": False,
            "trace_completeness": "not_claimed",
        },
        "review_policy": {
            "normalized_event_rows_reviewable": False,
            "raw_field_values_reviewable": False,
            "coverage_counts_reviewable": True,
            "schema_diagnostics_reviewable": True,
        },
    }
    coverage_output.write_text(canonical_json(coverage) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
