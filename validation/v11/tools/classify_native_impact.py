#!/usr/bin/env python3
"""Fail-closed NXB native-impact classifier core.

Consumes an admitted canonical policy plus explicit normalized changed-path
and dependency-graph input. Git diff production and dedicated-App identity
checks stay in outer orchestration.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import unicodedata
from collections import defaultdict, deque
from typing import Any, NoReturn

POLICY_AUTHORITY = "nxb-native-impact-policy-v1"
INPUT_AUTHORITY = "nxb-native-impact-classification-input-v1"
OUTPUT_AUTHORITY = "nxb-native-impact-classification-v1"
# Bound hostile canonical policy/graph inputs before allocating parser memory.
MAX_CANONICAL_INPUT_BYTES = 32 * 1024 * 1024
SHA40_RE = re.compile(r"^[0-9a-f]{40}$")
TOKEN_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
CHANGE_TYPES = {"added", "modified", "deleted", "renamed", "type_changed"}
FILE_TYPES = {"regular", "symlink", "submodule", "missing"}
WINDOWS_RESERVED_STEMS = {
    "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$",
    *(f"COM{i}" for i in range(1, 10)),
    *(f"LPT{i}" for i in range(1, 10)),
    "COM¹", "COM²", "COM³", "LPT¹", "LPT²", "LPT³",
}
CLASSES = ("native_required", "hosted_authority_only", "non_authority_metadata")


class ImpactError(RuntimeError):
    pass


def fail(message: str) -> NoReturn:
    raise ImpactError(message)


def reject_float(value: str) -> NoReturn:
    fail(f"floating-point JSON number forbidden: {value}")


def object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON property: {key}")
        result[key] = value
    return result


def validate_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        fail(f"{label} must be a non-empty string")
    if unicodedata.normalize("NFC", value) != value:
        fail(f"{label} must be NFC-normalized")
    if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in value):
        fail(f"{label} contains a control character")
    # Escaped JSON lone surrogates are accepted by Python's JSON parser but
    # cannot be encoded as strict UTF-8 canonical bytes. Reject them here
    # with a structured fail-closed error instead of a traceback.
    if any(0xD800 <= ord(ch) <= 0xDFFF for ch in value):
        fail(f"{label} contains invalid Unicode surrogate")
    return value


def validate_path(value: Any, label: str, *, prefix: bool = False) -> str:
    path = validate_string(value, label)
    if path.startswith("/") or "\\" in path:
        fail(f"{label} must be repository-relative with '/' separators")
    if any(ch in path for ch in "*?[]"):
        fail(f"{label} must not contain wildcard syntax")
    if "//" in path:
        fail(f"{label} contains an empty path segment")
    parts = path.rstrip("/").split("/")
    if any(part in {"", ".", ".."} for part in parts):
        fail(f"{label} contains dot/empty traversal segment")
    # Windows collapses trailing dots/spaces and reserves DOS device stems.
    # Reject aliases in both policy roots and changed-path graph inputs.
    for part in parts:
        if ":" in part or part.endswith((" ", ".")):
            fail(f"{label} contains ADS or trailing-dot/space segment")
        if any(ch in '<>"|' for ch in part):
            fail(f"{label} contains Windows forbidden character")
        if part.split(".", 1)[0].upper() in WINDOWS_RESERVED_STEMS:
            fail(f"{label} contains reserved Windows device segment")
    if not prefix and path.endswith("/"):
        fail(f"{label} exact path must not end with '/'")
    return path


def canonical_bytes(value: Any) -> bytes:
    def walk(item: Any, label: str = "$") -> None:
        if item is None or isinstance(item, (bool, int)):
            return
        if isinstance(item, float):
            fail(f"{label} contains floating-point value")
        if isinstance(item, str):
            validate_string(item, label)
            return
        if isinstance(item, list):
            for index, child in enumerate(item):
                walk(child, f"{label}[{index}]")
            return
        if isinstance(item, dict):
            for key, child in item.items():
                validate_string(key, f"{label}.<key>")
                walk(child, f"{label}.{key}")
            return
        fail(f"{label} contains unsupported type: {type(item).__name__}")

    walk(value)
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


def _input_identity(path: str, label: str) -> tuple[str, os.stat_result]:
    # Reject an ordinary-looking policy/input reached through a reparse parent.
    full = os.path.abspath(path)
    current = full
    source: os.stat_result | None = None
    while True:
        try:
            metadata = os.lstat(current)
        except OSError:
            fail(f"{label} source ancestry is unavailable: {current}")
        is_source = current == full
        if not (stat.S_ISREG(metadata.st_mode) if is_source else stat.S_ISDIR(metadata.st_mode)):
            fail(f"{label} source ancestry has unexpected file type: {current}")
        if stat.S_ISLNK(metadata.st_mode) or (
            getattr(metadata, "st_file_attributes", 0)
            & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
        ):
            fail(f"{label} source ancestry is reparse/symlink-backed: {current}")
        if is_source:
            source = metadata
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent
    assert source is not None
    return full, source


def _assert_same_input_identity(
    expected: os.stat_result, observed: os.stat_result, label: str
) -> None:
    identity_fields = ("st_dev", "st_ino", "st_mode", "st_size", "st_mtime_ns")
    if (
        not stat.S_ISREG(observed.st_mode)
        or getattr(observed, "st_file_attributes", 0)
        & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
        or any(getattr(expected, field) != getattr(observed, field) for field in identity_fields)
    ):
        fail(f"{label} source changed during canonical read")


def _ordinary_output_path(path: str) -> str:
    # Do not write a trusted decision through an untrusted junction/symlink parent.
    full = os.path.abspath(path)
    current = os.path.dirname(full)
    while True:
        try:
            metadata = os.lstat(current)
        except OSError:
            fail(f"output parent is unavailable: {current}")
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or stat.S_ISLNK(metadata.st_mode)
            or getattr(metadata, "st_file_attributes", 0)
            & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
        ):
            fail(f"output parent is not an ordinary directory: {current}")
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent
    if os.path.lexists(full):
        fail("output already exists")
    return full


def load_canonical_json(path: str, label: str) -> tuple[dict[str, Any], bytes]:
    full, expected = _input_identity(path, label)
    try:
        with open(full, "rb") as stream:
            _assert_same_input_identity(expected, os.fstat(stream.fileno()), label)
            raw = stream.read(MAX_CANONICAL_INPUT_BYTES + 1)
            _assert_same_input_identity(expected, os.fstat(stream.fileno()), label)
        _assert_same_input_identity(expected, os.lstat(full), label)
    except OSError:
        fail(f"{label} source became unavailable during canonical read")
    if len(raw) > MAX_CANONICAL_INPUT_BYTES:
        fail(f"{label} exceeds canonical input byte ceiling")
    if raw.startswith(b"\xef\xbb\xbf"):
        fail(f"{label} must not contain a UTF-8 BOM")
    try:
        text = raw.decode("utf-8", "strict")
        value = json.loads(
            text,
            object_pairs_hook=object_pairs,
            parse_float=reject_float,
            parse_constant=lambda x: fail(f"{label} non-finite number forbidden: {x}"),
        )
    except ImpactError:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError, TypeError, ValueError) as exc:
        fail(f"{label} is not strict UTF-8 JSON: {exc}")
    if not isinstance(value, dict):
        fail(f"{label} root must be an object")
    canonical = canonical_bytes(value)
    if raw != canonical:
        fail(f"{label} bytes are not canonical JSON")
    return value, raw


def exact_keys(obj: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(obj, dict):
        fail(f"{label} must be an object")
    actual = set(obj)
    if actual != expected:
        fail(
            f"{label} property drift: "
            f"missing={sorted(expected-actual)} extra={sorted(actual-expected)}"
        )
    return obj


def validate_rule(rule: Any, label: str) -> dict[str, str]:
    row = exact_keys(
        rule,
        {"rule_id", "match_type", "path", "reason_code"},
        label,
    )
    rule_id = validate_string(row["rule_id"], f"{label}.rule_id")
    reason = validate_string(row["reason_code"], f"{label}.reason_code")
    if TOKEN_RE.fullmatch(rule_id) is None or TOKEN_RE.fullmatch(reason) is None:
        fail(f"{label} rule/reason syntax invalid")
    match_type = row["match_type"]
    if not isinstance(match_type, str) or match_type not in {"exact", "prefix"}:
        fail(f"{label}.match_type invalid")
    path = validate_path(
        row["path"],
        f"{label}.path",
        prefix=match_type == "prefix",
    )
    return {
        "rule_id": rule_id,
        "match_type": match_type,
        "path": path,
        "reason_code": reason,
    }


def validate_edge(edge: Any, label: str) -> tuple[str, str, str]:
    row = exact_keys(edge, {"source", "target", "reason_code"}, label)
    source = validate_path(row["source"], f"{label}.source")
    target = validate_path(row["target"], f"{label}.target")
    reason = validate_string(row["reason_code"], f"{label}.reason_code")
    if TOKEN_RE.fullmatch(reason) is None:
        fail(f"{label}.reason_code syntax invalid")
    return source, target, reason


def validate_policy(policy: dict[str, Any]) -> dict[str, Any]:
    expected = {
        "authority",
        "schema_version",
        "policy_version",
        "native_roots",
        "hosted_authority_only_roots",
        "non_authority_metadata_roots",
        "dependency_edges",
        "forbidden_broad_patterns",
        "classification_precedence",
        "limits",
    }
    root = exact_keys(policy, expected, "policy")
    if root["authority"] != POLICY_AUTHORITY or root["schema_version"] != 1:
        fail("policy authority/schema_version drift")
    if type(root["policy_version"]) is not int or root["policy_version"] < 1:
        fail("policy_version invalid")
    if root["classification_precedence"] != list(CLASSES):
        fail("classification_precedence drift")

    limits = exact_keys(
        root["limits"],
        {"max_changed_paths", "max_dependency_edges", "max_graph_nodes"},
        "policy.limits",
    )
    for name, maximum in (
        ("max_changed_paths", 4096),
        ("max_dependency_edges", 65536),
        ("max_graph_nodes", 65536),
    ):
        value = limits[name]
        if type(value) is not int or value < 1 or value > maximum:
            fail(f"policy.limits.{name} invalid")

    rule_ids: set[str] = set()
    parsed: dict[str, list[dict[str, str]]] = {}
    for field in (
        "native_roots",
        "hosted_authority_only_roots",
        "non_authority_metadata_roots",
    ):
        rows = root[field]
        if not isinstance(rows, list):
            fail(f"policy.{field} must be an array")
        parsed[field] = []
        for index, item in enumerate(rows):
            rule = validate_rule(item, f"policy.{field}[{index}]")
            # Downgrade classes must use an actual directory boundary;
            # otherwise docs/safe also matches docs/safe-unrelated.
            # Native-required rules retain explicit filename prefixes.
            if (
                field != "native_roots"
                and rule["match_type"] == "prefix"
                and not rule["path"].endswith("/")
            ):
                fail("lower-trust prefix must end with '/'")
            if rule["rule_id"] in rule_ids:
                fail(f"duplicate policy rule_id: {rule['rule_id']}")
            rule_ids.add(rule["rule_id"])
            parsed[field].append(rule)

    broad = root["forbidden_broad_patterns"]
    if not isinstance(broad, list) or not broad or any(not isinstance(x, str) for x in broad):
        fail("forbidden_broad_patterns must be non-empty string array")
    if len(broad) != len(set(broad)):
        fail("forbidden_broad_patterns contains duplicate")
    for pattern in broad:
        validate_string(pattern, "policy.forbidden_broad_patterns[]")
    for rows in parsed.values():
        for rule in rows:
            if rule["path"] in broad:
                fail("policy root equals forbidden broad pattern")

    edges = root["dependency_edges"]
    if not isinstance(edges, list) or len(edges) > limits["max_dependency_edges"]:
        fail("policy dependency edge cardinality invalid")
    parsed_edges = [
        validate_edge(item, f"policy.dependency_edges[{index}]")
        for index, item in enumerate(edges)
    ]
    if len(parsed_edges) != len(set(parsed_edges)):
        fail("duplicate policy dependency edge")

    return {"rules": parsed, "edges": parsed_edges, "limits": limits}


def validate_change(row: Any, label: str) -> dict[str, Any]:
    expected = {"change_type", "old_path", "new_path", "old_type", "new_type"}
    item = exact_keys(row, expected, label)
    change_type = item["change_type"]
    if not isinstance(change_type, str) or change_type not in CHANGE_TYPES:
        fail(f"{label}.change_type invalid")
    old_type, new_type = item["old_type"], item["new_type"]
    if (
        not isinstance(old_type, str)
        or not isinstance(new_type, str)
        or old_type not in FILE_TYPES
        or new_type not in FILE_TYPES
    ):
        fail(f"{label} file type invalid")
    old_path = (
        None
        if item["old_path"] is None
        else validate_path(item["old_path"], f"{label}.old_path")
    )
    new_path = (
        None
        if item["new_path"] is None
        else validate_path(item["new_path"], f"{label}.new_path")
    )

    if change_type == "added":
        if (
            old_path is not None or new_path is None
            or old_type != "missing" or new_type == "missing"
        ):
            fail(f"{label} added shape invalid")
    elif change_type == "deleted":
        if (
            old_path is None or new_path is not None
            or old_type == "missing" or new_type != "missing"
        ):
            fail(f"{label} deleted shape invalid")
    elif change_type in {"modified", "type_changed"}:
        if (
            old_path is None or new_path is None or old_path != new_path
            or "missing" in {old_type, new_type}
        ):
            fail(f"{label} modified/type_changed shape invalid")
        if change_type == "modified" and old_type != new_type:
            fail(f"{label} modified file type changed")
        if change_type == "type_changed" and old_type == new_type:
            fail(f"{label} type_changed lacks file type change")
    elif change_type == "renamed":
        if (
            old_path is None or new_path is None or old_path == new_path
            or "missing" in {old_type, new_type}
        ):
            fail(f"{label} rename shape invalid")

    return {
        "change_type": change_type,
        "old_path": old_path,
        "new_path": new_path,
        "old_type": old_type,
        "new_type": new_type,
    }


def validate_input(
    value: dict[str, Any],
    limits: dict[str, int],
) -> tuple[list[dict[str, Any]], list[tuple[str, str, str]]]:
    expected = {
        "authority",
        "schema_version",
        "repository",
        "base_sha",
        "head_sha",
        "merge_base_sha",
        "changed_paths",
        "base_dependency_edges",
        "candidate_dependency_edges",
    }
    root = exact_keys(value, expected, "input")
    if root["authority"] != INPUT_AUTHORITY or root["schema_version"] != 1:
        fail("input authority/schema_version drift")
    validate_string(root["repository"], "input.repository")
    for field in ("base_sha", "head_sha", "merge_base_sha"):
        if not isinstance(root[field], str) or SHA40_RE.fullmatch(root[field]) is None:
            fail(f"input.{field} must be lowercase 40-hex")

    changes = root["changed_paths"]
    if not isinstance(changes, list) or not changes:
        fail("input.changed_paths must be non-empty")
    if len(changes) > limits["max_changed_paths"]:
        fail("input.changed_paths exceeds policy limit")
    parsed_changes = [
        validate_change(item, f"input.changed_paths[{index}]")
        for index, item in enumerate(changes)
    ]
    keys = [
        (
            row["change_type"],
            row["old_path"] or "",
            row["new_path"] or "",
            row["old_type"],
            row["new_type"],
        )
        for row in parsed_changes
    ]
    if len(keys) != len(set(keys)):
        fail("duplicate changed-path record")
    # Windows-equivalent paths may not denote two distinct files in the
    # same Git tree. Check base and candidate identities separately so a
    # legitimate case-only rename remains representable across trees.
    for side in ("old_path", "new_path"):
        present = [row[side].casefold() for row in parsed_changes if row[side] is not None]
        unique = set(present)
        if len(present) != len(unique):
            fail(f"Windows case-fold changed-path collision in {side}")
        # An endpoint is a file/submodule/symlink, never a directory.
        # It cannot also be a case-equivalent ancestor of another
        # file endpoint in the same base or candidate tree.
        for folded in unique:
            parts = folded.split("/")
            if any("/".join(parts[:depth]) in unique for depth in range(1, len(parts))):
                fail(f"Windows file/directory changed-path collision in {side}")

    edges: list[tuple[str, str, str]] = []
    for field in ("base_dependency_edges", "candidate_dependency_edges"):
        rows = root[field]
        if not isinstance(rows, list):
            fail(f"input.{field} must be array")
        edges.extend(
            validate_edge(item, f"input.{field}[{index}]")
            for index, item in enumerate(rows)
        )
    if len(edges) > limits["max_dependency_edges"]:
        fail("combined dependency edge cardinality exceeds policy limit")
    return parsed_changes, edges


def rule_match(path: str, rule: dict[str, str]) -> bool:
    if rule["match_type"] == "exact":
        return path == rule["path"]
    return path.startswith(rule["path"])


def native_rule_match(path: str, rule: dict[str, str]) -> bool:
    """Treat Windows case aliases conservatively for native-required roots only."""
    folded_path = path.casefold()
    folded_root = rule["path"].casefold()
    if rule["match_type"] == "exact":
        return folded_path == folded_root
    return folded_path.startswith(folded_root)


def closure_from_native(
    native_rules: list[dict[str, str]],
    edges: list[tuple[str, str, str]],
    max_nodes: int,
) -> tuple[set[str], dict[str, set[str]]]:
    adjacency: dict[str, set[str]] = defaultdict(set)
    reasons: dict[str, set[str]] = defaultdict(set)
    for source, target, reason in edges:
        # Preserve canonical edge identity, but traverse Windows-equivalent
        # source aliases as one dependency node. A case-only intermediary
        # must not break a native-required multi-hop dependency chain.
        adjacency[source.casefold()].add(target)
        reasons[target].add(reason)

    seeds = {
        rule["path"]
        for rule in native_rules
        if rule["match_type"] == "exact"
    }
    for source, _, _ in edges:
        if any(native_rule_match(source, rule) for rule in native_rules):
            seeds.add(source)

    # Exact and prefix-derived starting nodes count against the graph budget,
    # even when the work queue never discovers any additional descendants.
    if len(seeds) > max_nodes:
        fail("dependency graph exceeds max_graph_nodes")

    queue = deque(sorted(seeds))
    visited = set(seeds)
    while queue:
        node = queue.popleft()
        for target in sorted(adjacency.get(node.casefold(), ())):
            if target not in visited:
                visited.add(target)
                if len(visited) > max_nodes:
                    fail("dependency graph exceeds max_graph_nodes")
                queue.append(target)
    return visited, reasons


def classify_path(
    path: str,
    policy: dict[str, Any],
    native_closure: set[str],
    native_closure_casefold: set[str] | None = None,
) -> tuple[str, list[str], bool]:
    for rule in policy["rules"]["native_roots"]:
        if native_rule_match(path, rule):
            return "native_required", [rule["reason_code"], rule["rule_id"]], False

    # On Windows a case-only alias denotes the same dependency. Never
    # downgrade the aliased native target to a lower-trust hosted class.
    # The caller supplies the precomputed case-folded set for bounded graph
    # processing; direct classifier callers get the same semantics.
    folded = (
        native_closure_casefold
        if native_closure_casefold is not None
        else {native_path.casefold() for native_path in native_closure}
    )
    if path in native_closure or path.casefold() in folded:
        return "native_required", ["native_dependency_closure"], False

    for rule in policy["rules"]["hosted_authority_only_roots"]:
        if rule_match(path, rule):
            return (
                "hosted_authority_only",
                [rule["reason_code"], rule["rule_id"]],
                False,
            )

    for rule in policy["rules"]["non_authority_metadata_roots"]:
        if rule_match(path, rule):
            return (
                "non_authority_metadata",
                [rule["reason_code"], rule["rule_id"]],
                False,
            )

    return "native_required", ["unknown_unclassified_path"], True


def main() -> int:
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("--policy", required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    output_path = _ordinary_output_path(args.output)

    policy_obj, policy_raw = load_canonical_json(args.policy, "policy")
    parsed_policy = validate_policy(policy_obj)
    input_obj, _ = load_canonical_json(args.input, "input")
    changes, dynamic_edges = validate_input(input_obj, parsed_policy["limits"])

    all_edges = list(parsed_policy["edges"]) + dynamic_edges
    edge_set = sorted(set(all_edges))
    nodes = {path for edge in edge_set for path in edge[:2]}
    if len(nodes) > parsed_policy["limits"]["max_graph_nodes"]:
        fail("dependency graph node cardinality exceeds policy limit")

    native_closure, edge_reasons = closure_from_native(
        parsed_policy["rules"]["native_roots"],
        edge_set,
        parsed_policy["limits"]["max_graph_nodes"],
    )
    native_closure_casefold = {path.casefold() for path in native_closure}
    # Preserve the reason provenance of a graph target even when the
    # changed-file spelling differs only by Windows case equivalence.
    edge_reasons_casefold: dict[str, set[str]] = defaultdict(set)
    for target, codes in edge_reasons.items():
        edge_reasons_casefold[target.casefold()].update(codes)

    changed_records = sorted(
        changes,
        key=lambda row: (
            (row["old_path"] or "").encode("utf-8"),
            (row["new_path"] or "").encode("utf-8"),
            row["change_type"],
        ),
    )
    changed_subject = {
        "authority": "nxb-native-impact-changed-path-set-v1",
        "schema_version": 1,
        "changes": changed_records,
    }
    changed_sha = hashlib.sha256(canonical_bytes(changed_subject)).hexdigest()

    graph_subject = {
        "authority": "nxb-native-impact-graph-v1",
        "schema_version": 1,
        "edges": [
            {"source": source, "target": target, "reason_code": reason}
            for source, target, reason in edge_set
        ],
    }
    graph_sha = hashlib.sha256(canonical_bytes(graph_subject)).hexdigest()

    rank = {
        "non_authority_metadata": 1,
        "hosted_authority_only": 2,
        "native_required": 3,
    }
    highest = "non_authority_metadata"
    reasons: set[str] = set()
    unmatched = 0
    ambiguous = 0
    native_paths: set[str] = set()
    endpoint_results: list[dict[str, Any]] = []

    for change in changed_records:
        endpoints: list[tuple[str, str, str]] = []
        if change["old_path"] is not None:
            endpoints.append(("old", change["old_path"], change["old_type"]))
        if change["new_path"] is not None:
            endpoints.append(("new", change["new_path"], change["new_type"]))

        for side, path, file_type in endpoints:
            impact_class, path_reasons, was_unmatched = classify_path(
                path,
                parsed_policy,
                native_closure,
                native_closure_casefold,
            )
            if file_type in {"symlink", "submodule"}:
                impact_class = "native_required"
                path_reasons = list(path_reasons) + ["non_regular_file_shape"]
                ambiguous += 1
            if was_unmatched:
                unmatched += 1
            if impact_class == "native_required":
                native_paths.add(path)
            if rank[impact_class] > rank[highest]:
                highest = impact_class
            reasons.update(path_reasons)
            reasons.update(edge_reasons_casefold.get(path.casefold(), ()))
            endpoint_results.append(
                {
                    "side": side,
                    "path": path,
                    "file_type": file_type,
                    "impact_class": impact_class,
                }
            )

    decision = (
        "native_evidence"
        if highest == "native_required"
        else "native_not_required"
    )
    output = {
        "authority": OUTPUT_AUTHORITY,
        "schema_version": 1,
        "repository": input_obj["repository"],
        "base_sha": input_obj["base_sha"],
        "head_sha": input_obj["head_sha"],
        "merge_base_sha": input_obj["merge_base_sha"],
        "impact_class": highest,
        "decision_kind": decision,
        "impact_policy_sha256": hashlib.sha256(policy_raw).hexdigest(),
        "impact_graph_sha256": graph_sha,
        "changed_path_set_sha256": changed_sha,
        "impact_reason_codes": sorted(reasons),
        "native_relevant_path_count": len(native_paths),
        "ambiguous_path_count": ambiguous,
        "unmatched_path_count": unmatched,
        "endpoint_results": sorted(
            endpoint_results,
            key=lambda row: (row["path"].encode("utf-8"), row["side"]),
        ),
    }
    payload = canonical_bytes(output)

    _ordinary_output_path(output_path)
    try:
        descriptor = os.open(
            output_path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
    except FileExistsError:
        fail(f"output already exists: {output_path}")
    except OSError:
        fail(f"output became unavailable during exclusive creation: {output_path}")
    try:
        with os.fdopen(descriptor, "wb", closefd=True) as stream:
            descriptor = -1
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
    except OSError:
        fail(f"output write or sync failed: {output_path}")
    finally:
        if descriptor >= 0:
            os.close(descriptor)

    print(
        "NXB_NATIVE_IMPACT_CLASSIFICATION_PASS "
        f"impact_class={highest} "
        f"decision_kind={decision} "
        f"changed_path_set_sha256={changed_sha}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ImpactError as exc:
        print(f"NXB_NATIVE_IMPACT_CLASSIFICATION_ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2)
