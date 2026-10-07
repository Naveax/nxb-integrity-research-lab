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


def _ordinary_zip(path: Path) -> None:
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
    # A regular leaf under a symlink/junction parent is not an ordinary path.
    current = path.parent
    while True:
        try:
            parent_metadata = current.lstat()
        except OSError:
            fail("review ZIP parent path is unreadable")
        if not stat.S_ISDIR(parent_metadata.st_mode):
            fail("review ZIP parent is not an ordinary directory")
        if getattr(parent_metadata, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400):
            fail("review ZIP parent reparse-point forbidden")
        if current.parent == current:
            break
        current = current.parent


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


def _load_primary_schema(schema_root: Path, document_name: str) -> dict[str, Any]:
    binding = PRIMARY_SCHEMA_BINDINGS[document_name]
    schema_path = schema_root / binding["filename"]
    try:
        metadata = schema_path.lstat()
        content = schema_path.read_bytes()
    except OSError:
        fail(f"{document_name}: primary schema source absent or unreadable")
    if not stat.S_ISREG(metadata.st_mode):
        fail(f"{document_name}: primary schema source is not a regular file")
    if getattr(metadata, "st_file_attributes", 0) & getattr(
        stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400
    ):
        fail(f"{document_name}: primary schema source reparse-point forbidden")
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
    try:
        metadata = schema_path.lstat()
        content = schema_path.read_bytes()
    except OSError:
        fail(f"{document_name}: terminal schema source absent or unreadable")
    if not stat.S_ISREG(metadata.st_mode):
        fail(f"{document_name}: terminal schema source is not a regular file")
    if getattr(metadata, "st_file_attributes", 0) & getattr(
        stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400
    ):
        fail(f"{document_name}: terminal schema source reparse-point forbidden")
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
    try:
        metadata = schema_path.lstat()
        content = schema_path.read_bytes()
    except OSError:
        fail("A0 hosted schema source absent or unreadable")
    if not stat.S_ISREG(metadata.st_mode):
        fail("A0 hosted schema source is not a regular file")
    if getattr(metadata, "st_file_attributes", 0) & getattr(
        stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400
    ):
        fail("A0 hosted schema source reparse-point forbidden")
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
    _ordinary_zip(path)
    # Parse and hash one bounded byte snapshot. Reopening the path for parsing
    # would allow a replacement between hash verification and entry inspection.
    try:
        with path.open("rb") as stream:
            archive_bytes = stream.read(MAX_ZIP_BYTES + 1)
    except OSError:
        fail("review ZIP is absent or unreadable")
    if not archive_bytes or len(archive_bytes) > MAX_ZIP_BYTES:
        fail("review ZIP exceeds bounded preflight size")
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


def main() -> int:
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument(
        "--mode",
        choices=[
            "structural-preflight",
            "primary-schema-preflight",
            "review-schema-dag-preflight",
            "a0-hosted-schema-dag-preflight",
        ],
        required=True,
    )
    parser.add_argument(
        "--authority-mode",
        choices=sorted(AUTHORITY_MODE_NAMES),
        required=True,
        help="trusted caller-selected six-entry authority type",
    )
    parser.add_argument("--zip", required=True, help="absolute path to six-entry review ZIP")
    parser.add_argument("--expected-zip-sha256", help="independently supplied lowercase ZIP SHA-256")
    parser.add_argument(
        "--schema-root",
        help="absolute directory containing the exact frozen review schemas",
    )
    args = parser.parse_args()
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
