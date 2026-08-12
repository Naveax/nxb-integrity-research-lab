Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NxbV1InstallerSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-NxbV1InstallerLowerHex {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text,[Parameter(Mandatory)][int]$Length)
    return ($Text.Length -eq $Length -and $Text -cmatch '^[0-9a-f]+$')
}

function Test-NxbV1InstallerRelativePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path.IndexOf('|',[StringComparison]::Ordinal) -ge 0 -or $Path.IndexOf("`r",[StringComparison]::Ordinal) -ge 0 -or $Path.IndexOf("`n",[StringComparison]::Ordinal) -ge 0 -or $Path.IndexOf('\',[StringComparison]::Ordinal) -ge 0) { return $false }
    if ($Path.StartsWith('/',[StringComparison]::Ordinal) -or $Path -match '^[A-Za-z]:') { return $false }
    if ($Path.StartsWith('../',[StringComparison]::Ordinal) -or $Path.EndsWith('/..',[StringComparison]::Ordinal) -or $Path.Contains('/../')) { return $false }
    foreach ($character in $Path.ToCharArray()) {
        if ([int][char]$character -lt 32 -or [int][char]$character -gt 126) { return $false }
    }
    return $true
}

function Test-NxbV1InstallerPathChainNoReparse {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        }
        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $cursor) { break }
        $cursor = $parent
    }
    return $true
}

function Test-NxbV1InstallerRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter()][switch]$RequireExisting,
        [Parameter()][switch]$RequireAbsent
    )
    try {
        $full = [IO.Path]::GetFullPath($Path)
        $repo = [IO.Path]::GetFullPath($RepositoryRoot)
        $root = [IO.Path]::GetPathRoot($full)
        $trimChars = [char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
        if ([string]::Equals($full.TrimEnd($trimChars),$root.TrimEnd($trimChars),[StringComparison]::OrdinalIgnoreCase)) { return $false }

        $windows = [IO.Path]::GetFullPath($env:WINDIR)
        $system = [IO.Path]::GetFullPath([Environment]::SystemDirectory)
        foreach ($forbidden in @($windows,$system,$repo)) {
            $prefix = $forbidden.TrimEnd($trimChars) + [IO.Path]::DirectorySeparatorChar
            if ([string]::Equals($full,$forbidden,[StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { return $false }
        }

        $parent = Split-Path -Parent $full
        if ([string]::IsNullOrWhiteSpace($parent) -or -not (Test-Path -LiteralPath $parent -PathType Container)) { return $false }
        if (-not (Test-NxbV1InstallerPathChainNoReparse -Path $parent)) { return $false }
        if (Test-Path -LiteralPath $full) {
            if (-not (Test-NxbV1InstallerPathChainNoReparse -Path $full)) { return $false }
            if ($RequireAbsent) { return $false }
        }
        elseif ($RequireExisting) { return $false }
        return $true
    }
    catch { return $false }
}

function Get-NxbV1PackageManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$SourceHead,
        [Parameter()][int]$MaximumFiles = 2048,
        [Parameter()][int64]$MaximumBytes = 1073741824,
        [Parameter()][string]$CreatedUtc = ([DateTime]::UtcNow.ToString('o'))
    )
    $root = [IO.Path]::GetFullPath($PackageRoot)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'PackageRoot does not exist.' }
    if (-not (Test-NxbV1InstallerPathChainNoReparse -Path $root)) { throw 'PackageRoot or an ancestor is a reparse point.' }

    $trimChars = [char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $prefix = $root.TrimEnd($trimChars) + [IO.Path]::DirectorySeparatorChar
    $rowMap = @{}
    $total = [int64]0
    foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse -Force)) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw ('Package file is a reparse point: {0}' -f $file.FullName) }
        $full = [IO.Path]::GetFullPath($file.FullName)
        if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw ('Package file escaped root: {0}' -f $full) }
        $relative = $full.Substring($prefix.Length).Replace([IO.Path]::DirectorySeparatorChar,[char]'/')
        if (-not (Test-NxbV1InstallerRelativePath -Path $relative)) { throw ('Unsafe package relative path: {0}' -f $relative) }
        if ($rowMap.ContainsKey($relative)) { throw ('Duplicate package relative path: {0}' -f $relative) }
        $total += [int64]$file.Length
        if ($total -gt $MaximumBytes) { throw 'Package exceeds maximum byte budget.' }
        $rowMap[$relative] = [pscustomobject][ordered]@{ path=$relative; bytes=[int64]$file.Length; sha256=(Get-NxbV1InstallerSha256 -Path $full) }
        if ($rowMap.Count -gt $MaximumFiles) { throw 'Package exceeds maximum file count.' }
    }
    if ($rowMap.Count -lt 1) { throw 'Package contains no files.' }
    $paths = [string[]]@($rowMap.Keys)
    [Array]::Sort($paths,[StringComparer]::Ordinal)
    $orderedRows = [Collections.Generic.List[object]]::new()
    foreach ($path in $paths) { $orderedRows.Add($rowMap[$path]) }
    $ordered = @($orderedRows)
    return [pscustomobject][ordered]@{
        schema_version=1
        contract_id='nxb-v1-package-manifest-v1'
        release_version='1.0.0'
        source_head=$SourceHead.ToLowerInvariant()
        created_utc=$CreatedUtc
        file_count=$ordered.Count
        total_bytes=$total
        files=$ordered
    }
}

function Test-NxbV1PackageManifestObject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Manifest,[Parameter(Mandatory)][int]$MaximumFiles,[Parameter(Mandatory)][int64]$MaximumBytes)
    try {
        if ([int]$Manifest.schema_version -ne 1 -or [string]$Manifest.contract_id -cne 'nxb-v1-package-manifest-v1' -or [string]$Manifest.release_version -cne '1.0.0') { return $false }
        if (-not (Test-NxbV1InstallerLowerHex -Text ([string]$Manifest.source_head) -Length 40)) { return $false }
        $files = @($Manifest.files)
        if ($files.Count -lt 1 -or $files.Count -gt $MaximumFiles -or [int]$Manifest.file_count -ne $files.Count) { return $false }
        $seen = @{}
        $total = [int64]0
        $previous = $null
        foreach ($file in $files) {
            $path = [string]$file.path
            if (-not (Test-NxbV1InstallerRelativePath -Path $path) -or $seen.ContainsKey($path)) { return $false }
            if ($null -ne $previous -and [StringComparer]::Ordinal.Compare($previous,$path) -ge 0) { return $false }
            if ([int64]$file.bytes -lt 0 -or -not (Test-NxbV1InstallerLowerHex -Text ([string]$file.sha256) -Length 64)) { return $false }
            $seen[$path]=$true
            $previous=$path
            $total += [int64]$file.bytes
            if ($total -gt $MaximumBytes) { return $false }
        }
        return ([int64]$Manifest.total_bytes -eq $total)
    }
    catch { return $false }
}

function Test-NxbV1PackageAgainstManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][object]$Manifest)
    try {
        $root = [IO.Path]::GetFullPath($PackageRoot)
        $trimChars = [char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
        $prefix = $root.TrimEnd($trimChars) + [IO.Path]::DirectorySeparatorChar
        $actual = @{}
        foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse -Force)) {
            if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            $full = [IO.Path]::GetFullPath($file.FullName)
            if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { return $false }
            $relative = $full.Substring($prefix.Length).Replace([IO.Path]::DirectorySeparatorChar,[char]'/')
            if ($actual.ContainsKey($relative)) { return $false }
            $actual[$relative] = [pscustomobject]@{ bytes=[int64]$file.Length; sha256=(Get-NxbV1InstallerSha256 -Path $full) }
        }
        if ($actual.Count -ne @($Manifest.files).Count) { return $false }
        foreach ($expected in @($Manifest.files)) {
            $path=[string]$expected.path
            if (-not $actual.ContainsKey($path)) { return $false }
            if ([int64]$actual[$path].bytes -ne [int64]$expected.bytes -or [string]$actual[$path].sha256 -cne [string]$expected.sha256) { return $false }
        }
        return $true
    }
    catch { return $false }
}
