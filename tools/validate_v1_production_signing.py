#!/usr/bin/env python3
import argparse
import base64
import copy
import hashlib
import hmac
import json
from pathlib import Path
from typing import Any, Dict, List, Tuple

CANONICAL_CONTRACT = "nxb-v1-release-signature-canonical-v1"
PUBLIC_KEY_CONTRACT = "nxb-v1-rsa-public-key-v1"
ALGORITHM = "RSA-PKCS1-SHA256"
DIGEST_INFO_SHA256 = bytes.fromhex("3031300d060960864801650304020105000420")


def is_lower_hex(value: Any, length: int) -> bool:
    return isinstance(value, str) and len(value) == length and all(c in "0123456789abcdef" for c in value)


def valid_artifact_path(path: Any) -> bool:
    if not isinstance(path, str) or not path:
        return False
    if "|" in path or "\r" in path or "\n" in path or "\\" in path:
        return False
    if path.startswith("/") or (len(path) >= 2 and path[0].isalpha() and path[1] == ":"):
        return False
    if path.startswith("../") or path.endswith("/..") or "/../" in path:
        return False
    return all(32 <= ord(c) <= 126 for c in path)


def public_fingerprint(public_key: Dict[str, Any]) -> str:
    material = "\n".join(
        [
            PUBLIC_KEY_CONTRACT,
            f"modulus_b64={public_key['modulus_b64']}",
            f"exponent_b64={public_key['exponent_b64']}",
        ]
    )
    return hashlib.sha256(material.encode("utf-8")).hexdigest()


def canonical_material(envelope: Dict[str, Any]) -> str:
    if envelope.get("canonical_contract_id") != CANONICAL_CONTRACT:
        raise ValueError("canonical_contract_id")
    if envelope.get("schema_version") != 1:
        raise ValueError("schema_version")
    if envelope.get("release_version") != "1.0.0":
        raise ValueError("release_version")
    if not is_lower_hex(envelope.get("release_head"), 40):
        raise ValueError("release_head")
    if not is_lower_hex(envelope.get("certified_implementation_head"), 40):
        raise ValueError("certified_implementation_head")
    if not is_lower_hex(envelope.get("package_manifest_sha256"), 64):
        raise ValueError("package_manifest_sha256")
    if not is_lower_hex(envelope.get("release_notes_sha256"), 64):
        raise ValueError("release_notes_sha256")
    if envelope.get("signing_algorithm") != ALGORITHM:
        raise ValueError("signing_algorithm")
    if not isinstance(envelope.get("key_size_bits"), int) or envelope["key_size_bits"] < 3072:
        raise ValueError("key_size_bits")
    if not isinstance(envelope.get("signer_key_id"), str) or not envelope["signer_key_id"]:
        raise ValueError("signer_key_id")
    if not isinstance(envelope.get("created_utc"), str) or not envelope["created_utc"]:
        raise ValueError("created_utc")

    public_key = envelope.get("public_key")
    if not isinstance(public_key, dict):
        raise ValueError("public_key")
    if not is_lower_hex(public_key.get("fingerprint"), 64):
        raise ValueError("public_fingerprint")

    artifacts = envelope.get("artifacts")
    if not isinstance(artifacts, list) or not (1 <= len(artifacts) <= 256):
        raise ValueError("artifact_count")
    by_path: Dict[str, Dict[str, Any]] = {}
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            raise ValueError("artifact_shape")
        path = artifact.get("path")
        if not valid_artifact_path(path):
            raise ValueError("artifact_path")
        if path in by_path:
            raise ValueError("artifact_duplicate")
        byte_count = artifact.get("bytes")
        if not isinstance(byte_count, int) or byte_count < 0:
            raise ValueError("artifact_bytes")
        if not is_lower_hex(artifact.get("sha256"), 64):
            raise ValueError("artifact_sha256")
        by_path[path] = artifact

    paths = sorted(by_path.keys())
    lines = [
        CANONICAL_CONTRACT,
        "schema_version=1",
        f"release_version={envelope['release_version']}",
        f"release_head={envelope['release_head']}",
        f"certified_implementation_head={envelope['certified_implementation_head']}",
        f"package_manifest_sha256={envelope['package_manifest_sha256']}",
        f"release_notes_sha256={envelope['release_notes_sha256']}",
        f"artifact_count={len(paths)}",
        f"signer_mode={envelope.get('signer_mode')}",
        f"signer_key_id={envelope['signer_key_id']}",
        f"signing_algorithm={envelope['signing_algorithm']}",
        f"key_size_bits={envelope['key_size_bits']}",
        f"public_modulus_b64={public_key.get('modulus_b64')}",
        f"public_exponent_b64={public_key.get('exponent_b64')}",
        f"public_fingerprint={public_key['fingerprint']}",
        f"created_utc={envelope['created_utc']}",
    ]
    for path in paths:
        artifact = by_path[path]
        lines.append(f"artifact={path}|{artifact['bytes']}|{artifact['sha256']}")
    return "\n".join(lines)


def verify_rsa_signature(envelope: Dict[str, Any], material: str) -> bool:
    try:
        public_key = envelope["public_key"]
        modulus_bytes = base64.b64decode(public_key["modulus_b64"], validate=True)
        exponent_bytes = base64.b64decode(public_key["exponent_b64"], validate=True)
        signature = base64.b64decode(envelope["signature_b64"], validate=True)
        modulus = int.from_bytes(modulus_bytes, "big")
        exponent = int.from_bytes(exponent_bytes, "big")
        signature_int = int.from_bytes(signature, "big")
        if modulus <= 0 or exponent <= 1 or signature_int <= 0 or signature_int >= modulus:
            return False
        if modulus.bit_length() < 3072:
            return False
        k = (modulus.bit_length() + 7) // 8
        if len(signature) != k:
            return False
        encoded = pow(signature_int, exponent, modulus).to_bytes(k, "big")
        digest = hashlib.sha256(material.encode("utf-8")).digest()
        trailer = DIGEST_INFO_SHA256 + digest
        padding_len = k - len(trailer) - 3
        if padding_len < 8:
            return False
        expected = b"\x00\x01" + (b"\xff" * padding_len) + b"\x00" + trailer
        return hmac.compare_digest(encoded, expected)
    except Exception:
        return False


def validate(policy: Dict[str, Any], envelope: Dict[str, Any], expected_release_head: str, expected_certified_head: str) -> Tuple[List[str], str]:
    failures: List[str] = []
    try:
        material = canonical_material(envelope)
    except Exception as exc:
        return [f"canonical:{exc}"], ""

    public_key = envelope.get("public_key", {})
    computed_fingerprint = public_fingerprint(public_key)
    canonical_sha = hashlib.sha256(material.encode("utf-8")).hexdigest()

    requirements = {
        "policy_identity": policy.get("contract_id") == "nxb-v1-production-signing-v1" and policy.get("schema_version") == 1,
        "head_binding": envelope.get("release_head") == expected_release_head and envelope.get("certified_implementation_head") == expected_certified_head,
        "version_binding": envelope.get("release_version") == policy.get("target_version") == "1.0.0",
        "artifact_contract": isinstance(envelope.get("artifacts"), list) and 1 <= len(envelope["artifacts"]) <= int(policy.get("release_manifest", {}).get("maximum_artifacts", 0)),
        "algorithm_and_key_size": envelope.get("signing_algorithm") == policy.get("algorithm") and int(envelope.get("key_size_bits", 0)) >= int(policy.get("minimum_rsa_bits", 0)),
        "public_fingerprint": hmac.compare_digest(str(public_key.get("fingerprint", "")), computed_fingerprint),
        "canonical_sha256": hmac.compare_digest(str(envelope.get("canonical_sha256", "")), canonical_sha),
        "rsa_signature": verify_rsa_signature(envelope, material),
        "certification_signer_boundary": envelope.get("signer_mode") == "certification-ephemeral" and envelope.get("production_signer_claimed") is False and envelope.get("private_key_persisted") is False,
        "certification_key_id_binding": envelope.get("signer_key_id") == f"cert-ephemeral:{computed_fingerprint}",
        "production_policy_boundary": policy.get("production", {}).get("signer_mode") == "windows-certificate-store" and policy.get("production", {}).get("allow_pfx_path") is False and policy.get("production", {}).get("allow_pem_path") is False and policy.get("production", {}).get("allow_raw_private_key_bytes") is False,
        "production_key_protection": policy.get("production", {}).get("require_protected_private_key") is True and policy.get("production", {}).get("require_exact_thumbprint") is True,
    }
    for name, passed in requirements.items():
        if not passed:
            failures.append(name)
    return failures, material


def negative_controls(policy: Dict[str, Any], envelope: Dict[str, Any], expected_release_head: str, expected_certified_head: str) -> Dict[str, bool]:
    controls: Dict[str, bool] = {}

    def rejected(name: str, mutate) -> None:
        candidate = copy.deepcopy(envelope)
        mutate(candidate)
        failures, _ = validate(policy, candidate, expected_release_head, expected_certified_head)
        controls[name] = bool(failures)

    rejected("tampered_release_head", lambda x: x.__setitem__("release_head", "0" * 40))
    rejected("tampered_package_manifest_sha256", lambda x: x.__setitem__("package_manifest_sha256", "1" * 64))
    rejected("tampered_artifact_sha256", lambda x: x["artifacts"][0].__setitem__("sha256", "2" * 64))
    rejected("tampered_signer_fingerprint", lambda x: x["public_key"].__setitem__("fingerprint", "3" * 64))
    rejected("malformed_signature", lambda x: x.__setitem__("signature_b64", "%%%not-base64%%%"))
    rejected("weak_key_metadata", lambda x: x.__setitem__("key_size_bits", 2048))
    rejected("wrong_signer_key_id", lambda x: x.__setitem__("signer_key_id", "cert-ephemeral:wrong"))
    rejected("duplicate_artifact_path", lambda x: x["artifacts"].append(copy.deepcopy(x["artifacts"][0])))
    return controls


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", required=True)
    parser.add_argument("--envelope", required=True)
    parser.add_argument("--expected-release-head", required=True)
    parser.add_argument("--expected-certified-head", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    policy = json.loads(Path(args.policy).read_text(encoding="utf-8"))
    envelope = json.loads(Path(args.envelope).read_text(encoding="utf-8"))
    failures, _ = validate(policy, envelope, args.expected_release_head, args.expected_certified_head)
    controls = negative_controls(policy, envelope, args.expected_release_head, args.expected_certified_head)
    negative_failures = [name for name, passed in controls.items() if not passed]
    all_failures = failures + [f"negative:{name}" for name in negative_failures]

    result = {
        "schema_version": 1,
        "status": "passed" if not all_failures else "failed",
        "authority": "nxb-v1-production-signing-independent-v1",
        "requirements_validated": 12 - len(failures),
        "requirement_count": 12,
        "negative_controls_validated": 8 - len(negative_failures),
        "negative_count": 8,
        "release_head": envelope.get("release_head"),
        "certified_implementation_head": envelope.get("certified_implementation_head"),
        "public_fingerprint": envelope.get("public_key", {}).get("fingerprint"),
        "requirements_failures": failures,
        "negative_controls": controls,
        "failures": all_failures,
    }
    Path(args.output).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
