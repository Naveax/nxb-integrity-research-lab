Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NxbV1InstallerStatePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstallRoot)
    return (Join-Path -Path ([IO.Path]::GetFullPath($InstallRoot)) -ChildPath '.nxb-install-state.json')
}

function Get-NxbV1InstallerStateObject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstallRoot)
    $statePath = Get-NxbV1InstallerStatePath -InstallRoot $InstallRoot
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw 'Managed install state is missing.' }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ([int]$state.schema_version -ne 1 -or [string]$state.contract_id -cne 'nxb-v1-install-state-v1' -or [string]$state.release_version -cne '1.0.0') { throw 'Managed install state identity drift.' }
    if (-not (Test-NxbV1InstallerLowerHex -Text ([string]$state.source_head) -Length 40)) { throw 'Managed install state source head is invalid.' }
    if (-not (Test-NxbV1InstallerLowerHex -Text ([string]$state.package_manifest_sha256) -Length 64)) { throw 'Managed install state manifest hash is invalid.' }
    return $state
}

function Test-NxbV1InstalledRootAgainstManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][object]$Manifest)
    try {
        $root = [IO.Path]::GetFullPath($InstallRoot)
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $false }
        $trimChars = [char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
        $prefix = $root.TrimEnd($trimChars) + [IO.Path]::DirectorySeparatorChar
        $actual = @{}
        foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse -Force)) {
            if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            $full = [IO.Path]::GetFullPath($file.FullName)
            if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { return $false }
            $relative = $full.Substring($prefix.Length).Replace([IO.Path]::DirectorySeparatorChar,'/')
            if ($relative -ceq '.nxb-install-state.json') { continue }
            if ($actual.ContainsKey($relative)) { return $false }
            $actual[$relative] = [pscustomobject]@{ bytes=[int64]$file.Length; sha256=(Get-NxbV1InstallerSha256 -Path $full) }
        }
        if ($actual.Count -ne @($Manifest.files).Count) { return $false }
        foreach ($expected in @($Manifest.files)) {
            $path = [string]$expected.path
            if (-not $actual.ContainsKey($path)) { return $false }
            if ([int64]$actual[$path].bytes -ne [int64]$expected.bytes -or [string]$actual[$path].sha256 -cne [string]$expected.sha256) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Get-NxbV1InstallerStateDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][string]$InstallMode,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ManifestSha256,
        [Parameter()][string]$InstalledUtc = ([DateTime]::UtcNow.ToString('o'))
    )
    return [pscustomobject][ordered]@{
        schema_version=1
        contract_id='nxb-v1-install-state-v1'
        release_version='1.0.0'
        source_head=[string]$Manifest.source_head
        install_mode=$InstallMode
        install_root=[IO.Path]::GetFullPath($InstallRoot)
        package_manifest_sha256=$ManifestSha256
        installed_utc=$InstalledUtc
        managed_file_count=[int]$Manifest.file_count
        managed_total_bytes=[int64]$Manifest.total_bytes
    }
}
