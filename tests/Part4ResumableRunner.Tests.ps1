$ErrorActionPreference = 'Stop'

Describe 'NXB IRL-006 Part 4 resumable runner scheduler sharding contract' {
    BeforeAll {
        function Get-NxbPart4TestContext {
            $root = [string]$env:NXB_PART4_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_PART4_REPOSITORY_ROOT is required.' }
            $fullRoot = [IO.Path]::GetFullPath($root)
            return [pscustomobject][ordered]@{
                root=$fullRoot
                policy=Join-Path $fullRoot 'config\nxb-part4-runner-policy.json'
                schema=Join-Path $fullRoot 'schemas\nxb-part4-run-manifest.schema.json'
                common=Join-Path $fullRoot 'scripts\NxbPart4Runner.Common.ps1'
                worker=Join-Path $fullRoot 'scripts\Invoke-NxbPart4RunnerWorker.ps1'
                experiment=Join-Path $fullRoot 'scripts\Invoke-NxbPart4ResumableRunnerExperiment.ps1'
                certification=Join-Path $fullRoot 'scripts\Invoke-NxbPart4ResumableRunnerCertification.ps1'
                combined=Join-Path $fullRoot 'scripts\Invoke-NxbPart4CombinedCertification.ps1'
                validator=Join-Path $fullRoot 'tools\validate_part4_runner.py'
                inherited=Join-Path $fullRoot 'scripts\Invoke-NxbControllerTargetTransportCertification.ps1'
                ledger=Join-Path $fullRoot 'docs\NXB-KNOWN-ERROR-LEDGER.md'
            }
        }
    }

    It 'keeps every Part 4 authority component repo-owned' {
        $context = Get-NxbPart4TestContext
        foreach ($path in @($context.policy,$context.schema,$context.common,$context.worker,$context.experiment,$context.certification,$context.combined,$context.validator,$context.inherited,$context.ledger)) {
            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        }
    }

    It 'locks bounded synthetic policy budgets and four domains' {
        $context = Get-NxbPart4TestContext
        $policy = Get-Content -LiteralPath $context.policy -Raw | ConvertFrom-Json
        [int]$policy.schema_version | Should -Be 1
        [string]$policy.scope | Should -BeExactly 'bounded-local-synthetic-runner-certification-only'
        [int]$policy.task_count | Should -Be 24
        @($policy.domains).Count | Should -Be 4
        [int]$policy.shard_count | Should -Be 4
        [int]$policy.budget.maximum_committed_tasks | Should -Be 24
        [int]$policy.budget.maximum_ticks | Should -BeLessOrEqual 256
    }

    It 'defines an exact-head config scope and run-id bound manifest schema' {
        $context = Get-NxbPart4TestContext
        $schema = Get-Content -LiteralPath $context.schema -Raw | ConvertFrom-Json
        [bool]$schema.additionalProperties | Should -BeFalse
        foreach ($name in @('exact_head','config_sha256','scope_sha256','run_id','shard_count','tasks')) {
            @($schema.required) | Should -Contain $name
        }
    }

    It 'derives deterministic run id from repository head config scope and contract' {
        $context = Get-NxbPart4TestContext
        $source = Get-Content -LiteralPath $context.common -Raw
        $source | Should -Match ([regex]::Escape('function Get-NxbPart4RunId'))
        $source | Should -Match ([regex]::Escape('$Repository,$ExactHead,$ConfigSha256,$ScopeSha256,$ContractId'))
        $source | Should -Match ([regex]::Escape('return ''run-'' + (Get-NxbPart4Sha256Text -Text $material).Substring(0,32)'))
    }

    It 'uses sha256 prefix modulo shard count for deterministic sharding' {
        $context = Get-NxbPart4TestContext
        $source = Get-Content -LiteralPath $context.common -Raw
        $source | Should -Match ([regex]::Escape('$hash.Substring(0,8)'))
        $source | Should -Match ([regex]::Escape('$prefix % [uint32]$ShardCount'))
        $validator = Get-Content -LiteralPath $context.validator -Raw
        $validator | Should -Match ([regex]::Escape('int(sha256_text(task_id)[:8], 16) % shard_count'))
    }

    It 'atomically persists checkpoint state with an independent fingerprint' {
        $context = Get-NxbPart4TestContext
        $source = Get-Content -LiteralPath $context.common -Raw
        foreach ($token in @("'.tmp-'",'Move-Item -LiteralPath $tempPath -Destination $fullPath -Force','Get-NxbPart4CheckpointFingerprint','checkpoint_fingerprint_sha256')) {
            $source | Should -Match ([regex]::Escape($token))
        }
    }

    It 'reconciles durable receipts before scheduling resumed work' {
        $context = Get-NxbPart4TestContext
        $source = Get-Content -LiteralPath $context.worker -Raw
        $syncPosition = $source.IndexOf('Sync-NxbPart4ReceiptCheckpoint',[StringComparison]::Ordinal)
        $loopPosition = $source.IndexOf('while (@($checkpoint.completed_task_ids).Count',[StringComparison]::Ordinal)
        $syncPosition | Should -BeGreaterThan -1
        $loopPosition | Should -BeGreaterThan $syncPosition
        $source | Should -Match ([regex]::Escape('Receipt binding mismatch'))
        $source | Should -Match ([regex]::Escape('$receipt.committed_tick'))
        $source | Should -Match ([regex]::Escape('$Checkpoint.domain_last_served_tick'))
        $source | Should -Match ([regex]::Escape('Duplicate task execution attempted despite existing receipt'))
    }

    It 'injects a real process crash after receipt and before checkpoint advance' {
        $context = Get-NxbPart4TestContext
        $source = Get-Content -LiteralPath $context.worker -Raw
        $receiptPosition = $source.IndexOf('Write-NxbPart4AtomicJson -Path $receiptPath',[StringComparison]::Ordinal)
        $crashPosition = $source.IndexOf('Stop-Process -Id $PID -Force',[StringComparison]::Ordinal)
        $checkpointPosition = $source.IndexOf('$checkpoint.completed_task_ids = @(',[StringComparison]::Ordinal)
        $receiptPosition | Should -BeGreaterThan -1
        $crashPosition | Should -BeGreaterThan $receiptPosition
        $checkpointPosition | Should -BeGreaterThan $crashPosition
    }

    It 'implements graceful emergency and final completion stop modes' {
        $context = Get-NxbPart4TestContext
        $source = Get-Content -LiteralPath $context.worker -Raw
        foreach ($token in @("stop_mode = 'graceful'","stop_mode = 'emergency'","stop_mode = 'completed'",'exit 20','exit 30')) {
            $source | Should -Match ([regex]::Escape($token))
        }
    }

    It 'enforces task tick attempt and ready-queue budgets fail-closed' {
        $context = Get-NxbPart4TestContext
        $source = Get-Content -LiteralPath $context.worker -Raw
        foreach ($token in @('maximum_ticks','maximum_committed_tasks','maximum_attempts_per_task','maximum_ready_queue_depth')) {
            $source | Should -Match ([regex]::Escape($token))
        }
    }

    It 'implements adaptive score from priority coverage fairness saturation and retry state' {
        $context = Get-NxbPart4TestContext
        $source = Get-Content -LiteralPath $context.common -Raw
        foreach ($token in @('base_priority_weight','coverage_deficit_weight','fairness_credit_weight','saturation_penalty_weight','retry_penalty_weight')) {
            $source | Should -Match ([regex]::Escape($token))
        }
        $source | Should -Match ([regex]::Escape('Sort-Object Name'))
    }

    It 'uses bounded exponential retry backoff' {
        $context = Get-NxbPart4TestContext
        $source = Get-Content -LiteralPath $context.common -Raw
        $source | Should -Match ([regex]::Escape('function Get-NxbPart4BackoffTick'))
        $source | Should -Match ([regex]::Escape('[Math]::Pow(2,[Math]::Max(0,$Attempt - 1))'))
        $worker = Get-Content -LiteralPath $context.worker -Raw
        $worker | Should -Match ([regex]::Escape('not_before_tick'))
    }

    It 'runs crash graceful emergency and completion phases in one bounded experiment' {
        $context = Get-NxbPart4TestContext
        $source = Get-Content -LiteralPath $context.experiment -Raw
        foreach ($token in @('crash_after_receipt','-Mode graceful','-Mode emergency','-Mode continue','stale_checkpoint_observed')) {
            $source | Should -Match ([regex]::Escape($token))
        }
    }

    It 'gives the independent validator ten requirements and ten fail-closed mutations' {
        $context = Get-NxbPart4TestContext
        $source = Get-Content -LiteralPath $context.validator -Raw
        foreach ($token in @('exact_run_binding','checkpoint_resume','duplicate_prevention','budget_enforcement','stop_modes','adaptive_scheduler','coverage_saturation','fairness_backoff','bounded_queue','deterministic_sharding')) {
            $source | Should -Match ([regex]::Escape('"' + $token + '"'))
        }
        foreach ($token in @('stale_exact_head','config_hash_mismatch','scope_hash_mismatch','run_id_mismatch','duplicate_receipt','checkpoint_sequence_rollback','shard_mismatch','budget_exceeded','backoff_violation','fairness_violation')) {
            $source | Should -Match ([regex]::Escape('"' + $token + '"'))
        }
        $source | Should -Match ([regex]::Escape('Optional[Tuple[str, int]]'))
    }

    It 'chains Part 4 through Part 3 Part 2 and cryptographically binds nested closure artifacts' {
        $context = Get-NxbPart4TestContext
        $source = Get-Content -LiteralPath $context.certification -Raw
        $source | Should -Match ([regex]::Escape('Invoke-NxbControllerTargetTransportCertification.ps1'))
        $source | Should -Match ([regex]::Escape('-ExpectedHead $ExpectedHead'))
        $source | Should -Match ([regex]::Escape('inherited_part2_validated'))
        $source | Should -Match ([regex]::Escape('inherited_part3_negative_controls'))

        $combinedSource = Get-Content -LiteralPath $context.combined -Raw
        $combinedSource | Should -Match ([regex]::Escape('Invoke-NxbPart4ResumableRunnerCertification.ps1'))
        $combinedSource | Should -Match ([regex]::Escape('part3_review_zip_sha256'))
        $combinedSource | Should -Match ([regex]::Escape('part4_review_zip_sha256'))
        $combinedSource | Should -Match ([regex]::Escape('part234-combined-certification-receipt.json'))
    }

    It 'inherits permanent error gates and keeps Part 4 PowerShell source ASCII-clean' {
        $context = Get-NxbPart4TestContext
        $ledger = Get-Content -LiteralPath $context.ledger -Raw
        $ledger | Should -Match ([regex]::Escape('NXB-ERR-027'))
        foreach ($path in @($context.common,$context.worker,$context.experiment,$context.certification,$context.combined)) {
            $source = Get-Content -LiteralPath $path -Raw
            $source | Should -Not -Match '(?im)^\s*\$matches\s*='
            $source | Should -Not -Match '(?im)^\s*\$profile\s*='
            $source | Should -Not -Match '(?ims)catch\s*\{\s*\}'
            $source | Should -Not -Match '[^\u0000-\u007F]'
        }
    }
}
