#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import hmac
import json
from pathlib import Path
from typing import Any, Dict, List


class ValidationError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise ValidationError(message)


def load_json(path: Path) -> Dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(value, dict):
        fail(f"{path} must contain one JSON object")
    return value


def payload_text(frame: Dict[str, Any]) -> str:
    try:
        raw = base64.b64decode(str(frame["payload_b64"]), validate=True)
        return raw.decode("utf-8")
    except Exception as exc:  # noqa: BLE001
        fail(f"invalid frame payload_b64: {exc}")
    raise AssertionError("unreachable")


def canonical_material(frame: Dict[str, Any]) -> str:
    return "\n".join(
        [
            "schema=1",
            f"session_id={frame.get('session_id')}",
            f"sender_role={frame.get('sender_role')}",
            f"sequence={int(frame.get('sequence', -1))}",
            f"kind={frame.get('kind')}",
            f"payload_sha256={frame.get('payload_sha256')}",
            f"payload_b64={frame.get('payload_b64')}",
        ]
    )


def sign_frame(frame: Dict[str, Any], key: bytes) -> None:
    frame["auth_tag"] = hmac.new(key, canonical_material(frame).encode("utf-8"), hashlib.sha256).hexdigest()


def auth_valid(frame: Dict[str, Any], key: bytes) -> bool:
    if frame.get("schema_version") != 1:
        return False
    text = payload_text(frame)
    payload_sha = hashlib.sha256(text.encode("utf-8")).hexdigest()
    if frame.get("payload_sha256") != payload_sha:
        return False
    expected = hmac.new(key, canonical_material(frame).encode("utf-8"), hashlib.sha256).hexdigest()
    return hmac.compare_digest(str(frame.get("auth_tag", "")), expected)


def decoded_payload(frame: Dict[str, Any]) -> Dict[str, Any]:
    value = json.loads(payload_text(frame))
    if not isinstance(value, dict):
        fail("frame payload must be a JSON object")
    return value


def require_bool(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        fail(f"{label} must be boolean")
    return value


def validate_document(document: Dict[str, Any], config: Dict[str, Any]) -> Dict[str, Any]:
    if document.get("schema_version") != 1 or document.get("status") != "passed":
        fail("experiment status/schema mismatch")
    if document.get("scope") != config.get("scope"):
        fail("experiment scope mismatch")
    if document.get("protocol") != config.get("protocol"):
        fail("experiment protocol mismatch")
    if document.get("bind_address") != "127.0.0.1":
        fail("transport experiment is not loopback-bound")
    if document.get("production_secret_claimed") is not False:
        fail("transport experiment overclaims production secret handling")

    key_hex = str((config.get("authentication") or {}).get("certification_test_key_hex", ""))
    if len(key_hex) != 64 or any(ch not in "0123456789abcdef" for ch in key_hex):
        fail("certification test key must be 64 lowercase hex characters")
    key = bytes.fromhex(key_hex)
    if document.get("certification_key_sha256") != hashlib.sha256(key_hex.encode("utf-8")).hexdigest():
        fail("certification key fingerprint mismatch")

    session_id = str(document.get("session_id", ""))
    if not session_id or document.get("session_id_sha256") != hashlib.sha256(session_id.encode("utf-8")).hexdigest():
        fail("session identity hash mismatch")

    transcript = document.get("transcript")
    if not isinstance(transcript, list) or len(transcript) < 10:
        fail("transport transcript is missing or too small")

    expected_request_sequence = 1
    expected_response_sequence = 1
    accepted_event_count = 0
    backpressure_ack_count = 0
    labels: Dict[str, List[Dict[str, Any]]] = {}

    advancing_reasons = {"accepted", "drained", "resumed", "emergency_stop_armed", "shutdown"}
    nonadvancing_reasons = {"invalid_auth", "duplicate", "sequence_gap", "emergency_stop_active", "queue_full", "unsupported_kind", "frame_too_large"}

    for index, entry in enumerate(transcript):
        if not isinstance(entry, dict):
            fail(f"transcript entry {index} is not an object")
        label = str(entry.get("label", ""))
        labels.setdefault(label, []).append(entry)
        request = entry.get("request")
        response = entry.get("response")
        if not isinstance(request, dict) or not isinstance(response, dict):
            fail(f"transcript entry {index} lacks request/response objects")
        if request.get("session_id") != session_id or request.get("sender_role") != "controller":
            fail(f"request identity mismatch at transcript entry {index}")
        if response.get("session_id") != session_id or response.get("sender_role") != "target":
            fail(f"response identity mismatch at transcript entry {index}")

        expected_request_auth = require_bool(entry.get("request_auth_expected_valid"), f"entry {index} request auth expectation")
        observed_request_auth = auth_valid(request, key)
        if observed_request_auth != expected_request_auth:
            fail(f"request authentication expectation mismatch at entry {index}")
        if not auth_valid(response, key):
            fail(f"response authentication failed at entry {index}")
        if int(response.get("sequence", -1)) != expected_response_sequence:
            fail(f"response sequence discontinuity at entry {index}")
        expected_response_sequence += 1

        response_payload = decoded_payload(response)
        if response_payload != entry.get("response_payload"):
            fail(f"recorded response payload mismatch at entry {index}")
        reason = str(response_payload.get("reason", ""))
        request_sequence = int(request.get("sequence", -1))

        if reason in advancing_reasons:
            if not observed_request_auth or request_sequence != expected_request_sequence or response.get("kind") != "ack":
                fail(f"advancing request contract failed at entry {index}")
            expected_request_sequence += 1
            if reason == "accepted":
                accepted_event_count += 1
                if response_payload.get("backpressure") is True:
                    backpressure_ack_count += 1
        elif reason in nonadvancing_reasons:
            if response.get("kind") != "reject":
                fail(f"nonadvancing response must reject at entry {index}")
            if reason == "invalid_auth" and observed_request_auth:
                fail("invalid_auth response was emitted for a valid request")
            if reason == "duplicate" and not request_sequence < expected_request_sequence:
                fail("duplicate response does not describe an older sequence")
            if reason == "sequence_gap" and not request_sequence > expected_request_sequence:
                fail("sequence_gap response does not describe a future sequence")
            if reason == "emergency_stop_active" and request_sequence != expected_request_sequence:
                fail("emergency-stop denial changed/requested the wrong sequence")
        else:
            fail(f"unknown response reason at entry {index}: {reason}")

    configured_events = int(config.get("event_count", -1))
    if accepted_event_count != configured_events or int(document.get("configured_event_count", -1)) != configured_events:
        fail("accepted event count does not match configured event count")
    if backpressure_ack_count < 1:
        fail("transcript contains no authenticated backpressure acknowledgement")

    controls = document.get("controls")
    required_controls = config.get("required_controls")
    if not isinstance(controls, dict) or not isinstance(required_controls, list):
        fail("required transport controls are missing")
    for control in required_controls:
        if controls.get(control) is not True:
            fail(f"required control is not true: {control}")

    queue = document.get("queue") or {}
    config_queue = config.get("queue") or {}
    if int(queue.get("maximum_frames", -1)) != int(config_queue.get("maximum_frames", -2)):
        fail("queue maximum mismatch")
    if int(queue.get("high_watermark", -1)) != int(config_queue.get("high_watermark", -2)):
        fail("queue high watermark mismatch")
    if int(queue.get("low_watermark", -1)) != int(config_queue.get("low_watermark", -2)):
        fail("queue low watermark mismatch")
    if int(queue.get("overflow_count", -1)) != 0:
        fail("bounded queue overflowed")
    if int(queue.get("max_queue_depth_observed", -1)) > int(config_queue.get("maximum_frames", -2)):
        fail("observed queue depth exceeded the configured maximum")
    if int(queue.get("backpressure_count", 0)) < 1:
        fail("queue did not record backpressure")

    spool = document.get("spool") or {}
    if int(spool.get("record_count", 0)) < 1:
        fail("local spool contains no records")
    if int(spool.get("replayed_count", -1)) != int(spool.get("record_count", -2)):
        fail("local spool was not fully replayed")
    if int(spool.get("cursor_acknowledged_records", -1)) != int(spool.get("record_count", -2)):
        fail("spool cursor did not reach the final record")
    if int(spool.get("record_count", 0)) > int((config.get("spool") or {}).get("maximum_records", -1)):
        fail("spool record budget exceeded")
    if int(spool.get("byte_count", 0)) > int((config.get("spool") or {}).get("maximum_bytes", -1)):
        fail("spool byte budget exceeded")
    if spool.get("cleanup_verified") is not True:
        fail("local spool cleanup was not verified")
    spool_sha = str(spool.get("sha256", ""))
    if len(spool_sha) != 64 or any(ch not in "0123456789abcdef" for ch in spool_sha):
        fail("spool SHA-256 is invalid")
    replay_labels = sorted(label for label in labels if label.startswith("spool_replay_"))
    if len(replay_labels) != int(spool.get("record_count", -1)):
        fail("spool replay transcript label count does not match spooled record count")
    if any(len(labels[label]) != 1 for label in replay_labels):
        fail("one or more spool replay transcript labels are duplicated")
    if int(document.get("spool_replayed_event_count", -1)) != len(replay_labels):
        fail("review spool replay count does not match authenticated transcript replay labels")

    recovery = document.get("recovery") or {}
    if recovery.get("restart_performed") is not True:
        fail("target restart was not performed")
    if int(recovery.get("generation_after_restart", -1)) != 2:
        fail("target did not resume as generation two")
    if recovery.get("checkpoint_sequence_matched") is not True or recovery.get("resume_observed") is not True:
        fail("durable checkpoint/resume recovery did not validate")

    target = document.get("target") or {}
    if target.get("status") != "passed" or int(target.get("generation", -1)) != 2:
        fail("final target result is not passed generation two")
    if int(target.get("accepted_event_count", -1)) != configured_events:
        fail("target accepted-event counter mismatch")
    if int(target.get("auth_failure_count", 0)) < 1 or int(target.get("duplicate_count", 0)) < 1 or int(target.get("gap_count", 0)) < 1:
        fail("target negative-control counters are incomplete")
    if int(target.get("overflow_count", -1)) != 0:
        fail("target recorded queue overflow")
    if int(target.get("resume_count", 0)) < 1:
        fail("target recorded no resume")
    if target.get("emergency_stop") is not True or target.get("shutdown") is not True:
        fail("target emergency-stop/shutdown state is incomplete")

    def one(label: str) -> Dict[str, Any]:
        values = labels.get(label, [])
        if len(values) != 1:
            fail(f"expected one transcript control labeled {label}, observed {len(values)}")
        return values[0]

    if decoded_payload(one("invalid_auth_negative")["response"]).get("reason") != "invalid_auth":
        fail("invalid-auth transcript control mismatch")
    if decoded_payload(one("duplicate_negative")["response"]).get("reason") != "duplicate":
        fail("duplicate transcript control mismatch")
    if decoded_payload(one("gap_negative")["response"]).get("reason") != "sequence_gap":
        fail("gap transcript control mismatch")
    resume_payload = decoded_payload(one("resume_after_target_restart")["response"])
    if resume_payload.get("reason") != "resumed" or int(resume_payload.get("generation", -1)) != 2:
        fail("resume transcript control mismatch")
    if decoded_payload(one("emergency_stop")["response"]).get("reason") != "emergency_stop_armed":
        fail("emergency-stop transcript control mismatch")
    if decoded_payload(one("post_stop_event_negative")["response"]).get("reason") != "emergency_stop_active":
        fail("post-stop denial transcript control mismatch")
    if decoded_payload(one("shutdown")["response"]).get("reason") != "shutdown":
        fail("shutdown transcript control mismatch")

    return {
        "accepted_event_count": accepted_event_count,
        "transcript_entries": len(transcript),
        "response_sequence_count": expected_response_sequence - 1,
        "final_expected_request_sequence": expected_request_sequence,
        "backpressure_ack_count": backpressure_ack_count,
        "spool_replay_label_count": len(replay_labels),
    }


def expect_rejection(document: Dict[str, Any], config: Dict[str, Any], mutation_name: str) -> None:
    try:
        validate_document(document, config)
    except ValidationError:
        return
    fail(f"negative mutation was accepted: {mutation_name}")


def run_negative_controls(document: Dict[str, Any], config: Dict[str, Any]) -> int:
    mutations: List[tuple[str, Dict[str, Any]]] = []
    key = bytes.fromhex(str((config.get("authentication") or {})["certification_test_key_hex"]))

    request_auth = copy.deepcopy(document)
    for entry in request_auth["transcript"]:
        if entry.get("request_auth_expected_valid") is True:
            tag = str(entry["request"]["auth_tag"])
            entry["request"]["auth_tag"] = ("0" if tag[:1] != "0" else "1") + tag[1:]
            break
    mutations.append(("tampered_request_auth", request_auth))

    response_auth = copy.deepcopy(document)
    tag = str(response_auth["transcript"][0]["response"]["auth_tag"])
    response_auth["transcript"][0]["response"]["auth_tag"] = ("0" if tag[:1] != "0" else "1") + tag[1:]
    mutations.append(("tampered_response_auth", response_auth))

    response_sequence = copy.deepcopy(document)
    response_sequence_frame = response_sequence["transcript"][1]["response"]
    response_sequence_frame["sequence"] = 999
    sign_frame(response_sequence_frame, key)
    mutations.append(("response_sequence_gap", response_sequence))

    control_false = copy.deepcopy(document)
    control_false["controls"][str(config["required_controls"][0])] = False
    mutations.append(("required_control_false", control_false))

    queue_overflow = copy.deepcopy(document)
    queue_overflow["queue"]["overflow_count"] = 1
    mutations.append(("queue_overflow", queue_overflow))

    spool_mismatch = copy.deepcopy(document)
    spool_mismatch["spool"]["replayed_count"] = int(spool_mismatch["spool"]["record_count"]) - 1
    mutations.append(("spool_replay_mismatch", spool_mismatch))

    generation = copy.deepcopy(document)
    generation["recovery"]["generation_after_restart"] = 1
    mutations.append(("restart_generation_mismatch", generation))

    post_stop = copy.deepcopy(document)
    post_entry = next(entry for entry in post_stop["transcript"] if entry.get("label") == "post_stop_event_negative")
    post_entry["response"]["kind"] = "ack"
    sign_frame(post_entry["response"], key)
    mutations.append(("post_stop_ack", post_stop))

    accepted_count = copy.deepcopy(document)
    accepted_count["target"]["accepted_event_count"] = int(accepted_count["configured_event_count"]) - 1
    mutations.append(("accepted_event_count_mismatch", accepted_count))

    for name, mutated in mutations:
        expect_rejection(mutated, config, name)
    return len(mutations)


def main() -> None:
    parser = argparse.ArgumentParser(description="Independently validate NXB IRL-006 Part 3 controller/target transport evidence.")
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--experiment", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    config = load_json(args.config.resolve())
    experiment = load_json(args.experiment.resolve())
    if config.get("schema_version") != 1 or config.get("contract_id") != "nxb-irl006-part3-controller-target-transport-v1":
        fail("unexpected transport config contract")
    if args.output.exists():
        fail(f"output already exists: {args.output}")

    metrics = validate_document(experiment, config)
    negative_count = run_negative_controls(experiment, config)
    if negative_count != 9:
        fail(f"expected nine fail-closed mutation controls, observed {negative_count}")

    result = {
        "schema_version": 1,
        "status": "passed",
        "contract_id": config["contract_id"],
        "scope": config["scope"],
        "authenticated_channel": True,
        "monotonic_sequence": True,
        "duplicate_detection": True,
        "loss_detection": True,
        "bounded_queue": True,
        "backpressure": True,
        "local_spool": True,
        "emergency_stop": True,
        "interrupted_transfer_recovery": True,
        "negative_controls_validated": negative_count,
        "metrics": metrics,
        "experiment_sha256": hashlib.sha256(args.experiment.read_bytes()).hexdigest(),
        "config_sha256": hashlib.sha256(args.config.read_bytes()).hexdigest(),
        "production_secret_claimed": False,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    print("NXB controller/target transport validation passed: 9/9 requirements, negative_controls=9/9")


if __name__ == "__main__":
    try:
        main()
    except ValidationError as exc:
        raise SystemExit(f"controller/target transport validation failed: {exc}") from exc
