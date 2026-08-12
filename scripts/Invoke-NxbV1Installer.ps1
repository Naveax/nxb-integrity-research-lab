[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][ValidateSet('Stage','Install','Repair','Uninstall')][string]$Action,
    [Parameter(Mandatory)][ValidateSet('Portable','PerUser','PerMachine')][string]$Mode,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PackageRoot,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ManifestPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$InstallRoot,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ReceiptPath,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path -Path $PSScriptRoot -ChildPath 'NxbV1Installer.Common.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'NxbV1Installer.State.ps1')

function Invoke-NxbV1InstallerPopulateStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StageRoot,
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][string]$InstallMode,
        [Parameter(Mandatory)][string]$FinalInstallRoot,
        [Parameter(Mandatory)][string]$ManifestSha256
    )
    if (Test-Path -LiteralPath $StageRoot) { throw 'Installer staging root already exists.' }
    [IO.Directory]::CreateDirectory($StageRoot) | Out-Null
    try {
        foreach ($file in @($Manifest.files)) {
            $relative = [string]$file.path
            $nativeRelative = $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
            $source = [IO.Path]::GetFullPath((Join-Path -Path $PackageRoot -ChildPath $nativeRelative))
            $destination = [IO.Path]::GetFullPath((Join-Path -Path $StageRoot -ChildPath $nativeRelative))
            $destinationParent = Split-Path -Parent $destination
            if (-not [string]::IsNullOrWhiteSpace($destinationParent)) { [IO.Directory]::CreateDirectory($destinationParent) | Out-Null }
            [IO.File]::Copy($source,$destination,$false)
        }
        if (-not (Test-NxbV1PackageAgainstManifest -PackageRoot $StageRoot -Manifest $Manifest)) { throw 'Staged package bytes failed manifest verification.' }
        $state = Get-NxbV1InstallerStateDocument -Manifest $Manifest -InstallMode $InstallMode -InstallRoot $FinalInstallRoot -ManifestSha256 $ManifestSha256
        $statePath = Get-NxbV1InstallerStatePath -InstallRoot $StageRoot
        [IO.File]::WriteAllText($statePath,(($state | ConvertTo-Json -Depth 6)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
        if (-not (Test-NxbV1InstalledRootAgainstManifest -InstallRoot $StageRoot -Manifest $Manifest)) { throw 'Staged installed root failed post-state verification.' }
        return $state
    }
    catch {
        if (Test-Path -LiteralPath $StageRoot) { Remove-Item -LiteralPath $StageRoot -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
}

$policyPath = Join-Path -Path $repositoryRoot -ChildPath 'config\nxb-v1-installer-policy.json'
$policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
if ([string]$policy.contract_id -cne 'nxb-v1-installer-v1' -or [int]$policy.schema_version -ne 1) { throw 'NXB v1 installer policy identity drift.' }
if ($Action -ceq 'Stage' -and $Mode -cne 'Portable') { throw 'Stage action requires Portable mode.' }
if ($Action -ceq 'Install' -and $Mode -ceq 'Portable') { throw 'Portable mode must use Stage instead of Install.' }

$packageFull = [IO.Path]::GetFullPath($PackageRoot)
$manifestFull = [IO.Path]::GetFullPath($ManifestPath)
$installFull = [IO.Path]::GetFullPath($InstallRoot)
$receiptFull = [IO.Path]::GetFullPath($ReceiptPath)
if (-not (Test-Path -LiteralPath $packageFull -PathType Container)) { throw 'PackageRoot does not exist.' }
if (-not (Test-Path -LiteralPath $manifestFull -PathType Leaf)) { throw 'Package manifest does not exist.' }
if (-not (Test-NxbV1InstallerPathChainNoReparse -Path $packageFull) -or -not (Test-NxbV1InstallerPathChainNoReparse -Path $manifestFull)) { throw 'Package or manifest path traverses a reparse point.' }
if (Test-Path -LiteralPath $receiptFull) { throw 'Installer receipt output already exists.' }
$receiptParent = Split-Path -Parent $receiptFull
if ([string]::IsNullOrWhiteSpace($receiptParent) -or -not (Test-Path -LiteralPath $receiptParent -PathType Container) -or -not (Test-NxbV1InstallerPathChainNoReparse -Path $receiptParent)) { throw 'Installer receipt parent must be an existing non-reparse directory.' }
$trimChars = [char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
$installPrefix = $installFull.TrimEnd($trimChars) + [IO.Path]::DirectorySeparatorChar
if ($receiptFull -ceq $installFull -or $receiptFull.StartsWith($installPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Installer receipt must be outside InstallRoot.' }

$manifest = Get-Content -LiteralPath $manifestFull -Raw | ConvertFrom-Json
if (-not (Test-NxbV1PackageManifestObject -Manifest $manifest -MaximumFiles ([int]$policy.maximum_files) -MaximumBytes ([int64]$policy.maximum_package_bytes))) { throw 'Package manifest failed strict validation.' }
if (-not (Test-NxbV1PackageAgainstManifest -PackageRoot $packageFull -Manifest $manifest)) { throw 'Package bytes do not match manifest.' }
$manifestSha = Get-NxbV1InstallerSha256 -Path $manifestFull

$requireExisting = ($Action -ceq 'Repair' -or $Action -ceq 'Uninstall')
$requireAbsent = ($Action -ceq 'Stage' -or $Action -ceq 'Install')
if (-not (Test-NxbV1InstallerRoot -Path $installFull -RepositoryRoot $repositoryRoot -RequireExisting:$requireExisting -RequireAbsent:$requireAbsent)) { throw 'InstallRoot violates installer root policy.' }

if ($Mode -ceq 'PerMachine') {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'PerMachine installer mode requires Administrator.' }
    }
    finally { $identity.Dispose() }
}

$existingState = $null
if ($requireExisting) {
    $existingState = Get-NxbV1InstallerStateObject -InstallRoot $installFull
    if ([string]$existingState.install_root -cne $installFull -or [string]$existingState.install_mode -cne $Mode -or [string]$existingState.source_head -cne [string]$manifest.source_head -or [string]$existingState.package_manifest_sha256 -cne $manifestSha) { throw 'Managed install state does not match requested package/mode/root.' }
}

$rollbackUsed = $false
$filesVerified = [int]$manifest.file_count
$bytesVerified = [int64]$manifest.total_bytes
$operationSucceeded = $false
$stagingRoot = $null
$backupRoot = $null

if (-not $PSCmdlet.ShouldProcess($installFull,('NXB v1 installer action {0} ({1})' -f $Action,$Mode))) { throw 'Installer operation was not approved.' }

try {
    if ($Action -ceq 'Stage' -or $Action -ceq 'Install') {
        $stagingRoot = $installFull + '.nxb-stage-' + [Guid]::NewGuid().ToString('N')
        [void](Invoke-NxbV1InstallerPopulateStage -StageRoot $stagingRoot -PackageRoot $packageFull -Manifest $manifest -InstallMode $Mode -FinalInstallRoot $installFull -ManifestSha256 $manifestSha)
        [IO.Directory]::Move($stagingRoot,$installFull)
        $stagingRoot = $null
        if (-not (Test-NxbV1InstalledRootAgainstManifest -InstallRoot $installFull -Manifest $manifest)) { throw 'Installed root failed post-move verification.' }
        $installedState = Get-NxbV1InstallerStateObject -InstallRoot $installFull
        if ([string]$installedState.package_manifest_sha256 -cne $manifestSha) { throw 'Installed state manifest binding failed.' }
    }
    elseif ($Action -ceq 'Repair') {
        $stagingRoot = $installFull + '.nxb-repair-' + [Guid]::NewGuid().ToString('N')
        $backupRoot = $installFull + '.nxb-backup-' + [Guid]::NewGuid().ToString('N')
        [void](Invoke-NxbV1InstallerPopulateStage -StageRoot $stagingRoot -PackageRoot $packageFull -Manifest $manifest -InstallMode $Mode -FinalInstallRoot $installFull -ManifestSha256 $manifestSha)
        [IO.Directory]::Move($installFull,$backupRoot)
        try {
            [IO.Directory]::Move($stagingRoot,$installFull)
            $stagingRoot = $null
            if (-not (Test-NxbV1InstalledRootAgainstManifest -InstallRoot $installFull -Manifest $manifest)) { throw 'Repaired root failed verification.' }
            $repairedState = Get-NxbV1InstallerStateObject -InstallRoot $installFull
            if ([string]$repairedState.package_manifest_sha256 -cne $manifestSha) { throw 'Repaired state manifest binding failed.' }
        }
        catch {
            $rollbackUsed = $true
            if (Test-Path -LiteralPath $installFull) { Remove-Item -LiteralPath $installFull -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $backupRoot) { [IO.Directory]::Move($backupRoot,$installFull); $backupRoot=$null }
            throw
        }
        if (Test-Path -LiteralPath $backupRoot) { Remove-Item -LiteralPath $backupRoot -Recurse -Force; $backupRoot=$null }
    }
    else {
        if (-not (Test-NxbV1InstalledRootAgainstManifest -InstallRoot $installFull -Manifest $manifest)) { throw 'Uninstall requires an intact managed package; run Repair first.' }
        Remove-Item -LiteralPath $installFull -Recurse -Force
        if (Test-Path -LiteralPath $installFull) { throw 'Uninstall failed to remove managed InstallRoot.' }
    }
    $operationSucceeded = $true
}
finally {
    if (-not $operationSucceeded) {
        if ($null -ne $stagingRoot -and (Test-Path -LiteralPath $stagingRoot)) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue }
        if ($null -ne $backupRoot -and (Test-Path -LiteralPath $backupRoot) -and -not (Test-Path -LiteralPath $installFull)) {
            try { [IO.Directory]::Move($backupRoot,$installFull); $rollbackUsed=$true } catch { Write-Verbose 'Installer rollback move did not complete.' }
        }
    }
}

$receiptFilesVerified = $filesVerified
$receiptBytesVerified = $bytesVerified
if ($Action -ceq 'Uninstall') {
    $receiptFilesVerified = [int]$existingState.managed_file_count
    $receiptBytesVerified = [int64]$existingState.managed_total_bytes
}
$receipt = [pscustomobject][ordered]@{
    schema_version=1
    status='passed'
    authority='nxb-v1-installer-operation-v1'
    action=$Action
    install_mode=$Mode
    release_version='1.0.0'
    source_head=[string]$manifest.source_head
    install_root=$installFull
    package_manifest_sha256=$manifestSha
    files_verified=$receiptFilesVerified
    bytes_verified=$receiptBytesVerified
    data_removed=$false
    evidence_removed=$false
    rollback_used=$rollbackUsed
    created_utc=[DateTime]::UtcNow.ToString('o')
}
[IO.File]::WriteAllText($receiptFull,(($receipt | ConvertTo-Json -Depth 6)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
if ($PassThru) { $receipt }
if (-not $PassThru) { Write-Information ('NXB v1 installer {0} passed: mode={1} files={2} bytes={3} root={4}' -f $Action,$Mode,[int]$receipt.files_verified,[int64]$receipt.bytes_verified,$installFull) }
