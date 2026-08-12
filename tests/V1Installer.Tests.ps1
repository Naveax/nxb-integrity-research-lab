$ErrorActionPreference = 'Stop'

Describe 'NXB v1 installer contract' {
    BeforeAll {
        function Get-NxbV1InstallerTestContext {
            $root = [string]$env:NXB_V1_INSTALLER_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_V1_INSTALLER_REPOSITORY_ROOT is required.' }
            $full = [IO.Path]::GetFullPath($root)
            return [pscustomobject][ordered]@{
                root=$full
                policy=Join-Path $full 'config\nxb-v1-installer-policy.json'
                package_schema=Join-Path $full 'schemas\nxb-v1-package-manifest.schema.json'
                state_schema=Join-Path $full 'schemas\nxb-v1-install-state.schema.json'
                operation_schema=Join-Path $full 'schemas\nxb-v1-installer-operation-receipt.schema.json'
                lifecycle_schema=Join-Path $full 'schemas\nxb-v1-installer-lifecycle.schema.json'
                certification_schema=Join-Path $full 'schemas\nxb-v1-installer-certification-receipt.schema.json'
                common=Join-Path $full 'scripts\NxbV1Installer.Common.ps1'
                state=Join-Path $full 'scripts\NxbV1Installer.State.ps1'
                exporter=Join-Path $full 'scripts\Export-NxbV1PackageManifest.ps1'
                host=Join-Path $full 'scripts\Test-NxbV1InstallerHost.ps1'
                operator=Join-Path $full 'scripts\Invoke-NxbV1Installer.ps1'
                authority=Join-Path $full 'scripts\Invoke-NxbV1InstallerCertification.ps1'
                validator=Join-Path $full 'tools\validate_v1_installer.py'
                installer_errors=Join-Path $full 'config\nxb-v1-installer-known-error-signatures.json'
            }
        }
    }

    It 'keeps every installer authority component repo-owned' {
        $c=Get-NxbV1InstallerTestContext
        foreach ($p in @($c.policy,$c.package_schema,$c.state_schema,$c.operation_schema,$c.lifecycle_schema,$c.certification_schema,$c.common,$c.state,$c.exporter,$c.host,$c.operator,$c.authority,$c.validator,$c.installer_errors)) { Test-Path -LiteralPath $p -PathType Leaf | Should -BeTrue }
    }

    It 'binds installer to the native-certified production signing predecessor' {
        $p=Get-Content -LiteralPath (Get-NxbV1InstallerTestContext).policy -Raw | ConvertFrom-Json
        [string]$p.predecessor_production_signing_head | Should -BeExactly '91be58af59d0703de0159fea9d11935805e16022'
        [string]$p.release_integration_head | Should -BeExactly '9371399bab4fbb921ad94198aa148c597c7b6261'
        [string]$p.certified_implementation_head | Should -BeExactly 'a10535b294c4d7ba8a4c3683154609087bf50c4b'
        [string]$p.target_version | Should -BeExactly '1.0.0'
    }

    It 'defines a strict package manifest schema' {
        $s=Get-Content -LiteralPath (Get-NxbV1InstallerTestContext).package_schema -Raw | ConvertFrom-Json
        [bool]$s.additionalProperties | Should -BeFalse
        [string]$s.properties.contract_id.const | Should -BeExactly 'nxb-v1-package-manifest-v1'
        [int]$s.properties.files.maxItems | Should -Be 2048
        [bool]$s.properties.files.items.additionalProperties | Should -BeFalse
    }

    It 'defines a strict managed install-state schema' {
        $s=Get-Content -LiteralPath (Get-NxbV1InstallerTestContext).state_schema -Raw | ConvertFrom-Json
        [bool]$s.additionalProperties | Should -BeFalse
        [string]$s.properties.contract_id.const | Should -BeExactly 'nxb-v1-install-state-v1'
        @($s.properties.install_mode.enum) | Should -Contain 'Portable'
        @($s.properties.install_mode.enum) | Should -Contain 'PerMachine'
    }

    It 'defines a strict operation receipt that never claims data or evidence removal' {
        $s=Get-Content -LiteralPath (Get-NxbV1InstallerTestContext).operation_schema -Raw | ConvertFrom-Json
        [bool]$s.additionalProperties | Should -BeFalse
        [bool]$s.properties.data_removed.const | Should -BeFalse
        [bool]$s.properties.evidence_removed.const | Should -BeFalse
        @($s.properties.action.enum).Count | Should -Be 4
    }

    It 'defines a strict lifecycle evidence schema' {
        $s=Get-Content -LiteralPath (Get-NxbV1InstallerTestContext).lifecycle_schema -Raw | ConvertFrom-Json
        [bool]$s.additionalProperties | Should -BeFalse
        [bool]$s.properties.corruption_detected.const | Should -BeTrue
        [bool]$s.properties.repair_restored_bytes.const | Should -BeTrue
        [bool]$s.properties.machine_install_performed.const | Should -BeFalse
        [string]$s.properties.data_sentinel_sha256.pattern | Should -BeExactly '^[0-9a-f]{64}$'
        [string]$s.properties.evidence_sentinel_sha256.pattern | Should -BeExactly '^[0-9a-f]{64}$'
    }

    It 'defines a strict installer certification receipt' {
        $s=Get-Content -LiteralPath (Get-NxbV1InstallerTestContext).certification_schema -Raw | ConvertFrom-Json
        [bool]$s.additionalProperties | Should -BeFalse
        [string]$s.properties.authority.const | Should -BeExactly 'nxb-v1-installer-certification-v1'
        [string]$s.properties.ps7.const | Should -BeExactly '22/22'
        [int]$s.properties.independent_requirements.const | Should -Be 14
        [int]$s.properties.independent_negative_controls.const | Should -Be 10
    }

    It 'rejects traversal rooted backslash delimiter and control paths' {
        $c=Get-NxbV1InstallerTestContext
        . $c.common
        foreach ($bad in @('../x','C:/x','/x','a\b','a|b',"a`nb")) { Test-NxbV1InstallerRelativePath -Path $bad | Should -BeFalse }
        Test-NxbV1InstallerRelativePath -Path 'bin/nxb.ps1' | Should -BeTrue
    }

    It 'rejects filesystem Windows system repository and reparse install roots' {
        $source=Get-Content -LiteralPath (Get-NxbV1InstallerTestContext).common -Raw
        foreach ($token in @('[IO.Path]::GetPathRoot($full)','$env:WINDIR','[Environment]::SystemDirectory','[string]::Equals($full,$forbidden,[StringComparison]::OrdinalIgnoreCase)','$full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)','Test-NxbV1InstallerPathChainNoReparse')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'uses explicit ordinal package path ordering' {
        $source=Get-Content -LiteralPath (Get-NxbV1InstallerTestContext).common -Raw
        $source | Should -Match ([regex]::Escape('[Array]::Sort($paths,[StringComparer]::Ordinal)'))
        $source | Should -Not -Match '(?im)Sort-Object\b[^\r\n]*(?:path|relative)'
    }

    It 'binds every manifest row to byte count and SHA256 and rejects duplicates' {
        $source=Get-Content -LiteralPath (Get-NxbV1InstallerTestContext).common -Raw
        foreach ($token in @('$rowMap.ContainsKey($relative)','Get-NxbV1InstallerSha256 -Path $full','Package exceeds maximum byte budget.','Package exceeds maximum file count.')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'requires managed state identity before repair or uninstall' {
        $source=Get-Content -LiteralPath (Get-NxbV1InstallerTestContext).state -Raw
        foreach ($token in @('Managed install state is missing.','nxb-v1-install-state-v1','package_manifest_sha256','Test-NxbV1InstalledRootAgainstManifest')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'exports a manifest only after independent package-byte verification' {
        $source=Get-Content -LiteralPath (Get-NxbV1InstallerTestContext).exporter -Raw
        $source | Should -Match ([regex]::Escape('Package manifest output must be outside PackageRoot.'))
        $source | Should -Match ([regex]::Escape('$outputFull.StartsWith($packagePrefix,[StringComparison]::OrdinalIgnoreCase)'))
        $source | Should -Match ([regex]::Escape('Test-NxbV1PackageManifestObject'))
        $source | Should -Match ([regex]::Escape('Test-NxbV1PackageAgainstManifest'))
        $source | Should -Match ([regex]::Escape('[Text.UTF8Encoding]::new($false)'))
    }

    It 'uses bounded native stderr handling in host preflight' {
        $source=Get-Content -LiteralPath (Get-NxbV1InstallerTestContext).host -Raw
        foreach ($token in @('$previousErrorActionPreference = $ErrorActionPreference','$ErrorActionPreference = ''Continue''','$nativeExitCode = if ($null -eq $LASTEXITCODE)','PSNativeCommandUseErrorActionPreference')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'makes the mutating installer operator support ShouldProcess' {
        $source=Get-Content -LiteralPath (Get-NxbV1InstallerTestContext).operator -Raw
        $source | Should -Match ([regex]::Escape("[CmdletBinding(SupportsShouldProcess=`$true,ConfirmImpact='High')]"))
        $source | Should -Match ([regex]::Escape('$PSCmdlet.ShouldProcess'))
    }

    It 'separates Portable Stage from installed PerUser and PerMachine modes' {
        $source=Get-Content -LiteralPath (Get-NxbV1InstallerTestContext).operator -Raw
        $source | Should -Match ([regex]::Escape('Stage action requires Portable mode.'))
        $source | Should -Match ([regex]::Escape('Portable mode must use Stage instead of Install.'))
        $source | Should -Match ([regex]::Escape('PerMachine installer mode requires Administrator.'))
    }

    It 'uses sibling staging before publishing an install root' {
        $source=Get-Content -LiteralPath (Get-NxbV1InstallerTestContext).operator -Raw
        foreach ($token in @('.nxb-stage-','Invoke-NxbV1InstallerPopulateStage','[IO.Directory]::Move($stagingRoot,$installFull)','Installed root failed post-move verification.')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'repairs through backup replacement and explicit rollback' {
        $source=Get-Content -LiteralPath (Get-NxbV1InstallerTestContext).operator -Raw
        foreach ($token in @('.nxb-repair-','.nxb-backup-','$rollbackUsed = $true','[IO.Directory]::Move($backupRoot,$installFull)','Repaired root failed verification.')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'uninstalls only an intact managed package and preserves external data evidence' {
        $source=Get-Content -LiteralPath (Get-NxbV1InstallerTestContext).operator -Raw
        $source | Should -Match ([regex]::Escape('Uninstall requires an intact managed package; run Repair first.'))
        $source | Should -Match ([regex]::Escape('data_removed=$false'))
        $source | Should -Match ([regex]::Escape('evidence_removed=$false'))
    }

    It 'gives the independent validator fourteen requirements and ten negative controls' {
        $source=Get-Content -LiteralPath (Get-NxbV1InstallerTestContext).validator -Raw
        foreach ($token in @('"requirement_count": 14','"negative_count": 10','--data-sentinel','--evidence-sentinel','duplicate_manifest_path','traversal_manifest_path','unsorted_manifest','tampered_file_hash','wrong_total_bytes','stale_source_head','missing_corruption_detection','machine_install_claim','uninstall_data_removal','receipt_manifest_mismatch')) { $source | Should -Match ([regex]::Escape($token)) }
    }

    It 'carries four installer successor known-error rules without changing predecessors' {
        $d=Get-Content -LiteralPath (Get-NxbV1InstallerTestContext).installer_errors -Raw | ConvertFrom-Json
        @($d.rules).Count | Should -Be 4
        $ids=@($d.rules | ForEach-Object { [string]$_.id })
        foreach ($id in @('NXB-ERR-004','NXB-ERR-007','NXB-ERR-018','NXB-ERR-036')) { $ids | Should -Contain $id }
    }

    It 'locks the installer contract at exactly twenty-two tests' {
        $testSource=Get-Content -LiteralPath $PSCommandPath -Raw
        [regex]::Matches($testSource,"(?m)^\s*It\s+'").Count | Should -Be 22
    }
}
