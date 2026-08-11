#!/usr/bin/env python3
import argparse
import base64
import copy
import hashlib
import hmac
import json
import re
from pathlib import Path
from typing import Any, Dict, List, Tuple

HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
DIGEST_INFO_SHA256 = bytes.fromhex("3031300d060960864801650304020105000420")
AUTHORITY = "nxb-irl006-part5-signed-closure-v1"
ALGORITHM = "RSA-PKCS1-SHA256"


def load_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def public_key_fingerprint(modulus_b64: str, exponent_b64: str) -> str:
    return sha256_text("\n".join((ALGORITHM, modulus_b64, exponent_b64)))


def canonical_material(receipt: Dict[str, Any]) -> str:
    public_key = receipt["public_key"]
    nested = receipt["nested_evidence"]
    values = [
        receipt["authority"],
        str(int(receipt["schema_version"])),
        receipt["status"],
        receipt["head_sha"],
        str(int(receipt["closure_sequence"])),
        receipt["algorithm"],
        str(int(receipt["key_size_bits"])),
        str(bool(receipt["private_key_persisted"])).lower(),
        str(bool(receipt["production_signer_claimed"])).lower(),
        public_key["modulus_b64"],
        public_key["exponent_b64"],
        public_key["fingerprint_sha256"],
        nested["part234_review_zip_sha256"],
        nested["part234_receipt_sha256"],
        nested["part2_review_zip_sha256"],
        nested["part2_receipt_sha256"],
        nested["part3_review_zip_sha256"],
        nested["part3_receipt_sha256"],
        nested["part4_review_zip_sha256"],
        nested["part4_receipt_sha256"],
        receipt["nonce_b64"],
        receipt["created_utc"],
    ]
    return "\n".join(values)


def verify_rsa_pkcs1_sha256(receipt: Dict[str, Any], material: str) -> bool:
    try:
        modulus = base64.b64decode(receipt["public_key"]["modulus_b64"], validate=True)
        exponent = base64.b64decode(receipt["public_key"]["exponent_b64"], validate=True)
        signature = base64.b64decode(receipt["signature_b64"], validate=True)
    except Exception:
        return False
    if not modulus or not exponent or not signature:
        return False
    n = int.from_bytes(modulus, "big")
    e = int.from_bytes(exponent, "big")
    k = (n.bit_length() + 7) // 8
    if n <= 0 or e <= 1 or len(signature) != k:
        return False
    digest = hashlib.sha256(material.encode("utf-8")).digest()
    digest_info = DIGEST_INFO_SHA256 + digest
    padding_len = k - len(digest_info) - 3
    if padding_len < 8:
        return False
    expected = b"\x00\x01" + (b"\xff" * padding_len) + b"\x00" + digest_info
    signature_value = int.from_bytes(signature, "big")
    if signature_value >= n:
        return False
    actual = pow(signature_value, e, n).to_bytes(k, "big")
    return hmac.compare_digest(actual, expected)


def validate_receipt(receipt: Dict[str, Any], expected_head: str) -> Tuple[List[str], Dict[str, bool]]:
    errors: List[str] = []
    requirements: Dict[str, bool] = {}

    head_ok = isinstance(receipt.get("head_sha"), str) and bool(HEX40.fullmatch(receipt["head_sha"])) and receipt["head_sha"] == expected_head
    requirements["exact_head_binding"] = head_ok
    if not head_ok:
        errors.append("head_mismatch")

    if receipt.get("authority") != AUTHORITY:
        errors.append("authority_mismatch")
    if receipt.get("schema_version") != 1 or receipt.get("status") != "passed":
        errors.append("receipt_state_invalid")
    if receipt.get("algorithm") != ALGORITHM:
        errors.append("algorithm_mismatch")
    if int(receipt.get("key_size_bits", 0)) < 3072:
        errors.append("key_size_too_small")
    if int(receipt.get("closure_sequence", -1)) != 1:
        errors.append("closure_sequence_mismatch")
    requirements["closure_sequence_binding"] = int(receipt.get("closure_sequence", -1)) == 1

    if bool(receipt.get("private_key_persisted", True)):
        errors.append("private_key_persisted")
    requirements["private_key_non_persistence"] = receipt.get("private_key_persisted") is False
    if bool(receipt.get("production_signer_claimed", True)):
        errors.append("production_signer_claimed")
    requirements["production_signer_boundary"] = receipt.get("production_signer_claimed") is False

    public_key = receipt.get("public_key") or {}
    modulus_b64 = str(public_key.get("modulus_b64", ""))
    exponent_b64 = str(public_key.get("exponent_b64", ""))
    fingerprint = str(public_key.get("fingerprint_sha256", ""))
    expected_fingerprint = public_key_fingerprint(modulus_b64, exponent_b64)
    fingerprint_ok = bool(HEX64.fullmatch(fingerprint)) and hmac.compare_digest(fingerprint, expected_fingerprint)
    requirements["public_key_fingerprint_binding"] = fingerprint_ok
    if not fingerprint_ok:
        errors.append("public_key_fingerprint_mismatch")

    try:
        modulus_bytes = base64.b64decode(modulus_b64, validate=True)
        modulus_bits = int.from_bytes(modulus_bytes, "big").bit_length()
    except Exception:
        modulus_bits = 0
    if modulus_bits < 3072:
        errors.append("public_key_size_invalid")

    nested = receipt.get("nested_evidence") or {}
    nested_names = (
        "part234_review_zip_sha256",
        "part234_receipt_sha256",
        "part2_review_zip_sha256",
        "part2_receipt_sha256",
        "part3_review_zip_sha256",
        "part3_receipt_sha256",
        "part4_review_zip_sha256",
        "part4_receipt_sha256",
    )
    nested_ok = all(isinstance(nested.get(name), str) and bool(HEX64.fullmatch(nested[name])) for name in nested_names)
    requirements["nested_evidence_binding"] = nested_ok
    if not nested_ok:
        errors.append("nested_evidence_invalid")

    try:
        nonce = base64.b64decode(str(receipt.get("nonce_b64", "")), validate=True)
        nonce_ok = len(nonce) == 32
    except Exception:
        nonce_ok = False
    requirements["nonce_binding"] = nonce_ok
    if not nonce_ok:
        errors.append("nonce_invalid")

    material = canonical_material(receipt)
    canonical_hash = sha256_text(material)
    canonical_ok = isinstance(receipt.get("canonical_sha256"), str) and hmac.compare_digest(receipt["canonical_sha256"], canonical_hash)
    requirements["canonical_material_binding"] = canonical_ok
    if not canonical_ok:
        errors.append("canonical_hash_mismatch")

    signature_ok = verify_rsa_pkcs1_sha256(receipt, material)
    requirements["rsa_signature_valid"] = signature_ok
    requirements["independent_verification"] = signature_ok and canonical_ok and fingerprint_ok
    if not signature_ok:
        errors.append("signature_invalid")

    return sorted(set(errors)), requirements


def resign_canonical_hash_only(receipt: Dict[str, Any]) -> None:
    receipt["canonical_sha256"] = sha256_text(canonical_material(receipt))


def run_negative_controls(receipt: Dict[str, Any], expected_head: str) -> Dict[str, bool]:
    cases: Dict[str, Tuple[Dict[str, Any], str]] = {}

    mutated = copy.deepcopy(receipt)
    raw = bytearray(base64.b64decode(mutated["signature_b64"]))
    raw[-1] ^= 1
    mutated["signature_b64"] = base64.b64encode(bytes(raw)).decode("ascii")
    cases["tampered_signature"] = (mutated, "signature_invalid")

    mutated = copy.deepcopy(receipt)
    mutated["head_sha"] = "0" * 40
    resign_canonical_hash_only(mutated)
    cases["tampered_head"] = (mutated, "head_mismatch")

    mutated = copy.deepcopy(receipt)
    mutated["nested_evidence"]["part234_receipt_sha256"] = "1" * 64
    resign_canonical_hash_only(mutated)
    cases["tampered_part234_receipt_hash"] = (mutated, "signature_invalid")

    mutated = copy.deepcopy(receipt)
    mutated["public_key"]["fingerprint_sha256"] = "2" * 64
    resign_canonical_hash_only(mutated)
    cases["tampered_public_key_fingerprint"] = (mutated, "public_key_fingerprint_mismatch")

    mutated = copy.deepcopy(receipt)
    modulus = bytearray(base64.b64decode(mutated["public_key"]["modulus_b64"]))
    modulus[-1] ^= 2
    mutated["public_key"]["modulus_b64"] = base64.b64encode(bytes(modulus)).decode("ascii")
    mutated["public_key"]["fingerprint_sha256"] = public_key_fingerprint(mutated["public_key"]["modulus_b64"], mutated["public_key"]["exponent_b64"])
    resign_canonical_hash_only(mutated)
    cases["tampered_modulus"] = (mutated, "signature_invalid")

    mutated = copy.deepcopy(receipt)
    mutated["closure_sequence"] = 2
    resign_canonical_hash_only(mutated)
    cases["closure_sequence_replay"] = (mutated, "closure_sequence_mismatch")

    mutated = copy.deepcopy(receipt)
    mutated["algorithm"] = "RSA-SHA1"
    resign_canonical_hash_only(mutated)
    cases["algorithm_downgrade"] = (mutated, "algorithm_mismatch")

    mutated = copy.deepcopy(receipt)
    mutated["production_signer_claimed"] = True
    resign_canonical_hash_only(mutated)
    cases["production_signer_claimed"] = (mutated, "production_signer_claimed")

    mutated = copy.deepcopy(receipt)
    mutated["private_key_persisted"] = True
    resign_canonical_hash_only(mutated)
    cases["private_key_persisted"] = (mutated, "private_key_persisted")

    mutated = copy.deepcopy(receipt)
    mutated["canonical_sha256"] = "3" * 64
    cases["canonical_hash_mismatch"] = (mutated, "canonical_hash_mismatch")

    results: Dict[str, bool] = {}
    for name, (candidate, expected_error) in cases.items():
        errors, _ = validate_receipt(candidate, expected_head)
        results[name] = expected_error in errors
    return results


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--receipt", required=True)
    parser.add_argument("--policy", required=True)
    parser.add_argument("--expected-head", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    receipt = load_json(Path(args.receipt))
    policy = load_json(Path(args.policy))
    expected_head = args.expected_head.lower()
    if not HEX40.fullmatch(expected_head):
        raise SystemExit("expected head must be 40 lowercase hex characters")

    errors, requirements = validate_receipt(receipt, expected_head)
    negatives = run_negative_controls(receipt, expected_head)
    policy_requirements = [str(item) for item in policy.get("requirements", [])]
    policy_negatives = [str(item) for item in policy.get("negative_controls", [])]
    requirement_count = sum(bool(requirements.get(name, False)) for name in policy_requirements)
    negative_count = sum(bool(negatives.get(name, False)) for name in policy_negatives)
    status = "passed" if not errors and requirement_count == 10 and negative_count == 10 else "failed"

    document = {
        "schema_version": 1,
        "status": status,
        "authority": "independent-python-rsa-pkcs1-sha256-v1",
        "head_sha": expected_head,
        "requirements": requirements,
        "requirements_validated": requirement_count,
        "negative_controls": negatives,
        "negative_controls_validated": negative_count,
        "errors": errors,
    }
    Path(args.output).write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(document, sort_keys=True))
    return 0 if status == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
