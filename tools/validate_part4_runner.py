#!/usr/bin/env python3
from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

REPOSITORY = "Naveax/nxb-integrity-research-lab"
CONTRACT = "nxb-irl006-part4-resumable-runner-v1"
REQUIREMENTS = (
    "exact_run_binding",
    "checkpoint_resume",
    "duplicate_prevention",
    "budget_enforcement",
    "stop_modes",
    "adaptive_scheduler",
    "coverage_saturation",
    "fairness_backoff",
    "bounded_queue",
    "deterministic_sharding",
)


def fail(message: str) -> None:
    raise ValueError(message)


def load_json(path: Path) -> Dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(value, dict):
        fail(f"{path} must contain one JSON object")
    return value


def load_jsonl(path: Path) -> List[Dict[str, Any]]:
    result: List[Dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        if not line.strip():
            continue
        item = json.loads(line)
        if not isinstance(item, dict):
            fail("event log contains a non-object")
        result.append(item)
    return result


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def expected_shard(task_id: str, shard_count: int) -> int:
    return int(sha256_text(task_id)[:8], 16) % shard_count


def expected_run_id(manifest: Dict[str, Any]) -> str:
    material = "\n".join(
        [
            str(manifest["repository"]),
            str(manifest["exact_head"]),
            str(manifest["config_sha256"]),
            str(manifest["scope_sha256"]),
            str(manifest["contract_id"]),
        ]
    )
    return "run-" + sha256_text(material)[:32]


def expected_scope_sha(tasks: List[Dict[str, Any]]) -> str:
    material = "\n".join(
        f"{task['task_id']}|{task['domain']}|{int(task['base_priority'])}|{int(task['shard'])}"
        for task in sorted(tasks, key=lambda item: str(item["task_id"]))
    )
    return sha256_text(material)


def checkpoint_fingerprint(checkpoint: Dict[str, Any]) -> str:
    completed = ",".join(sorted(str(item) for item in checkpoint["completed_task_ids"]))
    attempts = ",".join(f"{key}={int(checkpoint['attempts'][key])}" for key in sorted(checkpoint["attempts"]))
    backoff = ",".join(f"{key}={int(checkpoint['not_before_tick'][key])}" for key in sorted(checkpoint["not_before_tick"]))
    domains = ",".join(f"{key}={int(checkpoint['domain_last_served_tick'][key])}" for key in sorted(checkpoint["domain_last_served_tick"]))
    material = "\n".join(
        [
            str(checkpoint["run_id"]), str(checkpoint["exact_head"]), str(checkpoint["config_sha256"]), str(checkpoint["scope_sha256"]),
            str(int(checkpoint["checkpoint_sequence"])), str(int(checkpoint["tick"])), str(int(checkpoint["budget_consumed"])),
            str(checkpoint["stop_mode"]), completed, attempts, backoff, domains,
        ]
    )
    return sha256_text(material)


def scheduler_score(task: Dict[str, Any], tick: int, attempts: Dict[str, int], domain_completed: Dict[str, int], domain_last: Dict[str, int], domain_target: Dict[str, int], policy: Dict[str, Any]) -> int:
    domain = str(task["domain"])
    completed = domain_completed[domain]
    coverage_deficit = max(0, domain_target[domain] - completed)
    fairness_credit = max(0, tick - domain_last[domain])
    return (
        int(task["base_priority"]) * int(policy["scheduler"]["base_priority_weight"])
        + coverage_deficit * int(policy["scheduler"]["coverage_deficit_weight"])
        + fairness_credit * int(policy["scheduler"]["fairness_credit_weight"])
        - completed * int(policy["scheduler"]["saturation_penalty_weight"])
        - attempts[str(task["task_id"])] * int(policy["scheduler"]["retry_penalty_weight"])
    )


def validate_model(model: Dict[str, Any]) -> Dict[str, bool]:
    policy = model["policy"]
    manifest = model["manifest"]
    checkpoint = model["checkpoint"]
    events = model["events"]
    receipts = model["receipts"]
    experiment = model["experiment"]

    if manifest.get("schema_version") != 1 or manifest.get("contract_id") != CONTRACT or manifest.get("repository") != REPOSITORY:
        fail("manifest identity mismatch")
    if manifest.get("config_sha256") != model["policy_sha256"]:
        fail("manifest config hash mismatch")
    tasks = manifest.get("tasks")
    if not isinstance(tasks, list) or len(tasks) != int(policy["task_count"]):
        fail("manifest task count mismatch")
    if manifest.get("scope_sha256") != expected_scope_sha(tasks):
        fail("manifest scope hash mismatch")
    if manifest.get("run_id") != expected_run_id(manifest):
        fail("manifest run id mismatch")
    if experiment.get("exact_head") != manifest.get("exact_head") or experiment.get("run_id") != manifest.get("run_id"):
        fail("experiment run binding mismatch")
    if experiment.get("config_sha256") != manifest.get("config_sha256") or experiment.get("scope_sha256") != manifest.get("scope_sha256"):
        fail("experiment config/scope binding mismatch")

    shard_count = int(manifest["shard_count"])
    task_by_id: Dict[str, Dict[str, Any]] = {}
    for task in tasks:
        task_id = str(task["task_id"])
        if task_id in task_by_id:
            fail("duplicate task id in manifest")
        if int(task["shard"]) != expected_shard(task_id, shard_count):
            fail(f"deterministic shard mismatch for {task_id}")
        task_by_id[task_id] = task

    if checkpoint.get("run_id") != manifest.get("run_id") or checkpoint.get("exact_head") != manifest.get("exact_head"):
        fail("checkpoint run/head binding mismatch")
    if checkpoint.get("config_sha256") != manifest.get("config_sha256") or checkpoint.get("scope_sha256") != manifest.get("scope_sha256"):
        fail("checkpoint config/scope binding mismatch")
    if checkpoint.get("checkpoint_fingerprint_sha256") != checkpoint_fingerprint(checkpoint):
        fail("checkpoint fingerprint mismatch")
    if checkpoint.get("stop_mode") != "completed":
        fail("final checkpoint is not completed")
    completed = [str(item) for item in checkpoint.get("completed_task_ids", [])]
    if len(completed) != len(tasks) or set(completed) != set(task_by_id):
        fail("final checkpoint completion set mismatch")
    if int(checkpoint.get("budget_consumed", -1)) != len(tasks):
        fail("checkpoint budget accounting mismatch")

    if len(receipts) != len(tasks):
        fail("receipt count mismatch")
    receipt_ids = [str(item.get("task_id")) for item in receipts]
    if len(set(receipt_ids)) != len(receipt_ids) or set(receipt_ids) != set(task_by_id):
        fail("receipt idempotency set mismatch")
    for receipt in receipts:
        task_id = str(receipt["task_id"])
        task = task_by_id[task_id]
        if receipt.get("status") != "succeeded" or receipt.get("run_id") != manifest.get("run_id"):
            fail("receipt status/run binding mismatch")
        for key in ("exact_head", "config_sha256", "scope_sha256"):
            if receipt.get(key) != manifest.get(key):
                fail(f"receipt {key} binding mismatch")
        if int(receipt["shard"]) != int(task["shard"]) or receipt.get("domain") != task.get("domain"):
            fail("receipt shard/domain mismatch")
        if receipt.get("synthetic_payload_sha256") != task.get("synthetic_payload_sha256"):
            fail("receipt payload hash mismatch")

    phases = experiment.get("phases")
    if not isinstance(phases, list) or [item.get("phase") for item in phases] != ["crash_after_receipt", "graceful", "emergency", "complete"]:
        fail("runner phase sequence mismatch")
    phase_sequences = [int(item["checkpoint_sequence"]) for item in phases]
    if any(right <= left for left, right in zip(phase_sequences, phase_sequences[1:])):
        fail("checkpoint sequence is not monotonic across phases")
    crash = experiment.get("crash_resume") or {}
    if crash.get("crash_observed") is not True or crash.get("stale_checkpoint_observed") is not True:
        fail("crash/stale-checkpoint evidence missing")
    if int(crash.get("receipt_count_after_crash", 0)) <= int(crash.get("checkpoint_completed_after_crash", 0)):
        fail("crash did not expose receipt-ahead-of-checkpoint window")
    if int(crash.get("final_receipts", -1)) != len(tasks) or int(crash.get("final_completed", -1)) != len(tasks):
        fail("resume did not complete all tasks")

    stop_kinds = {str(item.get("kind")) for item in events}
    for required in ("fault_injected_process_crash", "receipt_reconciled", "graceful_stop", "emergency_stop", "run_completed"):
        if required not in stop_kinds:
            fail(f"missing stop/recovery event {required}")

    domains = [str(item) for item in policy["domains"]]
    domain_target = {domain: sum(1 for task in tasks if task["domain"] == domain) for domain in domains}
    domain_completed = {domain: 0 for domain in domains}
    domain_last = {domain: 0 for domain in domains}
    attempts = {task_id: 0 for task_id in task_by_id}
    not_before = {task_id: 0 for task_id in task_by_id}
    completed_set = set()
    success_ticks: Dict[str, List[int]] = {domain: [] for domain in domains}
    pending_attempt: Optional[Tuple[str, int]] = None
    max_ready = 0
    maximum_attempt = 0

    for event in events:
        kind = str(event.get("kind"))
        if kind == "attempt_started":
            task_id = str(event["task_id"])
            tick = int(event["tick"])
            if task_id not in task_by_id or task_id in completed_set:
                fail("scheduler attempted unknown/completed task")
            ready: List[Tuple[int, str]] = []
            for candidate_id, candidate in task_by_id.items():
                if candidate_id in completed_set or not_before[candidate_id] > tick:
                    continue
                score = scheduler_score(candidate, tick, attempts, domain_completed, domain_last, domain_target, policy)
                ready.append((score, candidate_id))
            if not ready:
                fail("attempt started with an empty ready queue")
            max_ready = max(max_ready, len(ready))
            ready.sort(key=lambda item: (-item[0], item[1]))
            expected_score, expected_task = ready[0]
            if task_id != expected_task or int(event["scheduler_score"]) != expected_score:
                fail("adaptive scheduler selection/score mismatch")
            if int(event.get("ready_queue_depth", -1)) != len(ready):
                fail("ready queue depth evidence mismatch")
            attempts[task_id] += 1
            maximum_attempt = max(maximum_attempt, attempts[task_id])
            if int(event["attempt"]) != attempts[task_id]:
                fail("attempt counter mismatch")
            pending_attempt = (task_id, tick)
        elif kind == "attempt_failed":
            task_id = str(event["task_id"])
            tick = int(event["tick"])
            if pending_attempt != (task_id, tick):
                fail("failure event is not paired to the active attempt")
            expected_delay = min(
                int(policy["scheduler"]["maximum_backoff_ticks"]),
                int(policy["scheduler"]["base_backoff_ticks"]) * (2 ** max(0, attempts[task_id] - 1)),
            )
            expected_not_before = tick + expected_delay
            if int(event["not_before_tick"]) != expected_not_before or expected_not_before <= tick:
                fail("bounded exponential backoff mismatch")
            not_before[task_id] = expected_not_before
            pending_attempt = None
        elif kind == "receipt_committed":
            task_id = str(event["task_id"])
            tick = int(event["tick"])
            if pending_attempt != (task_id, tick):
                fail("receipt commit is not paired to the active attempt")
            if task_id in completed_set:
                fail("duplicate successful execution detected")
            completed_set.add(task_id)
            domain = str(task_by_id[task_id]["domain"])
            domain_completed[domain] += 1
            domain_last[domain] = tick
            success_ticks[domain].append(tick)
            pending_attempt = None

    if pending_attempt is not None:
        fail("event stream ended with an unpaired attempt")
    if completed_set != set(task_by_id):
        fail("event stream did not commit every task exactly once")
    if max_ready > int(policy["budget"]["maximum_ready_queue_depth"]):
        fail("ready queue exceeded configured bound")
    if maximum_attempt > int(policy["budget"]["maximum_attempts_per_task"]):
        fail("attempt budget exceeded")
    final_tick = int(experiment["scheduler"]["final_tick"])
    if final_tick > int(policy["budget"]["maximum_ticks"]):
        fail("tick budget exceeded")
    if int(experiment["scheduler"]["fail_once_event_count"]) != len(policy["fault_injection"]["fail_once_task_ids"]):
        fail("fail-once/backoff scenario count mismatch")

    starvation_bound = int(policy["scheduler"]["maximum_starvation_gap_ticks"])
    for domain, ticks in success_ticks.items():
        if len(ticks) != domain_target[domain]:
            fail("coverage target was not reached for every domain")
        gaps = [ticks[0]] + [right - left for left, right in zip(ticks, ticks[1:])] + [final_tick - ticks[-1]]
        if max(gaps) > starvation_bound:
            fail(f"fairness starvation bound exceeded for {domain}")

    duplicate = experiment.get("duplicate_prevention") or {}
    if int(duplicate.get("unique_receipt_count", -1)) != len(tasks) or int(duplicate.get("duplicate_receipt_group_count", -1)) != 0:
        fail("experiment duplicate-prevention accounting mismatch")
    if int(duplicate.get("receipt_commit_event_count", -1)) != len(tasks):
        fail("receipt commit event count mismatch")
    boundary = experiment.get("review_boundary") or {}
    if boundary.get("synthetic_only") is not True or boundary.get("raw_payload_reviewable") is not False or boundary.get("task_receipt_body_reviewable") is not False:
        fail("Part 4 review boundary mismatch")

    return {name: True for name in REQUIREMENTS}


def expect_rejection(model: Dict[str, Any], label: str) -> bool:
    try:
        validate_model(model)
    except (ValueError, KeyError, TypeError, IndexError):
        return True
    fail(f"negative control accepted: {label}")
    return False


def negative_controls(base: Dict[str, Any]) -> Dict[str, bool]:
    controls: Dict[str, bool] = {}
    mutations = []

    item = copy.deepcopy(base); item["manifest"]["exact_head"] = "0" * 40; mutations.append(("stale_exact_head", item))
    item = copy.deepcopy(base); item["manifest"]["config_sha256"] = "1" * 64; mutations.append(("config_hash_mismatch", item))
    item = copy.deepcopy(base); item["manifest"]["scope_sha256"] = "2" * 64; mutations.append(("scope_hash_mismatch", item))
    item = copy.deepcopy(base); item["manifest"]["run_id"] = "run-" + "3" * 32; mutations.append(("run_id_mismatch", item))
    item = copy.deepcopy(base); item["receipts"].append(copy.deepcopy(item["receipts"][0])); mutations.append(("duplicate_receipt", item))
    item = copy.deepcopy(base); item["experiment"]["phases"][2]["checkpoint_sequence"] = item["experiment"]["phases"][1]["checkpoint_sequence"]; mutations.append(("checkpoint_sequence_rollback", item))
    item = copy.deepcopy(base); item["manifest"]["tasks"][0]["shard"] = (int(item["manifest"]["tasks"][0]["shard"]) + 1) % int(item["manifest"]["shard_count"]); mutations.append(("shard_mismatch", item))
    item = copy.deepcopy(base); item["experiment"]["scheduler"]["final_tick"] = int(item["policy"]["budget"]["maximum_ticks"]) + 1; mutations.append(("budget_exceeded", item))
    item = copy.deepcopy(base); failure = next(event for event in item["events"] if event.get("kind") == "attempt_failed"); failure["not_before_tick"] = int(failure["tick"]); mutations.append(("backoff_violation", item))
    item = copy.deepcopy(base); item["policy"]["scheduler"]["maximum_starvation_gap_ticks"] = 0; mutations.append(("fairness_violation", item))

    for label, model in mutations:
        controls[label] = expect_rejection(model, label)
    if len(controls) != 10 or not all(controls.values()):
        fail("negative control matrix did not reach 10/10")
    return controls


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--events", type=Path, required=True)
    parser.add_argument("--receipts", type=Path, required=True)
    parser.add_argument("--experiment", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    if args.output.exists():
        fail(f"output already exists: {args.output}")
    policy = load_json(args.policy)
    manifest = load_json(args.manifest)
    checkpoint = load_json(args.checkpoint)
    experiment = load_json(args.experiment)
    events = load_jsonl(args.events)
    receipt_paths = sorted(args.receipts.glob("*.json"))
    receipts = [load_json(path) for path in receipt_paths]

    model = {
        "policy": policy,
        "policy_sha256": sha256_file(args.policy),
        "manifest": manifest,
        "checkpoint": checkpoint,
        "events": events,
        "receipts": receipts,
        "experiment": experiment,
    }
    requirements = validate_model(model)
    negatives = negative_controls(model)
    result = {
        "schema_version": 1,
        "status": "passed",
        "contract_id": CONTRACT,
        "run_id": manifest["run_id"],
        "exact_head": manifest["exact_head"],
        "requirements": requirements,
        "requirements_validated": len(REQUIREMENTS),
        "negative_control_rejections": negatives,
        "negative_controls_validated": len(negatives),
        "task_count": len(manifest["tasks"]),
        "shard_count": int(manifest["shard_count"]),
        "scope_boundary": "bounded-local-synthetic-runner-certification-only",
        "raw_payload_reviewable": False,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    print("NXB Part 4 independent runner validation passed: requirements=10/10 negative_controls=10/10")


if __name__ == "__main__":
    main()
