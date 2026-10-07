BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $script:SchemaPath = Join-Path $script:RepositoryRoot 'schemas\nxb-v11-environment-fingerprint.schema.json'
    $script:FixturePath = Join-Path $script:RepositoryRoot 'validation\v11\fixtures\native-runtime\environment-fingerprint-v1.synthetic.json'
    $script:EvidenceStorePath = Join-Path $script:RepositoryRoot 'scripts\Nxb.EvidenceStore.psm1'
    $script:PythonPath = if ($env:NXB_V11_PYTHON) {
        [IO.Path]::GetFullPath($env:NXB_V11_PYTHON)
    } else {
        [IO.Path]::GetFullPath((Get-Command python -ErrorAction Stop).Source)
    }
    Import-Module $script:EvidenceStorePath -Force
}

Describe 'V11 physical fingerprint source schema (claim-free)' {
    It 'reproduces 29 schema and identity regression checks' {
        $pythonCode = @'
#!/usr/bin/env python3
from __future__ import annotations
import copy, hashlib, json, pathlib, sys
from jsonschema import Draft202012Validator, FormatChecker

repo = pathlib.Path(sys.argv[1])
schema_path = repo / "schemas" / "nxb-v11-environment-fingerprint.schema.json"
fixture_path = repo / "validation" / "v11" / "fixtures" / "native-runtime" / "environment-fingerprint-v1.synthetic.json"
schema = json.loads(schema_path.read_text(encoding="utf-8"))
fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
Draft202012Validator.check_schema(schema)
validator = Draft202012Validator(schema, format_checker=FormatChecker())

def digest(value):
    doc = {k: v for k, v in value.items() if k not in {"captured_utc", "fingerprint_sha256"}}
    payload = json.dumps(doc, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()

def validate(value):
    return list(validator.iter_errors(value))

results = []
def pass_case(label, condition):
    if not condition:
        raise AssertionError("FAILED " + label)
    results.append(label)

pass_case("schema-2020-12-valid", True)
pass_case("positive-synthetic", not validate(fixture))
pass_case("stored-sha-exact", fixture["fingerprint_sha256"] == digest(fixture))

t=copy.deepcopy(fixture)
t["captured_utc"] = "2026-10-07T01:02:03Z"
pass_case("volatile-timestamp-excluded", digest(t) == digest(fixture))

for label,change in [
    ("ubr-drift", lambda d: d["windows"].__setitem__("ubr",9169)),
    ("pwsh-micro-drift", lambda d: d["powershell"].__setitem__("version","7.6.7")),
    ("policy-hash-drift", lambda d: d.__setitem__("policy_sha256","9"*64)),
    ("tree-drift", lambda d: d.__setitem__("head_tree_sha","c"*40)),
]:
    d=copy.deepcopy(fixture)
    change(d)
    pass_case(label+"-identity-change",digest(d)!=digest(fixture))

negative=[
    ("wrong-authority", lambda d:d.__setitem__("authority","other")),
    ("dirty-worktree", lambda d:d.__setitem__("worktree_clean",False)),
    ("unknown-property",lambda d:d.__setitem__("leaked_machine_serial","unsafe")),
    ("wrong-windows-product-type",lambda d:d["windows"].__setitem__("product_type",4)),
    ("wrong-arch",lambda d:d["windows"].__setitem__("architecture","amd64")),
    ("wrong-ubr-type",lambda d:d["windows"].__setitem__("ubr","9168")),
    ("wrong-git-sha",lambda d:d.__setitem__("head_sha","A"*40)),
    ("wrong-policy-sha",lambda d:d.__setitem__("policy_sha256","g"*64)),
    ("runner-label-duplicate",lambda d:d["runner"].__setitem__("labels",["self-hosted","self-hosted"])),
    ("runner-os-server",lambda d:d["runner"].__setitem__("os","Linux")),
    ("wpt-pairing-false",lambda d:d["wpt"].__setitem__("same_directory",False)),
    ("wpt-sibling-missing",lambda d:d["wpt"].__setitem__("wpr",{})),
    ("wpt-relative-traversal",lambda d:d["wpt"]["xperf"].__setitem__("relative_path","..\\xperf.exe")),
    ("user-home-leak",lambda d:d["python"].__setitem__("executable",r"C:\Users\someone\Python\python.exe")),
    ("user-home-case-variant",lambda d:d["python"].__setitem__("executable",r"C:\users\someone\python.exe")),
    ("unserviced-claim-with-null-proof",lambda d:d["adk"].__setitem__("servicing_proof_sha256",None)),
    ("serviced-claim-with-null-kb",lambda d:d["adk"].__setitem__("servicing_kb",None)),
    ("timestamp-no-utc",lambda d:d.__setitem__("captured_utc","2026-10-06T00:00:00")),
]
for label,change in negative:
    d=copy.deepcopy(fixture)
    change(d)
    errors=validate(d)
    pass_case("reject-"+label,bool(errors))

d=copy.deepcopy(fixture)
d["adk"]["servicing_state"]="unresolved"
d["adk"]["servicing_kb"]=None
d["adk"]["servicing_proof_sha256"]=None
d["adk"]["servicing_proof_kind"]=None
pass_case("unresolved-servicing-is-representable-not-admitted",not validate(d))

d=copy.deepcopy(fixture)
d["fingerprint_sha256"]="0"*64
pass_case("stored-fingerprint-tamper-rejected-by-identity",d["fingerprint_sha256"]!=digest(d))

pass_case("runner-labels-ordinal-and-unique",fixture["runner"]["labels"]==sorted(set(fixture["runner"]["labels"])))
print(json.dumps({"status":"PASS","count":len(results),"checks":results},separators=(",",":")))
'@
        $temporaryPy = Join-Path ([IO.Path]::GetTempPath()) (
            'nxb-v11-fingerprint-{0}.py' -f [Guid]::NewGuid().ToString('N')
        )
        [IO.File]::WriteAllText(
            $temporaryPy, $pythonCode, [Text.UTF8Encoding]::new($false)
        )
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = @(& $script:PythonPath $temporaryPy $script:RepositoryRoot 2>&1 | ForEach-Object { [string]$_ })
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
            Remove-Item -LiteralPath $temporaryPy -Force -ErrorAction SilentlyContinue
        }
        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        $result = ($output -join [Environment]::NewLine) | ConvertFrom-Json
        $result.status | Should -BeExactly 'PASS'
        [int]$result.count | Should -Be 29
        @($result.checks).Count | Should -Be 29
    }

    It 'recomputes the identical fingerprint identity using frozen PowerShell canonical JSON' {
        $doc = Get-Content -LiteralPath $script:FixturePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $expected = [string]$doc.fingerprint_sha256
        [void]$doc.PSObject.Properties.Remove('captured_utc')
        [void]$doc.PSObject.Properties.Remove('fingerprint_sha256')
        $json = ConvertTo-NxbCanonicalJson -InputObject $doc
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        $hasher = [Security.Cryptography.SHA256]::Create()
        try {
            $observed = [BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $hasher.Dispose()
        }
        $observed | Should -BeExactly $expected
    }

    It 'preserves strict source authority and excludes user-profile data from the synthetic fixture' {
        $schema = Get-Content -LiteralPath $script:SchemaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $schema.'$id' | Should -BeExactly 'urn:nxb:schema:nxb-v11-environment-fingerprint:v1'
        $schema.properties.authority.const | Should -BeExactly 'nxb-compatibility-environment-fingerprint-v1'
        [bool]$schema.additionalProperties | Should -BeFalse
        $fixture = Get-Content -LiteralPath $script:FixturePath -Raw -Encoding UTF8
        $fixture | Should -Not -Match '[A-Za-z]:\\[Uu][Ss][Ee][Rr][Ss]\\'
        $fixture | Should -Not -Match '"(?:ip_address|mac_address|machine_serial|hardware_uuid)"'
    }
}
Describe 'V11 claim-free fingerprint reconciliation boundary' {
    BeforeAll {
        $root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
        $script:FingerprintReconciler = Join-Path $root 'validation\v11\scripts\Get-NxbCompatibilityEnvironmentFingerprint.ps1'
        $script:FingerprintSchema = Join-Path $root 'schemas\nxb-v11-environment-fingerprint.schema.json'
        $script:FingerprintFixture = Join-Path $root 'validation\v11\fixtures\native-runtime\environment-fingerprint-v1.synthetic.json'
        $script:FingerprintPwsh = (Get-Command pwsh -ErrorAction Stop).Source
        $script:FingerprintPython = if ($env:NXB_V11_PYTHON) {
            [IO.Path]::GetFullPath($env:NXB_V11_PYTHON)
        } else {
            [IO.Path]::GetFullPath((Get-Command python -ErrorAction Stop).Source)
        }
        $script:FingerprintValidatorRoot = (
            & $script:FingerprintPython -c 'import pathlib,jsonschema;print(pathlib.Path(jsonschema.__file__).resolve().parent.parent)'
        ).Trim()
        Test-Path -LiteralPath $script:FingerprintValidatorRoot -PathType Container | Should -BeTrue
    }

    It 'binds the environment schema to the exact admitted LF and CRLF byte identities' {
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        $raw = [IO.File]::ReadAllBytes($script:FingerprintSchema)
        $text = $utf8.GetString($raw)
        $lf = $utf8.GetBytes($text.Replace("`r`n", "`n"))
        $crlf = $utf8.GetBytes($text.Replace("`r`n", "`n").Replace("`n", "`r`n"))
        $getSha256 = {
            param([byte[]]$Bytes)
            $hash = [Security.Cryptography.SHA256]::Create()
            try {
                ([BitConverter]::ToString($hash.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
            }
            finally {
                $hash.Dispose()
            }
        }

        (& $getSha256 $lf) | Should -BeExactly '04698ce35e2765e042f64582a11de77b3f60bded5a0f176857e84df1f51c9144'
        (& $getSha256 $crlf) | Should -BeExactly 'bd1996bb06b8e9714b579115d0124866bd45dd7f8d802421f8b973ea6218671c'
        @(
            '04698ce35e2765e042f64582a11de77b3f60bded5a0f176857e84df1f51c9144',
            'bd1996bb06b8e9714b579115d0124866bd45dd7f8d802421f8b973ea6218671c'
        ) | Should -Contain (& $getSha256 $raw)
    }

    It 'reconciles independent Python and frozen PowerShell canonical digests' {
        $args = @('-NoLogo','-NoProfile','-File',$script:FingerprintReconciler,
            '-ObservationJsonPath',$script:FingerprintFixture,
            '-PythonExecutablePath',$script:FingerprintPython,
            '-ValidatorPackageRoot',$script:FingerprintValidatorRoot)
        $result = @(& $script:FingerprintPwsh @args)
        $LASTEXITCODE | Should -Be 0
        $doc = ($result -join [Environment]::NewLine) | ConvertFrom-Json
        $doc.status | Should -BeExactly 'RECONCILED_CLAIM_FREE'
        $doc.cross_runtime_hash_match | Should -BeTrue
        $doc.physical_compatibility_claimed | Should -BeFalse
        $doc.fingerprint_sha256 | Should -BeExactly '9de216a4202d1117cda3fa8d11de20a069c04e67dbd37d030752dd2a4c577146'
    }

    It 'seals canonical bytes with the original captured_utc string unchanged' {
        $output = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-fingerprint-{0}.json' -f [Guid]::NewGuid().ToString('N'))
        try {
            $args = @('-NoLogo','-NoProfile','-File',$script:FingerprintReconciler,
                '-ObservationJsonPath',$script:FingerprintFixture,
                '-PythonExecutablePath',$script:FingerprintPython,
                '-ValidatorPackageRoot',$script:FingerprintValidatorRoot,
                '-OutputCanonicalJsonPath',$output)
            $result = @(& $script:FingerprintPwsh @args)
            $LASTEXITCODE | Should -Be 0
            Test-Path -LiteralPath $output -PathType Leaf | Should -BeTrue
            $bytes = [IO.File]::ReadAllBytes($output)
            $bytes[$bytes.Length - 1] | Should -Not -Be 10
            $text = [Text.UTF8Encoding]::new($false,$true).GetString($bytes)
            $text | Should -Match '"captured_utc":"2026-10-06T00:00:00Z"'
            $text | Should -Not -Match '00:00:00.0000000Z'
        }
        finally {
            Remove-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects a tampered stored fingerprint' {
        $path = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-tampered-fingerprint-{0}.json' -f [Guid]::NewGuid().ToString('N'))
        $source = Get-Content -LiteralPath $script:FingerprintFixture -Raw -Encoding UTF8
        $old = '9de216a4202d1117cda3fa8d11de20a069c04e67dbd37d030752dd2a4c577146'
        [IO.File]::WriteAllText($path,$source.Replace($old,('0' * 64)),[Text.UTF8Encoding]::new($false))
        try {
            $args = @('-NoLogo','-NoProfile','-File',$script:FingerprintReconciler,
                '-ObservationJsonPath',$path,
                '-PythonExecutablePath',$script:FingerprintPython,
                '-ValidatorPackageRoot',$script:FingerprintValidatorRoot)
            $previous = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $result = @(& $script:FingerprintPwsh @args 2>&1 | ForEach-Object { [string]$_ })
                $exitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previous
            }
            $exitCode | Should -Not -Be 0
            ($result -join [Environment]::NewLine) | Should -Match 'fingerprint SHA mismatch'
        }
        finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}
Describe 'V11 compatibility-plan structural boundary (claim-free)' {
    BeforeAll {
        $script:PlanRepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
        $script:PlanSchemaPath = Join-Path $script:PlanRepositoryRoot 'schemas\nxb-v11-compatibility-plan.schema.json'
        $script:PlanFixturePath = Join-Path $script:PlanRepositoryRoot 'validation\v11\fixtures\native-runtime\compatibility-plan-v1.synthetic.json'
        $script:PlanPython = if ($env:NXB_V11_PYTHON) {
            [IO.Path]::GetFullPath($env:NXB_V11_PYTHON)
        } else {
            [IO.Path]::GetFullPath((Get-Command python -ErrorAction Stop).Source)
        }
        Import-Module (Join-Path $script:PlanRepositoryRoot 'scripts\Nxb.EvidenceStore.psm1') -Force
    }

    It 'rejects structural plan drift without asserting native support' {
        $code = @(
            'from __future__ import annotations'
            'import copy, json, pathlib, sys'
            'from jsonschema import Draft202012Validator'
            'repo = pathlib.Path(sys.argv[1])'
            'schema = json.loads((repo / "schemas" / "nxb-v11-compatibility-plan.schema.json").read_text(encoding="utf-8"))'
            'fixture = json.loads((repo / "validation" / "v11" / "fixtures" / "native-runtime" / "compatibility-plan-v1.synthetic.json").read_text(encoding="utf-8"))'
            'Draft202012Validator.check_schema(schema)'
            'validator = Draft202012Validator(schema)'
            'results = []'
            'def check(label, condition):'
            '    if not condition: raise AssertionError("FAILED " + label)'
            '    results.append(label)'
            'def mutate(label, target, value, valid=False):'
            '    candidate = copy.deepcopy(fixture)'
            '    node = candidate'
            '    for part in target[:-1]: node = node[part]'
            '    node[target[-1]] = value'
            '    got = not list(validator.iter_errors(candidate))'
            '    check(label, got is valid)'
            'check("positive-baseline", not list(validator.iter_errors(fixture)))'
            'check("review-six", fixture["review"]["entry_count"] == 6)'
            'check("no-physical-claim", "physical_support_claimed" not in fixture)'
            'mutate("reject-disabled-cell", ["cell","status"], "provisional-disabled")'
            'mutate("reject-invalid-authority", ["authority"], "other")'
            'mutate("reject-wrong-repository", ["repository"], "other/repository")'
            'mutate("reject-bad-dispatcher-sha", ["dispatcher","sha"], "F" * 40)'
            'mutate("reject-wrong-predecessor-issue", ["predecessor","issue"], 27)'
            'mutate("reject-unknown-root-field", ["raw_etl"], "secret")'
            'mutate("reject-non-baseline-null-ref", ["cell","axis"], "python")'
            'mutate("reject-main-pr-number", ["candidate","pr_number"], 51)'
            'mutate("reject-main-branch", ["candidate","branch"], "candidate/feature")'
            'mutate("reject-wrong-cycle-count", ["endurance","bounded_cycle_count"], 6)'
            'mutate("reject-over-ticks", ["limits","runner","max_ticks"], 257)'
            'mutate("reject-over-attempts", ["limits","runner","max_attempts_per_task"], 4)'
            'mutate("reject-over-frame", ["limits","transport","max_frame_bytes"], 16385)'
            'mutate("reject-over-spool", ["limits","transport","max_spool_bytes"], 262145)'
            'mutate("reject-queue-overflow", ["limits","transport","queue_overflow"], 1)'
            'mutate("reject-over-trace-ring", ["limits","observability","max_trace_ring_bytes"], 67108865)'
            'mutate("reject-review-seven", ["review","entry_count"], 7)'
            'mutate("reject-production-key", ["production_boundary","private_key_used"], True)'
            'mutate("reject-production-release", ["production_boundary","release_mutation"], True)'
            'mutate("reject-lineage-hash", ["lineage","a1_policy_enablement_receipt_sha256"], "z" * 64)'
            'mutate("reject-intent-float", ["intent","sha256"], 2.5)'
            'mutate("reject-observability-disk-zero", ["limits","observability","max_disk_bytes"], 0)'
            'd=copy.deepcopy(fixture)'
            'd["execution_mode"]="candidate"'
            'd["candidate"]["pr_number"]=51'
            'd["candidate"]["branch"]="native/feature"'
            'd["candidate"]["sha"]="2" * 40'
            'd["candidate"]["tree_sha"]="3" * 40'
            'd["cell"]["axis"]="python"'
            'd["cell"]["baseline_cell_id"]=fixture["cell"]["id"]'
            'd["cell"]["axis_change_count"]=1'
            'check("positive-candidate-shape", not list(validator.iter_errors(d)))'
            'd["candidate"]["pr_number"]=None'
            'check("reject-candidate-missing-pr", bool(list(validator.iter_errors(d))))'
            'd=copy.deepcopy(fixture)'
            'd["cell"]["axis"]="hardware"'
            'd["cell"]["baseline_cell_id"]=fixture["cell"]["id"]'
            'd["cell"]["axis_change_count"]=2'
            'check("reject-multi-axis-without-reference", bool(list(validator.iter_errors(d))))'
            'd["cell"]["cross_axis_exception_reference"]="issue49:synthetic-cross-axis-exception"'
            'check("represent-explicit-exception-only", not list(validator.iter_errors(d)))'
            'd=copy.deepcopy(fixture)'
            'd["endurance"]["tier"]="24h"'
            'd["endurance"]["bounded_cycle_count"]=24'
            'check("positive-bounded-24h-shape", not list(validator.iter_errors(d)))'
            'print(json.dumps({"status":"PASS","count":len(results),"checks":results},separators=(",",":")))'
        ) -join [Environment]::NewLine

        $temp = Join-Path ([IO.Path]::GetTempPath()) (
            'nxb-v11-plan-check-{0}.py' -f [Guid]::NewGuid().ToString('N')
        )
        [IO.File]::WriteAllText($temp,$code,[Text.UTF8Encoding]::new($false))
        $previous = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = @(& $script:PlanPython $temp $script:PlanRepositoryRoot 2>&1 | ForEach-Object { [string]$_ })
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previous
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        $result = ($output -join [Environment]::NewLine) | ConvertFrom-Json
        $result.status | Should -BeExactly 'PASS'
        [int]$result.count | Should -Be 30
        @($result.checks).Count | Should -Be 30
    }

    It 'preserves exact canonical synthetic fixture bytes and restrictive authority' {
        $schema = Get-Content -LiteralPath $script:PlanSchemaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $schema.'$id' | Should -BeExactly 'urn:nxb:schema:nxb-v11-compatibility-plan:v1'
        $schema.properties.authority.const | Should -BeExactly 'nxb-v11-compatibility-plan-v1'
        [bool]$schema.additionalProperties | Should -BeFalse

        $fixture = Get-Content -LiteralPath $script:PlanFixturePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $expected = ConvertTo-NxbCanonicalJson -InputObject $fixture
        $bytes = [IO.File]::ReadAllBytes($script:PlanFixturePath)
        $text = [Text.UTF8Encoding]::new($false,$true).GetString($bytes)
        $text | Should -BeExactly $expected
        $fixture.execution_mode | Should -BeExactly 'admitted_main'
        $fixture.candidate.pr_number | Should -BeNullOrEmpty
        $fixture.production_boundary.private_key_used | Should -BeFalse
        $fixture.production_boundary.repository_protection_mutated | Should -BeFalse
    }
}
Describe 'V11 claim-free endurance-cycle summary contract' {
    It 'preserves a canonical synthetic fixture without physical admission' {
        $schemaPath = Join-Path $script:RepositoryRoot 'schemas\nxb-v11-endurance-cycle-summary.schema.json'
        $fixturePath = Join-Path $script:RepositoryRoot 'validation\v11\fixtures\native-runtime\endurance-cycle-summary-v1.synthetic.json'
        $schema = Get-Content -LiteralPath $schemaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $fixture = Get-Content -LiteralPath $fixturePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $schema.'$id' | Should -BeExactly 'urn:nxb:schema:nxb-v11-endurance-cycle-summary:v1'
        $schema.properties.authority.const | Should -BeExactly 'nxb-v11-endurance-cycle-summary-v1'
        [bool]$schema.additionalProperties | Should -BeFalse
        $fixture.status | Should -BeExactly 'synthetic_closed_unadmitted'
        $fixture.physical_compatibility_claimed | Should -BeFalse
        $fixture.raw_payloads_embedded | Should -BeFalse
        $fixture.review.entry_count | Should -Be 6

        $raw = [IO.File]::ReadAllBytes($fixturePath)
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($raw)
        $canonicalCode = @(
            'import json, pathlib, sys'
            'p = pathlib.Path(sys.argv[1])'
            'raw = p.read_bytes()'
            'value = json.loads(raw.decode("utf-8", "strict"))'
            'canonical = json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")'
            'print("PASS" if raw == canonical else "FAIL")'
        ) -join [Environment]::NewLine
        $canonicalTemp = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-endurance-canonical-{0}.py' -f [Guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($canonicalTemp, $canonicalCode, [Text.UTF8Encoding]::new($false))
        try {
            $check = @(& $script:PythonPath -I $canonicalTemp $fixturePath 2>&1 | ForEach-Object { [string]$_ })
            $checkExit = $LASTEXITCODE
        }
        finally {
            Remove-Item -LiteralPath $canonicalTemp -Force -ErrorAction SilentlyContinue
        }
        $checkExit | Should -Be 0 -Because ($check -join [Environment]::NewLine)
        $check.Count | Should -Be 1
        $check[0] | Should -BeExactly 'PASS'
    }

    It 'enforces structural 1h/6h/24h and bounded negative controls' {
        $code = @'
from __future__ import annotations
import copy, json, pathlib, sys
from jsonschema import Draft202012Validator
r=pathlib.Path(sys.argv[1])
s=json.loads((r/"schemas"/"nxb-v11-endurance-cycle-summary.schema.json").read_text(encoding="utf-8"))
f=json.loads((r/"validation"/"v11"/"fixtures"/"native-runtime"/"endurance-cycle-summary-v1.synthetic.json").read_text(encoding="utf-8"))
Draft202012Validator.check_schema(s)
v=Draft202012Validator(s)
checks=[]
def check(name,ok):
    if not ok: raise AssertionError(name)
    checks.append(name)
check("positive-1h",v.is_valid(f))
for tier,n in (("6h",6),("24h",24)):
    x=copy.deepcopy(f)
    x["endurance_tier"]=tier
    x["cycle_count"]=n
    x["cycles"]=copy.deepcopy(f["cycles"])*n
    for i,c in enumerate(x["cycles"]):c["index"]=i+1
    check("positive-"+tier,v.is_valid(x))
cases=[
 ("wrong-authority",["authority"],"other"),
 ("wrong-review-count",["review","entry_count"],7),
 ("wrong-physical-claim",["physical_compatibility_claimed"],True),
 ("wrong-raw-payload",["raw_payloads_embedded"],True),
 ("wrong-1h-count",["cycle_count"],6),
 ("wrong-24h-length",["endurance_tier"],"24h"),
 ("wrong-unknown-root",["raw_etl"],"leak"),
 ("wrong-unknown-cycle",["cycles",0,"raw_etl"],"leak"),
 ("wrong-task-count",["cycles",0,"part4","task_count"],23),
 ("wrong-task-ticks",["cycles",0,"part4","max_ticks_observed"],257),
 ("wrong-task-attempts",["cycles",0,"part4","max_attempts_observed"],4),
 ("wrong-task-queue",["cycles",0,"part4","ready_queue_peak"],25),
 ("wrong-recovery",["cycles",0,"part4","final_resume_closed"],False),
 ("wrong-transport-events",["cycles",0,"part3","synthetic_event_count"],23),
 ("wrong-transport-frame",["cycles",0,"part3","max_frame_bytes_observed"],16385),
 ("wrong-transport-queue",["cycles",0,"part3","max_queue_depth_observed"],9),
 ("wrong-transport-overflow",["cycles",0,"part3","queue_overflow"],1),
 ("wrong-transport-spool",["cycles",0,"part3","spool_byte_peak"],262145),
 ("wrong-transport-reconnect",["cycles",0,"part3","reconnect_attempts"],4),
 ("wrong-observability-wpr",["cycles",0,"observability","memory_wpr_trigger_count"],2),
 ("wrong-observability-ring",["cycles",0,"observability","trace_ring_bytes"],67108865),
 ("wrong-observability-pre",["cycles",0,"observability","trace_pre_seconds"],31),
 ("wrong-observability-disk",["cycles",0,"observability","disk_bytes"],536870913),
 ("wrong-trace-loss",["cycles",0,"observability","trace_lost_events"],1),
 ("wrong-trace-accounting",["cycles",0,"observability","trace_accounting_closed"],False),
 ("wrong-release-mutation",["production_boundary","release_mutation"],True),
 ("wrong-uppercase-policy-sha",["policy_sha256"],"A"*64),
 ("wrong-cell-id",["cell_id"],"bad cell")
]
for name,path,value in cases:
    x=copy.deepcopy(f)
    node=x
    for k in path[:-1]:node=node[k]
    node[path[-1]]=value
    check(name,not v.is_valid(x))
print(json.dumps({"status":"PASS","count":len(checks)},separators=(",",":")))
'@
        $temp = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-endurance-check-{0}.py' -f [Guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($temp, $code, [Text.UTF8Encoding]::new($false))
        $previous = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = @(& $script:PythonPath $temp $script:RepositoryRoot 2>&1 | ForEach-Object { [string]$_ })
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previous
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        $result = ($output -join [Environment]::NewLine) | ConvertFrom-Json
        $result.status | Should -BeExactly 'PASS'
        [int]$result.count | Should -Be 31
    }
}


Describe 'V11 native semantic preflight (claim-free)' {
    BeforeAll {
        $script:NativeSemanticPath = Join-Path $script:RepositoryRoot 'validation\v11\scripts\Invoke-NxbV11CompatibilityNativeValidation.ps1'
        $script:NativeSemanticPwsh = [IO.Path]::GetFullPath((Get-Command pwsh -ErrorAction Stop).Source)
        $script:NativePlanFixture = Join-Path $script:RepositoryRoot 'validation\v11\fixtures\native-runtime\compatibility-plan-v1.synthetic.json'
        $script:NativeFingerprintFixture = Join-Path $script:RepositoryRoot 'validation\v11\fixtures\native-runtime\environment-fingerprint-v1.synthetic.json'

        function Get-NativeSemanticSha256 {
            param([Parameter(Mandatory = $true)][byte[]]$Bytes)
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
            }
            finally {
                $sha.Dispose()
            }
        }

        function Set-NativeSemanticFingerprintIdentity {
            param([Parameter(Mandatory = $true)]$Document)
            $copy = ($Document | ConvertTo-Json -Compress -Depth 100) | ConvertFrom-Json
            [void]$copy.PSObject.Properties.Remove('captured_utc')
            [void]$copy.PSObject.Properties.Remove('fingerprint_sha256')
            $canonical = ConvertTo-NxbCanonicalJson -InputObject $copy
            $digest = Get-NativeSemanticSha256 -Bytes ([Text.UTF8Encoding]::new($false, $true).GetBytes($canonical))
            $Document.fingerprint_sha256 = $digest
            return $digest
        }

        function Write-NativeSemanticCanonicalJson {
            param(
                [Parameter(Mandatory = $true)][string]$Path,
                [Parameter(Mandatory = $true)]$Document
            )
            $canonical = ConvertTo-NxbCanonicalJson -InputObject $Document
            [IO.File]::WriteAllText($Path, $canonical, [Text.UTF8Encoding]::new($false, $true))
            return Get-NativeSemanticSha256 -Bytes ([Text.UTF8Encoding]::new($false, $true).GetBytes($canonical))
        }

        function New-NativeSemanticFixture {
            param(
                [ValidateSet('stable', 'post-drift', 'stored-tamper', 'candidate-mismatch', 'wpt-unpaired', 'production-boundary')]
                [string]$Mode = 'stable'
            )

            $root = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v11-native-semantic-' + [Guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($root)
            $planPath = Join-Path $root 'plan.json'
            $beforePath = Join-Path $root 'before.json'
            $afterPath = Join-Path $root 'after.json'

            $plan = Get-Content -LiteralPath $script:NativePlanFixture -Raw -Encoding UTF8 | ConvertFrom-Json
            $before = Get-Content -LiteralPath $script:NativeFingerprintFixture -Raw -Encoding UTF8 | ConvertFrom-Json
            $after = Get-Content -LiteralPath $script:NativeFingerprintFixture -Raw -Encoding UTF8 | ConvertFrom-Json

            $before.policy_sha256 = [string]$plan.policy.sha256
            $after.policy_sha256 = [string]$plan.policy.sha256
            $before.captured_utc = '2026-10-06T00:00:00Z'
            $after.captured_utc = '2026-10-06T01:00:00Z'

            switch ($Mode) {
                'post-drift' {
                    $after.windows.ubr = [int]$after.windows.ubr + 1
                }
                'candidate-mismatch' {
                    $before.head_sha = ('c' * 40)
                }
                'wpt-unpaired' {
                    $after.wpt.same_directory = $false
                }
                'production-boundary' {
                    $plan.production_boundary.private_key_used = $true
                }
            }

            $beforeIdentity = Set-NativeSemanticFingerprintIdentity -Document $before
            $afterIdentity = Set-NativeSemanticFingerprintIdentity -Document $after
            if ($Mode -eq 'stored-tamper') {
                $after.fingerprint_sha256 = ('0' * 64)
            }

            $planSha = Write-NativeSemanticCanonicalJson -Path $planPath -Document $plan
            [void](Write-NativeSemanticCanonicalJson -Path $beforePath -Document $before)
            [void](Write-NativeSemanticCanonicalJson -Path $afterPath -Document $after)

            return [pscustomobject]@{
                Root = $root
                PlanPath = [IO.Path]::GetFullPath($planPath)
                BeforePath = [IO.Path]::GetFullPath($beforePath)
                AfterPath = [IO.Path]::GetFullPath($afterPath)
                PlanSha256 = $planSha
                BeforeIdentity = $beforeIdentity
                AfterIdentity = $afterIdentity
                CandidateSha = [string]$plan.candidate.sha
                CandidateTree = [string]$plan.candidate.tree_sha
                CellId = [string]$plan.cell.id
                PolicySha256 = [string]$plan.policy.sha256
            }
        }

        function Invoke-NativeSemanticChild {
            param(
                [Parameter(Mandatory = $true)]$Fixture,
                [string]$ExpectedPlanSha256
            )

            if ([string]::IsNullOrWhiteSpace($ExpectedPlanSha256)) {
                $ExpectedPlanSha256 = [string]$Fixture.PlanSha256
            }

            $runnerPath = Join-Path $Fixture.Root ('runner-' + [Guid]::NewGuid().ToString('N') + '.ps1')
            $runner = @'
param(
    [Parameter(Mandatory = $true)][string]$NativePath,
    [Parameter(Mandatory = $true)][string]$PlanPath,
    [Parameter(Mandatory = $true)][string]$ExpectedPlanSha256,
    [Parameter(Mandatory = $true)][string]$BeforePath,
    [Parameter(Mandatory = $true)][string]$AfterPath,
    [Parameter(Mandatory = $true)][string]$ModulePath
)
$ErrorActionPreference = 'Stop'
try {
    $result = & $NativePath -PlanJsonPath $PlanPath -ExpectedPlanSha256 $ExpectedPlanSha256 -FingerprintBeforeJsonPath $BeforePath -FingerprintAfterJsonPath $AfterPath -EvidenceStoreModulePath $ModulePath -PassThru
    $result | ConvertTo-Json -Compress -Depth 30
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
'@
            [IO.File]::WriteAllText($runnerPath, $runner, [Text.UTF8Encoding]::new($false, $true))

            $previous = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $output = @(& $script:NativeSemanticPwsh -NoLogo -NoProfile -File $runnerPath -NativePath $script:NativeSemanticPath -PlanPath $Fixture.PlanPath -ExpectedPlanSha256 $ExpectedPlanSha256 -BeforePath $Fixture.BeforePath -AfterPath $Fixture.AfterPath -ModulePath $script:EvidenceStorePath 2>&1 | ForEach-Object { [string]$_ })
                $exitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previous
            }

            $text = $output -join [Environment]::NewLine
            $result = $null
            if ($exitCode -eq 0) {
                $result = $text | ConvertFrom-Json
            }
            return [pscustomobject]@{
                ExitCode = [int]$exitCode
                Text = $text
                Result = $result
            }
        }
    }

    It 'binds canonical plan authority to a stable pre/post fingerprint identity without claiming support' {
        $fixture = New-NativeSemanticFixture -Mode stable
        try {
            $run = Invoke-NativeSemanticChild -Fixture $fixture
            $run.ExitCode | Should -Be 0
            [string]$run.Result.status | Should -BeExactly 'NATIVE_HARNESS_PREFLIGHT_ONLY'
            [bool]$run.Result.admitted | Should -BeFalse
            [bool]$run.Result.physical_compatibility_claimed | Should -BeFalse
            [bool]$run.Result.native_wpt_dispatch_performed | Should -BeFalse
            [bool]$run.Result.workload_executed | Should -BeFalse
            [bool]$run.Result.repository_mutated | Should -BeFalse
            [string]$run.Result.plan_sha256 | Should -BeExactly $fixture.PlanSha256
            [string]$run.Result.fingerprint_before_sha256 | Should -BeExactly $fixture.BeforeIdentity
            [string]$run.Result.fingerprint_after_sha256 | Should -BeExactly $fixture.BeforeIdentity
            [bool]$run.Result.fingerprint_stable | Should -BeTrue
            [string]$run.Result.candidate_sha | Should -BeExactly $fixture.CandidateSha
            [string]$run.Result.candidate_tree_sha | Should -BeExactly $fixture.CandidateTree
            [string]$run.Result.cell_id | Should -BeExactly $fixture.CellId
            [string]$run.Result.policy_sha256 | Should -BeExactly $fixture.PolicySha256
            [string]$run.Result.endurance_tier | Should -BeExactly '1h'
            [int]$run.Result.endurance_cycle_count | Should -Be 1
        }
        finally {
            Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects external plan digest drift and independently valid pre/post identity drift' {
        $fixture = New-NativeSemanticFixture -Mode stable
        try {
            $run = Invoke-NativeSemanticChild -Fixture $fixture -ExpectedPlanSha256 ('0' * 64)
            $run.ExitCode | Should -Be 1
            $run.Text | Should -Match 'compatibility plan SHA-256 mismatch'
        }
        finally {
            Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
        }

        $drift = New-NativeSemanticFixture -Mode post-drift
        try {
            $drift.BeforeIdentity | Should -Not -BeExactly $drift.AfterIdentity
            $run = Invoke-NativeSemanticChild -Fixture $drift
            $run.ExitCode | Should -Be 1
            $run.Text | Should -Match 'pre/post fingerprint identity drift'
        }
        finally {
            Remove-Item -LiteralPath $drift.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects stored fingerprint tamper and plan/fingerprint candidate mismatch' {
        $tamper = New-NativeSemanticFixture -Mode stored-tamper
        try {
            $run = Invoke-NativeSemanticChild -Fixture $tamper
            $run.ExitCode | Should -Be 1
            $run.Text | Should -Match 'stored fingerprint SHA-256 mismatch'
        }
        finally {
            Remove-Item -LiteralPath $tamper.Root -Recurse -Force -ErrorAction SilentlyContinue
        }

        $mismatch = New-NativeSemanticFixture -Mode candidate-mismatch
        try {
            $run = Invoke-NativeSemanticChild -Fixture $mismatch
            $run.ExitCode | Should -Be 1
            $run.Text | Should -Match 'candidate SHA does not match the plan'
        }
        finally {
            Remove-Item -LiteralPath $mismatch.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects WPT pairing failure and any production-boundary mutation' {
        $wpt = New-NativeSemanticFixture -Mode wpt-unpaired
        try {
            $run = Invoke-NativeSemanticChild -Fixture $wpt
            $run.ExitCode | Should -Be 1
            $run.Text | Should -Match 'paired WPT tools from the same directory'
        }
        finally {
            Remove-Item -LiteralPath $wpt.Root -Recurse -Force -ErrorAction SilentlyContinue
        }

        $production = New-NativeSemanticFixture -Mode production-boundary
        try {
            $run = Invoke-NativeSemanticChild -Fixture $production
            $run.ExitCode | Should -Be 1
            $run.Text | Should -Match 'production boundary is not claim-free'
        }
        finally {
            Remove-Item -LiteralPath $production.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'remains an offline semantic preflight and cannot execute WPT or workload code' {
        $source = Get-Content -LiteralPath $script:NativeSemanticPath -Raw
        $source | Should -Not -Match '(?i)\bInvoke-(WebRequest|RestMethod)\b'
        $source | Should -Not -Match '(?im)\bgh\s+(api|workflow|run)\b'
        $source | Should -Not -Match '(?i)\bStart-Process\b'
        $source | Should -Not -Match '(?im)\bgit\s+(push|commit|merge|tag|reset|checkout)\b'
        $source | Should -Not -Match '(?i)&\s*[^\r\n]*(?:wpr|xperf)(?:\.exe)?\b'
        $source | Should -Not -Match '(?i)\b(upload-artifact|download-artifact)\b'
        $source | Should -Not -Match '(?i)\b(Set-Content|Add-Content|Out-File|WriteAllText|WriteAllBytes|CreateNew)\b'
        $source | Should -Match "status\s*=\s*'NATIVE_HARNESS_PREFLIGHT_ONLY'"
        $source | Should -Match 'physical_compatibility_claimed\s*=\s*\$false'
        $source | Should -Match 'workload_executed\s*=\s*\$false'
    }
}
