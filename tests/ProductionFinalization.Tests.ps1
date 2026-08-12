$ErrorActionPreference = 'Stop'

Describe 'NXB IRL-006 Part 6-10 production finalization contract' {
    BeforeAll {
        function Get-NxbFinalTestContext {
            $root = [string]$env:NXB_FINAL_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_FINAL_REPOSITORY_ROOT is required.' }
            return [pscustomobject][ordered]@{
                root = [IO.Path]::GetFullPath($root)
                policy = Join-Path $root 'config\nxb-production-finalization-policy.json'
                common = Join-Path $root 'scripts\NxbProductionFinalization.Common.ps1'
                part6 = Join-Path $root 'scripts\Invoke-NxbPart6FindingEngineCertification.ps1'
                part7 = Join-Path $root 'scripts\Invoke-NxbPart7BoundedActiveValidationCertification.ps1'
                part8 = Join-Path $root 'scripts\Invoke-NxbPart8EvidenceHardeningCertification.ps1'
                part9 = Join-Path $root 'scripts\Invoke-NxbPart9SupplyChainCertification.ps1'
                part10 = Join-Path $root 'scripts\Invoke-NxbPart10ProductionFreezeCertification.ps1'
                final = Join-Path $root 'scripts\Invoke-NxbProductionFinalCertification.ps1'
                cli = Join-Path $root 'scripts\nxb.ps1'
                validator = Join-Path $root 'tools\validate_production_finalization.py'
                scanner = Join-Path $root 'scripts\Invoke-NxbKnownErrorScan.ps1'
                signatures = Join-Path $root 'config\nxb-known-error-signatures.json'
            }
        }
    }

    It 'keeps every Part 6-10 authority component repo-owned' {
        $context = Get-NxbFinalTestContext
        foreach ($path in @($context.policy,$context.common,$context.part6,$context.part7,$context.part8,$context.part9,$context.part10,$context.final,$context.cli,$context.validator,$context.scanner,$context.signatures)) {
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

    It 'binds the new roadmap stack to the certified Part 5 predecessor' {
        $context = Get-NxbFinalTestContext
        $policy = Get-Content -LiteralPath $context.policy -Raw | ConvertFrom-Json
        [string]$policy.certified_predecessor_head | Should -BeExactly '7dad7f15eccf074078573f8bbe2d89877218672d'
        [int]$policy.known_error_minimum_rules | Should -Be 22
    }

    It 'makes Part 6 finding IDs deterministic and evidence-hash bound' {
        $context = Get-NxbFinalTestContext
        $source = Get-Content -LiteralPath $context.common -Raw
        foreach ($token in @('New-NxbFinalFindingId','Invoke-NxbFinalFindingCorrelation','Evidence SHA-256 must be 64 lowercase hex characters.','finding-')) {
            $source | Should -Match ([regex]::Escape($token))
        }
    }

    It 'keeps Part 6 correlation root-cause driven and severity non-promoting' {
        $context = Get-NxbFinalTestContext
        $source = Get-Content -LiteralPath $context.part6 -Raw
        $source | Should -Match ([regex]::Escape('root_cause_key'))
        $source | Should -Match ([regex]::Escape('duplicate_suppressed = 1'))
        $source | Should -Match ([regex]::Escape('severity_promoted = $false'))
    }

    It 'restricts Part 7 certification networking to loopback safe methods and budgets' {
        $context = Get-NxbFinalTestContext
        $policy = Get-Content -LiteralPath $context.policy -Raw | ConvertFrom-Json
        [string]$policy.certification.network_mode | Should -BeExactly 'loopback-only'
        @($policy.certification.allowed_hosts) | Should -Contain '127.0.0.1'
        @($policy.certification.allowed_methods) | Should -Not -Contain 'POST'
        [int]$policy.certification.maximum_requests | Should -BeLessOrEqual 8
    }

    It 'requires permit authorization and kill switch for non-certification validation' {
        $context = Get-NxbFinalTestContext
        $source = Get-Content -LiteralPath $context.common -Raw
        $source | Should -Match ([regex]::Escape('$Plan.permit_sha256'))
        $source | Should -Match ([regex]::Escape('$Plan.scope_authorized'))
        $source | Should -Match ([regex]::Escape('$Plan.kill_switch_armed'))
    }

    It 'performs a real loopback native probe without production secrets' {
        $context = Get-NxbFinalTestContext
        $source = Get-Content -LiteralPath $context.part7 -Raw
        foreach ($token in @('Net.Sockets.TcpListener','127.0.0.1','GET /certification HTTP/1.1','production_secret_in_evidence = $false')) {
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

    It 'makes Part 9 update authority staged-only with rollback metadata' {
        $context = Get-NxbFinalTestContext
        $source = Get-Content -LiteralPath $context.part9 -Raw
        $source | Should -Match ([regex]::Escape('staged_only = $true'))
        $source | Should -Match ([regex]::Escape('auto_apply = $false'))
        $source | Should -Match ([regex]::Escape('rollback_requires_explicit_operator = $true'))
    }

    It 'provides a unified non-destructive CLI' {
        $context = Get-NxbFinalTestContext
        $source = Get-Content -LiteralPath $context.cli -Raw
        foreach ($token in @("'status'","'hash'","'inspect-manifest'","'certify-final'")) {
            $source | Should -Match ([regex]::Escape($token))
        }
        $source | Should -Not -Match '(?im)\b(Format-Volume|Clear-Disk|Invoke-Expression)\b'
    }

    It 'validates package hashes signer fingerprint and rejects auto-apply' {
        $context = Get-NxbFinalTestContext
        $source = Get-Content -LiteralPath $context.common -Raw
        foreach ($token in @('Test-NxbFinalPackageManifest','signer_fingerprint_sha256','staged_only','auto_apply')) {
            $source | Should -Match ([regex]::Escape($token))
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

    It 'requires the final authority to re-certify Part 5 before Parts 6-10' {
        $context = Get-NxbFinalTestContext
        $source = Get-Content -LiteralPath $context.final -Raw
        $source | Should -Match ([regex]::Escape('Invoke-NxbPart5SignedClosureCertificationV2.ps1'))
        $source | Should -Match ([regex]::Escape('Invoke-NxbPart6FindingEngineCertification.ps1'))
        $source | Should -Match ([regex]::Escape('Invoke-NxbPart10ProductionFreezeCertification.ps1'))
    }

    It 'keeps active production-finalization PowerShell authority ASCII clean' {
        $context = Get-NxbFinalTestContext
        foreach ($path in @($context.common,$context.part6,$context.part7,$context.part8,$context.part9,$context.part10,$context.final,$context.cli)) {
            $bad = @([IO.File]::ReadAllBytes($path) | Where-Object { [int]$_ -gt 0x7F })
            $bad.Count | Should -Be 0
        }
    }
}
