[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PackageRoot,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$SourceHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path -Path $PSScriptRoot -ChildPath 'NxbV1Installer.Common.ps1')

$policyPath = Join-Path -Path $repositoryRoot -ChildPath 'config\nxb-v1-installer-policy.json'
$policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
if ([string]$policy.contract_id -cne 'nxb-v1-installer-v1' -or [int]$policy.schema_version -ne 1) { throw 'NXB v1 installer policy identity drift.' }

$outputFull = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $outputFull) { throw 'Package manifest output already exists.' }
$outputParent = Split-Path -Parent $outputFull
if ([string]::IsNullOrWhiteSpace($outputParent) -or -not (Test-Path -LiteralPath $outputParent -PathType Container)) { throw 'Package manifest output parent must already exist.' }
if (-not (Test-NxbV1InstallerPathChainNoReparse -Path $outputParent)) { throw 'Package manifest output parent is a reparse point or traverses one.' }

$manifest = Get-NxbV1PackageManifest `
    -PackageRoot $PackageRoot `
    -SourceHead $SourceHead `
    -MaximumFiles ([int]$policy.maximum_files) `
    -MaximumBytes ([int64]$policy.maximum_package_bytes)
if (-not (Test-NxbV1PackageManifestObject -Manifest $manifest -MaximumFiles ([int]$policy.maximum_files) -MaximumBytes ([int64]$policy.maximum_package_bytes))) { throw 'Generated package manifest failed its own strict contract.' }
if (-not (Test-NxbV1PackageAgainstManifest -PackageRoot $PackageRoot -Manifest $manifest)) { throw 'Generated package manifest does not bind the package bytes.' }

$json = ($manifest | ConvertTo-Json -Depth 10) + [Environment]::NewLine
[IO.File]::WriteAllText($outputFull,$json,[Text.UTF8Encoding]::new($false))
if ($PassThru) { $manifest }
if (-not $PassThru) { Write-Information ('NXB v1 package manifest exported: files={0} bytes={1} output={2}' -f [int]$manifest.file_count,[int64]$manifest.total_bytes,$outputFull) }
