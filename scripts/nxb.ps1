[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('status','hash','inspect-manifest','stage-update','certify-final','version','doctor','config-validate','evidence-verify','update-check','update-stage','update-apply','update-rollback')][string]$Command,
    [Parameter()][string]$Path,
    [Parameter()][string]$ExpectedVersion,
    [Parameter()][string]$ExpectedHead,
    [Parameter()][string]$OutputDirectory,
    [Parameter()][string]$StagingRoot,
    [Parameter()][string]$ConfigPath,
    [Parameter()][string]$ExperimentPath,
    [Parameter()][string]$BundlePath,
    [Parameter()][string]$CertificatePath,
    [Parameter()][string]$InstallRoot,
    [Parameter()][string]$UpdateRoot,
    [Parameter()][string]$ReceiptPath,
    [Parameter()][string]$PackageRoot,
    [Parameter()][string]$ManifestPath,
    [Parameter()][string]$DescriptorPath,
    [Parameter()][string]$EnvelopePath,
    [Parameter()][string]$TrustPath,
    [Parameter()][switch]$Json,
    [Parameter()][switch]$CliProcess,
    [Parameter()][switch]$DryRun,
    [Parameter()][switch]$NonInteractive,
    [Parameter()][switch]$ConfirmMutation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $RepositoryRoot 'scripts\NxbProductionFinalization.Common.ps1')
. (Join-Path $RepositoryRoot 'scripts\NxbV1Cli.Common.ps1')

$cliPolicy = Get-NxbV1CliPolicy -RepositoryRoot $RepositoryRoot
$commandData = $null
$mutationPerformed = $false
$successMessage = 'Command completed successfully.'
$envelope = $null
if ($NonInteractive -and -not $CliProcess) {
    throw (Get-NxbV1CliFailure -Policy $cliPolicy -Category 'usage' -Message '-NonInteractive requires -CliProcess so prompt-free process semantics and exit codes are explicit.')
}
if ($NonInteractive) { $successMessage = 'Command completed successfully in non-interactive mode.' }

try {
    switch ($Command) {
        'status' {
            $policyPath = Join-Path $RepositoryRoot 'config\nxb-production-finalization-policy.json'
            $policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
            $releaseAuthority = $cliPolicy.release_authority
            $statusPolicy = $cliPolicy.status
            if (
                $null -eq $releaseAuthority -or
                $null -eq $statusPolicy -or
                [string]$statusPolicy.contract_id -cne 'nxb-v1-cli-status-v2' -or
                [string]$statusPolicy.historical_policy_path -cne 'config/nxb-production-finalization-policy.json' -or
                [string]$releaseAuthority.state -cne 'released' -or
                $releaseAuthority.production_release -isnot [bool] -or
                -not [bool]$releaseAuthority.production_release -or
                [int]$releaseAuthority.release_sequence -ne 2 -or
                [string]$releaseAuthority.tag -cne 'v1.0.1' -or
                [string]$releaseAuthority.head -cnotmatch '^[0-9a-f]{40}$' -or
                [string]$releaseAuthority.tree -cnotmatch '^[0-9a-f]{40}$' -or
                [string]$releaseAuthority.final_closure_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
                [string]$releaseAuthority.predecessor_version -cne '1.0.0' -or
                [string]$releaseAuthority.predecessor_head -cne 'a4f1b242c003333b1f34b1cd54ca37cab33fbf4f' -or
                [string]$policy.part10.release_version -cne '1.0.0-candidate' -or
                [string]$cliPolicy.target_version -cne '1.0.1'
            ) {
                throw (Get-NxbV1CliFailure -Policy $cliPolicy -Category 'trust_integrity' -Message 'Post-release CLI status authority is incomplete or inconsistent.')
            }
            $commandData = [pscustomobject][ordered]@{
                contract_id = [string]$policy.contract_id
                release_version = [string]$policy.part10.release_version
                production_merge_performed = $false
                update_mode = 'staged-only'
                signed_update_mode = 'explicit-stage-apply-rollback'
                certified_update_head = [string]$cliPolicy.predecessor_update_head
                status_contract_id = [string]$statusPolicy.contract_id
                historical_contract_id = [string]$policy.contract_id
                historical_release_version = [string]$policy.part10.release_version
                historical_production_merge_performed = $false
                target_version = [string]$cliPolicy.target_version
                release_state = [string]$releaseAuthority.state
                production_release = [bool]$releaseAuthority.production_release
                production_release_tag = [string]$releaseAuthority.tag
                production_release_head = [string]$releaseAuthority.head
                production_release_tree = [string]$releaseAuthority.tree
                production_final_closure_sha256 = [string]$releaseAuthority.final_closure_sha256
            }
            break
        }
        'version' {
            $releaseAuthority = $cliPolicy.release_authority
            if (
                $null -eq $releaseAuthority -or
                [string]$releaseAuthority.state -cne 'released' -or
                $releaseAuthority.production_release -isnot [bool] -or
                -not [bool]$releaseAuthority.production_release -or
                [string]$releaseAuthority.tag -cne 'v1.0.1' -or
                [string]$releaseAuthority.head -cnotmatch '^[0-9a-f]{40}$' -or
                [string]$releaseAuthority.final_closure_sha256 -cnotmatch '^[0-9a-f]{64}$'
            ) {
                throw (Get-NxbV1CliFailure -Policy $cliPolicy -Category 'trust_integrity' -Message 'Post-release CLI version authority is incomplete or inconsistent.')
            }
            $commandData = [pscustomobject][ordered]@{
                version = [string]$cliPolicy.target_version
                cli_contract = [string]$cliPolicy.contract_id
                release_state = [string]$releaseAuthority.state
                certified_update_head = [string]$cliPolicy.predecessor_update_head
                production_release = [bool]$releaseAuthority.production_release
                production_release_tag = [string]$releaseAuthority.tag
                production_release_head = [string]$releaseAuthority.head
                production_final_closure_sha256 = [string]$releaseAuthority.final_closure_sha256
            }
            break
        }
        'hash' {
            Assert-NxbV1CliValue -Policy $cliPolicy -Value $Path -Name '-Path'
            $commandData = [pscustomobject][ordered]@{
                path = [IO.Path]::GetFullPath($Path)
                sha256 = Get-NxbFinalFileSha256 -Path $Path
            }
            break
        }
        'inspect-manifest' {
            Assert-NxbV1CliValue -Policy $cliPolicy -Value $Path -Name '-Path'
            Assert-NxbV1CliValue -Policy $cliPolicy -Value $ExpectedVersion -Name '-ExpectedVersion'
            $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            $valid = Test-NxbFinalPackageManifest -Manifest $manifest -ExpectedVersion $ExpectedVersion
            $seenPath = @{}
            foreach ($file in @($manifest.files)) {
                $relative = [string]$file.path
                if ([string]::IsNullOrWhiteSpace($relative) -or $relative -match '(^/|^[A-Za-z]:|(^|/)\.\.(/|$)|\\)' -or $seenPath.ContainsKey($relative)) {
                    $valid = $false
                    break
                }
                $seenPath[$relative] = $true
            }
            $commandData = [pscustomobject][ordered]@{
                valid = [bool]$valid
                path = [IO.Path]::GetFullPath($Path)
            }
            break
        }
        'stage-update' {
            Assert-NxbV1CliValue -Policy $cliPolicy -Value $Path -Name '-Path'
            Assert-NxbV1CliValue -Policy $cliPolicy -Value $ExpectedVersion -Name '-ExpectedVersion'
            Assert-NxbV1CliValue -Policy $cliPolicy -Value $StagingRoot -Name '-StagingRoot'
            if ($CliProcess -and -not $DryRun -and -not $ConfirmMutation) {
                throw (Get-NxbV1CliFailure -Policy $cliPolicy -Category 'usage' -Message 'stage-update requires -ConfirmMutation in CLI process mode or -DryRun.')
            }
            $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            if (-not (Test-NxbFinalPackageManifest -Manifest $manifest -ExpectedVersion $ExpectedVersion)) {
                throw (Get-NxbV1CliFailure -Policy $cliPolicy -Category 'trust_integrity' -Message 'Package manifest failed validation before staging.')
            }
            $stageFull = [IO.Path]::GetFullPath($StagingRoot)
            if (Test-Path -LiteralPath $stageFull) {
                throw (Get-NxbV1CliFailure -Policy $cliPolicy -Category 'state_precondition' -Message 'Staging root must not already exist.')
            }
            $seenPath = @{}
            $fileMap = @{}
            foreach ($file in @($manifest.files)) {
                $relative = [string]$file.path
                if ([string]::IsNullOrWhiteSpace($relative) -or $relative -match '(^/|^[A-Za-z]:|(^|/)\.\.(/|$)|\\)' -or $seenPath.ContainsKey($relative)) {
                    throw (Get-NxbV1CliFailure -Policy $cliPolicy -Category 'trust_integrity' -Message ('Unsafe or duplicate package relative path: {0}' -f $relative))
                }
                $seenPath[$relative] = $true
                $fileMap[$relative] = $file
            }
            $paths = [string[]]@($fileMap.Keys)
            [Array]::Sort($paths,[StringComparer]::Ordinal)
            if ($DryRun) {
                $commandData = [pscustomobject][ordered]@{
                    status = 'verified'
                    staging_root = $stageFull
                    file_count = $paths.Count
                    files = @()
                    auto_apply = $false
                    dry_run = $true
                }
                break
            }
            [IO.Directory]::CreateDirectory($stageFull) | Out-Null
            $mutationPerformed = $true
            $staged = [Collections.Generic.List[object]]::new()
            foreach ($relative in $paths) {
                $file = $fileMap[$relative]
                $source = Join-Path $RepositoryRoot $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
                if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                    throw (Get-NxbV1CliFailure -Policy $cliPolicy -Category 'trust_integrity' -Message ('Package source missing: {0}' -f $relative))
                }
                $sourceSha = Get-NxbFinalFileSha256 -Path $source
                if ($sourceSha -cne [string]$file.sha256) {
                    throw (Get-NxbV1CliFailure -Policy $cliPolicy -Category 'trust_integrity' -Message ('Package source SHA-256 mismatch: {0}' -f $relative))
                }
                $destination = Join-Path $stageFull $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
                $parent = Split-Path -Parent $destination
                [IO.Directory]::CreateDirectory($parent) | Out-Null
                [IO.File]::Copy($source,$destination,$false)
                $destinationSha = Get-NxbFinalFileSha256 -Path $destination
                if ($destinationSha -cne [string]$file.sha256) {
                    throw (Get-NxbV1CliFailure -Policy $cliPolicy -Category 'mutation_runtime' -Message ('Staged file SHA-256 mismatch: {0}' -f $relative))
                }
                $staged.Add([pscustomobject][ordered]@{ path=$relative; sha256=$destinationSha; bytes=[int64](Get-Item -LiteralPath $destination).Length })
            }
            $commandData = [pscustomobject][ordered]@{
                status = 'staged'
                staging_root = $stageFull
                file_count = $staged.Count
                files = @($staged)
                auto_apply = $false
            }
            break
        }
        'certify-final' {
            Assert-NxbV1CliValue -Policy $cliPolicy -Value $ExpectedHead -Name '-ExpectedHead'
            Assert-NxbV1CliValue -Policy $cliPolicy -Value $OutputDirectory -Name '-OutputDirectory'
            $finalAuthority = Join-Path $RepositoryRoot 'scripts\Invoke-NxbProductionFinalCertificationV2.ps1'
            try {
                $finalPipeline = @(& $finalAuthority -ExpectedHead $ExpectedHead -OutputDirectory $OutputDirectory -PassThru 3>$null 4>$null 5>$null 6>$null)
                $commandData = $null
                foreach ($item in $finalPipeline) {
                    if ($null -eq $item) { continue }
                    $statusProperty = $item.PSObject.Properties['status']
                    if ($null -ne $statusProperty -and [string]$statusProperty.Value -ceq 'passed') { $commandData = $item }
                }
                if ($null -eq $commandData) { throw 'Final certification authority returned no passed result.' }
            }
            catch {
                throw (Get-NxbV1CliFailure -Policy $cliPolicy -Category 'certification' -Message $_.Exception.Message)
            }
            break
        }
        'doctor' {
            $commandData = Invoke-NxbV1CliDoctor -Policy $cliPolicy -RepositoryRoot $RepositoryRoot
            break
        }
        'config-validate' {
            $effectiveConfigPath = $ConfigPath
            if ([string]::IsNullOrWhiteSpace($effectiveConfigPath)) { $effectiveConfigPath = $Path }
            Assert-NxbV1CliValue -Policy $cliPolicy -Value $effectiveConfigPath -Name '-ConfigPath'
            try { $document = Get-Content -LiteralPath $effectiveConfigPath -Raw | ConvertFrom-Json }
            catch { throw (Get-NxbV1CliFailure -Policy $cliPolicy -Category 'config' -Message $_.Exception.Message) }
            $validConfig = Test-NxbV1CliConfigDocument -Document $document
            if (-not $validConfig) { throw (Get-NxbV1CliFailure -Policy $cliPolicy -Category 'config' -Message 'CLI configuration failed strict validation.') }
            $commandData = [pscustomobject][ordered]@{
                valid = $true
                path = [IO.Path]::GetFullPath($effectiveConfigPath)
                contract_id = [string]$document.contract_id
            }
            break
        }
        'evidence-verify' {
            Assert-NxbV1CliValue -Policy $cliPolicy -Value $ExperimentPath -Name '-ExperimentPath'
            $commandData = Invoke-NxbV1CliEvidenceVerification -Policy $cliPolicy -RepositoryRoot $RepositoryRoot -ExperimentPath $ExperimentPath -BundlePath $BundlePath -CertificatePath $CertificatePath
            break
        }
        'update-check' {
            foreach ($required in @(
                @('-InstallRoot',$InstallRoot),@('-UpdateRoot',$UpdateRoot),@('-ReceiptPath',$ReceiptPath),@('-PackageRoot',$PackageRoot),
                @('-ManifestPath',$ManifestPath),@('-DescriptorPath',$DescriptorPath),@('-EnvelopePath',$EnvelopePath),@('-TrustPath',$TrustPath)
            )) { Assert-NxbV1CliValue -Policy $cliPolicy -Value ([string]$required[1]) -Name ([string]$required[0]) }
            $commandData = Invoke-NxbV1CliSignedUpdate -Policy $cliPolicy -RepositoryRoot $RepositoryRoot -Mode Check -InstallRoot $InstallRoot -UpdateRoot $UpdateRoot -ReceiptPath $ReceiptPath -PackageRoot $PackageRoot -ManifestPath $ManifestPath -DescriptorPath $DescriptorPath -EnvelopePath $EnvelopePath -TrustPath $TrustPath -DryRun
            break
        }
        'update-stage' {
            foreach ($required in @(
                @('-InstallRoot',$InstallRoot),@('-UpdateRoot',$UpdateRoot),@('-ReceiptPath',$ReceiptPath),@('-PackageRoot',$PackageRoot),
                @('-ManifestPath',$ManifestPath),@('-DescriptorPath',$DescriptorPath),@('-EnvelopePath',$EnvelopePath),@('-TrustPath',$TrustPath)
            )) { Assert-NxbV1CliValue -Policy $cliPolicy -Value ([string]$required[1]) -Name ([string]$required[0]) }
            if (-not $DryRun -and -not $ConfirmMutation) { throw (Get-NxbV1CliFailure -Policy $cliPolicy -Category 'usage' -Message 'update-stage requires -ConfirmMutation or -DryRun.') }
            if ($DryRun) {
                $commandData = Invoke-NxbV1CliSignedUpdate -Policy $cliPolicy -RepositoryRoot $RepositoryRoot -Mode Stage -InstallRoot $InstallRoot -UpdateRoot $UpdateRoot -ReceiptPath $ReceiptPath -PackageRoot $PackageRoot -ManifestPath $ManifestPath -DescriptorPath $DescriptorPath -EnvelopePath $EnvelopePath -TrustPath $TrustPath -DryRun
            }
            else {
                $null = Invoke-NxbV1CliSignedUpdate -Policy $cliPolicy -RepositoryRoot $RepositoryRoot -Mode Stage -InstallRoot $InstallRoot -UpdateRoot $UpdateRoot -ReceiptPath $ReceiptPath -PackageRoot $PackageRoot -ManifestPath $ManifestPath -DescriptorPath $DescriptorPath -EnvelopePath $EnvelopePath -TrustPath $TrustPath -DryRun
                $mutationPerformed = $true
                $commandData = Invoke-NxbV1CliSignedUpdate -Policy $cliPolicy -RepositoryRoot $RepositoryRoot -Mode Stage -InstallRoot $InstallRoot -UpdateRoot $UpdateRoot -ReceiptPath $ReceiptPath -PackageRoot $PackageRoot -ManifestPath $ManifestPath -DescriptorPath $DescriptorPath -EnvelopePath $EnvelopePath -TrustPath $TrustPath
            }
            break
        }
        'update-apply' {
            foreach ($required in @(@('-InstallRoot',$InstallRoot),@('-UpdateRoot',$UpdateRoot),@('-ReceiptPath',$ReceiptPath),@('-TrustPath',$TrustPath))) {
                Assert-NxbV1CliValue -Policy $cliPolicy -Value ([string]$required[1]) -Name ([string]$required[0])
            }
            if (-not $DryRun -and -not $ConfirmMutation) { throw (Get-NxbV1CliFailure -Policy $cliPolicy -Category 'usage' -Message 'update-apply requires -ConfirmMutation or -DryRun.') }
            if ($DryRun) {
                $commandData = Invoke-NxbV1CliSignedUpdate -Policy $cliPolicy -RepositoryRoot $RepositoryRoot -Mode Apply -InstallRoot $InstallRoot -UpdateRoot $UpdateRoot -ReceiptPath $ReceiptPath -TrustPath $TrustPath -DryRun
            }
            else {
                $null = Invoke-NxbV1CliSignedUpdate -Policy $cliPolicy -RepositoryRoot $RepositoryRoot -Mode Apply -InstallRoot $InstallRoot -UpdateRoot $UpdateRoot -ReceiptPath $ReceiptPath -TrustPath $TrustPath -DryRun
                $mutationPerformed = $true
                $commandData = Invoke-NxbV1CliSignedUpdate -Policy $cliPolicy -RepositoryRoot $RepositoryRoot -Mode Apply -InstallRoot $InstallRoot -UpdateRoot $UpdateRoot -ReceiptPath $ReceiptPath -TrustPath $TrustPath
            }
            break
        }
        'update-rollback' {
            foreach ($required in @(@('-InstallRoot',$InstallRoot),@('-UpdateRoot',$UpdateRoot),@('-ReceiptPath',$ReceiptPath))) {
                Assert-NxbV1CliValue -Policy $cliPolicy -Value ([string]$required[1]) -Name ([string]$required[0])
            }
            if (-not $DryRun -and -not $ConfirmMutation) { throw (Get-NxbV1CliFailure -Policy $cliPolicy -Category 'usage' -Message 'update-rollback requires -ConfirmMutation or -DryRun.') }
            if ($DryRun) {
                $commandData = Invoke-NxbV1CliSignedUpdate -Policy $cliPolicy -RepositoryRoot $RepositoryRoot -Mode Rollback -InstallRoot $InstallRoot -UpdateRoot $UpdateRoot -ReceiptPath $ReceiptPath -DryRun
            }
            else {
                $null = Invoke-NxbV1CliSignedUpdate -Policy $cliPolicy -RepositoryRoot $RepositoryRoot -Mode Rollback -InstallRoot $InstallRoot -UpdateRoot $UpdateRoot -ReceiptPath $ReceiptPath -DryRun
                $mutationPerformed = $true
                $commandData = Invoke-NxbV1CliSignedUpdate -Policy $cliPolicy -RepositoryRoot $RepositoryRoot -Mode Rollback -InstallRoot $InstallRoot -UpdateRoot $UpdateRoot -ReceiptPath $ReceiptPath
            }
            break
        }
    }
    $envelope = ConvertTo-NxbV1CliEnvelope -Policy $cliPolicy -Command $Command -Status passed -Category success -Message $successMessage -MutationPerformed $mutationPerformed -Data $commandData
}
catch {
    if (-not $CliProcess -and -not $Json) { throw }
    $envelope = ConvertTo-NxbV1CliFailureEnvelope -Policy $cliPolicy -Command $Command -ErrorRecord $_
    $envelope.mutation_performed = $mutationPerformed
}

if (-not $CliProcess -and -not $Json) {
    Write-Output $commandData
    return
}

if ($Json) {
    [Console]::Out.WriteLine(($envelope | ConvertTo-Json -Depth 32 -Compress))
}
elseif ([string]$envelope.status -ceq 'passed') {
    [Console]::Out.WriteLine(('NXB {0}: PASS' -f $Command))
    if ($null -ne $envelope.data) { [Console]::Out.WriteLine(($envelope.data | ConvertTo-Json -Depth 32)) }
}
else {
    [Console]::Error.WriteLine(('NXB {0}: {1}: {2}' -f $Command,[string]$envelope.category,[string]$envelope.message))
}

if ($CliProcess) { $Host.SetShouldExit([int]$envelope.exit_code) }
