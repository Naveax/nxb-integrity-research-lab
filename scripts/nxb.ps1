[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('status','hash','inspect-manifest','certify-final')][string]$Command,
    [Parameter()][string]$Path,
    [Parameter()][string]$ExpectedVersion,
    [Parameter()][string]$ExpectedHead,
    [Parameter()][string]$OutputDirectory
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
        [pscustomobject][ordered]@{
            valid = Test-NxbFinalPackageManifest -Manifest $manifest -ExpectedVersion $ExpectedVersion
            path = [IO.Path]::GetFullPath($Path)
        }
        break
    }
    'certify-final' {
        if ([string]::IsNullOrWhiteSpace($ExpectedHead)) { throw '-ExpectedHead is required for certify-final.' }
        if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { throw '-OutputDirectory is required for certify-final.' }
        & (Join-Path $RepositoryRoot 'scripts\Invoke-NxbProductionFinalCertification.ps1') -ExpectedHead $ExpectedHead -OutputDirectory $OutputDirectory
        break
    }
}
