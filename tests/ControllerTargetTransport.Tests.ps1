$ErrorActionPreference = 'Stop'

Describe 'NXB IRL-006 Part 3 controller target transport contract' {
    BeforeAll {
        function Get-NxbTransportTestContext {
            $root = [string]$env:NXB_TRANSPORT_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_TRANSPORT_REPOSITORY_ROOT is required.' }
            $fullRoot = [IO.Path]::GetFullPath($root)
            return [pscustomobject][ordered]@{
                root = $fullRoot
                config = Join-Path $fullRoot 'config\nxb-controller-target-transport.json'
                common = Join-Path $fullRoot 'scripts\NxbControllerTargetTransport.Common.ps1'
                target = Join-Path $fullRoot 'scripts\Start-NxbControllerTargetTransportTarget.ps1'
                experiment = Join-Path $fullRoot 'scripts\Invoke-NxbControllerTargetTransportExperiment.ps1'
                certification = Join-Path $fullRoot 'scripts\Invoke-NxbControllerTargetTransportCertification.ps1'
                validator = Join-Path $fullRoot 'tools\validate_controller_target_transport.py'
                scanner = Join-Path $fullRoot 'scripts\Invoke-NxbKnownErrorScan.ps1'
                ledger = Join-Path $fullRoot 'docs\NXB-KNOWN-ERROR-LEDGER.md'
                signatures = Join-Path $fullRoot 'config\nxb-known-error-signatures.json'
            }
        }
    }

    It 'keeps every Part 3 transport authority component repo-owned' {
        $context = Get-NxbTransportTestContext
        foreach ($path in @($context.config,$context.common,$context.target,$context.experiment,$context.certification,$context.validator,$context.scanner,$context.ledger,$context.signatures)) {
            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        }
    }

    It 'locks the bounded loopback transport contract and queue budgets' {
        $context = Get-NxbTransportTestContext
        $config = Get-Content -LiteralPath $context.config -Raw | ConvertFrom-Json
        [int]$config.schema_version | Should -Be 1
        [string]$config.contract_id | Should -BeExactly 'nxb-irl006-part3-controller-target-transport-v1'
        [string]$config.scope | Should -BeExactly 'loopback-controller-target-certification-only'
        [string]$config.bind_address | Should -BeExactly '127.0.0.1'
        [int]$config.queue.low_watermark | Should -BeLessThan ([int]$config.queue.high_watermark)
        [int]$config.queue.high_watermark | Should -BeLessThan ([int]$config.queue.maximum_frames)
        [int]$config.spool.maximum_records | Should -BeGreaterThan ([int]$config.event_count)
    }

    It 'uses certification-only HMAC authentication without claiming a production secret' {
        $context = Get-NxbTransportTestContext
        $config = Get-Content -LiteralPath $context.config -Raw | ConvertFrom-Json
        [string]$config.authentication.algorithm | Should -BeExactly 'HMACSHA256'
        [string]$config.authentication.certification_test_key_hex | Should -Match '^[0-9a-f]{64}$'
        [bool]$config.authentication.production_secret_claimed | Should -BeFalse
        [bool]$config.review_privacy.authentication_key_reviewable | Should -BeFalse
    }

    It 'binds every frame to canonical payload hashing fixed-time HMAC verification and stable byte-array cardinality' {
        $context = Get-NxbTransportTestContext
        $source = Get-Content -LiteralPath $context.common -Raw
        foreach ($token in @('Get-NxbTransportCanonicalMaterial','HMACSHA256','payload_sha256','payload_b64','session_id','sender_role','sequence','auth_tag','CryptographicOperations]::FixedTimeEquals','return ,$bytes')) {
            $source | Should -Match ([regex]::Escape($token))
        }
        $source | Should -Match ([regex]::Escape('Test-NxbTransportFrame'))
    }

    It 'authenticates target requests before any sequence classification' {
        $context = Get-NxbTransportTestContext
        $source = Get-Content -LiteralPath $context.target -Raw
        $authPosition = $source.IndexOf('Test-NxbTransportFrame',[StringComparison]::Ordinal)
        $sequencePosition = $source.IndexOf('$requestSequence = [int64]$frame.sequence',[StringComparison]::Ordinal)
        $authPosition | Should -BeGreaterThan -1
        $sequencePosition | Should -BeGreaterThan $authPosition
        $source | Should -Match ([regex]::Escape("reason='invalid_auth'"))
    }

    It 'keeps duplicate and sequence-gap rejection nonadvancing' {
        $context = Get-NxbTransportTestContext
        $source = Get-Content -LiteralPath $context.target -Raw
        $source | Should -Match ([regex]::Escape('$requestSequence -lt $expectedSequence'))
        $source | Should -Match ([regex]::Escape("reason='duplicate'"))
        $source | Should -Match ([regex]::Escape('$requestSequence -gt $expectedSequence'))
        $source | Should -Match ([regex]::Escape("reason='sequence_gap'"))
        $source | Should -Match ([regex]::Escape('$state.next_expected_sequence = $expectedSequence + 1'))
    }

    It 'enforces bounded queue high-water backpressure before overflow' {
        $context = Get-NxbTransportTestContext
        $source = Get-Content -LiteralPath $context.target -Raw
        foreach ($token in @('$queue.Count -ge $maxQueue','$queue.Count -ge $highWatermark','$queue.Count -gt $lowWatermark','backpressure_active','overflow_count','max_queue_depth_observed')) {
            $source | Should -Match ([regex]::Escape($token))
        }
    }

    It 'persists target checkpoint state atomically before wire acknowledgement and advances restart generation' {
        $context = Get-NxbTransportTestContext
        $source = Get-Content -LiteralPath $context.target -Raw
        $source | Should -Match ([regex]::Escape('$fullPath + ''.tmp-'''))
        $source | Should -Match ([regex]::Escape('Move-Item -LiteralPath $tempPath -Destination $fullPath -Force'))
        $source | Should -Match ([regex]::Escape('$state.generation = [int]$state.generation + 1'))
        $source | Should -Match ([regex]::Escape('$statePath = Join-Path $stateRoot ''target-state.json'''))
        $persistPosition = $source.IndexOf('Write-NxbTransportTargetJson -Path $StatePath -InputObject $State',[StringComparison]::Ordinal)
        $wirePosition = $source.IndexOf('$Writer.WriteLine((ConvertTo-NxbTransportJsonLine -Frame $response))',[StringComparison]::Ordinal)
        $persistPosition | Should -BeGreaterThan -1
        $wirePosition | Should -BeGreaterThan $persistPosition
    }

    It 'executes invalid-auth duplicate and loss controls against the real loopback socket with an intentionally empty initial transcript' {
        $context = Get-NxbTransportTestContext
        $source = Get-Content -LiteralPath $context.experiment -Raw
        foreach ($token in @('Connect-NxbTransportExperimentClient','invalid_auth_negative','duplicate_negative','gap_negative','TamperAuthentication')) {
            $source | Should -Match ([regex]::Escape($token))
        }
        $source | Should -Match ([regex]::Escape('[Net.IPAddress]::Loopback'))
        $source | Should -Match ([regex]::Escape('[Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Transcript'))
        $source | Should -Not -Match ([regex]::Escape('[Parameter(Mandatory)][Collections.Generic.List[object]]$Transcript'))
        $source | Should -Match ([regex]::Escape('$transcript = [Collections.Generic.List[object]]::new()'))
        $source | Should -Match ([regex]::Escape('[Parameter(Mandatory)][object[]]$Records'))
    }

    It 'spools pending events within byte and record budgets and persists replay cursor' {
        $context = Get-NxbTransportTestContext
        $source = Get-Content -LiteralPath $context.experiment -Raw
        foreach ($token in @('Write-NxbTransportSpool','maximum_records','maximum_bytes','controller-spool.jsonl','controller-spool-cursor.json','acknowledged_records','spoolReplayCount')) {
            $source | Should -Match ([regex]::Escape($token))
        }
    }

    It 'restarts the target process and resumes from the persisted exact checkpoint' {
        $context = Get-NxbTransportTestContext
        $source = Get-Content -LiteralPath $context.experiment -Raw
        $source | Should -Match ([regex]::Escape('$targetProcess.Kill()'))
        $source | Should -Match ([regex]::Escape('$checkpointMatched'))
        $source | Should -Match ([regex]::Escape("-Kind resume"))
        $source | Should -Match ([regex]::Escape("resume_after_target_restart"))
        $source | Should -Match ([regex]::Escape('$restartGeneration -ne 2'))
    }

    It 'arms emergency stop and proves later authenticated data is rejected' {
        $context = Get-NxbTransportTestContext
        $source = Get-Content -LiteralPath $context.experiment -Raw
        $source | Should -Match ([regex]::Escape('-Kind emergency_stop'))
        $source | Should -Match ([regex]::Escape('post_stop_event_negative'))
        $source | Should -Match ([regex]::Escape("reason -ceq 'emergency_stop_active'"))
        $targetSource = Get-Content -LiteralPath $context.target -Raw
        $targetSource | Should -Match ([regex]::Escape('$kind -ceq ''event'''))
        $targetSource | Should -Match ([regex]::Escape("reason='emergency_stop_active'"))
    }

    It 'independently recomputes request and response authentication plus monotonic sequencing' {
        $context = Get-NxbTransportTestContext
        $source = Get-Content -LiteralPath $context.validator -Raw
        foreach ($token in @('hmac.new','canonical_material','auth_valid','expected_request_sequence','expected_response_sequence','sequence_gap','duplicate','emergency_stop_active')) {
            $source | Should -Match ([regex]::Escape($token))
        }
    }

    It 'requires nine independent fail-closed evidence mutations' {
        $context = Get-NxbTransportTestContext
        $source = Get-Content -LiteralPath $context.validator -Raw
        foreach ($token in @('tampered_request_auth','tampered_response_auth','response_sequence_gap','required_control_false','queue_overflow','spool_replay_mismatch','restart_generation_mismatch','post_stop_ack','accepted_event_count_mismatch')) {
            $source | Should -Match ([regex]::Escape($token))
        }
        $source | Should -Match ([regex]::Escape('negative_count != 9'))
    }

    It 'chains Part 3 certification through inherited Part 2 and final zero-error scan' {
        $context = Get-NxbTransportTestContext
        $source = Get-Content -LiteralPath $context.certification -Raw
        foreach ($token in @('Invoke-NxbSemanticHardeningCertificationV2.ps1','ControllerTargetTransport.Tests.ps1','validate_controller_target_transport.py','Independent transport evidence replay','Final exact-tree zero-error scan')) {
            $source | Should -Match ([regex]::Escape($token))
        }
    }

    It 'inherits the permanent error ledger through ERR-033 and excludes known active bad patterns' {
        $context = Get-NxbTransportTestContext
        $ledger = Get-Content -LiteralPath $context.ledger -Raw
        $ledger | Should -Match ([regex]::Escape('NXB-ERR-033'))
        $signatureDocument = Get-Content -LiteralPath $context.signatures -Raw | ConvertFrom-Json
        @($signatureDocument.rules | Where-Object { [string]$_.id -ceq 'NXB-ERR-033' }).Count | Should -Be 1
        foreach ($path in @($context.common,$context.target,$context.experiment,$context.certification)) {
            $source = Get-Content -LiteralPath $path -Raw
            $source | Should -Not -Match '(?im)^\s*\$matches\s*='
            $source | Should -Not -Match '(?im)^\s*\$profile\s*='
            $source | Should -Not -Match '(?ims)catch\s*\{\s*\}'
            $source | Should -Not -Match '(?im)\.claim_targets\.PSObject\.Properties\b'
        }
    }
}
