[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('status','hash','inspect-manifest','stage-update','certify-final')][string]$Command,
    [Parameter()][string]$Path,
    [Parameter()][string]$ExpectedVersion,
    [Parameter()][string]$ExpectedHead,
    [Parameter()][string]$OutputDirectory,
    [Parameter()][string]$StagingRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $RepositoryRoot 'scripts\NxbProductionFinalization.Common.ps1')

switch ($Command) {
    'status' {
        $policyPath = Join-Path $RepositoryRoot 'config\nxb-production-finalization-policy.json'
        $policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
        [pscustomobject][ordered]@{
            contract_id = [string]$policy.contract_id
            release_version = [string]$policy.part10.release_version
            production_merge_performed = $false
            update_mode = 'staged-only'
        }
        break
    }
    'hash' {
        if ([string]::IsNullOrWhiteSpace($Path)) { throw '-Path is required for hash.' }
        [pscustomobject][ordered]@{
            path = [IO.Path]::GetFullPath($Path)
            sha256 = Get-NxbFinalFileSha256 -Path $Path
        }
        break
    }
    'inspect-manifest' {
        if ([string]::IsNullOrWhiteSpace($Path)) { throw '-Path is required for inspect-manifest.' }
        if ([string]::IsNullOrWhiteSpace($ExpectedVersion)) { throw '-ExpectedVersion is required for inspect-manifest.' }
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
        [pscustomobject][ordered]@{
            valid = [bool]$valid
            path = [IO.Path]::GetFullPath($Path)
        }
        break
    }
    'stage-update' {
        if ([string]::IsNullOrWhiteSpace($Path)) { throw '-Path is required for stage-update.' }
        if ([string]::IsNullOrWhiteSpace($ExpectedVersion)) { throw '-ExpectedVersion is required for stage-update.' }
        if ([string]::IsNullOrWhiteSpace($StagingRoot)) { throw '-StagingRoot is required for stage-update.' }
        $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if (-not (Test-NxbFinalPackageManifest -Manifest $manifest -ExpectedVersion $ExpectedVersion)) {
            throw 'Package manifest failed validation before staging.'
        }
        $stageFull = [IO.Path]::GetFullPath($StagingRoot)
        if (Test-Path -LiteralPath $stageFull) { throw 'Staging root must not already exist.' }
        [IO.Directory]::CreateDirectory($stageFull) | Out-Null
        $staged = [Collections.Generic.List[object]]::new()
        $seenPath = @{}
        foreach ($file in @($manifest.files | Sort-Object path)) {
            $relative = [string]$file.path
            if ([string]::IsNullOrWhiteSpace($relative) -or $relative -match '(^/|^[A-Za-z]:|(^|/)\.\.(/|$)|\\)' -or $seenPath.ContainsKey($relative)) {
                throw ('Unsafe or duplicate package relative path: {0}' -f $relative)
            }
            $seenPath[$relative] = $true
            $source = Join-Path $RepositoryRoot $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw ('Package source missing: {0}' -f $relative) }
            $sourceSha = Get-NxbFinalFileSha256 -Path $source
            if ($sourceSha -cne [string]$file.sha256) { throw ('Package source SHA-256 mismatch: {0}' -f $relative) }
            $destination = Join-Path $stageFull $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
            $parent = Split-Path -Parent $destination
            [IO.Directory]::CreateDirectory($parent) | Out-Null
            [IO.File]::Copy($source,$destination,$false)
            $destinationSha = Get-NxbFinalFileSha256 -Path $destination
            if ($destinationSha -cne [string]$file.sha256) { throw ('Staged file SHA-256 mismatch: {0}' -f $relative) }
            $staged.Add([pscustomobject][ordered]@{ path=$relative; sha256=$destinationSha; bytes=[int64](Get-Item -LiteralPath $destination).Length })
        }
        [pscustomobject][ordered]@{
            status = 'staged'
            staging_root = $stageFull
            file_count = $staged.Count
            files = @($staged)
            auto_apply = $false
        }
        break
    }
    'certify-final' {
        if ([string]::IsNullOrWhiteSpace($ExpectedHead)) { throw '-ExpectedHead is required for certify-final.' }
        if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { throw '-OutputDirectory is required for certify-final.' }
        & (Join-Path $RepositoryRoot 'scripts\Invoke-NxbProductionFinalCertificationV2.ps1') -ExpectedHead $ExpectedHead -OutputDirectory $OutputDirectory
        break
    }
}
