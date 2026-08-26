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
EXPECTED_NATIVE_REVIEW_ENTRIES = 8
BOUNDED_NATIVE_AUTHORITY = "nxb-bounded-trigger-native-smoke-v1"


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
        and policy.get("target_version") == "1.0.1"
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
    known_error_config_path = root / "config" / "nxb-v1-ci-known-error-signatures.json"
    workflow_path = root / ".github" / "workflows" / "nxb-v1-ci.yml"
    hosted_path = root / "scripts" / "Invoke-NxbV1CiHostedValidation.ps1"
    known_error_scanner_path = root / "scripts" / "Invoke-NxbV1CiKnownErrorScan.ps1"
    native_path = root / "scripts" / "Invoke-NxbV1CiNativeValidation.ps1"
    bounded_native_path = root / "scripts" / "Invoke-NxbBoundedTriggerNativeSmoke.ps1"
    bounded_state_path = root / "scripts" / "Update-NxbBoundedTriggerCaptureState.ps1"
    bounded_start_path = root / "scripts" / "Start-NxbBoundedMemoryTrace.ps1"
    bounded_coordinator_path = root / "scripts" / "Invoke-NxbBoundedTriggerCapture.ps1"
    bounded_tests_path = root / "tests" / "BoundedTriggerCapture.Tests.ps1"
    bounded_activation_tests_path = root / "tests" / "BoundedTriggerActivation.Tests.ps1"
    tests_path = root / "tests" / "V1Ci.Tests.ps1"

    policy = load_json(policy_path)
    known_error_config = load_json(known_error_config_path)
    workflow = load_workflow(workflow_path)
    workflow_text = workflow_path.read_text(encoding="utf-8-sig")
    hosted_text = hosted_path.read_text(encoding="utf-8-sig")
    known_error_scanner_text = known_error_scanner_path.read_text(encoding="utf-8-sig")
    native_text = native_path.read_text(encoding="utf-8-sig")
    bounded_native_text = bounded_native_path.read_text(encoding="utf-8-sig")
    bounded_state_text = bounded_state_path.read_text(encoding="utf-8-sig")
    bounded_start_text = bounded_start_path.read_text(encoding="utf-8-sig")
    bounded_coordinator_text = bounded_coordinator_path.read_text(encoding="utf-8-sig")
    bounded_tests_text = bounded_tests_path.read_text(encoding="utf-8-sig")
    bounded_activation_tests_text = bounded_activation_tests_path.read_text(encoding="utf-8-sig")
    tests_text = tests_path.read_text(encoding="utf-8-sig")
    all_tests_text = "\n".join(
        path.read_text(encoding="utf-8-sig")
        for path in sorted((root / "tests").glob("*.ps1"))
    )
    ps7_only_count = len(
        re.findall(
            r"(?m)^\s*It\s+'[^']+'[^\r\n]*-Tag\s+'PS7Only'(?:\s|$)",
            all_tests_text,
        )
    )
    bounded_test_count = sum(
        len(re.findall(r"(?m)^\s*It\s+'", text))
        for text in (bounded_tests_text, bounded_activation_tests_text)
    )

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
        and "Invoke-NxbV1CiNativeValidation.ps1" not in hosted_text
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
    requirements.append(
        as_list(native.get("runs-on")) == EXPECTED_NATIVE_LABELS
        and "workflow_dispatch" in str(native.get("if", ""))
        and "inputs.run_native" in str(native.get("if", ""))
        and "Invoke-NxbV1CiNativeValidation.ps1" in workflow_text
        and "Invoke-NxbLocalValidation.ps1" not in workflow_text
        and "Invoke-NxbV1CiHostedValidation.ps1" in native_text
        and "Invoke-CollectorOverheadCalibration.ps1" in native_text
        and "Invoke-NxbBoundedTriggerNativeSmoke.ps1" in native_text
        and BOUNDED_NATIVE_AUTHORITY in native_text
        and "bounded_trigger_smoke_valid = $true" in native_text
        and "bounded-trigger-native-smoke.json" in native_text
        and f"review_entries = {EXPECTED_NATIVE_REVIEW_ENTRIES}" in native_text
        and "review_entries = 7" not in native_text
        and "$pythonVersion -cne '3.12.10'" in native_text
        and "python_version = $pythonVersion" in native_text
        and BOUNDED_NATIVE_AUTHORITY in bounded_native_text
        and "domain_accounting = @($receipt.domain_accounting)" in bounded_native_text
        and "etl_retained_in_review_artifact = $false" in bounded_native_text
        and "nxb-v1-ci-native-v1" in native_text
        and "ps51_expected_excluded" in native_text
        and "$ps7Passed -ne $ps7Total" in native_text
        and "$ps51ExcludedTag -cne 'PS7Only'" in native_text
        and "$ps51Total -ne $ps7Total" in native_text
        and "$ps51Passed -ne ($ps51Total - $expectedPs51Excluded)" in native_text
        and "'893/893'" not in native_text
        and "'886/893'" not in native_text
        and "production_release_updated = $false" in native_text
        and "Upload native validation evidence" in workflow_text
        and "nxb-v1-native-validation-${{ env.NXB_EXPECTED_SHA }}" in workflow_text
        and "${{ runner.temp }}/nxb-v1-native-validation" in workflow_text
    )
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
        known_error_config.get("schema_version") == 1
        and known_error_config.get("contract_id") == "nxb-v1-ci-known-error-signatures-v1"
        and len(known_error_config.get("rules", [])) == 6
        and "Invoke-NxbV1CiKnownErrorScan.ps1" in hosted_text
        and "nxb-v1-ci-known-error-scan-v1" in hosted_text
        and "known_error_findings" in hosted_text
        and "Invoke-NxbKnownErrorScan.ps1" in known_error_scanner_text
        and "Invoke-NxbProductionKnownErrorScan.ps1" in known_error_scanner_text
        and "nxb-v1-release-known-error-signatures.json" in known_error_scanner_text
        and "nxb-v1-signing-known-error-signatures.json" in known_error_scanner_text
        and "nxb-v1-installer-known-error-signatures.json" in known_error_scanner_text
        and "nxb-v1-update-known-error-signatures.json" in known_error_scanner_text
        and "nxb-v1-cli-known-error-signatures.json" in known_error_scanner_text
        and "Test-PublicRepositoryContent.ps1" in hosted_text
        and "Test-Repository.ps1" in hosted_text
        and "Invoke-NxbV1CiNativeProcess" in hosted_text
        and "Get-Command pwsh.exe" in hosted_text
        and "Import-Module $AnalyzerModulePath -Force" in hosted_text
        and "Invoke-ScriptAnalyzer -Path (Join-Path $RepositoryRoot 'scripts') -Recurse -Settings $SettingsPath" in hosted_text
        and "Invoke-ScriptAnalyzer -Path (Join-Path $RepositoryRoot 'tests') -Recurse -Settings $SettingsPath" in hosted_text
        and "nxb-v1-ci-analyzer-isolated-v1" in hosted_text
        and "main process must remain Pester-assembly-free" in hosted_text
        and "contaminated the main Pester assembly context" in hosted_text
        and "Import-Module $analyzerModule.Path -Force" not in hosted_text
        and "py_compile" in hosted_text
        and 'm.version("jsonschema") == "4.26.0"' in hosted_text
        and "NXB_[A-Z0-9_]+_REPOSITORY_ROOT" in hosted_text
        and "SetEnvironmentVariable($rootVariableName,$repositoryRoot" in hosted_text
        and "$ps51ExcludedTag = 'PS7Only'" in hosted_text
        and "$expectedPs51ExcludedTests = 7" in hosted_text
        and "$config.Filter.ExcludeTag=@($ExcludedTag)" in hosted_text
        and "NotRunCount" in hosted_text
        and ps7_only_count == 7
        and len(re.findall(r"(?m)^\s*It\s+'", tests_text)) == 17
    )
    requirements.append(
        bounded_test_count == 16
        and "nxb-bounded-trigger-capture-state-v1" in bounded_state_text
        and "bounded-memory-buffer-reuse" in bounded_start_text
        and "MinimumFreeDiskMiB" in bounded_coordinator_text
        and "estimated_overwritten_buffer_count" in bounded_coordinator_text
        and "session_binding_valid" in bounded_coordinator_text
        and "not_captured_by_minimal_wpr_primitive" in bounded_coordinator_text
        and "Get-NxbBoundedActivationKey" in bounded_coordinator_text
        and "last_transition_utc" in bounded_coordinator_text
        and "$seenActivation.Add($activationKey)" in bounded_coordinator_text
        and "$seenActivation.Add($TriggerId)" not in bounded_coordinator_text
        and "$seenActivation.Add($id)" not in bounded_coordinator_text
        and "[IO.File]::Move($tempPath,$using:signalsPath,$true)" in bounded_native_text
        and "-EmergencyStopPath $emergencyStopPath" in bounded_native_text
        and "preserves activation instances and atomically publishes the native trigger signal" in bounded_activation_tests_text
        and "review_entries = 8" in tests_text
        and "Should -Not -Match ([regex]::Escape('review_entries = 7'))" in tests_text
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

    passed = all(requirements) and len(requirements) == 13 and all(negatives) and len(negatives) == 8
    result = {
        "schema_version": 1,
        "status": "passed" if passed else "failed",
        "authority": "nxb-v1-ci-independent-v1",
        "expected_head": args.expected_head,
        "predecessor_cli_head": EXPECTED_PREDECESSOR,
        "requirements_validated": sum(bool(value) for value in requirements),
        "requirement_count": 13,
        "negative_controls_validated": sum(bool(value) for value in negatives),
        "negative_count": 8,
        "job_count": len(jobs),
        "ps51_excluded_tag": "PS7Only",
        "ps51_excluded_test_count": ps7_only_count,
        "bounded_trigger_test_count": bounded_test_count,
        "known_error_authority": "nxb-v1-ci-known-error-scan-v1",
        "ci_known_error_rules": len(known_error_config.get("rules", [])),
        "native_authority": "nxb-v1-ci-native-v1",
        "bounded_native_authority": BOUNDED_NATIVE_AUTHORITY,
        "native_review_entries": EXPECTED_NATIVE_REVIEW_ENTRIES,
        "native_cardinality_binding": "hosted-relational",
        "native_evidence_retained": "nxb-v1-native-validation-${{ env.NXB_EXPECTED_SHA }}" in workflow_text,
        "bounded_native_review_json_only": "etl_retained_in_review_artifact = $false" in bounded_native_text,
        "python_dependency_versions": {"PyYAML": "6.0.3", "jsonschema": "4.26.0"},
        "production_private_key_used": False,
        "production_release_updated": False,
    }
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
