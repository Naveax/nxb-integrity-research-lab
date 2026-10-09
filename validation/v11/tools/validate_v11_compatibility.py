#!/usr/bin/env python3
"""NXB V11 six-entry review ZIP envelope and claim-free schema/DAG preflight.

Every successful mode remains non-admitting. GitHub-side run/artifact
provenance, candidate/base CAS, predecessor replay admission, and production
authority are reconstructed by later independent admission layers.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import stat
import sys
import unicodedata
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any, NoReturn

AUTHORITY = "nxb-v11-review-zip-envelope-preflight-v1"
AUTHORITY_MODE_NAMES = {
    "a0-hosted": frozenset(
        {
            "compatibility-policy-summary.json",
            "canonicalization-conformance.json",
            "native-impact-classifier-fixtures.json",
            "known-error-scan.json",
            "independent-validation.json",
            "a0-substrate-receipt.json",
        }
    ),
    "physical-compatibility": frozenset(
        {
            "environment-fingerprint.json",
            "compatibility-plan.json",
            "endurance-cycle-summary.json",
            "known-error-scan.json",
            "independent-validation.json",
            "compatibility-certification-receipt.json",
        }
    ),
}
FROZEN_FILENAME_SET_SHA256 = {
    "a0-hosted": "79ca4d7140bfccd859cd2952e70f7dc636a1612ad1b475f7509e57bd4cd7c977",
    "physical-compatibility": "5874922efe9cc136886e8d590b05ebe7c3604e8b509314ea767788467b711d17",
}
# Structural preflight checks only authority IDs whose exact values are already
# frozen independently. Missing entries remain schema_semantics gates, not
# permissive authority fallbacks.
KNOWN_AUTHORITY_BY_MODE = {
    "a0-hosted": {
        "known-error-scan.json": "nxb-v11-known-error-scan-v1",
        "a0-substrate-receipt.json": "nxb-v11-a0-substrate-receipt-v1",
    },
    "physical-compatibility": {
        "environment-fingerprint.json": "nxb-compatibility-environment-fingerprint-v1",
        "compatibility-plan.json": "nxb-v11-compatibility-plan-v1",
        "endurance-cycle-summary.json": "nxb-v11-endurance-cycle-summary-v1",
        "known-error-scan.json": "nxb-v11-known-error-scan-v1",
        "independent-validation.json": "nxb-v11-compatibility-independent-v1",
        "compatibility-certification-receipt.json": "nxb-v11-compatibility-certification-receipt-v1",
    },
}
# These are deliberately conservative preflight limits, NOT policy admission.
MAX_ENTRY_BYTES = 1024 * 1024
MAX_TOTAL_UNCOMPRESSED = 6 * MAX_ENTRY_BYTES
MAX_ZIP_BYTES = 12 * 1024 * 1024
# Checked before allocating memory for any external schema source.
MAX_SCHEMA_BYTES = 1024 * 1024
I64_MAX = (1 << 63) - 1
I64_MIN = -(1 << 63)
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
PRIMARY_SCHEMA_BINDINGS = {
    "environment-fingerprint.json": {
        "filename": "nxb-v11-environment-fingerprint.schema.json",
        "schema_id": "urn:nxb:schema:nxb-v11-environment-fingerprint:v1",
        "sha256": frozenset({
            "04698ce35e2765e042f64582a11de77b3f60bded5a0f176857e84df1f51c9144",
            "bd1996bb06b8e9714b579115d0124866bd45dd7f8d802421f8b973ea6218671c",
        }),
    },
    "compatibility-plan.json": {
        "filename": "nxb-v11-compatibility-plan.schema.json",
        "schema_id": "urn:nxb:schema:nxb-v11-compatibility-plan:v1",
        "sha256": frozenset({
            "0b9d94321c17e5ea1ccc1d72062ac39f2e61f514f19dd228c125b909db76f4ab",
            "541d5d055421a2e520f373921f64c60210a625954511b554574eecaaacf5afec",
        }),
    },
    "endurance-cycle-summary.json": {
        "filename": "nxb-v11-endurance-cycle-summary.schema.json",
        "schema_id": "urn:nxb:schema:nxb-v11-endurance-cycle-summary:v1",
        "sha256": frozenset({
            "2264e2c646fe0d1ce3c34535b36ffb2fa8c900067eaff5ba225a64732a1af818",
            "0a195596f187ba40b233833c900fdd8df0c80128d6af0631a3eea7d2996dd0a8",
        }),
    },
    "known-error-scan.json": {
        "filename": "nxb-v11-known-error-scan.schema.json",
        "schema_id": "urn:nxb:schema:nxb-v11-known-error-scan:v1",
        "sha256": frozenset({
            "2ba6df7feca2bd46d480e61f06ab0a9a173c97411182470bdbfbc47f994ed3d4",
            "18de57a96b203cdaf6dd519df497adaa98a90cf2a742341f04fcb953cbc2a741",
        }),
    },
}
TERMINAL_SCHEMA_BINDINGS = {
    "independent-validation.json": {
        "filename": "nxb-v11-independent-validation.schema.json",
        "schema_id": "urn:nxb:schema:nxb-v11-independent-validation:v1",
        "sha256": frozenset({
            "017403a3e71573cbbde562a2900a4c63b5bcdd6b43018db1d4baa0606baeb34c",
            "0fc845e41da5592449232638c8ff8b5e90257679acd139f13ca7eaa8dd41c602",
        }),
    },
    "compatibility-certification-receipt.json": {
        "filename": "nxb-v11-compatibility-receipt.schema.json",
        "schema_id": "urn:nxb:schema:nxb-v11-compatibility-receipt:v1",
        "sha256": frozenset({
            "d0968bc248da678bf52061c09b82a0bc7eace1194eaa663b53a68eff4aab39aa",
            "787736cf6cca7872b8c8ee20d0f97dcb32eeba45d46aeb363236e0aaab394aac",
        }),
    },
}
EXPECTED_JSONSCHEMA_VERSION = "4.26.0"


class PreflightError(ValueError):
    """Expected fail-closed rejection, exit status 2."""


def fail(reason: str) -> NoReturn:
    raise PreflightError(reason)


def _pairs_unique(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail("duplicate JSON object key")
        result[key] = value
    return result


def _parse_integer(value: str) -> int:
    number = int(value)
    if not I64_MIN <= number <= I64_MAX:
        fail("JSON integer outside signed 64-bit range")
    return number


def _parse_float(_value: str) -> NoReturn:
    fail("floating-point JSON numbers are forbidden")


def _parse_constant(_value: str) -> NoReturn:
    fail("non-finite JSON numbers are forbidden")


def _check_strings(value: Any) -> None:
    if isinstance(value, str):
        if unicodedata.normalize("NFC", value) != value:
            fail("non-NFC JSON string")
        if any(ord(char) < 0x20 or ord(char) == 0x7f for char in value):
            fail("JSON string contains a control character")
        if any(0xD800 <= ord(char) <= 0xDFFF for char in value):
            fail("JSON string contains an unpaired Unicode surrogate")
    elif isinstance(value, dict):
        for key, child in value.items():
            _check_strings(key)
            if not key.isascii():
                fail("JSON object key outside ASCII contract")
            _check_strings(child)
    elif isinstance(value, list):
        for child in value:
            _check_strings(child)


def _canonical_document(
    content: bytes, name: str, authority_mode: str
) -> dict[str, Any]:
    if content.startswith(b"\xef\xbb\xbf"):
        fail(f"{name}: UTF-8 BOM forbidden")
    try:
        decoded = content.decode("utf-8", "strict")
    except UnicodeDecodeError:
        fail(f"{name}: invalid UTF-8")
    try:
        document = json.loads(
            decoded,
            object_pairs_hook=_pairs_unique,
            parse_int=_parse_integer,
            parse_float=_parse_float,
            parse_constant=_parse_constant,
        )
    except (ValueError, TypeError, RecursionError) as exc:
        if isinstance(exc, PreflightError):
            raise
        fail(f"{name}: malformed JSON")
    if not isinstance(document, dict):
        fail(f"{name}: JSON root must be an object")
    try:
        _check_strings(document)
        canonical = json.dumps(
            document, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    except (RecursionError, UnicodeError):
        fail(f"{name}: JSON nesting or Unicode invalid")
    if content != canonical:
        fail(f"{name}: non-canonical JSON bytes")
    expected_authority = KNOWN_AUTHORITY_BY_MODE[authority_mode].get(name)
    if expected_authority is not None and document.get("authority") != expected_authority:
        fail(f"{name}: wrong authority identifier for {authority_mode}")
    return document


def _filename_set_sha256(authority_mode: str, names: list[str]) -> str:
    logical = {
        "authority": "nxb-v11-artifact-filename-set-v1",
        "authority_mode": authority_mode,
        "filenames": sorted(names),
    }
    canonical = json.dumps(
        logical,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def _regular_zip_entry(info: zipfile.ZipInfo, expected_names: frozenset[str]) -> None:
    name = info.filename
    if name not in expected_names:
        fail("unexpected, nested or unsafe review entry")
    if info.is_dir():
        fail("directory review entry forbidden")
    if info.flag_bits & 0x1:
        fail("encrypted review entry forbidden")
    if info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
        fail("unsupported review compression method")
    if info.file_size < 0 or info.file_size > MAX_ENTRY_BYTES:
        fail("review entry exceeds preflight byte ceiling")
    if info.compress_size < 0 or info.compress_size > MAX_ZIP_BYTES:
        fail("review entry compressed byte ceiling exceeded")
    if info.create_system == 3:
        unix_mode = (info.external_attr >> 16) & 0xffff
        if unix_mode:
            kind = stat.S_IFMT(unix_mode)
            if kind not in (0, stat.S_IFREG):
                fail("nonregular UNIX review entry metadata")
    if info.external_attr & 0x10:
        fail("directory-attribute review entry forbidden")
    if info.filename != unicodedata.normalize("NFC", info.filename):
        fail("non-NFC review entry path")


def _ordinary_parent_directories(path: Path, label: str) -> None:
    # A regular leaf below a symlink or junction is not an ordinary source path.
    # Inspect every ancestor, not only the immediate parent or leaf metadata.
    current = path.parent
    while True:
        try:
            metadata = current.lstat()
        except OSError:
            fail(f"{label} parent path is unreadable")
        if not stat.S_ISDIR(metadata.st_mode):
            fail(f"{label} parent is not an ordinary directory")
        if getattr(metadata, "st_file_attributes", 0) & getattr(
            stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400
        ):
            fail(f"{label} parent reparse-point forbidden")
        if current.parent == current:
            break
        current = current.parent


def _ordinary_zip(path: Path) -> os.stat_result:
    if not path.is_absolute():
        fail("ZIP path must be absolute")
    try:
        metadata = path.lstat()
    except OSError:
        fail("review ZIP is absent or unreadable")
    if not stat.S_ISREG(metadata.st_mode):
        fail("review ZIP must be an ordinary regular file")
    if getattr(metadata, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400):
        fail("review ZIP reparse-point forbidden")
    if metadata.st_size <= 0 or metadata.st_size > MAX_ZIP_BYTES:
        fail("review ZIP exceeds bounded preflight size")
    _ordinary_parent_directories(path, "review ZIP")
    return metadata


def _verify_review_zip_identity(
    expected: os.stat_result, observed: os.stat_result
) -> None:
    # Bind the bounded ZIP snapshot to the exact regular file checked above.
    # This detects replacement/metadata drift, not an adversarial atomic FS snapshot.
    fields = ("st_dev", "st_ino", "st_mode", "st_size", "st_mtime_ns")
    if (
        not stat.S_ISREG(observed.st_mode)
        or getattr(observed, "st_file_attributes", 0)
        & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
        or any(getattr(expected, field) != getattr(observed, field) for field in fields)
    ):
        fail("review ZIP changed during read")


def _ordinary_schema_root(path: Path) -> None:
    if not path.is_absolute():
        fail("schema root must be absolute")
    try:
        metadata = path.lstat()
    except OSError:
        fail("schema root is absent or unreadable")
    if not stat.S_ISDIR(metadata.st_mode):
        fail("schema root must be an ordinary directory")
    if getattr(metadata, "st_file_attributes", 0) & getattr(
        stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400
    ):
        fail("schema root reparse-point forbidden")
    _ordinary_parent_directories(path, "schema root")


def _verify_bounded_schema_source_identity(
    expected: os.stat_result, observed: os.stat_result
) -> None:
    fields = ("st_dev", "st_ino", "st_mode", "st_size", "st_mtime_ns")
    if (
        not stat.S_ISREG(observed.st_mode)
        or stat.S_ISLNK(observed.st_mode)
        or getattr(observed, "st_file_attributes", 0)
        & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
        or any(getattr(expected, key) != getattr(observed, key) for key in fields)
    ):
        fail("schema source changed during read")


def _read_bounded_schema(path: Path, label: str) -> bytes:
    if not path.is_absolute():
        fail(f"{label} path must be absolute")
    _ordinary_parent_directories(path, label)
    try:
        metadata = path.lstat()
    except OSError:
        fail(f"{label} absent or unreadable")
    if not stat.S_ISREG(metadata.st_mode):
        fail(f"{label} is not a regular file")
    if getattr(metadata, "st_file_attributes", 0) & getattr(
        stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400
    ):
        fail(f"{label} reparse-point forbidden")
    if metadata.st_size <= 0 or metadata.st_size > MAX_SCHEMA_BYTES:
        fail(f"{label} exceeds schema source byte ceiling")
    try:
        with path.open("rb") as stream:
            _verify_bounded_schema_source_identity(metadata, os.fstat(stream.fileno()))
            content = stream.read(MAX_SCHEMA_BYTES + 1)
            _verify_bounded_schema_source_identity(metadata, os.fstat(stream.fileno()))
        _verify_bounded_schema_source_identity(metadata, path.lstat())
    except OSError:
        fail(f"{label} absent or unreadable")
    if not content or len(content) > MAX_SCHEMA_BYTES:
        fail(f"{label} exceeds schema source byte ceiling")
    return content


def _load_primary_schema(schema_root: Path, document_name: str) -> dict[str, Any]:
    binding = PRIMARY_SCHEMA_BINDINGS[document_name]
    schema_path = schema_root / binding["filename"]
    content = _read_bounded_schema(
        schema_path, f"{document_name}: primary schema source"
    )
    digest = hashlib.sha256(content).hexdigest()
    if digest not in binding["sha256"]:
        fail(f"{document_name}: primary schema source SHA-256 drift")
    if content.startswith(b"\xef\xbb\xbf"):
        fail(f"{document_name}: primary schema UTF-8 BOM forbidden")
    try:
        decoded = content.decode("utf-8", "strict")
        schema = json.loads(
            decoded,
            object_pairs_hook=_pairs_unique,
            parse_int=_parse_integer,
            parse_float=_parse_float,
            parse_constant=_parse_constant,
        )
    except (UnicodeDecodeError, ValueError, TypeError, RecursionError):
        fail(f"{document_name}: primary schema source is invalid JSON")
    if not isinstance(schema, dict):
        fail(f"{document_name}: primary schema root must be an object")
    _check_strings(schema)
    if schema.get("$id") != binding["schema_id"]:
        fail(f"{document_name}: primary schema ID drift")
    if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
        fail(f"{document_name}: primary schema dialect drift")
    return schema


def _validate_primary_schema_documents(
    documents: dict[str, dict[str, Any]], schema_root: Path
) -> str:
    _ordinary_schema_root(schema_root)
    try:
        from importlib.metadata import PackageNotFoundError, version
        from jsonschema import Draft202012Validator, FormatChecker
        from jsonschema.exceptions import SchemaError, ValidationError
        jsonschema_version = version("jsonschema")
    except (ImportError, PackageNotFoundError):
        fail("jsonschema package unavailable for primary schema preflight")
    if jsonschema_version != EXPECTED_JSONSCHEMA_VERSION:
        fail("jsonschema package version differs from primary schema preflight pin")
    for document_name in PRIMARY_SCHEMA_BINDINGS:
        if document_name not in documents:
            fail(f"{document_name}: primary review document missing")
        schema = _load_primary_schema(schema_root, document_name)
        try:
            Draft202012Validator.check_schema(schema)
            Draft202012Validator(
                schema, format_checker=FormatChecker()
            ).validate(documents[document_name])
        except SchemaError:
            fail(f"{document_name}: primary schema contract invalid")
        except ValidationError:
            fail(f"{document_name}: primary schema semantic validation failed")
    return jsonschema_version


def _load_terminal_schema(schema_root: Path, document_name: str) -> dict[str, Any]:
    binding = TERMINAL_SCHEMA_BINDINGS[document_name]
    schema_path = schema_root / binding["filename"]
    content = _read_bounded_schema(
        schema_path, f"{document_name}: terminal schema source"
    )
    digest = hashlib.sha256(content).hexdigest()
    if digest not in binding["sha256"]:
        fail(f"{document_name}: terminal schema source SHA-256 drift")
    if content.startswith(b"\xef\xbb\xbf"):
        fail(f"{document_name}: terminal schema UTF-8 BOM forbidden")
    try:
        schema = json.loads(
            content.decode("utf-8", "strict"),
            object_pairs_hook=_pairs_unique,
            parse_int=_parse_integer,
            parse_float=_parse_float,
            parse_constant=_parse_constant,
        )
    except (UnicodeDecodeError, ValueError, TypeError, RecursionError):
        fail(f"{document_name}: terminal schema source is invalid JSON")
    if not isinstance(schema, dict):
        fail(f"{document_name}: terminal schema root must be an object")
    _check_strings(schema)
    if schema.get("$id") != binding["schema_id"]:
        fail(f"{document_name}: terminal schema ID drift")
    if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
        fail(f"{document_name}: terminal schema dialect drift")
    return schema


def _validate_terminal_schema_documents(
    documents: dict[str, dict[str, Any]], schema_root: Path
) -> str:
    _ordinary_schema_root(schema_root)
    try:
        from importlib.metadata import PackageNotFoundError, version
        from jsonschema import Draft202012Validator, FormatChecker
        from jsonschema.exceptions import SchemaError, ValidationError
        jsonschema_version = version("jsonschema")
    except (ImportError, PackageNotFoundError):
        fail("jsonschema package unavailable for terminal schema preflight")
    if jsonschema_version != EXPECTED_JSONSCHEMA_VERSION:
        fail("jsonschema package version differs from terminal schema preflight pin")
    for document_name in TERMINAL_SCHEMA_BINDINGS:
        if document_name not in documents:
            fail(f"{document_name}: terminal review document missing")
        schema = _load_terminal_schema(schema_root, document_name)
        try:
            Draft202012Validator.check_schema(schema)
            Draft202012Validator(
                schema, format_checker=FormatChecker()
            ).validate(documents[document_name])
        except SchemaError:
            fail(f"{document_name}: terminal schema contract invalid")
        except ValidationError:
            fail(f"{document_name}: terminal schema semantic validation failed")
    return jsonschema_version


def _validate_review_schema_documents(
    documents: dict[str, dict[str, Any]], schema_root: Path
) -> str:
    primary_version = _validate_primary_schema_documents(documents, schema_root)
    terminal_version = _validate_terminal_schema_documents(documents, schema_root)
    if primary_version != terminal_version:
        fail("primary/terminal schema validator version mismatch")
    return primary_version


A0_HOSTED_SCHEMA_BINDING = {
    "filename": "nxb-v11-a0-hosted-substrate.schema.json",
    "schema_id": "urn:nxb:schema:nxb-v11-a0-hosted-substrate:v1",
    "sha256": frozenset({
        "8390beb59c45810cb2a009c7dd384b60ed0f48b3f26464abf4f9a58c850db85a",
    }),
}

A0_PRIMARY_HASH_FIELDS = {
    "compatibility-policy-summary.json": "compatibility_policy_summary_sha256",
    "canonicalization-conformance.json": "canonicalization_conformance_sha256",
    "native-impact-classifier-fixtures.json": "native_impact_classifier_fixtures_sha256",
    "known-error-scan.json": "known_error_scan_sha256",
}

A0_DAG_COMMON_FIELDS = (
    "repository",
    "repository_id",
    "workflow_id",
    "workflow_path",
    "workflow_blob_sha",
    "run_id",
    "run_attempt",
    "event",
    "pr_number",
    "base_ref",
    "head_ref",
    "candidate_sha",
    "candidate_tree_sha",
    "base_sha",
    "base_tree_sha",
    "predecessor_main_sha",
    "predecessor_tree_sha",
    "allowlist_version",
    "allowlist_authority_comment",
    "allowlist_sha256",
    "changed_path_set_sha256",
    "validation_toolchain_lock_sha256",
    "trusted_preparation_receipt_sha256",
    "predecessor_replay_artifact_id",
    "predecessor_replay_sha256",
    "predecessor_replay_receipt_sha256",
    "inherited_v1_pr_run_id",
    "inherited_v1_pr_artifact_id",
    "inherited_v1_pr_artifact_sha256",
)


def _load_a0_hosted_schema(schema_root: Path) -> dict[str, Any]:
    binding = A0_HOSTED_SCHEMA_BINDING
    schema_path = schema_root / binding["filename"]
    content = _read_bounded_schema(schema_path, "A0 hosted schema source")
    digest = hashlib.sha256(content).hexdigest()
    if digest not in binding["sha256"]:
        fail("A0 hosted schema source SHA-256 drift")
    if content.startswith(b"\xef\xbb\xbf"):
        fail("A0 hosted schema UTF-8 BOM forbidden")
    try:
        schema = json.loads(
            content.decode("utf-8", "strict"),
            object_pairs_hook=_pairs_unique,
            parse_int=_parse_integer,
            parse_float=_parse_float,
            parse_constant=_parse_constant,
        )
    except (UnicodeDecodeError, ValueError, TypeError, RecursionError):
        fail("A0 hosted schema source is invalid JSON")
    if not isinstance(schema, dict):
        fail("A0 hosted schema root must be an object")
    _check_strings(schema)
    if schema.get("$id") != binding["schema_id"]:
        fail("A0 hosted schema ID drift")
    if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
        fail("A0 hosted schema dialect drift")
    return schema


def _validate_a0_hosted_schema_documents(
    documents: dict[str, dict[str, Any]],
    schema_root: Path,
    filename_set_sha256: str,
) -> str:
    _ordinary_schema_root(schema_root)
    try:
        from importlib.metadata import PackageNotFoundError, version
        from jsonschema import Draft202012Validator, FormatChecker
        from jsonschema.exceptions import SchemaError, ValidationError

        jsonschema_version = version("jsonschema")
    except (ImportError, PackageNotFoundError):
        fail("jsonschema package unavailable for A0 hosted schema preflight")
    if jsonschema_version != EXPECTED_JSONSCHEMA_VERSION:
        fail("jsonschema package version differs from A0 hosted schema preflight pin")
    schema = _load_a0_hosted_schema(schema_root)
    envelope = {
        "authority": "nxb-v11-a0-hosted-substrate-v1",
        "schema_version": 1,
        "filename_set_sha256": filename_set_sha256,
        "documents": documents,
    }
    try:
        Draft202012Validator.check_schema(schema)
        Draft202012Validator(
            schema, format_checker=FormatChecker()
        ).validate(envelope)
    except SchemaError:
        fail("A0 hosted schema contract invalid")
    except ValidationError:
        fail("A0 hosted schema semantic validation failed")
    return jsonschema_version


def _validate_a0_hosted_internal_dag(
    documents: dict[str, dict[str, Any]], entry_hashes: dict[str, str]
) -> None:
    independent = documents["independent-validation.json"]
    receipt = documents["a0-substrate-receipt.json"]
    policy = documents["compatibility-policy-summary.json"]
    known_error = documents["known-error-scan.json"]

    for document_name, field_name in A0_PRIMARY_HASH_FIELDS.items():
        expected = entry_hashes[document_name]
        if independent.get(field_name) != expected:
            fail(f"A0 independent-validation DAG hash mismatch for {document_name}")
        if receipt.get(field_name) != expected:
            fail(f"A0 substrate receipt DAG hash mismatch for {document_name}")

    if receipt.get("independent_validation_sha256") != entry_hashes[
        "independent-validation.json"
    ]:
        fail("A0 substrate receipt independent-validation SHA-256 mismatch")

    for field_name in A0_DAG_COMMON_FIELDS:
        if independent.get(field_name) != receipt.get(field_name):
            fail(f"A0 terminal DAG identity mismatch: {field_name}")

    for field_name in (
        "repository",
        "candidate_sha",
        "candidate_tree_sha",
        "base_sha",
        "base_tree_sha",
        "predecessor_main_sha",
        "predecessor_tree_sha",
    ):
        if policy.get(field_name) != independent.get(field_name):
            fail(f"A0 policy-summary identity mismatch: {field_name}")

    if policy.get("compatibility_policy_sha256") != receipt.get(
        "compatibility_policy_sha256"
    ):
        fail("A0 compatibility-policy digest mismatch")
    if policy.get("compatibility_policy_schema_sha256") != receipt.get(
        "compatibility_policy_schema_sha256"
    ):
        fail("A0 compatibility-policy schema digest mismatch")
    if policy.get("validation_toolchain_lock_sha256") != independent.get(
        "validation_toolchain_lock_sha256"
    ):
        fail("A0 validation-toolchain lock mismatch in independent validation")
    if policy.get("validation_toolchain_lock_sha256") != receipt.get(
        "validation_toolchain_lock_sha256"
    ):
        fail("A0 validation-toolchain lock mismatch in substrate receipt")
    if policy.get("powershell_module_lock_sha256") != receipt.get(
        "powershell_module_lock_sha256"
    ):
        fail("A0 PowerShell module-lock digest mismatch")
    if policy.get("selected_host_python_dependency_lock_sha256") != receipt.get(
        "python_dependency_lock_sha256"
    ):
        fail("A0 Python dependency-lock digest mismatch")

    if known_error.get("status") != "passed":
        fail("A0 known-error scan did not pass")
    if known_error.get("finding_count") != 0:
        fail("A0 known-error scan contains findings")
    if known_error.get("failure_override_permitted") is not False:
        fail("A0 known-error failure override forbidden")

    if independent.get("requirements_total") != independent.get("requirements_passed"):
        fail("A0 independent requirements were not all passed")
    if independent.get("requirements_all_passed") is not True:
        fail("A0 independent requirements-all-passed flag is false")
    if independent.get("negative_controls_total") != independent.get(
        "negative_controls_passed"
    ):
        fail("A0 negative controls were not all passed")
    if independent.get("negative_controls_all_passed") is not True:
        fail("A0 negative-controls-all-passed flag is false")

    boundary = independent.get("production_boundary")
    if not isinstance(boundary, dict):
        fail("A0 production boundary must be an object")
    production_mapping = {
        "private_key_used": "production_private_key_used",
        "signer_used": "production_signer_used",
        "tag_mutation": "production_tag_created",
        "release_mutation": "production_release_updated",
        "merge_mutation": "production_merge_mutated",
        "repository_protection_mutated": "repository_protection_mutated",
    }
    for boundary_field, receipt_field in production_mapping.items():
        if boundary.get(boundary_field) != receipt.get(receipt_field):
            fail(f"A0 production-boundary mismatch: {receipt_field}")

    if receipt.get("review_entries") != 6:
        fail("A0 substrate receipt review cardinality mismatch")
    if independent.get("admitted") is not False or receipt.get("admitted") is not False:
        fail("A0 claim-free DAG cannot self-admit")
    if independent.get("physical_compatibility_claims") != 0:
        fail("A0 independent validation cannot claim physical compatibility")
    if receipt.get("physical_compatibility_claims") != 0:
        fail("A0 substrate receipt cannot claim physical compatibility")
    if independent.get("native_wpt_dispatch_performed") is not False:
        fail("A0 independent validation cannot claim native WPT dispatch")
    if receipt.get("native_wpt_dispatch_performed") is not False:
        fail("A0 substrate receipt cannot claim native WPT dispatch")


PRIMARY_HASH_FIELDS = {
    "environment-fingerprint.json": "environment_fingerprint_sha256",
    "compatibility-plan.json": "compatibility_plan_sha256",
    "endurance-cycle-summary.json": "endurance_summary_sha256",
    "known-error-scan.json": "known_error_scan_sha256",
}

DAG_COMMON_FIELDS = (
    "repository",
    "workflow_id",
    "workflow_blob_sha",
    "harness_manifest_sha256",
    "dispatcher_sha",
    "dispatcher_tree_sha",
    "candidate_sha",
    "candidate_tree_sha",
    "base_sha",
    "base_tree_sha",
    "predecessor_main_sha",
    "predecessor_tree_sha",
    "cell_id",
    "support_class",
    "axis",
    "intent_sha256",
    "policy_sha256",
    "fingerprint_sha256",
    "predecessor_replay_artifact_id",
    "predecessor_replay_sha256",
    "predecessor_replay_receipt_sha256",
)


def _validate_internal_review_dag(
    documents: dict[str, dict[str, Any]], entry_hashes: dict[str, str]
) -> None:
    independent = documents["independent-validation.json"]
    receipt = documents["compatibility-certification-receipt.json"]

    for document_name, field_name in PRIMARY_HASH_FIELDS.items():
        expected = entry_hashes[document_name]
        if independent.get(field_name) != expected:
            fail(f"independent-validation DAG hash mismatch for {document_name}")
        if receipt.get(field_name) != expected:
            fail(f"certification receipt DAG hash mismatch for {document_name}")

    if receipt.get("independent_validation_sha256") != entry_hashes[
        "independent-validation.json"
    ]:
        fail("certification receipt independent-validation SHA-256 mismatch")

    for field_name in DAG_COMMON_FIELDS:
        if independent.get(field_name) != receipt.get(field_name):
            fail(f"terminal DAG identity mismatch: {field_name}")

    if independent.get("selector_provenance") != receipt.get("selector_provenance"):
        fail("terminal DAG selector provenance mismatch")
    selector = independent.get("selector_provenance")
    if not isinstance(selector, dict):
        fail("terminal DAG selector provenance must be an object")
    if selector.get("compatibility_policy_sha256") != independent.get("policy_sha256"):
        fail("independent validation policy/selector digest mismatch")
    if receipt.get("selector_provenance", {}).get(
        "compatibility_policy_sha256"
    ) != receipt.get("policy_sha256"):
        fail("certification receipt policy/selector digest mismatch")

    for independent_field, receipt_field in (
        ("run_id", "trusted_native_run_id"),
        ("run_attempt", "trusted_native_run_attempt"),
        ("job_id", "trusted_native_job_id"),
        ("job_name", "trusted_native_job_name"),
    ):
        if independent.get(independent_field) != receipt.get(receipt_field):
            fail(f"trusted-native DAG identity mismatch: {receipt_field}")

    environment = documents["environment-fingerprint.json"]
    plan = documents["compatibility-plan.json"]
    endurance = documents["endurance-cycle-summary.json"]
    known_error = documents["known-error-scan.json"]

    candidate_sha = independent.get("candidate_sha")
    candidate_tree = independent.get("candidate_tree_sha")
    if environment.get("head_sha") != candidate_sha:
        fail("environment/candidate SHA mismatch")
    if environment.get("head_tree_sha") != candidate_tree:
        fail("environment/candidate tree mismatch")
    if plan.get("candidate", {}).get("sha") != candidate_sha:
        fail("plan/candidate SHA mismatch")
    if plan.get("candidate", {}).get("tree_sha") != candidate_tree:
        fail("plan/candidate tree mismatch")
    if endurance.get("candidate", {}).get("sha") != candidate_sha:
        fail("endurance/candidate SHA mismatch")
    if endurance.get("candidate", {}).get("tree_sha") != candidate_tree:
        fail("endurance/candidate tree mismatch")

    if plan.get("base", {}).get("sha") != independent.get("base_sha"):
        fail("plan/base SHA mismatch")
    if plan.get("base", {}).get("tree_sha") != independent.get("base_tree_sha"):
        fail("plan/base tree mismatch")
    if plan.get("predecessor", {}).get("main_sha") != independent.get(
        "predecessor_main_sha"
    ):
        fail("plan/predecessor SHA mismatch")
    if plan.get("predecessor", {}).get("main_tree_sha") != independent.get(
        "predecessor_tree_sha"
    ):
        fail("plan/predecessor tree mismatch")

    if environment.get("cell_id") != independent.get("cell_id"):
        fail("environment/cell mismatch")
    if environment.get("support_class") != independent.get("support_class"):
        fail("environment/support class mismatch")
    if plan.get("cell", {}).get("id") != independent.get("cell_id"):
        fail("plan/cell mismatch")
    if plan.get("cell", {}).get("support_class") != independent.get("support_class"):
        fail("plan/support class mismatch")
    if plan.get("cell", {}).get("axis") != independent.get("axis"):
        fail("plan/axis mismatch")
    if endurance.get("cell_id") != independent.get("cell_id"):
        fail("endurance/cell mismatch")
    if endurance.get("support_class") != independent.get("support_class"):
        fail("endurance/support class mismatch")

    if plan.get("intent", {}).get("sha256") != independent.get("intent_sha256"):
        fail("plan/intent digest mismatch")
    if endurance.get("intent_sha256") != independent.get("intent_sha256"):
        fail("endurance/intent digest mismatch")
    if environment.get("policy_sha256") != independent.get("policy_sha256"):
        fail("environment/policy digest mismatch")
    if plan.get("policy", {}).get("sha256") != independent.get("policy_sha256"):
        fail("plan/policy digest mismatch")
    if endurance.get("policy_sha256") != independent.get("policy_sha256"):
        fail("endurance/policy digest mismatch")
    if environment.get("fingerprint_sha256") != independent.get("fingerprint_sha256"):
        fail("environment/fingerprint digest mismatch")
    if endurance.get("fingerprint_sha256") != independent.get("fingerprint_sha256"):
        fail("endurance/fingerprint digest mismatch")

    production_boundary = independent.get("production_boundary")
    if plan.get("production_boundary") != production_boundary:
        fail("plan/production boundary mismatch")
    if endurance.get("production_boundary") != production_boundary:
        fail("endurance/production boundary mismatch")
    if receipt.get("production_boundary") != production_boundary:
        fail("terminal production boundary mismatch")

    if plan.get("review", {}).get("entry_count") != 6:
        fail("plan review cardinality mismatch")
    if endurance.get("review", {}).get("entry_count") != 6:
        fail("endurance review cardinality mismatch")
    if receipt.get("review_entry_count") != 6:
        fail("receipt review cardinality mismatch")

    if known_error.get("status") != "passed":
        fail("known-error scan did not pass")
    if known_error.get("finding_count") != 0:
        fail("known-error scan contains findings")
    if known_error.get("failure_override_permitted") is not False:
        fail("known-error failure override forbidden")

    if independent.get("physical_compatibility_claimed") is not False:
        fail("independent validation cannot claim physical compatibility")
    if receipt.get("physical_compatibility_claimed") is not False:
        fail("claim-free review DAG cannot claim physical compatibility")


def inspect_zip(
    path: Path,
    authority_mode: str,
    expected_digest: str | None = None,
    schema_root: Path | None = None,
    schema_scope: str = "primary",
) -> dict[str, Any]:
    """Check byte/path/canonical JSON structure only. Never return 'admitted'."""
    if authority_mode not in AUTHORITY_MODE_NAMES:
        fail("unknown authority mode")
    expected_names = AUTHORITY_MODE_NAMES[authority_mode]
    expected_filename_set_sha = _filename_set_sha256(
        authority_mode, list(expected_names)
    )
    if expected_filename_set_sha != FROZEN_FILENAME_SET_SHA256[authority_mode]:
        fail("internal filename-set authority contract drift")
    expected_zip_metadata = _ordinary_zip(path)
    # Parse and hash one bounded byte snapshot. Reopening the path for parsing
    # would allow a replacement between hash verification and entry inspection.
    # Also verify the opened descriptor and pathname still identify the file
    # that passed the initial ordinary-path inspection.
    try:
        with path.open("rb") as stream:
            _verify_review_zip_identity(expected_zip_metadata, os.fstat(stream.fileno()))
            archive_bytes = stream.read(MAX_ZIP_BYTES + 1)
            _verify_review_zip_identity(expected_zip_metadata, os.fstat(stream.fileno()))
        _verify_review_zip_identity(expected_zip_metadata, path.lstat())
    except OSError:
        fail("review ZIP is absent or unreadable")
    if not archive_bytes or len(archive_bytes) > MAX_ZIP_BYTES:
        fail("review ZIP exceeds bounded preflight size")
    if len(archive_bytes) != expected_zip_metadata.st_size:
        fail("review ZIP changed during read")
    outer_sha = hashlib.sha256(archive_bytes).hexdigest()
    if expected_digest is not None:
        if SHA256_RE.fullmatch(expected_digest) is None:
            fail("expected ZIP digest must be lowercase SHA-256")
        if outer_sha != expected_digest:
            fail("independently supplied ZIP digest mismatch")

    try:
        with zipfile.ZipFile(io.BytesIO(archive_bytes), mode="r", allowZip64=False) as archive:
            entries = archive.infolist()
            if len(entries) != len(expected_names):
                fail("review entry count is not exactly six")
            if archive.comment:
                fail("review ZIP comment forbidden")
            names = [entry.filename for entry in entries]
            if len(set(names)) != len(names) or len({name.casefold() for name in names}) != len(names):
                fail("duplicate or case-colliding review entries")
            if set(names) != expected_names:
                fail("review ZIP names differ from selected authority-mode contract")
            observed_filename_set_sha = _filename_set_sha256(authority_mode, names)
            if observed_filename_set_sha != expected_filename_set_sha:
                fail("review filename-set digest mismatch")
            for entry in entries:
                _regular_zip_entry(entry, expected_names)
            if sum(entry.file_size for entry in entries) > MAX_TOTAL_UNCOMPRESSED:
                fail("review uncompressed bytes exceed preflight ceiling")
            rows: list[dict[str, Any]] = []
            documents: dict[str, dict[str, Any]] = {}
            for entry in sorted(entries, key=lambda item: item.filename.encode("utf-8")):
                try:
                    with archive.open(entry, "r") as data:
                        content = data.read(MAX_ENTRY_BYTES + 1)
                        if len(content) > MAX_ENTRY_BYTES or data.read(1):
                            fail("decompressed entry exceeds preflight ceiling")
                except (RuntimeError, OSError, EOFError, ValueError, zipfile.BadZipFile) as exc:
                    if isinstance(exc, PreflightError):
                        raise
                    fail("ZIP entry failed decompression/CRC verification")
                documents[entry.filename] = _canonical_document(
                    content, entry.filename, authority_mode
                )
                rows.append({
                    "name": entry.filename,
                    "byte_length": len(content),
                    "sha256": hashlib.sha256(content).hexdigest(),
                })
    except (OSError, zipfile.BadZipFile, zipfile.LargeZipFile):
        fail("malformed or unsupported ZIP envelope")

    entry_hashes = {row["name"]: row["sha256"] for row in rows}
    primary_schema_documents_validated = 0
    terminal_schema_documents_validated = 0
    a0_hosted_schema_validated = False
    internal_evidence_dag_validated = False
    if schema_root is not None:
        if schema_scope == "a0-hosted":
            if authority_mode != "a0-hosted":
                fail("A0 hosted schema preflight requires a0-hosted authority mode")
            schema_validator_version = _validate_a0_hosted_schema_documents(
                documents, schema_root, expected_filename_set_sha
            )
            _validate_a0_hosted_internal_dag(documents, entry_hashes)
            status = "A0_HOSTED_SCHEMA_DAG_VALIDATED"
            schema_semantics_validated = True
            a0_hosted_schema_validated = True
            internal_evidence_dag_validated = True
            unverified_gates = [
                "validation_toolchain_provenance",
                "policy_and_lock_source_bindings",
                "predecessor_replay_artifact_admission",
                "github_run_artifact_and_job_provenance",
                "candidate_base_and_predecessor_cas",
                "inherited_v1_artifact_admission",
                "negative_control_admission",
            ]
        else:
            if authority_mode != "physical-compatibility":
                fail("schema preflight requires physical-compatibility authority mode")
            if schema_scope == "review":
                schema_validator_version = _validate_review_schema_documents(
                    documents, schema_root
                )
                _validate_internal_review_dag(documents, entry_hashes)
                status = "REVIEW_SCHEMAS_DAG_VALIDATED"
                schema_semantics_validated = True
                primary_schema_documents_validated = len(PRIMARY_SCHEMA_BINDINGS)
                terminal_schema_documents_validated = len(TERMINAL_SCHEMA_BINDINGS)
                internal_evidence_dag_validated = True
                unverified_gates = [
                    "validation_toolchain_provenance",
                    "policy_and_lock_bindings",
                    "predecessor_replay",
                    "github_run_artifact_and_job_provenance",
                    "trusted_native_identity",
                    "pre_post_environment_stability",
                    "negative_control_admission",
                ]
            elif schema_scope == "primary":
                schema_validator_version = _validate_primary_schema_documents(
                    documents, schema_root
                )
                status = "PRIMARY_SCHEMAS_VALIDATED"
                schema_semantics_validated = True
                primary_schema_documents_validated = len(PRIMARY_SCHEMA_BINDINGS)
                unverified_gates = [
                    "validation_toolchain_provenance",
                    "internal_evidence_dag",
                    "policy_and_lock_bindings",
                    "predecessor_replay",
                    "github_run_artifact_and_job_provenance",
                    "trusted_native_identity",
                    "pre_post_environment_stability",
                    "negative_control_admission",
                ]
            else:
                fail("unknown schema preflight scope")
    else:
        status = "STRUCTURE_ONLY"
        schema_semantics_validated = False
        schema_validator_version = None
        unverified_gates = [
            "schema_semantics",
            "internal_evidence_dag",
            "policy_and_lock_bindings",
            "predecessor_replay",
            "github_run_artifact_and_job_provenance",
            "trusted_native_identity",
            "pre_post_environment_stability",
            "negative_control_admission",
        ]

    return {
        "authority": AUTHORITY,
        "status": status,
        "authority_mode": authority_mode,
        "expected_filename_set_sha256": expected_filename_set_sha,
        "observed_filename_set_sha256": observed_filename_set_sha,
        "filename_count": len(rows),
        "admitted": False,
        "physical_compatibility_claimed": False,
        "native_wpt_dispatch_performed": False,
        "repository_mutated": False,
        "zip_sha256": outer_sha,
        "entry_count": len(rows),
        "entries": rows,
        "schema_semantics_validated": schema_semantics_validated,
        "primary_schema_documents_validated": primary_schema_documents_validated,
        "terminal_schema_documents_validated": terminal_schema_documents_validated,
        "a0_hosted_schema_validated": a0_hosted_schema_validated,
        "internal_evidence_dag_validated": internal_evidence_dag_validated,
        "schema_validator_version": schema_validator_version,
        "schema_validator_package_provenance_admitted": False,
        "unverified_gates": unverified_gates,
    }



# Seven-entry frozen predecessor-replay external preflight.
# Re-homed here by A0 scope repair; no separate executable path is authorized.
PREDECESSOR_REPLAY_AUTHORITY = "nxb-v11-predecessor-replay-envelope-preflight-v1"

PREDECESSOR_WRAPPER_AUTHORITY = "nxb-v11-predecessor-replay-v1"

PREDECESSOR_WRAPPER_SCHEMA_FILE = "nxb-v11-predecessor-replay-receipt.schema.json"

PREDECESSOR_WRAPPER_SCHEMA_ID = "urn:nxb:schema:nxb-v11-predecessor-replay-receipt:v1"

PREDECESSOR_WRAPPER_SCHEMA_SHA256 = "e305ff9d4e9e143f21650ed3dcdd02ceaf17542fc601ce35fc2cff3cfb7f43b8"

PREDECESSOR_EXPECTED_NAMES = frozenset(
    {
        "hosted-ci-receipt.json",
        "known-error-scan.json",
        "pester-ps51.xml",
        "pester-ps7.xml",
        "ps51-summary.json",
        "run-ps51.ps1",
        "predecessor-replay-receipt.json",
    }
)

PREDECESSOR_CHILD_HASH_FIELDS = {
    "hosted-ci-receipt.json": "hosted_ci_receipt_sha256",
    "known-error-scan.json": "known_error_scan_sha256",
    "pester-ps51.xml": "pester_ps51_xml_sha256",
    "pester-ps7.xml": "pester_ps7_xml_sha256",
    "ps51-summary.json": "ps51_summary_sha256",
    "run-ps51.ps1": "run_ps51_sha256",
}

PREDECESSOR_FROZEN_PS7_TOTAL = 916

PREDECESSOR_FROZEN_PS51_PASSED = 909

PREDECESSOR_FROZEN_PS51_NOT_RUN = 7

PREDECESSOR_FROZEN_PS51_EXCLUDED_TAG = "PS7Only"

PREDECESSOR_FROZEN_RUN_PS51_SHA256 = (
    "035ac21a439c448be6ad6d946bd3526162f678b1858d09562b69c5616a49397b"
)

PREDECESSOR_MAX_ZIP_BYTES = 8 * 1024 * 1024

PREDECESSOR_MAX_ENTRY_BYTES = 2 * 1024 * 1024

PREDECESSOR_MAX_TOTAL_UNCOMPRESSED = 8 * 1024 * 1024

PREDECESSOR_GIT40_RE = re.compile(r"^[0-9a-f]{40}$")

PREDECESSOR_DECIMAL_RE = re.compile(r"^[1-9][0-9]*$")

def _predecessor_strict_json(content: bytes, name: str) -> dict[str, Any]:
    if content.startswith(b"\xef\xbb\xbf"):
        fail(f"{name}: UTF-8 BOM forbidden")
    try:
        decoded = content.decode("utf-8", "strict")
        document = json.loads(
            decoded,
            object_pairs_hook=_pairs_unique,
            parse_int=_parse_integer,
            parse_float=_parse_float,
            parse_constant=_parse_constant,
        )
    except (UnicodeDecodeError, ValueError, TypeError, RecursionError) as exc:
        if isinstance(exc, PreflightError):
            raise
        fail(f"{name}: invalid JSON")
    if not isinstance(document, dict):
        fail(f"{name}: JSON root must be an object")
    _check_strings(document)
    return document


def _predecessor_ordinary_path(path: Path, *, directory: bool) -> None:
    if not path.is_absolute():
        fail("input path must be absolute")
    try:
        metadata = path.lstat()
    except OSError:
        fail("input path is absent or unreadable")
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected(metadata.st_mode):
        fail("input path has the wrong filesystem type")
    if getattr(metadata, "st_file_attributes", 0) & getattr(
        stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400
    ):
        fail("input path reparse-point forbidden")
    _ordinary_parent_directories(path, "input path")


def _predecessor_regular_zip_entry(info: zipfile.ZipInfo) -> None:
    if info.filename not in PREDECESSOR_EXPECTED_NAMES:
        fail("unexpected, nested, or unsafe predecessor replay entry")
    if info.is_dir():
        fail("directory predecessor replay entry forbidden")
    if info.flag_bits & 0x1:
        fail("encrypted predecessor replay entry forbidden")
    if info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
        fail("unsupported predecessor replay compression method")
    if info.file_size < 0 or info.file_size > PREDECESSOR_MAX_ENTRY_BYTES:
        fail("predecessor replay entry exceeds byte ceiling")
    if info.compress_size < 0 or info.compress_size > PREDECESSOR_MAX_ZIP_BYTES:
        fail("predecessor replay compressed entry exceeds byte ceiling")
    if info.create_system == 3:
        unix_mode = (info.external_attr >> 16) & 0xFFFF
        if unix_mode:
            kind = stat.S_IFMT(unix_mode)
            if kind not in (0, stat.S_IFREG):
                fail("nonregular UNIX predecessor replay entry metadata")
    if info.external_attr & 0x10:
        fail("directory-attribute predecessor replay entry forbidden")
    if info.filename != unicodedata.normalize("NFC", info.filename):
        fail("non-NFC predecessor replay entry name")


def _predecessor_load_wrapper_schema(schema_root: Path) -> dict[str, Any]:
    _predecessor_ordinary_path(schema_root, directory=True)
    path = schema_root / PREDECESSOR_WRAPPER_SCHEMA_FILE
    content = _read_bounded_schema(path, "predecessor replay wrapper schema")
    if hashlib.sha256(content).hexdigest() != PREDECESSOR_WRAPPER_SCHEMA_SHA256:
        fail("predecessor replay wrapper schema SHA-256 drift")
    schema = _predecessor_strict_json(content, PREDECESSOR_WRAPPER_SCHEMA_FILE)
    if schema.get("$id") != PREDECESSOR_WRAPPER_SCHEMA_ID:
        fail("predecessor replay wrapper schema ID drift")
    if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
        fail("predecessor replay wrapper schema dialect drift")
    return schema


def _predecessor_validate_wrapper_schema(
    wrapper: dict[str, Any], schema_root: Path
) -> str:
    try:
        from importlib.metadata import PackageNotFoundError, version
        from jsonschema import Draft202012Validator, FormatChecker
        from jsonschema.exceptions import SchemaError, ValidationError

        jsonschema_version = version("jsonschema")
    except (ImportError, PackageNotFoundError):
        fail("jsonschema package unavailable for predecessor replay preflight")
    if jsonschema_version != EXPECTED_JSONSCHEMA_VERSION:
        fail("jsonschema package version differs from predecessor replay pin")
    schema = _predecessor_load_wrapper_schema(schema_root)
    try:
        Draft202012Validator.check_schema(schema)
        Draft202012Validator(
            schema, format_checker=FormatChecker()
        ).validate(wrapper)
    except SchemaError:
        fail("predecessor replay wrapper schema contract invalid")
    except ValidationError:
        fail("predecessor replay wrapper schema semantic validation failed")
    return jsonschema_version


def _predecessor_positive_int_text(value: int, label: str) -> str:
    text = str(value)
    if PREDECESSOR_DECIMAL_RE.fullmatch(text) is None:
        fail(f"{label} must be a positive decimal integer")
    return text


def _predecessor_expect_sha(value: str, label: str, *, git: bool = False) -> str:
    pattern = PREDECESSOR_GIT40_RE if git else SHA256_RE
    if pattern.fullmatch(value) is None:
        fail(f"{label} has invalid lowercase digest syntax")
    return value


def _predecessor_xml_results(content: bytes, name: str) -> dict[str, int]:
    # The byte-level DTD scanner is only complete for UTF-8 XML. An XML
    # parser also accepts UTF-16, where every ASCII DTD byte is interleaved
    # with NUL and the scanner would otherwise miss forbidden declarations.
    if b"\x00" in content:
        fail(f"{name}: XML must be UTF-8 without NUL bytes")
    try:
        content.decode("utf-8", "strict")
    except UnicodeDecodeError:
        fail(f"{name}: XML must be UTF-8")
    if b"<!DOCTYPE" in content.upper() or b"<!ENTITY" in content.upper():
        fail(f"{name}: XML DTD/entity declarations forbidden")
    try:
        root = ET.fromstring(content)
    except (ET.ParseError, ValueError, RecursionError):
        fail(f"{name}: invalid XML")
    if root.tag != "test-results":
        fail(f"{name}: unexpected NUnit root element")
    if root.attrib.get("name") != "Pester":
        fail(f"{name}: unexpected NUnit producer name")

    result: dict[str, int] = {}
    for field in (
        "total",
        "errors",
        "failures",
        "not-run",
        "inconclusive",
        "ignored",
        "skipped",
        "invalid",
    ):
        raw = root.attrib.get(field)
        if raw is None or not raw.isascii() or not raw.isdigit():
            fail(f"{name}: invalid NUnit {field} attribute")
        result[field] = int(raw)
    for field in ("errors", "failures", "inconclusive", "ignored", "skipped", "invalid"):
        if result[field] != 0:
            fail(f"{name}: NUnit failure/skip state is nonzero")
    return result


def _predecessor_all_empty_known_error_findings(value: Any) -> bool:
    # JSON is an acyclic, byte-bounded tree. An explicit stack preserves the
    # recursive all-empty semantics without consuming Python call-stack depth.
    pending = [value]
    while pending:
        current = pending.pop()
        if isinstance(current, list):
            if current:
                return False
        elif isinstance(current, dict):
            pending.extend(current.values())
        else:
            return False
    return True


def _verify_predecessor_zip_identity(
    expected: os.stat_result, observed: os.stat_result
) -> None:
    fields = ("st_dev", "st_ino", "st_mode", "st_size", "st_mtime_ns")
    if (
        not stat.S_ISREG(observed.st_mode)
        or stat.S_ISLNK(observed.st_mode)
        or getattr(observed, "st_file_attributes", 0)
        & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
        or any(getattr(expected, key) != getattr(observed, key) for key in fields)
    ):
        fail("predecessor replay ZIP changed during read")


def inspect_predecessor_replay(
    path: Path,
    schema_root: Path,
    expected_zip_sha256: str,
    expected_predecessor_main_sha: str,
    expected_predecessor_tree_sha: str,
    expected_observer_successor_head_sha: str,
    expected_run_id: int,
    expected_run_attempt: int,
    expected_artifact_name: str,
    expected_predecessor_policy_sha256: str,
) -> dict[str, Any]:
    _predecessor_expect_sha(expected_zip_sha256, "expected ZIP SHA-256")
    _predecessor_expect_sha(expected_predecessor_main_sha, "expected predecessor main SHA", git=True)
    _predecessor_expect_sha(expected_predecessor_tree_sha, "expected predecessor tree SHA", git=True)
    _predecessor_expect_sha(
        expected_observer_successor_head_sha,
        "expected observer successor head SHA",
        git=True,
    )
    _predecessor_expect_sha(
        expected_predecessor_policy_sha256,
        "expected predecessor policy SHA-256",
    )
    run_id_text = _predecessor_positive_int_text(expected_run_id, "expected run ID")
    attempt_text = _predecessor_positive_int_text(expected_run_attempt, "expected run attempt")

    expected_reconstructed_name = (
        f"{PREDECESSOR_WRAPPER_AUTHORITY}-{expected_predecessor_main_sha}-"
        f"{expected_observer_successor_head_sha}-{run_id_text}-{attempt_text}"
    )
    if expected_artifact_name != expected_reconstructed_name:
        fail("independently supplied predecessor replay artifact name mismatch")

    _predecessor_ordinary_path(path, directory=False)
    try:
        metadata = path.lstat()
        if metadata.st_size <= 0 or metadata.st_size > PREDECESSOR_MAX_ZIP_BYTES:
            fail("predecessor replay ZIP exceeds bounded size")
        # Bind the original filesystem identity to the opened descriptor and
        # subsequent pathname without parsing a second, possibly replaced ZIP.
        with path.open("rb") as stream:
            _verify_predecessor_zip_identity(metadata, os.fstat(stream.fileno()))
            archive_bytes = stream.read(PREDECESSOR_MAX_ZIP_BYTES + 1)
            _verify_predecessor_zip_identity(metadata, os.fstat(stream.fileno()))
        _verify_predecessor_zip_identity(metadata, path.lstat())
    except OSError:
        fail("predecessor replay ZIP unreadable")
    if not archive_bytes or len(archive_bytes) > PREDECESSOR_MAX_ZIP_BYTES:
        fail("predecessor replay ZIP exceeds bounded size")
    outer_sha256 = hashlib.sha256(archive_bytes).hexdigest()
    if outer_sha256 != expected_zip_sha256:
        fail("independently supplied predecessor replay ZIP digest mismatch")

    try:
        with zipfile.ZipFile(
            io.BytesIO(archive_bytes), mode="r", allowZip64=False
        ) as archive:
            entries = archive.infolist()
            if archive.comment:
                fail("predecessor replay ZIP comment forbidden")
            if len(entries) != len(PREDECESSOR_EXPECTED_NAMES):
                fail("predecessor replay entry count is not exactly seven")
            names = [entry.filename for entry in entries]
            if len(set(names)) != len(names):
                fail("duplicate predecessor replay entry names")
            if len({name.casefold() for name in names}) != len(names):
                fail("case-colliding predecessor replay entry names")
            if set(names) != PREDECESSOR_EXPECTED_NAMES:
                fail("predecessor replay entry set mismatch")
            for entry in entries:
                _predecessor_regular_zip_entry(entry)
            if sum(entry.file_size for entry in entries) > PREDECESSOR_MAX_TOTAL_UNCOMPRESSED:
                fail("predecessor replay uncompressed bytes exceed ceiling")

            contents: dict[str, bytes] = {}
            for entry in entries:
                try:
                    with archive.open(entry, "r") as stream:
                        content = stream.read(PREDECESSOR_MAX_ENTRY_BYTES + 1)
                        if len(content) > PREDECESSOR_MAX_ENTRY_BYTES or stream.read(1):
                            fail("predecessor replay entry exceeds decompression ceiling")
                except (RuntimeError, OSError, EOFError, ValueError, zipfile.BadZipFile):
                    fail("predecessor replay entry failed decompression/CRC verification")
                contents[entry.filename] = content
    except (OSError, zipfile.BadZipFile, zipfile.LargeZipFile):
        fail("malformed or unsupported predecessor replay ZIP")

    wrapper = _predecessor_strict_json(
        contents["predecessor-replay-receipt.json"],
        "predecessor-replay-receipt.json",
    )
    schema_validator_version = _predecessor_validate_wrapper_schema(wrapper, schema_root)

    if wrapper.get("authority") != PREDECESSOR_WRAPPER_AUTHORITY:
        fail("predecessor replay wrapper authority mismatch")
    if wrapper.get("entry_count") != 7:
        fail("predecessor replay wrapper cardinality mismatch")

    child_hashes: dict[str, str] = {}
    for name, field in PREDECESSOR_CHILD_HASH_FIELDS.items():
        digest = hashlib.sha256(contents[name]).hexdigest()
        child_hashes[name] = digest
        if wrapper.get(field) != digest:
            fail(f"predecessor replay child SHA-256 mismatch for {name}")

    if child_hashes["run-ps51.ps1"] != PREDECESSOR_FROZEN_RUN_PS51_SHA256:
        fail("frozen predecessor run-ps51.ps1 byte identity drift")

    expected_tuple = {
        "predecessor_main_sha": expected_predecessor_main_sha,
        "predecessor_tree_sha": expected_predecessor_tree_sha,
        "observer_successor_head_sha": expected_observer_successor_head_sha,
        "run_id": expected_run_id,
        "run_attempt": expected_run_attempt,
        "artifact_name": expected_artifact_name,
        "predecessor_policy_sha256": expected_predecessor_policy_sha256,
    }
    for field, expected in expected_tuple.items():
        if wrapper.get(field) != expected:
            fail(f"predecessor replay independent tuple mismatch: {field}")

    if wrapper.get("predecessor_source_semantics") != "frozen-v1":
        fail("predecessor replay source semantics drift")
    if wrapper.get("replay_environment_acquisition") != "successor-locked":
        fail("predecessor replay acquisition boundary drift")
    if wrapper.get("historical_environment_byte_identity_claimed") is not False:
        fail("predecessor replay historical byte-identity overclaim")
    if wrapper.get("pester_expected_partition_reproduced") is not True:
        fail("predecessor replay partition reproduction flag is false")
    if wrapper.get("known_error_findings") != 0:
        fail("predecessor replay wrapper reports known-error findings")
    if wrapper.get("analyzer_findings") != 0:
        fail("predecessor replay wrapper reports analyzer findings")

    hosted = _predecessor_strict_json(contents["hosted-ci-receipt.json"], "hosted-ci-receipt.json")
    known_error = _predecessor_strict_json(contents["known-error-scan.json"], "known-error-scan.json")
    ps51_summary = _predecessor_strict_json(contents["ps51-summary.json"], "ps51-summary.json")

    if (type(hosted.get("schema_version")) is not int or hosted.get("schema_version") != 1
            or hosted.get("status") != "passed"):
        fail("frozen hosted receipt status/schema mismatch")
    if hosted.get("authority") != "nxb-v1-ci-hosted-v1":
        fail("frozen hosted receipt authority mismatch")
    if hosted.get("head_sha") != expected_predecessor_main_sha:
        fail("frozen hosted receipt predecessor head mismatch")
    if hosted.get("pester_version") != wrapper.get("pester_version"):
        fail("frozen hosted receipt Pester version mismatch")
    if hosted.get("psscriptanalyzer_version") != wrapper.get(
        "psscriptanalyzer_version"
    ):
        fail("frozen hosted receipt PSScriptAnalyzer version mismatch")
    hosted_python = hosted.get("python_version")
    if hosted_python not in (
        wrapper.get("python_version"),
        f"Python {wrapper.get('python_version')}",
    ):
        fail("frozen hosted receipt Python version mismatch")
    if hosted.get("known_error_authority") != "nxb-v1-ci-known-error-scan-v1":
        fail("frozen hosted receipt known-error authority mismatch")
    if (type(hosted.get("known_error_findings")) is not int
            or hosted.get("known_error_findings") != 0):
        fail("frozen hosted receipt reports known-error findings")
    if (type(hosted.get("analyzer_findings")) is not int
            or hosted.get("analyzer_findings") != 0):
        fail("frozen hosted receipt reports analyzer findings")
    if hosted.get("analyzer_process_isolated") is not True:
        fail("frozen hosted receipt analyzer isolation flag is false")
    if hosted.get("production_release_updated") is not False:
        fail("frozen hosted receipt claims production release mutation")

    frozen_hosted_counts = {
        "ps7_passed": PREDECESSOR_FROZEN_PS7_TOTAL,
        "ps7_total": PREDECESSOR_FROZEN_PS7_TOTAL,
        "ps7_not_run": 0,
        "ps51_passed": PREDECESSOR_FROZEN_PS51_PASSED,
        "ps51_total": PREDECESSOR_FROZEN_PS7_TOTAL,
        "ps51_not_run": PREDECESSOR_FROZEN_PS51_NOT_RUN,
        "ps51_excluded_tag": PREDECESSOR_FROZEN_PS51_EXCLUDED_TAG,
        "ps51_expected_excluded": PREDECESSOR_FROZEN_PS51_NOT_RUN,
    }
    for field, expected in frozen_hosted_counts.items():
        if type(hosted.get(field)) is not type(expected) or hosted.get(field) != expected:
            fail(f"frozen hosted receipt partition mismatch: {field}")

    if (type(known_error.get("schema_version")) is not int
            or known_error.get("schema_version") != 1
            or known_error.get("status") != "passed"):
        fail("frozen known-error scan status/schema mismatch")
    if known_error.get("authority") != "nxb-v1-ci-known-error-scan-v1":
        fail("frozen known-error scan authority mismatch")
    if type(known_error.get("finding_count")) is not int or known_error.get("finding_count") != 0:
        fail("frozen known-error scan contains findings")
    if known_error.get("failed_contracts") != []:
        fail("frozen known-error scan contains failed contracts")
    if not _predecessor_all_empty_known_error_findings(known_error.get("findings")):
        fail("frozen known-error scan finding buckets are not empty")

    expected_summary = {
        "passed": PREDECESSOR_FROZEN_PS51_PASSED,
        "failed": 0,
        "skipped": 0,
        "not_run": PREDECESSOR_FROZEN_PS51_NOT_RUN,
        "total": PREDECESSOR_FROZEN_PS7_TOTAL,
        "excluded_tag": PREDECESSOR_FROZEN_PS51_EXCLUDED_TAG,
        "expected_excluded": PREDECESSOR_FROZEN_PS51_NOT_RUN,
    }
    for field, expected in expected_summary.items():
        if type(ps51_summary.get(field)) is not type(expected) or ps51_summary.get(field) != expected:
            fail(f"frozen PS5.1 summary partition mismatch: {field}")

    ps7_xml = _predecessor_xml_results(contents["pester-ps7.xml"], "pester-ps7.xml")
    ps51_xml = _predecessor_xml_results(contents["pester-ps51.xml"], "pester-ps51.xml")
    if ps7_xml["total"] != PREDECESSOR_FROZEN_PS7_TOTAL or ps7_xml["not-run"] != 0:
        fail("frozen PS7 NUnit partition mismatch")
    # Pester's NUnit 2.5 writer reports the executed PS5.1 count in total and
    # excluded tests separately in not-run. The JSON summary retains logical
    # discovery total 916.
    if (
        ps51_xml["total"] != PREDECESSOR_FROZEN_PS51_PASSED
        or ps51_xml["not-run"] != PREDECESSOR_FROZEN_PS51_NOT_RUN
    ):
        fail("frozen PS5.1 NUnit partition mismatch")

    if wrapper.get("production_boundary") != {
        "private_key_used": False,
        "signer_used": False,
        "tag_mutation": False,
        "release_mutation": False,
        "merge_mutation": False,
        "repository_protection_mutated": False,
    }:
        fail("predecessor replay production boundary is not claim-free")

    return {
        "authority": PREDECESSOR_REPLAY_AUTHORITY,
        "status": "PREDECESSOR_REPLAY_ARTIFACT_VALIDATED",
        "admitted": False,
        "repository_mutated": False,
        "native_wpt_dispatch_performed": False,
        "production_mutation_claimed": False,
        "entry_count": len(PREDECESSOR_EXPECTED_NAMES),
        "zip_sha256": outer_sha256,
        "artifact_name": expected_artifact_name,
        "predecessor_main_sha": expected_predecessor_main_sha,
        "predecessor_tree_sha": expected_predecessor_tree_sha,
        "observer_successor_head_sha": expected_observer_successor_head_sha,
        "run_id": expected_run_id,
        "run_attempt": expected_run_attempt,
        "wrapper_schema_validated": True,
        "wrapper_schema_sha256": PREDECESSOR_WRAPPER_SCHEMA_SHA256,
        "schema_validator_version": schema_validator_version,
        "child_hash_bindings_validated": True,
        "frozen_hosted_receipt_validated": True,
        "frozen_known_error_scan_validated": True,
        "frozen_pester_partition_validated": True,
        "frozen_run_ps51_identity_validated": True,
        "production_boundary_validated": True,
        "frozen_partition": {
            "ps7_passed": PREDECESSOR_FROZEN_PS7_TOTAL,
            "ps7_total": PREDECESSOR_FROZEN_PS7_TOTAL,
            "ps51_passed": PREDECESSOR_FROZEN_PS51_PASSED,
            "ps51_total": PREDECESSOR_FROZEN_PS7_TOTAL,
            "ps51_not_run": PREDECESSOR_FROZEN_PS51_NOT_RUN,
            "ps51_excluded_tag": PREDECESSOR_FROZEN_PS51_EXCLUDED_TAG,
        },
        "unverified_gates": [
            "github_run_and_artifact_metadata_provenance",
            "detached_predecessor_worktree_cas",
            "runtime_and_package_byte_provenance",
            "successor_toolchain_acquisition_provenance",
            "a0_hosted_artifact_cross_binding",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument(
        "--mode",
        choices=[
            "structural-preflight",
            "primary-schema-preflight",
            "review-schema-dag-preflight",
            "a0-hosted-schema-dag-preflight",
            "predecessor-replay-external-preflight",
        ],
        required=True,
    )
    parser.add_argument(
        "--authority-mode",
        choices=sorted(AUTHORITY_MODE_NAMES),
        required=False,
        help="trusted caller-selected six-entry authority type",
    )
    parser.add_argument("--zip", required=True, help="absolute path to six-entry review ZIP")
    parser.add_argument("--expected-zip-sha256", help="independently supplied lowercase ZIP SHA-256")
    parser.add_argument(
        "--schema-root",
        help="absolute directory containing the exact frozen review schemas",
    )
    parser.add_argument("--expected-predecessor-main-sha")
    parser.add_argument("--expected-predecessor-tree-sha")
    parser.add_argument("--expected-observer-successor-head-sha")
    parser.add_argument("--expected-run-id", type=int)
    parser.add_argument("--expected-run-attempt", type=int)
    parser.add_argument("--expected-artifact-name")
    parser.add_argument("--expected-predecessor-policy-sha256")
    args = parser.parse_args()
    predecessor_only = (
        "expected_predecessor_main_sha",
        "expected_predecessor_tree_sha",
        "expected_observer_successor_head_sha",
        "expected_run_id",
        "expected_run_attempt",
        "expected_artifact_name",
        "expected_predecessor_policy_sha256",
    )
    if args.mode == "predecessor-replay-external-preflight":
        if args.authority_mode is not None:
            fail("predecessor replay mode does not accept --authority-mode")
        if args.schema_root is None:
            fail("predecessor replay mode requires --schema-root")
        if args.expected_zip_sha256 is None:
            fail("predecessor replay mode requires --expected-zip-sha256")
        missing = [name for name in predecessor_only if getattr(args, name) is None]
        if missing:
            fail("predecessor replay mode missing required binding: " + missing[0])
        report = inspect_predecessor_replay(
            Path(args.zip),
            Path(args.schema_root),
            args.expected_zip_sha256,
            args.expected_predecessor_main_sha,
            args.expected_predecessor_tree_sha,
            args.expected_observer_successor_head_sha,
            args.expected_run_id,
            args.expected_run_attempt,
            args.expected_artifact_name,
            args.expected_predecessor_policy_sha256,
        )
        print(json.dumps(report, sort_keys=True, ensure_ascii=False, separators=(",", ":")))
        return 0

    if args.authority_mode is None:
        fail("--authority-mode is required for six-entry review modes")
    if any(getattr(args, name) is not None for name in predecessor_only):
        fail("predecessor replay binding arguments require predecessor replay mode")
    schema_root: Path | None = None
    schema_scope = "primary"
    if args.mode in ("primary-schema-preflight", "review-schema-dag-preflight"):
        if args.authority_mode != "physical-compatibility":
            fail("schema preflight requires physical-compatibility authority mode")
        if args.schema_root is None:
            fail("schema preflight requires --schema-root")
        schema_root = Path(args.schema_root)
        if args.mode == "review-schema-dag-preflight":
            schema_scope = "review"
    elif args.mode == "a0-hosted-schema-dag-preflight":
        if args.authority_mode != "a0-hosted":
            fail("A0 hosted schema preflight requires a0-hosted authority mode")
        if args.schema_root is None:
            fail("A0 hosted schema preflight requires --schema-root")
        schema_root = Path(args.schema_root)
        schema_scope = "a0-hosted"
    elif args.schema_root is not None:
        fail("--schema-root is only valid with schema preflight modes")
    report = inspect_zip(
        Path(args.zip),
        args.authority_mode,
        args.expected_zip_sha256,
        schema_root,
        schema_scope,
    )
    print(json.dumps(report, sort_keys=True, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PreflightError as exc:
        print(f"NXB_V11_REVIEW_ZIP_PREFLIGHT_ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2)
