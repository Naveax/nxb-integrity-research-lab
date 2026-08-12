$ErrorActionPreference = 'Stop'

Describe 'NXB v1 signed staged update contract' {
    BeforeAll {
        function Get-NxbV1UpdateTestContext {
            $root=[string]$env:NXB_V1_UPDATE_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_V1_UPDATE_REPOSITORY_ROOT is required.' }
            $full=[IO.Path]::GetFullPath($root)
            return [pscustomobject][ordered]@{
                root=$full
                policy=Join-Path $full 'config\nxb-v1-update-policy.json'
                descriptor_schema=Join-Path $full 'schemas\nxb-v1-update-descriptor.schema.json'
                trust_schema=Join-Path $full 'schemas\nxb-v1-update-trust.schema.json'
                stage_schema=Join-Path $full 'schemas\nxb-v1-update-stage-state.schema.json'
                state_schema=Join-Path $full 'schemas\nxb-v1-update-state.schema.json'
                operation_schema=Join-Path $full 'schemas\nxb-v1-update-operation-receipt.schema.json'
                lifecycle_schema=Join-Path $full 'schemas\nxb-v1-update-lifecycle.schema.json'
                certification_schema=Join-Path $full 'schemas\nxb-v1-update-certification-receipt.schema.json'
                common=Join-Path $full 'scripts\NxbV1Update.Common.ps1'
                state=Join-Path $full 'scripts\NxbV1Update.State.ps1'
                operator=Join-Path $full 'scripts\Invoke-NxbV1Updater.ps1'
                authority=Join-Path $full 'scripts\Invoke-NxbV1UpdateCertification.ps1'
                validator=Join-Path $full 'tools\validate_v1_update.py'
                update_errors=Join-Path $full 'config\nxb-v1-update-known-error-signatures.json'
                release_errors=Join-Path $full 'config\nxb-v1-release-known-error-signatures.json'
            }
        }
    }

    It 'keeps every update authority component repo-owned' {
        $c=Get-NxbV1UpdateTestContext
        foreach ($p in @($c.policy,$c.descriptor_schema,$c.trust_schema,$c.stage_schema,$c.state_schema,$c.operation_schema,$c.lifecycle_schema,$c.certification_schema,$c.common,$c.state,$c.operator,$c.authority,$c.validator,$c.update_errors,$c.release_errors)) { Test-Path -LiteralPath $p -PathType Leaf | Should -BeTrue }
    }

    It 'binds update to native-certified installer and signing predecessors' {
        $p=Get-Content -LiteralPath (Get-NxbV1UpdateTestContext).policy -Raw | ConvertFrom-Json
        [string]$p.predecessor_installer_head | Should -BeExactly 'efdeb275c25a7df1326d7effdddb4af8d83ef81d'
        [string]$p.production_signing_head | Should -BeExactly '91be58af59d0703de0159fea9d11935805e16022'
        [string]$p.release_integration_head | Should -BeExactly '9371399bab4fbb921ad94198aa148c597c7b6261'
        [string]$p.certified_implementation_head | Should -BeExactly 'a10535b294c4d7ba8a4c3683154609087bf50c4b'
    }

    It 'defines a strict signed update descriptor schema' {
        $s=Get-Content -LiteralPath (Get-NxbV1UpdateTestContext).descriptor_schema -Raw | ConvertFrom-Json
        [bool]$s.additionalProperties | Should -BeFalse
        [string]$s.properties.contract_id.const | Should -BeExactly 'nxb-v1-update-descriptor-v1'
        [int]$s.properties.release_sequence.minimum | Should -Be 1
        @($s.properties.channel.enum) | Should -Contain 'stable'
    }

    It 'defines a strict pinned update trust schema' {
        $s=Get-Content -LiteralPath (Get-NxbV1UpdateTestContext).trust_schema -Raw | ConvertFrom-Json
        [bool]$s.additionalProperties | Should -BeFalse
        [string]$s.properties.contract_id.const | Should -BeExactly 'nxb-v1-update-trust-v1'
        [bool]$s.properties.allow_downgrade.const | Should -BeFalse
        [string]$s.properties.trusted_signer_fingerprint.pattern | Should -BeExactly '^[0-9a-f]{64}$'
    }

    It 'defines a strict stage state schema' {
        $s=Get-Content -LiteralPath (Get-NxbV1UpdateTestContext).stage_schema -Raw | ConvertFrom-Json
        [bool]$s.additionalProperties | Should -BeFalse
        [string]$s.properties.status.const | Should -BeExactly 'staged'
        [string]$s.properties.envelope_sha256.pattern | Should -BeExactly '^[0-9a-f]{64}$'
    }

    It 'defines persistent update state, anti-replay floor and atomic authoritative JSON publication' {
        $c=Get-NxbV1UpdateTestContext
        $s=Get-Content -LiteralPath $c.state_schema -Raw | ConvertFrom-Json
        [bool]$s.additionalProperties | Should -BeFalse
        @($s.required) | Should -Contain 'current_channel'
        @($s.required) | Should -Contain 'rollback_channel'
        @($s.required) | Should -Contain 'rollback_tree_sha256'
        @($s.required) | Should -Contain 'highest_seen_release_sequence'
        [int]$s.properties.highest_seen_release_sequence.minimum | Should -Be 0
        $source=Get-Content -LiteralPath $c.state -Raw
        foreach ($token in @("'.nxb-json-'",'[IO.FileStream]::new','[IO.FileOptions]::WriteThrough','$stream.Flush($true)','[IO.File]::Replace($tempPath,$full,$null)','[IO.File]::Move($tempPath,$full)','highest_seen_release_sequence','return [int]$state.highest_seen_release_sequence')) { $source | Should -Match ([regex]::Escape($token)) }
        $source | Should -Not -Match '(?im)^\s*\[IO\.File\]::WriteAllText\(\$full\b'
        $source | Should -Not -Match '(?im)^\s*return\s+\[int\]\$state\.current_release_sequence\s*$'
    }

    It 'defines update operation receipts with explicit no-auto-apply evidence' {
        $s=Get-Content -LiteralPath (Get-NxbV1UpdateTestContext).operation_schema -Raw | ConvertFrom-Json
        [bool]$s.additionalProperties | Should -BeFalse
        [bool]$s.properties.auto_apply.const | Should -BeFalse
        @($s.properties.action.enum).Count | Should -Be 3
        [string]$s.properties.production_release_updated.type | Should -BeExactly 'boolean'
    }

    It 'defines lifecycle evidence for apply and both rollback paths' {
        $s=Get-Content -LiteralPath (Get-NxbV1UpdateTestContext).lifecycle_schema -Raw | ConvertFrom-Json
        [bool]$s.additionalProperties | Should -BeFalse
        [bool]$s.properties.failure_rollback_passed.const | Should -BeTrue
        [bool]$s.properties.manual_rollback_passed.const | Should -BeTrue
        [string]$s.properties.initial_tree_sha256.pattern | Should -BeExactly '^[0-9a-f]{64}$'
        [string]$s.properties.rolled_back_tree_sha256.pattern | Should -BeExactly '^[0-9a-f]{64}$'
    }

    It 'defines a strict update certification receipt' {
        $s=Get-Content -LiteralPath (Get-NxbV1UpdateTestContext).certification_schema -Raw | ConvertFrom-Json
        [bool]$s.additionalProperties | Should -BeFalse
        [string]$s.properties.ps7.const | Should -BeExactly '24/24'
        [int]$s.properties.independent_requirements.const | Should -Be 16
        [int]$s.properties.independent_negative_controls.const | Should -Be 12
        [int]$s.properties.update_known_error_rules.const | Should -Be 6
    }

    It 'requires RSA verification and an exact pinned signer fingerprint' {
        $source=Get-Content -LiteralPath (Get-NxbV1UpdateTestContext).common -Raw
        foreach ($token in @('Test-NxbV1SignedReleaseEnvelope','trusted_signer_fingerprint','Envelope.public_key.fingerprint','production-windows-certificate-store','certification-ephemeral')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'binds signed descriptor manifest and package artifacts to real fixture bytes' {
        $c=Get-NxbV1UpdateTestContext
        $source=Get-Content -LiteralPath $c.common -Raw
        foreach ($token in @('update/update-descriptor.json','package/','package_manifest_sha256','Test-NxbV1PackageAgainstManifest','Get-NxbV1UpdateEnvelopeArtifactMap')) { $source | Should -Match ([regex]::Escape($token)) }
        $authoritySource=Get-Content -LiteralPath $c.authority -Raw
        foreach ($token in @('$artifactPath=Join-Path -Path $targetPackageRoot -ChildPath $nativeRelative','$artifactItem=Get-Item -LiteralPath $artifactPath','bytes=[int64]$artifactItem.Length','sha256=(Get-NxbV1UpdateCertSha256 -Path $artifactPath)')) { $authoritySource | Should -Match ([regex]::Escape($token)) }
    }

    It 'uses ordinal update tree canonicalization' {
        $source=Get-Content -LiteralPath (Get-NxbV1UpdateTestContext).common -Raw
        $source | Should -Match ([regex]::Escape('[Array]::Sort($paths,[StringComparer]::Ordinal)'))
        $source | Should -Not -Match '(?im)Sort-Object\b[^\r\n]*(?:path|relative|entry|file)'
    }

    It 'makes update mutations support ShouldProcess' {
        $source=Get-Content -LiteralPath (Get-NxbV1UpdateTestContext).operator -Raw
        $source | Should -Match ([regex]::Escape("[CmdletBinding(SupportsShouldProcess=`$true,ConfirmImpact='High')]"))
        $source | Should -Match ([regex]::Escape('$PSCmdlet.ShouldProcess'))
    }

    It 'stages without auto applying and supports only monotonic staged supersession' {
        $source=Get-Content -LiteralPath (Get-NxbV1UpdateTestContext).operator -Raw
        foreach ($token in @("-ChildPath 'staged-package'","-ChildPath 'staged-metadata'",'auto_apply=$false','Existing staged update sequence is newer or equal.','Supersede staged sequence')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'revalidates exact stage root trust and signed bundle before Apply' {
        $source=Get-Content -LiteralPath (Get-NxbV1UpdateTestContext).operator -Raw
        foreach ($token in @('Stage package root binding drift.','Trust anchor changed after Stage.','Staged metadata hash drift.','Staged update failed revalidation before Apply.')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'applies through candidate publish, retained rollback snapshot and failed-validation atomic restore' {
        $operatorSource=Get-Content -LiteralPath (Get-NxbV1UpdateTestContext).operator -Raw
        foreach ($token in @('.nxb-update-candidate-','.nxb-update-rollback-','Invoke-NxbV1UpdateAtomicSwap','rollback_available=$true','rollback_tree_sha256=$previousTreeSha','highest_seen_release_sequence=[int]$descriptor.release_sequence')) { $operatorSource | Should -Match ([regex]::Escape($token)) }
        $commonSource=Get-Content -LiteralPath (Get-NxbV1UpdateTestContext).common -Raw
        foreach ($token in @('Invoke-NxbV1UpdateAtomicSwap','PostPublishValidation','Atomic update post-publish validation failed.','[IO.Directory]::Move($rollback,$current)')) { $commonSource | Should -Match ([regex]::Escape($token)) }
    }

    It 'restores the previous install if update state publication fails' {
        $source=Get-Content -LiteralPath (Get-NxbV1UpdateTestContext).operator -Raw
        foreach ($token in @('.nxb-update-failed-','[IO.Directory]::Move($rollbackRoot,$installFull)','Write-NxbV1UpdateJson -Path (Get-NxbV1UpdateStatePath')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'manual rollback verifies tree hash, preserves anti-replay floor and preserves forward state until state write succeeds' {
        $source=Get-Content -LiteralPath (Get-NxbV1UpdateTestContext).operator -Raw
        foreach ($token in @('Rollback snapshot tree hash mismatch.','.nxb-update-displaced-','Restored rollback tree hash mismatch.','rollback_available=$false','highest_seen_release_sequence=[int]$state.highest_seen_release_sequence')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'rejects sequence replay downgrade revoked heads and channel mismatch' {
        $c=Get-NxbV1UpdateTestContext
        $source=Get-Content -LiteralPath $c.common -Raw
        foreach ($token in @('release_sequence -le $CurrentReleaseSequence','minimum_release_sequence','revoked_release_heads','Descriptor.channel -cne [string]$Trust.channel')) { $source | Should -Match ([regex]::Escape($token)) }
        $authoritySource=Get-Content -LiteralPath $c.authority -Raw
        foreach ($token in @('rollbackFloorPreserved','rollbackReplayRejected','highest_seen_release_sequence','--update-state')) { $authoritySource | Should -Match ([regex]::Escape($token)) }
    }

    It 'keeps production and certification signer modes separate' {
        $source=Get-Content -LiteralPath (Get-NxbV1UpdateTestContext).common -Raw
        $source | Should -Match ([regex]::Escape("Envelope.signer_mode -cne 'certification-ephemeral'"))
        $source | Should -Match ([regex]::Escape("Envelope.signer_mode -cne 'production-windows-certificate-store'"))
        $source | Should -Match ([regex]::Escape('production_signer_claimed'))
    }

    It 'gives the independent validator sixteen requirements twelve negatives raw RSA and persisted anti-replay replay' {
        $source=Get-Content -LiteralPath (Get-NxbV1UpdateTestContext).validator -Raw
        foreach ($token in @("'requirement_count':16","'negative_count':12",'pow(s, e, n)','wrong_signer','tampered_signature','revoked_head','sequence_replay','minimum_sequence','channel_mismatch','weak_key_metadata','duplicate_artifact','missing_descriptor_artifact','tampered_package_hash','auto_apply_claim','missing_manual_rollback','update_state','highest_seen_release_sequence')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'carries six update successor rules without duplicating release ERR-036' {
        $d=Get-Content -LiteralPath (Get-NxbV1UpdateTestContext).update_errors -Raw | ConvertFrom-Json
        @($d.rules).Count | Should -Be 6
        $ids=@($d.rules | ForEach-Object { [string]$_.id })
        foreach ($id in @('NXB-ERR-004','NXB-ERR-007','NXB-ERR-018','NXB-ERR-037','NXB-ERR-038','NXB-ERR-039')) { $ids | Should -Contain $id }
        $ids | Should -Not -Contain 'NXB-ERR-036'
    }

    It 'delegates ERR-036 to the release scanner across update authority files' {
        $d=Get-Content -LiteralPath (Get-NxbV1UpdateTestContext).release_errors -Raw | ConvertFrom-Json
        @($d.rules).Count | Should -Be 1
        [string]$d.rules[0].id | Should -BeExactly 'NXB-ERR-036'
        $includes=@($d.rules[0].include | ForEach-Object { [string]$_ })
        foreach ($path in @('scripts/NxbV1Update.Common.ps1','scripts/NxbV1Update.State.ps1','scripts/Invoke-NxbV1Updater.ps1','scripts/Invoke-NxbV1UpdateCertification.ps1','tests/V1Update.Tests.ps1')) { $includes | Should -Contain $path }
    }

    It 'locks the update contract at exactly twenty-four tests' {
        $testSource=Get-Content -LiteralPath $PSCommandPath -Raw
        [regex]::Matches($testSource,"(?m)^\s*It\s+'").Count | Should -Be 24
    }
}
