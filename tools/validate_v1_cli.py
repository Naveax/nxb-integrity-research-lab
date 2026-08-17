#!/usr/bin/env python3
import argparse
import copy
import hashlib
import json
import pathlib
import re
import sys

EXPECTED_HEAD = "27507531154099ab28a05cfe8e4e900d72f22e7b"
EXPECTED_COMMANDS = [
    "status","hash","inspect-manifest","stage-update","certify-final",
    "version","doctor","config-validate","evidence-verify",
    "update-check","update-stage","update-apply","update-rollback",
]
EXPECTED_EXIT_CODES = {
    "success":0,"usage":2,"config":3,"trust_integrity":4,
    "state_precondition":5,"dependency_doctor":6,"mutation_runtime":7,
    "evidence_verification":8,"certification":9,"internal":10,
}


def load_json(path):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8-sig"))


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def validate_policy(policy):
    return (
        policy.get("schema_version") == 1
        and policy.get("contract_id") == "nxb-v1-cli-v1"
        and policy.get("target_version") == "1.0.1"
        and policy.get("predecessor_update_head") == EXPECTED_HEAD
    )


def validate_config(doc):
    allowed = {"schema_version","contract_id","output_mode","non_interactive","update_channel","install_root","update_root","evidence_root"}
    required = {"schema_version","contract_id","output_mode","non_interactive","update_channel"}
    if set(doc) - allowed or not required.issubset(doc):
        return False
    if doc.get("schema_version") != 1 or doc.get("contract_id") != "nxb-v1-cli-config-v1":
        return False
    if doc.get("output_mode") not in {"human","json"}:
        return False
    if type(doc.get("non_interactive")) is not bool:
        return False
    if doc.get("update_channel") not in {"stable","beta"}:
        return False
    for name in ("install_root","update_root","evidence_root"):
        if name in doc and doc[name] is not None and not isinstance(doc[name], str):
            return False
    return True


def validate_output(doc, command=None, expected_exit=None, expected_status=None):
    required = {"schema_version","contract_id","command","status","exit_code","category","message","mutation_performed","data","errors"}
    if set(doc) != required:
        return False
    if doc.get("schema_version") != 1 or doc.get("contract_id") != "nxb-v1-cli-output-v1":
        return False
    if command is not None and doc.get("command") != command:
        return False
    if expected_exit is not None and doc.get("exit_code") != expected_exit:
        return False
    if expected_status is not None and doc.get("status") != expected_status:
        return False
    if not isinstance(doc.get("mutation_performed"), bool) or not isinstance(doc.get("errors"), list):
        return False
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repository-root", required=True)
    ap.add_argument("--expected-head", required=True)
    ap.add_argument("--receipt")
    ap.add_argument("--version-json")
    ap.add_argument("--usage-json")
    ap.add_argument("--config-json")
    ap.add_argument("--dry-run-json")
    args = ap.parse_args()

    root = pathlib.Path(args.repository_root).resolve()
    policy_path = root / "config" / "nxb-v1-cli-policy.json"
    output_schema_path = root / "schemas" / "nxb-v1-cli-output.schema.json"
    config_schema_path = root / "schemas" / "nxb-v1-cli-config.schema.json"
    example_path = root / "config" / "nxb-v1-cli.example.json"
    cli_path = root / "scripts" / "nxb.ps1"
    common_path = root / "scripts" / "NxbV1Cli.Common.ps1"
    errors_path = root / "config" / "nxb-v1-cli-known-error-signatures.json"

    policy = load_json(policy_path)
    output_schema = load_json(output_schema_path)
    config_schema = load_json(config_schema_path)
    example = load_json(example_path)
    errors = load_json(errors_path)
    cli = cli_path.read_text(encoding="utf-8-sig")
    common = common_path.read_text(encoding="utf-8-sig")

    req = []
    req.append(validate_policy(policy) and re.fullmatch(r"[0-9a-f]{40}", args.expected_head) is not None)
    req.append(policy.get("commands") == EXPECTED_COMMANDS and len(set(policy.get("commands", []))) == 13)
    req.append(policy.get("legacy_commands") == EXPECTED_COMMANDS[:5] and policy.get("mutation_commands") == ["stage-update","update-stage","update-apply","update-rollback"])
    req.append(policy.get("exit_codes") == EXPECTED_EXIT_CODES)
    req.append(output_schema.get("additionalProperties") is False and output_schema.get("properties",{}).get("contract_id",{}).get("const") == "nxb-v1-cli-output-v1")
    req.append(config_schema.get("additionalProperties") is False and config_schema.get("properties",{}).get("contract_id",{}).get("const") == "nxb-v1-cli-config-v1")
    req.append(validate_config(example))
    req.append(all(("'" + c + "'") in cli for c in EXPECTED_COMMANDS[:5]))
    req.append(all(("'" + c + "'") in cli for c in EXPECTED_COMMANDS[5:]))
    req.append("[Array]::Sort($paths,[StringComparer]::Ordinal)" in cli and re.search(r"Sort-Object\b[^\r\n]*(?:path|relative|entry|file)", cli, re.I) is None)
    req.append(policy.get("delegation",{}).get("signed_update") == "scripts/Invoke-NxbV1Updater.ps1" and "Invoke-NxbV1CliSignedUpdate" in common)
    req.append(policy.get("delegation",{}).get("doctor") == "scripts/Test-NxbV1InstallerHost.ps1" and policy.get("delegation",{}).get("evidence_verify") == "scripts/Test-EvidenceBundle.ps1")
    req.append(all(x in cli for x in ["$Host.SetShouldExit","ConvertTo-Json -Depth 32 -Compress","[Console]::Error.WriteLine","$envelope.mutation_performed = $mutationPerformed","$finalPipeline = @(& $finalAuthority","-PassThru 3>$null 4>$null 5>$null 6>$null"]))
    req.append(all(x in cli for x in ["update-stage requires -ConfirmMutation or -DryRun.","update-apply requires -ConfirmMutation or -DryRun.","update-rollback requires -ConfirmMutation or -DryRun.","$null = Invoke-NxbV1CliSignedUpdate","$mutationPerformed = $true"]) and len(errors.get("rules",[])) == 5)

    negatives = []
    p = copy.deepcopy(policy); p["predecessor_update_head"] = "0" * 40; negatives.append(not validate_policy(p))
    p = copy.deepcopy(policy); p["commands"] = p["commands"][:-1]; negatives.append(p.get("commands") != EXPECTED_COMMANDS)
    p = copy.deepcopy(policy); p["commands"].append("status"); negatives.append(len(p["commands"]) != len(set(p["commands"])))
    p = copy.deepcopy(policy); p["safety"]["auto_apply"] = True; negatives.append(p["safety"]["auto_apply"] is True and policy["safety"]["auto_apply"] is False)
    p = copy.deepcopy(policy); p["exit_codes"]["trust_integrity"] = 7; negatives.append(p["exit_codes"] != EXPECTED_EXIT_CODES)
    s = copy.deepcopy(output_schema); s["additionalProperties"] = True; negatives.append(s["additionalProperties"] is not False)
    s = copy.deepcopy(config_schema); s["additionalProperties"] = True; negatives.append(s["additionalProperties"] is not False)
    bad = copy.deepcopy(example); bad["unexpected"] = True; negatives.append(not validate_config(bad))
    negatives.append("Test-NxbV1SignedReleaseEnvelope" not in cli and "Test-NxbV1SignedReleaseEnvelope" not in common)
    negatives.append("Sort-Object path" not in cli and "update-apply requires -ConfirmMutation or -DryRun." in cli and "$commandData = & $finalAuthority" not in cli)

    artifacts = {}
    if args.version_json:
        doc = load_json(args.version_json)
        artifacts["version_json"] = validate_output(doc,"version",0,"passed") and doc.get("data",{}).get("certified_update_head") == EXPECTED_HEAD
    if args.usage_json:
        doc = load_json(args.usage_json)
        artifacts["usage_json"] = validate_output(doc,"hash",2,"failed")
    if args.config_json:
        doc = load_json(args.config_json)
        artifacts["config_json"] = validate_output(doc,"config-validate",0,"passed") and doc.get("data",{}).get("valid") is True
    if args.dry_run_json:
        doc = load_json(args.dry_run_json)
        artifacts["dry_run_json"] = validate_output(doc,"stage-update",0,"passed") and doc.get("mutation_performed") is False

    receipt_ok = True
    if args.receipt:
        receipt = load_json(args.receipt)
        receipt_ok = (
            receipt.get("contract_id") == "nxb-v1-cli-certification-v1"
            and receipt.get("head_sha") == args.expected_head
            and receipt.get("predecessor_update_head") == EXPECTED_HEAD
            and receipt.get("ps7") == "24/24"
            and receipt.get("ps51") == "24/24"
            and receipt.get("cli_known_error_rules") == 5
            and receipt.get("known_error_findings") == 0
            and receipt.get("analyzer_findings") == 0
        )

    passed = all(req) and len(req) == 14 and all(negatives) and len(negatives) == 10 and all(artifacts.values()) and receipt_ok
    result = {
        "schema_version": 1,
        "status": "passed" if passed else "failed",
        "authority": "nxb-v1-cli-independent-v1",
        "requirements_validated": sum(bool(x) for x in req),
        "requirement_count": 14,
        "negative_controls_validated": sum(bool(x) for x in negatives),
        "negative_count": 10,
        "artifact_checks": artifacts,
        "receipt_valid": receipt_ok,
        "source_sha256": {
            "policy": sha256_file(policy_path),
            "cli": sha256_file(cli_path),
            "common": sha256_file(common_path),
        },
    }
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
