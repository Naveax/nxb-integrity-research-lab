$ErrorActionPreference = 'Stop'

Describe 'NXB v1 production CLI contract' {
    BeforeAll {
        function Get-NxbV1CliTestContext {
            $root = [string]$env:NXB_V1_CLI_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_V1_CLI_REPOSITORY_ROOT is required.' }
            $full = [IO.Path]::GetFullPath($root)
            return [pscustomobject][ordered]@{
                root=$full
                policy=Join-Path $full 'config\nxb-v1-cli-policy.json'
                example=Join-Path $full 'config\nxb-v1-cli.example.json'
                errors=Join-Path $full 'config\nxb-v1-cli-known-error-signatures.json'
                release_errors=Join-Path $full 'config\nxb-v1-release-known-error-signatures.json'
                output_schema=Join-Path $full 'schemas\nxb-v1-cli-output.schema.json'
                config_schema=Join-Path $full 'schemas\nxb-v1-cli-config.schema.json'
                certification_schema=Join-Path $full 'schemas\nxb-v1-cli-certification-receipt.schema.json'
                common=Join-Path $full 'scripts\NxbV1Cli.Common.ps1'
                cli=Join-Path $full 'scripts\nxb.ps1'
                scanner=Join-Path $full 'scripts\Invoke-NxbV1CliKnownErrorScan.ps1'
                authority=Join-Path $full 'scripts\Invoke-NxbV1CliCertification.ps1'
                validator=Join-Path $full 'tools\validate_v1_cli.py'
            }
        }
        . (Join-Path ([string]$env:NXB_V1_CLI_REPOSITORY_ROOT) 'scripts\NxbV1Cli.Common.ps1')
    }

    It 'keeps every CLI authority component repo-owned' {
        $c=Get-NxbV1CliTestContext
        foreach ($p in @($c.policy,$c.example,$c.errors,$c.release_errors,$c.output_schema,$c.config_schema,$c.certification_schema,$c.common,$c.cli,$c.scanner,$c.authority,$c.validator)) { Test-Path -LiteralPath $p -PathType Leaf | Should -BeTrue }
    }

    It 'binds CLI to the native-certified update predecessor and thirteen commands' {
        $p=Get-Content -LiteralPath (Get-NxbV1CliTestContext).policy -Raw | ConvertFrom-Json
        [string]$p.contract_id | Should -BeExactly 'nxb-v1-cli-v1'
        [string]$p.predecessor_update_head | Should -BeExactly '27507531154099ab28a05cfe8e4e900d72f22e7b'
        @($p.commands).Count | Should -Be 13
        @($p.legacy_commands).Count | Should -Be 5
        @($p.mutation_commands).Count | Should -Be 4
    }

    It 'defines stable distinct CLI exit codes' {
        $p=Get-Content -LiteralPath (Get-NxbV1CliTestContext).policy -Raw | ConvertFrom-Json
        [int]$p.exit_codes.success | Should -Be 0
        [int]$p.exit_codes.usage | Should -Be 2
        [int]$p.exit_codes.config | Should -Be 3
        [int]$p.exit_codes.trust_integrity | Should -Be 4
        [int]$p.exit_codes.state_precondition | Should -Be 5
        [int]$p.exit_codes.dependency_doctor | Should -Be 6
        [int]$p.exit_codes.mutation_runtime | Should -Be 7
        [int]$p.exit_codes.evidence_verification | Should -Be 8
        [int]$p.exit_codes.certification | Should -Be 9
        [int]$p.exit_codes.internal | Should -Be 10
    }

    It 'defines a strict stable CLI output envelope schema' {
        $s=Get-Content -LiteralPath (Get-NxbV1CliTestContext).output_schema -Raw | ConvertFrom-Json
        [bool]$s.additionalProperties | Should -BeFalse
        [string]$s.properties.contract_id.const | Should -BeExactly 'nxb-v1-cli-output-v1'
        @($s.required) | Should -Contain 'exit_code'
        @($s.required) | Should -Contain 'mutation_performed'
        @($s.required) | Should -Contain 'errors'
    }

    It 'defines a strict CLI configuration schema' {
        $s=Get-Content -LiteralPath (Get-NxbV1CliTestContext).config_schema -Raw | ConvertFrom-Json
        [bool]$s.additionalProperties | Should -BeFalse
        [string]$s.properties.contract_id.const | Should -BeExactly 'nxb-v1-cli-config-v1'
        @($s.required) | Should -Contain 'output_mode'
        @($s.required) | Should -Contain 'non_interactive'
        @($s.required) | Should -Contain 'update_channel'
    }

    It 'accepts the repo-owned example CLI configuration' {
        $c=Get-NxbV1CliTestContext
        $document=Get-Content -LiteralPath $c.example -Raw | ConvertFrom-Json
        (Test-NxbV1CliConfigDocument -Document $document) | Should -BeTrue
    }

    It 'returns stable version metadata without claiming production release' {
        $c=Get-NxbV1CliTestContext
        $result=& $c.cli -Command version
        [string]$result.version | Should -BeExactly '1.0.0'
        [string]$result.release_state | Should -BeExactly 'candidate'
        [bool]$result.production_release | Should -BeFalse
        [string]$result.certified_update_head | Should -BeExactly '27507531154099ab28a05cfe8e4e900d72f22e7b'
    }

    It 'hashes real file bytes through the retained hash command' {
        $c=Get-NxbV1CliTestContext
        $path=Join-Path ([IO.Path]::GetTempPath()) ('nxb-cli-hash-{0}.bin' -f [Guid]::NewGuid().ToString('N'))
        try {
            [IO.File]::WriteAllBytes($path,[byte[]](1,2,3,4))
            $result=& $c.cli -Command hash -Path $path
            [string]$result.path | Should -BeExactly ([IO.Path]::GetFullPath($path))
            [string]$result.sha256 | Should -Match '^[0-9a-f]{64}$'
        }
        finally { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
    }

    It 'rejects unknown fields in CLI configuration' {
        $c=Get-NxbV1CliTestContext
        $path=Join-Path ([IO.Path]::GetTempPath()) ('nxb-cli-config-{0}.json' -f [Guid]::NewGuid().ToString('N'))
        try {
            $bad=[pscustomobject][ordered]@{ schema_version=1; contract_id='nxb-v1-cli-config-v1'; output_mode='human'; non_interactive=$false; update_channel='stable'; unexpected=$true }
            [IO.File]::WriteAllText($path,(($bad|ConvertTo-Json -Depth 8)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
            { & $c.cli -Command config-validate -ConfigPath $path } | Should -Throw
        }
        finally { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
    }

    It 'retains the five certified Part 9 command names' {
        $source=Get-Content -LiteralPath (Get-NxbV1CliTestContext).cli -Raw
        foreach ($token in @("'status'","'hash'","'inspect-manifest'","'stage-update'","'certify-final'")) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'extends status without rewriting the staged-only legacy claim' {
        $source=Get-Content -LiteralPath (Get-NxbV1CliTestContext).cli -Raw
        foreach ($token in @("update_mode = 'staged-only'","signed_update_mode = 'explicit-stage-apply-rollback'",'certified_update_head')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'uses ordinal ordering for the retained legacy stage-update path' {
        $source=Get-Content -LiteralPath (Get-NxbV1CliTestContext).cli -Raw
        $source | Should -Match ([regex]::Escape('[Array]::Sort($paths,[StringComparer]::Ordinal)'))
        $source | Should -Not -Match '(?im)Sort-Object\b[^\r\n]*(?:path|relative|entry|file)'
        $source | Should -Match ([regex]::Escape('auto_apply = $false'))
    }

    It 'requires explicit mutation confirmation for legacy stage-update in CLI process mode' {
        $source=Get-Content -LiteralPath (Get-NxbV1CliTestContext).cli -Raw
        foreach ($token in @('$CliProcess -and -not $DryRun -and -not $ConfirmMutation','stage-update requires -ConfirmMutation in CLI process mode or -DryRun.')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'retains final certification delegation' {
        $source=Get-Content -LiteralPath (Get-NxbV1CliTestContext).cli -Raw
        $source | Should -Match ([regex]::Escape('Invoke-NxbProductionFinalCertificationV2.ps1'))
        $source | Should -Match ([regex]::Escape("-Category 'certification'"))
    }

    It 'delegates doctor to the installer host preflight' {
        $c=Get-NxbV1CliTestContext
        $p=Get-Content -LiteralPath $c.policy -Raw | ConvertFrom-Json
        [string]$p.delegation.doctor | Should -BeExactly 'scripts/Test-NxbV1InstallerHost.ps1'
        $source=Get-Content -LiteralPath $c.common -Raw
        $source | Should -Match ([regex]::Escape('Invoke-NxbV1CliDoctor'))
    }

    It 'delegates evidence verification to the existing evidence authority' {
        $c=Get-NxbV1CliTestContext
        $p=Get-Content -LiteralPath $c.policy -Raw | ConvertFrom-Json
        [string]$p.delegation.evidence_verify | Should -BeExactly 'scripts/Test-EvidenceBundle.ps1'
        $source=Get-Content -LiteralPath $c.common -Raw
        $source | Should -Match ([regex]::Escape('Invoke-NxbV1CliEvidenceVerification'))
    }

    It 'delegates signed update commands to the native-certified updater authority' {
        $c=Get-NxbV1CliTestContext
        $p=Get-Content -LiteralPath $c.policy -Raw | ConvertFrom-Json
        [string]$p.delegation.signed_update | Should -BeExactly 'scripts/Invoke-NxbV1Updater.ps1'
        $source=Get-Content -LiteralPath $c.common -Raw
        foreach ($token in @("ValidateSet('Check','Stage','Apply','Rollback')",'$parameters[''WhatIf''] = $true','Confirm=$false')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'makes update-check non-mutating through updater WhatIf' {
        $source=Get-Content -LiteralPath (Get-NxbV1CliTestContext).cli -Raw
        foreach ($token in @("'update-check'",'-Mode Check','-DryRun')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'requires confirmation or dry-run for signed update mutations' {
        $source=Get-Content -LiteralPath (Get-NxbV1CliTestContext).cli -Raw
        foreach ($token in @('update-stage requires -ConfirmMutation or -DryRun.','update-apply requires -ConfirmMutation or -DryRun.','update-rollback requires -ConfirmMutation or -DryRun.')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'separates JSON human output and process exit behavior' {
        $source=Get-Content -LiteralPath (Get-NxbV1CliTestContext).cli -Raw
        foreach ($token in @('$Json','$CliProcess','$NonInteractive','[Console]::Out.WriteLine','[Console]::Error.WriteLine','$Host.SetShouldExit','ConvertTo-Json -Depth 32 -Compress')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'carries four CLI successor rules without duplicating release ERR-036' {
        $d=Get-Content -LiteralPath (Get-NxbV1CliTestContext).errors -Raw | ConvertFrom-Json
        @($d.rules).Count | Should -Be 4
        $ids=@($d.rules | ForEach-Object { [string]$_.id })
        foreach ($id in @('NXB-ERR-004','NXB-ERR-007','NXB-ERR-018','NXB-ERR-037')) { $ids | Should -Contain $id }
        $ids | Should -Not -Contain 'NXB-ERR-036'
    }

    It 'delegates ERR-036 to the inherited release scanner across CLI authority files' {
        $d=Get-Content -LiteralPath (Get-NxbV1CliTestContext).release_errors -Raw | ConvertFrom-Json
        @($d.rules).Count | Should -Be 1
        [string]$d.rules[0].id | Should -BeExactly 'NXB-ERR-036'
        $includes=@($d.rules[0].include | ForEach-Object { [string]$_ })
        foreach ($path in @('scripts/NxbV1Cli.Common.ps1','scripts/nxb.ps1','scripts/Invoke-NxbV1CliKnownErrorScan.ps1','scripts/Invoke-NxbV1CliCertification.ps1','tests/V1Cli.Tests.ps1')) { $includes | Should -Contain $path }
    }

    It 'keeps CLI successor source ASCII clean and free of destructive dynamic execution primitives' {
        $c=Get-NxbV1CliTestContext
        foreach ($path in @($c.common,$c.cli,$c.scanner,$c.authority)) {
            $bad=@([IO.File]::ReadAllBytes($path) | Where-Object { [int]$_ -gt 0x7F })
            $bad.Count | Should -Be 0
            $source=Get-Content -LiteralPath $path -Raw
            $source | Should -Not -Match '(?im)\b(Format-Volume|Clear-Disk|Invoke-Expression)\b'
        }
    }

    It 'locks the production CLI contract at exactly twenty-four tests' {
        $testSource=Get-Content -LiteralPath $PSCommandPath -Raw
        [regex]::Matches($testSource,"(?m)^\s*It\s+'").Count | Should -Be 24
    }
}
