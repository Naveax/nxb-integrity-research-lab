$ErrorActionPreference = 'Stop'

Describe 'NXB IRL-006 semantic evidence authority contract' {
    BeforeAll {
        function Get-NxbSemanticTestRoot {
            $root = [string]$env:NXB_SEMANTIC_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_SEMANTIC_REPOSITORY_ROOT is required.' }
            return [IO.Path]::GetFullPath($root)
        }

        function Get-NxbSemanticFixtureObject {
            $root = Get-NxbSemanticTestRoot
            $fixturePath = Join-Path $root 'tests\fixtures\semantic-evidence\valid-semantic-receipt.json'
            return (Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json)
        }

        function Get-NxbSemanticTestSha256Text {
            param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
                return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
            }
            finally { $sha.Dispose() }
        }

        function Get-NxbSemanticTestFingerprint {
            param([Parameter(Mandatory)][object]$Receipt)
            $scopeHash = Get-NxbSemanticTestSha256Text -Text ([string]$Receipt.capture.scope)
            $limitationArray = @($Receipt.validation.limitations | ForEach-Object { [string]$_ })
            $limitationHash = Get-NxbSemanticTestSha256Text -Text ($limitationArray -join "`n")
            $negativeText = ([bool]$Receipt.validation.negative_controls_passed).ToString().ToLowerInvariant()
            $cleanupText = ([bool]$Receipt.validation.cleanup_verified).ToString().ToLowerInvariant()
            $independentText = ([bool]$Receipt.validation.independent_validation_passed).ToString().ToLowerInvariant()
            $material = @(
                'schema=1',
                ('receipt_id={0}' -f [string]$Receipt.receipt_id),
                ('claim_name={0}' -f [string]$Receipt.claim_name),
                ('status={0}' -f [string]$Receipt.status),
                ('repository={0}' -f [string]$Receipt.authority.repository),
                ('exact_head={0}' -f [string]$Receipt.authority.exact_head),
                ('policy_sha256={0}' -f [string]$Receipt.authority.policy_sha256),
                ('machine_id_sha256={0}' -f [string]$Receipt.machine.machine_id_sha256),
                ('scope_sha256={0}' -f $scopeHash),
                ('source_kind={0}' -f [string]$Receipt.capture.source_kind),
                ('bounded_session_seconds={0}' -f [int64]$Receipt.capture.bounded_session_seconds),
                ('artifact_count={0}' -f [int64]$Receipt.evidence.artifact_count),
                ('artifact_index_sha256={0}' -f [string]$Receipt.evidence.artifact_index_sha256),
                ('negative_controls_passed={0}' -f $negativeText),
                ('cleanup_verified={0}' -f $cleanupText),
                ('independent_validation_passed={0}' -f $independentText),
                ('validator_name={0}' -f [string]$Receipt.validation.validator_name),
                ('validator_version={0}' -f [string]$Receipt.validation.validator_version),
                ('validator_implementation_sha256={0}' -f [string]$Receipt.validation.validator_implementation_sha256),
                ('limitations_sha256={0}' -f $limitationHash)
            ) -join "`n"
            return (Get-NxbSemanticTestSha256Text -Text $material)
        }

        function Write-NxbSemanticTestReceiptDocument {
            param(
                [Parameter(Mandatory)][object]$Receipt,
                [Parameter()][switch]$KeepFingerprint
            )
            if (-not $KeepFingerprint) {
                $Receipt.receipt_fingerprint_sha256 = Get-NxbSemanticTestFingerprint -Receipt $Receipt
            }
            $path = Join-Path $TestDrive ('semantic-{0}.json' -f [Guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText(
                $path,
                (($Receipt | ConvertTo-Json -Depth 20) + [Environment]::NewLine),
                [Text.UTF8Encoding]::new($false)
            )
            return $path
        }

        $root = Get-NxbSemanticTestRoot
        $validatorPath = Join-Path $root 'scripts\Test-NxbSemanticEvidenceReceipt.ps1'
        $pythonValidatorPath = Join-Path $root 'tools\validate_semantic_evidence_receipt.py'
        $fixturePath = Join-Path $root 'tests\fixtures\semantic-evidence\valid-semantic-receipt.json'
        $expectedHead = '1111111111111111111111111111111111111111'
        $expectedPolicy = '2222222222222222222222222222222222222222222222222222222222222222'
        $expectedMachine = '3333333333333333333333333333333333333333333333333333333333333333'
    }

    It 'keeps every Part 1 semantic authority component repo-owned' {
        $root = Get-NxbSemanticTestRoot
        foreach ($relative in @(
            'schemas\nxb-semantic-evidence-receipt.schema.json',
            'scripts\Test-NxbSemanticEvidenceReceipt.ps1',
            'tools\validate_semantic_evidence_receipt.py',
            'tests\fixtures\semantic-evidence\valid-semantic-receipt.json',
            'tests\SemanticEvidenceAuthority.Tests.ps1',
            'scripts\Invoke-NxbSemanticEvidenceAuthorityCertification.ps1',
            'docs\NXB-IRL-006-SEMANTIC-EVIDENCE-AUTHORITY.md'
        )) {
            Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf | Should -BeTrue
        }
    }

    It 'locks the schema to exactly eight semantic claims and three receipt states' {
        $root = Get-NxbSemanticTestRoot
        $schema = Get-Content -LiteralPath (Join-Path $root 'schemas\nxb-semantic-evidence-receipt.schema.json') -Raw | ConvertFrom-Json
        [int]$schema.properties.schema_version.const | Should -Be 1
        @($schema.properties.claim_name.enum).Count | Should -Be 8
        @($schema.properties.status.enum).Count | Should -Be 3
        @($schema.properties.status.enum) | Should -Contain 'validated'
        @($schema.properties.status.enum) | Should -Contain 'failed'
        @($schema.properties.status.enum) | Should -Contain 'unavailable'
    }

    It 'accepts the canonical validated fixture in PowerShell and marks it promotable' {
        $result = & $validatorPath -ReceiptPath $fixturePath -ExpectedHead $expectedHead -ExpectedPolicySha256 $expectedPolicy -ExpectedMachineIdSha256 $expectedMachine -PassThru
        [string]$result.status | Should -BeExactly 'passed'
        [bool]$result.promotable | Should -BeTrue
        [string]$result.claim_name | Should -BeExactly 'pnp_lifecycle_semantics'
        [string]$result.receipt_fingerprint_sha256 | Should -BeExactly 'c1731bc3d7f45107b45a7bb11c06a62de4036199c0795ed749279d25a53baecb'
    }

    It 'accepts the same fixture in the independent Python validator with matching identity' {
        $pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
        if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
        $pythonPath = [string]$pythonCommand.Source
        $pythonOutput = & $pythonPath $pythonValidatorPath $fixturePath --expected-head $expectedHead --expected-policy-sha256 $expectedPolicy --expected-machine-id-sha256 $expectedMachine
        $LASTEXITCODE | Should -Be 0
        $pythonResult = $pythonOutput | ConvertFrom-Json
        [string]$pythonResult.status | Should -BeExactly 'passed'
        [bool]$pythonResult.promotable | Should -BeTrue
        [string]$pythonResult.receipt_fingerprint_sha256 | Should -BeExactly 'c1731bc3d7f45107b45a7bb11c06a62de4036199c0795ed749279d25a53baecb'
    }

    It 'rejects unknown top-level properties before promotion' {
        $receipt = Get-NxbSemanticFixtureObject
        $receipt | Add-Member -NotePropertyName unexpected -NotePropertyValue 'blocked'
        $path = Write-NxbSemanticTestReceiptDocument -Receipt $receipt
        { & $validatorPath -ReceiptPath $path -ExpectedHead $expectedHead -ExpectedPolicySha256 $expectedPolicy } | Should -Throw '*top-level property set is not exact*'
    }

    It 'rejects a cross-head or stale receipt even when its fingerprint is recomputed' {
        $receipt = Get-NxbSemanticFixtureObject
        $receipt.authority.exact_head = '6666666666666666666666666666666666666666'
        $path = Write-NxbSemanticTestReceiptDocument -Receipt $receipt
        { & $validatorPath -ReceiptPath $path -ExpectedHead $expectedHead -ExpectedPolicySha256 $expectedPolicy } | Should -Throw '*exact-head mismatch*'
    }

    It 'rejects a receipt bound to a different policy fingerprint' {
        $receipt = Get-NxbSemanticFixtureObject
        $receipt.authority.policy_sha256 = '7777777777777777777777777777777777777777777777777777777777777777'
        $path = Write-NxbSemanticTestReceiptDocument -Receipt $receipt
        { & $validatorPath -ReceiptPath $path -ExpectedHead $expectedHead -ExpectedPolicySha256 $expectedPolicy } | Should -Throw '*policy mismatch*'
    }

    It 'rejects cross-machine evidence when a machine binding is required' {
        $receipt = Get-NxbSemanticFixtureObject
        $path = Write-NxbSemanticTestReceiptDocument -Receipt $receipt
        $otherMachine = '8888888888888888888888888888888888888888888888888888888888888888'
        { & $validatorPath -ReceiptPath $path -ExpectedHead $expectedHead -ExpectedPolicySha256 $expectedPolicy -ExpectedMachineIdSha256 $otherMachine } | Should -Throw '*machine mismatch*'
    }

    It 'rejects an unknown semantic claim name' {
        $receipt = Get-NxbSemanticFixtureObject
        $receipt.claim_name = 'invented_semantics'
        $path = Write-NxbSemanticTestReceiptDocument -Receipt $receipt
        { & $validatorPath -ReceiptPath $path -ExpectedHead $expectedHead -ExpectedPolicySha256 $expectedPolicy } | Should -Throw '*Unknown semantic claim*'
    }

    It 'rejects validated promotion without at least one evidence artifact' {
        $receipt = Get-NxbSemanticFixtureObject
        $receipt.evidence.artifact_count = 0
        $path = Write-NxbSemanticTestReceiptDocument -Receipt $receipt
        { & $validatorPath -ReceiptPath $path -ExpectedHead $expectedHead -ExpectedPolicySha256 $expectedPolicy } | Should -Throw '*requires at least one evidence artifact*'
    }

    It 'rejects validated promotion when negative controls did not pass' {
        $receipt = Get-NxbSemanticFixtureObject
        $receipt.validation.negative_controls_passed = $false
        $path = Write-NxbSemanticTestReceiptDocument -Receipt $receipt
        { & $validatorPath -ReceiptPath $path -ExpectedHead $expectedHead -ExpectedPolicySha256 $expectedPolicy } | Should -Throw '*requires negative controls to pass*'
    }

    It 'rejects validated promotion without cleanup verification' {
        $receipt = Get-NxbSemanticFixtureObject
        $receipt.validation.cleanup_verified = $false
        $path = Write-NxbSemanticTestReceiptDocument -Receipt $receipt
        { & $validatorPath -ReceiptPath $path -ExpectedHead $expectedHead -ExpectedPolicySha256 $expectedPolicy } | Should -Throw '*requires cleanup verification*'
    }

    It 'rejects validated promotion without independent validation' {
        $receipt = Get-NxbSemanticFixtureObject
        $receipt.validation.independent_validation_passed = $false
        $path = Write-NxbSemanticTestReceiptDocument -Receipt $receipt
        { & $validatorPath -ReceiptPath $path -ExpectedHead $expectedHead -ExpectedPolicySha256 $expectedPolicy } | Should -Throw '*requires independent validation*'
    }

    It 'rejects a capture whose end precedes its start' {
        $receipt = Get-NxbSemanticFixtureObject
        $receipt.capture.ended_utc = '2026-08-11T08:59:59Z'
        $path = Write-NxbSemanticTestReceiptDocument -Receipt $receipt
        { & $validatorPath -ReceiptPath $path -ExpectedHead $expectedHead -ExpectedPolicySha256 $expectedPolicy } | Should -Throw '*capture end must be after capture start*'
    }

    It 'rejects an observed capture duration that exceeds its declared bound' {
        $receipt = Get-NxbSemanticFixtureObject
        $receipt.capture.bounded_session_seconds = 5
        $path = Write-NxbSemanticTestReceiptDocument -Receipt $receipt
        { & $validatorPath -ReceiptPath $path -ExpectedHead $expectedHead -ExpectedPolicySha256 $expectedPolicy } | Should -Throw '*observed duration exceeds bounded_session_seconds*'
    }

    It 'rejects semantic tampering when the canonical fingerprint is stale' {
        $receipt = Get-NxbSemanticFixtureObject
        $receipt.capture.scope = 'tampered-scope'
        $path = Write-NxbSemanticTestReceiptDocument -Receipt $receipt -KeepFingerprint
        { & $validatorPath -ReceiptPath $path -ExpectedHead $expectedHead -ExpectedPolicySha256 $expectedPolicy } | Should -Throw '*fingerprint mismatch*'
    }

    It 'accepts a structurally valid failed receipt but never marks it promotable' {
        $receipt = Get-NxbSemanticFixtureObject
        $receipt.status = 'failed'
        $receipt.evidence.artifact_count = 0
        $receipt.validation.negative_controls_passed = $false
        $receipt.validation.cleanup_verified = $false
        $receipt.validation.independent_validation_passed = $false
        $path = Write-NxbSemanticTestReceiptDocument -Receipt $receipt
        $result = & $validatorPath -ReceiptPath $path -ExpectedHead $expectedHead -ExpectedPolicySha256 $expectedPolicy -PassThru
        [string]$result.status | Should -BeExactly 'passed'
        [bool]$result.promotable | Should -BeFalse
    }

    It 'accepts a structurally valid unavailable receipt but never marks it promotable' {
        $receipt = Get-NxbSemanticFixtureObject
        $receipt.status = 'unavailable'
        $receipt.evidence.artifact_count = 0
        $receipt.validation.negative_controls_passed = $false
        $receipt.validation.cleanup_verified = $false
        $receipt.validation.independent_validation_passed = $false
        $path = Write-NxbSemanticTestReceiptDocument -Receipt $receipt
        $result = & $validatorPath -ReceiptPath $path -ExpectedHead $expectedHead -ExpectedPolicySha256 $expectedPolicy -PassThru
        [string]$result.status | Should -BeExactly 'passed'
        [bool]$result.promotable | Should -BeFalse
    }
}
