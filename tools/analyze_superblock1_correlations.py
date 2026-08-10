#!/usr/bin/env python3
import argparse
import bisect
import hashlib
import json
import statistics
from collections import Counter, defaultdict, deque
from pathlib import Path


def canonical_json(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stable_hash(value) -> str:
    return hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()


def selected_field_items(event, tokens):
    fields = event.get("fields") or {}
    selected = []
    for key in sorted(fields, key=lambda item: item.casefold()):
        lower = key.casefold()
        if key.startswith("__xperf_opaque_tail_"):
            continue
        if not any(token in lower for token in tokens):
            continue
        value = fields.get(key)
        if value is None:
            continue
        text = str(value).strip()
        if not text:
            continue
        selected.append((key, text))
    return selected


def correlation_key(event, kind):
    process_id = event.get("process_id")
    thread_id = event.get("thread_id")
    if kind == "present":
        selected = selected_field_items(event, ("swapchain", "presentid", "hwnd"))
        basis = "pid+named_present_identifier" if selected else "pid_only"
        components = {"process_id": process_id, "named": selected}
        if process_id is None and not selected:
            return None, "unkeyed"
    elif kind == "thread":
        components = {"process_id": process_id, "thread_id": thread_id}
        basis = "pid+tid" if process_id is not None and thread_id is not None else "partial_pid_tid"
        if process_id is None and thread_id is None:
            return None, "unkeyed"
    elif kind == "image":
        selected = selected_field_items(
            event,
            ("image name", "image file", "file name", "imagebase", "baseaddress", "image base"),
        )
        components = {"process_id": process_id, "named": selected}
        basis = "pid+named_image_identifier" if selected else "pid_only"
        if process_id is None and not selected:
            return None, "unkeyed"
    else:
        components = {"process_id": process_id}
        basis = "pid"
        if process_id is None:
            return None, "unkeyed"
    return stable_hash(components), basis


def pair_events(events, label, start_names, stop_names, key_kind):
    pending = defaultdict(deque)
    basis_counts = Counter()
    pairs = []
    unkeyed_starts = 0
    unkeyed_stops = 0
    unmatched_stops = 0

    for event in events:
        name = event.get("source_event_name")
        if name not in start_names and name not in stop_names:
            continue
        key_hash, basis = correlation_key(event, key_kind)
        basis_counts[basis] += 1
        if key_hash is None:
            if name in start_names:
                unkeyed_starts += 1
            else:
                unkeyed_stops += 1
            continue
        if name in start_names:
            pending[key_hash].append((event, basis))
            continue
        queue = pending.get(key_hash)
        if not queue:
            unmatched_stops += 1
            continue
        start_event, start_basis = queue.popleft()
        stop_index = int(event["sequence_index"])
        start_index = int(start_event["sequence_index"])
        pairs.append(
            {
                "record_type": "structural_pair",
                "pair_type": label,
                "key_sha256": key_hash,
                "key_basis": start_basis,
                "start_sequence_index": start_index,
                "stop_sequence_index": stop_index,
                "sequence_delta": stop_index - start_index,
                "process_id": start_event.get("process_id"),
                "thread_id": start_event.get("thread_id"),
                "claims": {
                    "sequence_order_only": True,
                    "sequence_delta_is_time": False,
                    "pair_semantics_validated": False,
                },
            }
        )

    unmatched_starts = sum(len(queue) for queue in pending.values())
    deltas = [item["sequence_delta"] for item in pairs]
    summary = {
        "pair_count": len(pairs),
        "unmatched_starts": unmatched_starts,
        "unmatched_stops": unmatched_stops,
        "unkeyed_starts": unkeyed_starts,
        "unkeyed_stops": unkeyed_stops,
        "key_basis_counts": dict(sorted(basis_counts.items())),
        "sequence_delta": {
            "minimum": min(deltas) if deltas else None,
            "median": statistics.median(deltas) if deltas else None,
            "maximum": max(deltas) if deltas else None,
            "unit": "event_sequence_index",
            "time_unit_resolved": False,
        },
    }
    return pairs, summary


def hashed_group_key(event, tokens, label):
    selected = selected_field_items(event, tokens)
    components = {"process_id": event.get("process_id"), "named": selected}
    if not selected:
        return stable_hash(components), "pid_only"
    return stable_hash(components), f"pid+named_{label}_identifier"


def summarize_tcp(events, target_pid):
    groups = defaultdict(lambda: {"names": Counter(), "sequences": defaultdict(list), "rows": 0})
    basis_counts = Counter()
    total = 0
    target_rows = 0
    for event in events:
        if event.get("event_family") != "tcp":
            continue
        total += 1
        if event.get("process_id") == target_pid:
            target_rows += 1
        key_hash, basis = hashed_group_key(event, ("addr", "address", "port"), "network")
        basis_counts[basis] += 1
        group = groups[key_hash]
        name = str(event.get("source_event_name"))
        group["names"][name] += 1
        group["sequences"][name].append(int(event["sequence_index"]))
        group["rows"] += 1

    def count_with(name):
        return sum(1 for group in groups.values() if group["names"].get(name, 0) > 0)

    connect_disconnect = 0
    ordered_connect_disconnect = 0
    bidirectional = 0
    for group in groups.values():
        names = group["names"]
        if names.get("TcpConnect", 0) and names.get("TcpDisconnect", 0):
            connect_disconnect += 1
            if min(group["sequences"]["TcpConnect"]) < max(group["sequences"]["TcpDisconnect"]):
                ordered_connect_disconnect += 1
        if names.get("TcpSend", 0) and names.get("TcpRecv", 0):
            bidirectional += 1

    return {
        "row_count": total,
        "target_pid_rows": target_rows,
        "structural_key_count": len(groups),
        "key_basis_counts": dict(sorted(basis_counts.items())),
        "keys_with_connect": count_with("TcpConnect"),
        "keys_with_disconnect": count_with("TcpDisconnect"),
        "keys_with_send": count_with("TcpSend"),
        "keys_with_recv": count_with("TcpRecv"),
        "keys_with_retransmit": count_with("TcpRetransmit"),
        "keys_with_connect_and_disconnect": connect_disconnect,
        "keys_with_connect_before_disconnect": ordered_connect_disconnect,
        "keys_with_send_and_recv": bidirectional,
        "claims": {
            "hashed_structural_grouping": True,
            "connection_lifecycle_validated": False,
            "network_latency_semantics": False,
        },
    }


def summarize_activity(events, family, tokens, label, target_pid):
    groups = Counter()
    basis_counts = Counter()
    total = 0
    target_rows = 0
    for event in events:
        if event.get("event_family") != family:
            continue
        total += 1
        if event.get("process_id") == target_pid:
            target_rows += 1
        key_hash, basis = hashed_group_key(event, tokens, label)
        groups[key_hash] += 1
        basis_counts[basis] += 1
    return {
        "row_count": total,
        "target_pid_rows": target_rows,
        "structural_key_count": len(groups),
        "key_basis_counts": dict(sorted(basis_counts.items())),
        "claims": {
            "hashed_structural_grouping": True,
            "payload_semantics_validated": False,
        },
    }


def target_pid_summary(events, target_pid):
    domain_counts = Counter()
    family_counts = Counter()
    thread_ids = set()
    target_events = []
    kernel_sequences = []
    for event in events:
        if event.get("process_id") != target_pid:
            continue
        target_events.append(event)
        domain = str(event.get("domain"))
        family = str(event.get("event_family"))
        domain_counts[domain] += 1
        family_counts[f"{domain}:{family}"] += 1
        if event.get("thread_id") is not None:
            thread_ids.add(int(event["thread_id"]))
        if domain == "kernel_lifecycle":
            kernel_sequences.append(int(event["sequence_index"]))

    kernel_sequences.sort()
    adjacency = Counter()
    anchors = 0
    with_neighbor = 0
    for event in target_events:
        if event.get("domain") not in {"gpu", "network"}:
            continue
        anchors += 1
        index = int(event["sequence_index"])
        pos = bisect.bisect_left(kernel_sequences, index)
        candidates = []
        if pos > 0:
            candidates.append(abs(index - kernel_sequences[pos - 1]))
        if pos < len(kernel_sequences):
            candidates.append(abs(kernel_sequences[pos] - index))
        if not candidates:
            continue
        with_neighbor += 1
        delta = min(candidates)
        if delta <= 1:
            adjacency["le_1"] += 1
        elif delta <= 5:
            adjacency["le_5"] += 1
        elif delta <= 25:
            adjacency["le_25"] += 1
        elif delta <= 100:
            adjacency["le_100"] += 1
        else:
            adjacency["gt_100"] += 1

    return {
        "target_process_id": target_pid,
        "row_count": len(target_events),
        "domain_counts": dict(sorted(domain_counts.items())),
        "family_counts": dict(sorted(family_counts.items())),
        "distinct_thread_id_count": len(thread_ids),
        "gpu_network_anchor_rows": anchors,
        "anchors_with_same_pid_kernel_neighbor": with_neighbor,
        "nearest_same_pid_kernel_sequence_delta_buckets": dict(sorted(adjacency.items())),
        "claims": {
            "exact_pid_attribution": True,
            "exact_tid_attribution_when_present": True,
            "sequence_adjacency_only": True,
            "sequence_delta_is_time": False,
            "causal_relationship_validated": False,
        },
    }


def cross_domain_pid_summary(events):
    pid_domains = defaultdict(set)
    tid_domains = defaultdict(set)
    for event in events:
        process_id = event.get("process_id")
        thread_id = event.get("thread_id")
        domain = event.get("domain")
        if process_id is not None:
            pid_domains[int(process_id)].add(str(domain))
        if process_id is not None and thread_id is not None:
            tid_domains[(int(process_id), int(thread_id))].add(str(domain))
    pid_width = Counter(len(domains) for domains in pid_domains.values())
    tid_width = Counter(len(domains) for domains in tid_domains.values())
    return {
        "distinct_pid_count": len(pid_domains),
        "multi_domain_pid_count": sum(1 for domains in pid_domains.values() if len(domains) >= 2),
        "three_domain_pid_count": sum(1 for domains in pid_domains.values() if len(domains) >= 3),
        "pid_domain_width_counts": {str(key): value for key, value in sorted(pid_width.items())},
        "distinct_pid_tid_count": len(tid_domains),
        "multi_domain_pid_tid_count": sum(1 for domains in tid_domains.values() if len(domains) >= 2),
        "pid_tid_domain_width_counts": {str(key): value for key, value in sorted(tid_width.items())},
    }


def read_events(path):
    events = []
    expected_sequence = 0
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            text = line.strip()
            if not text:
                continue
            event = json.loads(text)
            sequence_index = int(event.get("sequence_index"))
            if sequence_index != expected_sequence:
                raise SystemExit(
                    f"non-contiguous sequence index at line {line_number}: "
                    f"expected={expected_sequence} actual={sequence_index}"
                )
            expected_sequence += 1
            events.append(event)
    return events


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--records-output", required=True)
    parser.add_argument("--summary-output", required=True)
    parser.add_argument("--source-head", required=True)
    parser.add_argument("--normalizer-head", required=True)
    parser.add_argument("--experiment-id", required=True)
    parser.add_argument("--target-pid", required=True, type=int)
    args = parser.parse_args()

    input_path = Path(args.input).resolve()
    records_output = Path(args.records_output).resolve()
    summary_output = Path(args.summary_output).resolve()
    if not input_path.is_file():
        raise SystemExit(f"input not found: {input_path}")
    for output in (records_output, summary_output):
        if output.exists():
            raise SystemExit(f"output already exists: {output}")
        output.parent.mkdir(parents=True, exist_ok=True)

    events = read_events(input_path)
    if not events:
        raise SystemExit("normalized event input is empty")

    pair_specs = [
        (
            "dxgi_present",
            {"Microsoft-Windows-DXGI/Present/win:Start"},
            {"Microsoft-Windows-DXGI/Present/win:Stop"},
            "present",
        ),
        (
            "dxgi_present_mpo",
            {"Microsoft-Windows-DXGI/PresentMultiplaneOverlay/win:Start"},
            {"Microsoft-Windows-DXGI/PresentMultiplaneOverlay/win:Stop"},
            "present",
        ),
        ("process_lifecycle", {"P-Start"}, {"P-End"}, "process"),
        ("process_rundown", {"P-DCStart"}, {"P-DCEnd"}, "process"),
        ("thread_lifecycle", {"T-Start"}, {"T-End"}, "thread"),
        ("thread_rundown", {"T-DCStart"}, {"T-DCEnd"}, "thread"),
        ("image_lifecycle", {"I-Start"}, {"I-End"}, "image"),
        ("image_rundown", {"I-DCStart"}, {"I-DCEnd"}, "image"),
    ]

    all_records = []
    pair_summaries = {}
    for label, starts, stops, key_kind in pair_specs:
        records, summary = pair_events(events, label, starts, stops, key_kind)
        all_records.extend(records)
        pair_summaries[label] = summary

    all_records.sort(
        key=lambda item: (
            item["start_sequence_index"],
            item["stop_sequence_index"],
            item["pair_type"],
            item["key_sha256"],
        )
    )
    with records_output.open("w", encoding="utf-8", newline="\n") as handle:
        for record in all_records:
            handle.write(canonical_json(record) + "\n")

    tcp = summarize_tcp(events, args.target_pid)
    dns = summarize_activity(
        events,
        "dns",
        ("query", "name", "server", "interface", "address", "addr"),
        "dns",
        args.target_pid,
    )
    registry = summarize_activity(
        events,
        "registry",
        ("key name", "keyname", "kcb", "path"),
        "registry",
        args.target_pid,
    )
    target = target_pid_summary(events, args.target_pid)
    cross_domain = cross_domain_pid_summary(events)

    domain_counts = Counter(str(event.get("domain")) for event in events)
    family_counts = Counter(
        f"{event.get('domain')}:{event.get('event_family')}" for event in events
    )

    summary = {
        "schema_version": 1,
        "status": "passed",
        "source": {
            "capture_head": args.source_head.lower(),
            "normalizer_head": args.normalizer_head.lower(),
            "experiment_id": args.experiment_id,
            "normalized_events_sha256": sha256_file(input_path),
            "normalized_event_rows": len(events),
            "target_process_id": args.target_pid,
        },
        "observed": {
            "domain_counts": dict(sorted(domain_counts.items())),
            "family_counts": dict(sorted(family_counts.items())),
        },
        "pairing": pair_summaries,
        "network": {
            "tcp": tcp,
            "dns": dns,
        },
        "kernel": {
            "registry": registry,
        },
        "cross_domain": cross_domain,
        "target_pid": target,
        "local_pair_record_count": len(all_records),
        "local_pair_records_sha256": sha256_file(records_output),
        "review_policy": {
            "raw_normalized_event_rows_reviewable": False,
            "raw_identifier_values_reviewable": False,
            "pair_key_hashes_reviewable": False,
            "aggregate_counts_reviewable": True,
            "sequence_delta_aggregates_reviewable": True,
        },
        "claims": {
            "sequence_order_correlation": True,
            "exact_pid_attribution": True,
            "exact_tid_attribution_when_present": True,
            "hashed_identifier_grouping": True,
            "structural_start_stop_pairing": True,
            "timestamp_unit_resolved": False,
            "sequence_delta_is_time": False,
            "present_pairing_semantics": False,
            "present_success_semantics": False,
            "gpu_queue_semantics": False,
            "tcp_connection_lifecycle_validated": False,
            "network_connection_semantics": False,
            "network_latency_semantics": False,
            "dns_payload_semantics": False,
            "kernel_lifecycle_semantics": False,
            "registry_operation_semantics": False,
            "causal_relationship_validated": False,
            "root_cause_validated": False,
            "trace_completeness": "not_claimed",
        },
    }
    summary_output.write_text(canonical_json(summary) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
