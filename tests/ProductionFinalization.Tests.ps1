$ErrorActionPreference = 'Stop'

Describe 'NXB IRL-006 Part 6-10 production finalization contract' {
    BeforeAll {
        function Get-NxbFinalTestContext {
            $root = [string]$env:NXB_FINAL_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_FINAL_REPOSITORY_ROOT is required.' }
            return [pscustomobject][ordered]@{
                root = [IO.Path]::GetFullPath($root)
                policy = Join-Path $root 'config\nxb-production-finalization-policy.json'
                extensionConfig = Join-Path $root 'config\nxb-production-known-error-extension.json'
                common = Join-Path $root 'scripts\NxbProductionFinalization.Common.ps1'
                part6 = Join-Path $root 'scripts\Invoke-NxbPart6FindingEngineCertification.ps1'
                part7 = Join-Path $root 'scripts\Invoke-NxbPart7BoundedActiveValidationCertification.ps1'
                part8 = Join-Path $root 'scripts\Invoke-NxbPart8EvidenceHardeningCertification.ps1'
                part9 = Join-Path $root 'scripts\Invoke-NxbPart9SupplyChainCertification.ps1'
                part10 = Join-Path $root 'scripts\Invoke-NxbPart10ProductionFreezeCertification.ps1'
                final = Join-Path $root 'scripts\Invoke-NxbProductionFinalCertification.ps1'
                finalV2 = Join-Path $root 'scripts\Invoke-NxbProductionFinalCertificationV2.ps1'
                extensionScanner = Join-Path $root 'scripts\Invoke-NxbProductionKnownErrorScan.ps1'
                cli = Join-Path $root 'scripts\nxb.ps1'
                prefreeze = Join-Path $root 'tools\validate_production_prefreeze.py'
                validator = Join-Path $root 'tools\validate_production_finalization.py'
                scanner = Join-Path $root 'scripts\Invoke-NxbKnownErrorScan.ps1'
                signatures = Join-Path $root 'config\nxb-known-error-signatures.json'
            }
        }
    }

    It 'keeps every Part 6-10 authority component repo-owned' {
        $context = Get-NxbFinalTestContext
        foreach ($path in @($context.policy,$context.extensionConfig,$context.common,$context.part6,$context.part7,$context.part8,$context.part9,$context.part10,$context.final,$context.finalV2,$context.extensionScanner,$context.cli,$context.prefreeze,$context.validator,$context.scanner,$context.signatures)) {
            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        }
    }

    It 'locks the five roadmap contracts and requirement cardinalities' {
        $context = Get-NxbFinalTestContext
        $policy = Get-Content -LiteralPath $context.policy -Raw | ConvertFrom-Json
        [string]$policy.contract_id | Should -BeExactly 'nxb-irl006-part6-10-production-finalization-v1'
        @($policy.part6.requirements).Count | Should -Be 8
        @($policy.part7.requirements).Count | Should -Be 10
        @($policy.part8.requirements).Count | Should -Be 10
        @($policy.part9.requirements).Count | Should -Be 10
        @($policy.part10.requirements).Count | Should -Be 10
    }

    It 'binds the new roadmap stack to certified Part 5 and permanent scanner extension' {
        $context = Get-NxbFinalTestContext
        $policy = Get-Content -LiteralPath $context.policy -Raw | ConvertFrom-Json
        $extension = Get-Content -LiteralPath $context.extensionConfig -Raw | ConvertFrom-Json
        $signatures = Get-Content -LiteralPath $context.signatures -Raw | ConvertFrom-Json
        [string]$policy.certified_predecessor_head | Should -BeExactly '7dad7f15eccf074078573f8bbe2d89877218672d'
        [int]$policy.known_error_minimum_rules | Should -Be 22
        @($signatures.rules).Count | Should -BeGreaterOrEqual 23
        @($signatures.rules | Where-Object { [string]$_.id -ceq 'NXB-ERR-034' }).Count | Should -Be 1
        @($extension.rules).Count | Should -Be 9
        @($extension.guard_contracts).Count | Should -Be 1
        @($extension.authority_paths) | Should -Contain 'scripts/Invoke-NxbProductionFinalCertificationV2.ps1'
    }

    It 'makes Part 6 finding IDs deterministic and evidence-hash bound' {
        $context = Get-NxbFinalTestContext
        $source = Get-Content -LiteralPath $context.common -Raw
        foreach ($token in @('Get-NxbFinalFindingId','Invoke-NxbFinalFindingCorrelation','Evidence SHA-256 must be 64 lowercase hex characters.','finding-')) {
            $source | Should -Match ([regex]::Escape($token))
        }
    }

    It 'keeps Part 6 correlation root-cause driven target-session bound and severity non-promoting' {
        $context = Get-NxbFinalTestContext
        $source = Get-Content -LiteralPath $context.part6 -Raw
        foreach ($token in @('root_cause_key','duplicate_suppressed = 1','severity_promoted = $false',"orchestration_mode = 'bounded-authorized-session'",'target_session_binding = $true','destructive_validation_allowed = $false')) {
            $source | Should -Match ([regex]::Escape($token))
        }
    }

    It 'restricts Part 7 certification networking to loopback safe methods and budgets' {
        $context = Get-NxbFinalTestContext
        $policy = Get-Content -LiteralPath $context.policy -Raw | ConvertFrom-Json
        [string]$policy.certification.network_mode | Should -BeExactly 'loopback-only'
        @($policy.certification.allowed_hosts) | Should -Contain '127.0.0.1'
        @($policy.certification.allowed_methods) | Should -Not -Contain 'POST'
        [int]$policy.certification.maximum_requests | Should -BeLessOrEqual 8
    }

    It 'requires canonical permit scope host method and kill switch for non-certification validation' {
        $context = Get-NxbFinalTestContext
        $source = Get-Content -LiteralPath $context.common -Raw
        foreach ($token in @('$Plan.permit_sha256','$Plan.permit_scope_id','$Plan.permit_host','$Plan.permit_method','$Plan.scope_authorized','$Plan.kill_switch_armed','@(''nxb-part7-permit-v1'',$permitScopeId,$permitHost,$permitMethod)','Get-NxbFinalSha256Text -Text $permitMaterial')) {
            $source | Should -Match ([regex]::Escape($token))
        }
    }

    It 'performs a real loopback native probe and binds browser API credential references without production secrets' {
        $context = Get-NxbFinalTestContext
        $source = Get-Content -LiteralPath $context.part7 -Raw
        foreach ($token in @('Net.Sockets.TcpListener','127.0.0.1','GET /certification HTTP/1.1','production_secret_in_evidence = $false','permit_canonical_hash_binding = $true','browser_api_session_boundary = $true','credential_reference_only = $true',"adapter_modes = @('http-api','browser')",'secret_material_embedded = $false')) {
            $source | Should -Match ([regex]::Escape($token))
        }
    }

    It 'redacts explicit secret values before evidence emission' {
        $context = Get-NxbFinalTestContext
        $source = Get-Content -LiteralPath $context.common -Raw
        $source | Should -Match ([regex]::Escape('Protect-NxbFinalSecretText'))
        $source | Should -Match ([regex]::Escape("'[REDACTED]'"))
    }

    It 'makes Part 8 reject stale cross-session missing and tampered evidence' {
        $context = Get-NxbFinalTestContext
        $source = Get-Content -LiteralPath $context.part8 -Raw
        foreach ($token in @('stale_head','cross_session','missing_evidence','tampered_payload','evidence_hash_mismatch')) {
            $source | Should -Match ([regex]::Escape($token))
        }
    }

    It 'requires Part 8 dual-runtime contract passes before compatibility certification' {
        $context = Get-NxbFinalTestContext
        $source = Get-Content -LiteralPath $context.part8 -Raw
        $source | Should -Match ([regex]::Escape('$Ps7ContractPassed'))
        $source | Should -Match ([regex]::Escape('$Ps51ContractPassed'))
        $source | Should -Match ([regex]::Escape('requires PS7 and PS5.1 contract passes'))
    }

    It 'enforces bounded Part 8 runtime and artifact bytes' {
        $context = Get-NxbFinalTestContext
        $source = Get-Content -LiteralPath $context.part8 -Raw
        $source | Should -Match ([regex]::Escape('maximum_artifact_bytes'))
        $source | Should -Match ([regex]::Escape('maximum_seconds'))
        $source | Should -Match ([regex]::Escape('[Diagnostics.Stopwatch]::StartNew()'))
    }

    It 'makes Part 9 update authority staged-only hash-verified and rollback bounded' {
        $context = Get-NxbFinalTestContext
        $source = Get-Content -LiteralPath $context.part9 -Raw
        foreach ($token in @('staged_only = $true','auto_apply = $false','rollback_requires_explicit_operator = $true','staged_update_executed = $true','staged_file_count','autonomous_certification_workflow = $true')) {
            $source | Should -Match ([regex]::Escape($token))
        }
    }

    It 'provides a unified non-destructive CLI with explicit stage-update' {
        $context = Get-NxbFinalTestContext
        $source = Get-Content -LiteralPath $context.cli -Raw
        foreach ($token in @("'status'","'hash'","'inspect-manifest'","'stage-update'","'certify-final'",'Staging root must not already exist.','Invoke-NxbProductionFinalCertificationV2.ps1')) {
            $source | Should -Match ([regex]::Escape($token))
        }
        $source | Should -Not -Match '(?im)\b(Format-Volume|Clear-Disk|Invoke-Expression)\b'
    }

    It 'validates complete package paths hashes signer fingerprint and rejects auto-apply' {
        $context = Get-NxbFinalTestContext
        $source = Get-Content -LiteralPath $context.part9 -Raw
        foreach ($token in @('Invoke-NxbProductionFinalCertificationV2.ps1','Invoke-NxbProductionKnownErrorScan.ps1','validate_production_finalization.py','ProductionFinalization.Tests.ps1','packageRelativePaths','path = $relative')) {
            $source | Should -Match ([regex]::Escape($token))
        }
        $validatorSource = Get-Content -LiteralPath $context.validator -Raw
        foreach ($token in @('safe_package_path','repository_root.joinpath','part9_repository_rehash')) {
            $validatorSource | Should -Match ([regex]::Escape($token))
        }
    }

    It 'binds Part 10 report freeze to Part 5 and exactly four Part 6-9 receipts' {
        $context = Get-NxbFinalTestContext
        $source = Get-Content -LiteralPath $context.part10 -Raw
        $source | Should -Match ([regex]::Escape('$Part5SignedReceiptPath'))
        $source | Should -Match ([regex]::Escape('$Part5ReviewZipPath'))
        $source | Should -Match ([regex]::Escape('$partReceipts.Count -ne 4'))
    }

    It 'keeps the v1 candidate report and freeze explicitly unmerged' {
        $context = Get-NxbFinalTestContext
        $source = Get-Content -LiteralPath $context.part10 -Raw
        $source | Should -Match ([regex]::Escape('production_merge_performed = $false'))
        $source | Should -Match ([regex]::Escape('v1_freeze_candidate = $true'))
    }

    It 'uses an independent Python validator with twelve fail-closed mutations' {
        $context = Get-NxbFinalTestContext
        $source = Get-Content -LiteralPath $context.validator -Raw
        foreach ($token in @('part6_stale_head','part7_secret_leak','part8_fault_accepted','package_auto_apply','part10_merge_claim','report_merge_claim')) {
            $source | Should -Match ([regex]::Escape($token))
        }
        $source | Should -Match ([regex]::Escape('len(negatives) == 12'))
    }

    It 'requires V2 to wrap the final child and permanent production scanner' {
        $context = Get-NxbFinalTestContext
        $v2Source = Get-Content -LiteralPath $context.finalV2 -Raw
        $v2Source | Should -Match ([regex]::Escape('Invoke-NxbProductionFinalCertification.ps1'))
        $v2Source | Should -Match ([regex]::Escape('Invoke-NxbProductionKnownErrorScan.ps1'))
        $childSource = Get-Content -LiteralPath $context.final -Raw
        $childSource | Should -Match ([regex]::Escape('Invoke-NxbPart5SignedClosureCertificationV2.ps1'))
        $childSource | Should -Match ([regex]::Escape('Invoke-NxbPart6FindingEngineCertification.ps1'))
        $childSource | Should -Match ([regex]::Escape('Invoke-NxbPart10ProductionFreezeCertification.ps1'))
        $childSource | Should -Match ([regex]::Escape('validate_production_prefreeze.py'))
    }

    It 'keeps active production-finalization PowerShell authority ASCII clean' {
        $context = Get-NxbFinalTestContext
        foreach ($path in @($context.common,$context.part6,$context.part7,$context.part8,$context.part9,$context.part10,$context.final,$context.finalV2,$context.extensionScanner,$context.cli)) {
            $bad = @([IO.File]::ReadAllBytes($path) | Where-Object { [int]$_ -gt 0x7F })
            $bad.Count | Should -Be 0
        }
    }
}
