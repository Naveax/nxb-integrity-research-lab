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
    target_pid_rows = 0
    domain_counts = Counter()
    family_counts = Counter()
    event_name_counts = Counter()
    recognized_header_shapes = set()
    normalized_count = 0

    with input_path.open("r", encoding="utf-8-sig", errors="replace", newline="") as handle:
        reader = csv.reader(handle, skipinitialspace=True)
        for row in reader:
            if len(row) < 2 or row[1].strip() != "TimeStamp":
                continue
            name = row[0].strip()
            columns = [cell.strip() for cell in row[1:]]
            columns_sha = sha256_bytes(("\n".join(columns)).encode("utf-8"))
            shape = {"columns": columns, "columns_sha256": columns_sha}
            existing = schemas[name][len(row)]
            if not any(item["columns_sha256"] == columns_sha for item in existing):
                existing.append(shape)
                header_rows += 1
                if classify_event(name):
                    recognized_header_shapes.add((name, columns_sha))

    with input_path.open("r", encoding="utf-8-sig", errors="replace", newline="") as handle, events_output.open(
        "w", encoding="utf-8", newline="\n"
    ) as output_handle:
        reader = csv.reader(handle, skipinitialspace=True)
        for row in reader:
            if len(row) < 2:
                if row:
                    malformed_rows += 1
                continue
            if row[1].strip() == "TimeStamp":
                continue
            source_rows += 1
            name = row[0].strip()
            classification = classify_event(name)
            if classification is None:
                continue
            recognized_rows += 1
            candidates = schemas.get(name, {}).get(len(row), [])
            if len(candidates) != 1:
                unresolved_schema_rows += 1
                continue
            schema = candidates[0]
            columns = schema["columns"]
            values = row[1:]
            fields = {
                columns[index]: values[index].strip() if index < len(values) else ""
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
            event = {
                "schema_version": 1,
                "sequence_index": normalized_count,
                "experiment_id": args.experiment_id,
                "source_head": args.source_head.lower(),
                "source_event_name": name,
                "domain": domain,
                "event_family": family,
                "columns_sha256": schema["columns_sha256"],
                "timestamp_raw": timestamp_raw,
                "process_id": process_id,
                "thread_id": thread_id,
                "cpu": cpu,
                "fields": fields,
                "claims": {
                    "event_name_mapping_only": True,
                    "timestamp_unit_resolved": False,
                    "latency_semantics": False,
                    "queue_semantics": False,
                    "present_pairing_semantics": False,
                },
            }
            output_handle.write(canonical_json(event) + "\n")
            normalized_count += 1
            domain_counts[domain] += 1
            family_counts[f"{domain}:{family}"] += 1
            event_name_counts[name] += 1

    normalized_sha = sha256_file(events_output)
    coverage = {
        "schema_version": 1,
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
            "target_pid_rows": target_pid_rows if args.target_pid is not None else None,
        },
        "domain_counts": dict(sorted(domain_counts.items())),
        "family_counts": dict(sorted(family_counts.items())),
        "event_name_counts": dict(sorted(event_name_counts.items())),
        "normalized_events_sha256": normalized_sha,
        "claims": {
            "structural_event_name_mapping": True,
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
        },
    }
    coverage_output.write_text(canonical_json(coverage) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
