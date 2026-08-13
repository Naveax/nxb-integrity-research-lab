#!/usr/bin/env python3
import argparse
import copy
import json
import pathlib
import re
import sys

import yaml

EXPECTED_PREDECESSOR = "e665e8c27cb085853d23c8804ffaa97a19807eb9"
CHECKOUT_SHA = "3d3c42e5aac5ba805825da76410c181273ba90b1"
SETUP_PYTHON_SHA = "5fda3b95a4ea91299a34e894583c3862153e4b97"
UPLOAD_ARTIFACT_SHA = "ea165f8d65b6e75b540449e92b4886f43607fa02"
EXPECTED_CHECKS = {
    "hosted_contract": "nxb-v1 / hosted-contract",
    "signed_release_verify": "nxb-v1 / signed-release-verify",
    "native_wpt": "nxb-v1 / native-wpt",
    "release_candidate": "nxb-v1 / release-candidate",
}
EXPECTED_NATIVE_LABELS = ["self-hosted", "Windows", "X64", "nxb-native", "wpt"]


def load_json(path):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8-sig"))


def load_workflow(path):
    with open(path, "r", encoding="utf-8-sig") as handle:
        return yaml.load(handle, Loader=yaml.BaseLoader)


def as_list(value):
    if isinstance(value, list):
        return value
    if value is None:
        return []
    return [value]


def text_has_write_permission(text):
    return re.search(
        r"(?im)^\s*(?:actions|checks|contents|deployments|discussions|id-token|issues|packages|pages|pull-requests|repository-projects|security-events|statuses):\s*write\s*$",
        text,
    ) is not None


def validate_policy(policy):
    return (
        policy.get("schema_version") == 1
        and policy.get("contract_id") == "nxb-v1-ci-v1"
        and policy.get("target_version") == "1.0.0"
        and policy.get("predecessor_cli_head") == EXPECTED_PREDECESSOR
        and policy.get("certified_cli_pointer") == "certified/nxb-v1-cli"
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", required=True)
    parser.add_argument("--expected-head", required=True)
    args = parser.parse_args()

    root = pathlib.Path(args.repository_root).resolve()
    policy_path = root / "config" / "nxb-v1-ci-policy.json"
    workflow_path = root / ".github" / "workflows" / "nxb-v1-ci.yml"
    hosted_path = root / "scripts" / "Invoke-NxbV1CiHostedValidation.ps1"
    tests_path = root / "tests" / "V1Ci.Tests.ps1"

    policy = load_json(policy_path)
    workflow = load_workflow(workflow_path)
    workflow_text = workflow_path.read_text(encoding="utf-8-sig")
    hosted_text = hosted_path.read_text(encoding="utf-8-sig")
    tests_text = tests_path.read_text(encoding="utf-8-sig")

    jobs = workflow.get("jobs", {}) if isinstance(workflow, dict) else {}
    triggers = workflow.get("on", {}) if isinstance(workflow, dict) else {}
    permissions = workflow.get("permissions", {}) if isinstance(workflow, dict) else {}
    hosted = jobs.get("hosted-contract", {})
    signed = jobs.get("signed-release-verify", {})
    native = jobs.get("native-wpt", {})
    aggregate = jobs.get("release-candidate", {})
    workflow_policy = policy.get("workflow", {})

    requirements = []
    requirements.append(validate_policy(policy) and re.fullmatch(r"[0-9a-f]{40}", args.expected_head) is not None)
    requirements.append(permissions == {"contents": "read"} and not text_has_write_permission(workflow_text))
    requirements.append(isinstance(triggers, dict) and "pull_request" in triggers and "workflow_dispatch" in triggers and "pull_request_target" not in triggers)
    requirements.append(set(jobs) == {"hosted-contract", "signed-release-verify", "native-wpt", "release-candidate"} and policy.get("checks") == EXPECTED_CHECKS)
    requirements.append(
        workflow_policy.get("checkout_sha") == CHECKOUT_SHA
        and workflow_policy.get("setup_python_sha") == SETUP_PYTHON_SHA
        and workflow_policy.get("upload_artifact_sha") == UPLOAD_ARTIFACT_SHA
        and f"actions/checkout@{CHECKOUT_SHA}" in workflow_text
        and f"actions/setup-python@{SETUP_PYTHON_SHA}" in workflow_text
        and f"actions/upload-artifact@{UPLOAD_ARTIFACT_SHA}" in workflow_text
    )
    requirements.append(
        hosted.get("runs-on") == "windows-2022"
        and "Invoke-NxbV1CiHostedValidation.ps1" in workflow_text
        and "Invoke-NxbLocalValidation.ps1" not in hosted_text
        and "nxb-v1-hosted-validation-${{ env.NXB_EXPECTED_SHA }}" in workflow_text
        and "${{ runner.temp }}/nxb-v1-hosted-validation" in workflow_text
    )
    requirements.append(
        signed.get("runs-on") == "windows-2022"
        and "Invoke-NxbV1ProductionSigningCertification.ps1" in workflow_text
        and "PSObject.Properties['actual_production_release_signed']" in workflow_text
        and "PSObject.Properties['production_signer_claimed']" in workflow_text
        and "$result.actual_release_signed" not in workflow_text
        and "secrets." not in workflow_text.lower()
    )
    requirements.append(as_list(native.get("runs-on")) == EXPECTED_NATIVE_LABELS and "workflow_dispatch" in str(native.get("if", "")) and "inputs.run_native" in str(native.get("if", "")) and "Invoke-NxbLocalValidation.ps1" in workflow_text)
    requirements.append(set(as_list(aggregate.get("needs"))) == {"hosted-contract", "signed-release-verify", "native-wpt"} and "always()" in str(aggregate.get("if", "")))
    requirements.append("continue-on-error: true" not in workflow_text.lower() and "secrets." not in workflow_text.lower() and "pull_request_target" not in workflow_text)
    requirements.append(
        workflow_policy.get("pester_version") == "5.7.1"
        and workflow_policy.get("psscriptanalyzer_version") == "1.25.0"
        and workflow_policy.get("pyyaml_version") == "6.0.3"
        and workflow_policy.get("jsonschema_version") == "4.26.0"
        and "PyYAML==6.0.3 jsonschema==4.26.0" in workflow_text
    )
    requirements.append(
        "Test-PublicRepositoryContent.ps1" in hosted_text
        and "Test-Repository.ps1" in hosted_text
        and "Invoke-ScriptAnalyzer" in hosted_text
        and "py_compile" in hosted_text
        and 'm.version("jsonschema") == "4.26.0"' in hosted_text
        and "NXB_[A-Z0-9_]+_REPOSITORY_ROOT" in hosted_text
        and "SetEnvironmentVariable($rootVariableName,$repositoryRoot" in hosted_text
        and len(re.findall(r"(?m)^\s*It\s+'", tests_text)) == 17
    )

    negatives = []
    mutated = copy.deepcopy(policy)
    mutated["predecessor_cli_head"] = "0" * 40
    negatives.append(not validate_policy(mutated))
    negatives.append(text_has_write_permission(workflow_text + "\ncontents: write\n"))
    negatives.append("pull_request_target" in (workflow_text + "\npull_request_target:\n"))
    negatives.append("secrets." in (workflow_text + "\n${{ secrets.NXB_PRODUCTION_KEY }}\n").lower())
    mutated_native = copy.deepcopy(native)
    mutated_native["runs-on"] = "windows-2022"
    negatives.append(as_list(mutated_native.get("runs-on")) != EXPECTED_NATIVE_LABELS)
    mutated_native = copy.deepcopy(native)
    mutated_native.pop("if", None)
    negatives.append("workflow_dispatch" not in str(mutated_native.get("if", "")))
    negatives.append(re.search(r"actions/checkout@v\d", workflow_text + "\nactions/checkout@v7\n") is not None)
    negatives.append("continue-on-error: true" in (workflow_text + "\ncontinue-on-error: true\n").lower())

    passed = all(requirements) and len(requirements) == 12 and all(negatives) and len(negatives) == 8
    result = {
        "schema_version": 1,
        "status": "passed" if passed else "failed",
        "authority": "nxb-v1-ci-independent-v1",
        "expected_head": args.expected_head,
        "predecessor_cli_head": EXPECTED_PREDECESSOR,
        "requirements_validated": sum(bool(value) for value in requirements),
        "requirement_count": 12,
        "negative_controls_validated": sum(bool(value) for value in negatives),
        "negative_count": 8,
        "job_count": len(jobs),
        "python_dependency_versions": {"PyYAML": "6.0.3", "jsonschema": "4.26.0"},
        "production_private_key_used": False,
        "production_release_updated": False,
    }
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
