param(
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,

    [Parameter(Mandatory = $true)]
    [ValidateSet('powershell-portable-zip', 'powershell-nupkg', 'python-wheel')]
    [string]$ArchiveKind,

    [Parameter(Mandatory = $true)]
    [string]$DestinationRoot,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedSha256,

    [Parameter(Mandatory = $true)]
    [int]$MaxEntries,

    [Parameter(Mandatory = $true)]
    [long]$MaxEntryBytes,

    [Parameter(Mandatory = $true)]
    [long]$MaxTotalBytes,

    [Parameter(Mandatory = $true)]
    [double]$MaxCompressionRatio,

    [Parameter(Mandatory = $true)]
    [string]$ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Authority = 'nxb-v11-verified-archive-extraction-v1'
$ReservedDosNames = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
foreach ($name in @(
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
)) {
    [void]$ReservedDosNames.Add($name)
}

function Fail {
    param([Parameter(Mandatory = $true)][string]$Message)
    throw $Message
}

function Get-FullPathStrict {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Fail "$Label is empty."
    }

    $full = [IO.Path]::GetFullPath($Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path) -or
        -not $full.Equals($Path, [StringComparison]::OrdinalIgnoreCase)) {
        Fail "$Label must be an absolute normalized path: $Path"
    }
    return $full
}

function Assert-OrdinaryDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $full = Get-FullPathStrict -Path $Path -Label $Label
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        Fail "$Label is not an existing directory: $full"
    }

    $item = Get-Item -LiteralPath $full -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "$Label is reparse-backed: $full"
    }

    return $full
}

function Assert-OrdinaryFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $full = Get-FullPathStrict -Path $Path -Label $Label
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Fail "$Label is not an existing file: $full"
    }

    $item = Get-Item -LiteralPath $full -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "$Label is reparse-backed: $full"
    }

    return $full
}

function Assert-UnderRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $pathFull = [IO.Path]::GetFullPath($Path)
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar

    if (-not $pathFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        Fail "$Label is outside NXB_V11_MATERIALIZATION_ROOT: $pathFull"
    }
}

function Assert-NoReparseAncestorChain {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$StopRoot,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $stop = [IO.Path]::GetFullPath($StopRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $current = [IO.Path]::GetFullPath($Path)

    while ($true) {
        if (-not (Test-Path -LiteralPath $current)) {
            Fail "$Label ancestor does not exist: $current"
        }

        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Fail "$Label ancestor is reparse-backed: $current"
        }

        if ($current.Equals($stop, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }

        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or
            $parent.Equals($current, [StringComparison]::OrdinalIgnoreCase)) {
            Fail "$Label ancestor walk escaped materialization root."
        }
        $current = [IO.Path]::GetFullPath($parent)
    }
}

function Get-RelativeArchivePath {
    param(
        [Parameter(Mandatory = $true)][string]$EntryName,
        [Parameter(Mandatory = $true)][bool]$Directory
    )

    if ([string]::IsNullOrEmpty($EntryName)) {
        Fail 'ZIP entry name is empty.'
    }
    if ($EntryName.Contains('\')) {
        Fail "ZIP entry contains backslash: $EntryName"
    }
    if ($EntryName.StartsWith('/') -or
        $EntryName.StartsWith('//') -or
        $EntryName -match '^[A-Za-z]:') {
        Fail "ZIP entry is rooted/drive-qualified: $EntryName"
    }
    $nfcEntryName = $EntryName.Normalize([Text.NormalizationForm]::FormC)
    if (-not [string]::Equals($nfcEntryName, $EntryName, [StringComparison]::Ordinal)) {
        Fail "ZIP entry is not NFC-normalized: $EntryName"
    }

    $name = if ($Directory) {
        $EntryName.TrimEnd('/')
    }
    else {
        $EntryName
    }

    if ([string]::IsNullOrEmpty($name)) {
        Fail "ZIP directory entry has no path: $EntryName"
    }

    $segments = $name.Split('/')
    foreach ($segment in $segments) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -in @('.', '..')) {
            Fail "ZIP entry contains empty/dot/traversal segment: $EntryName"
        }
        if ($segment.EndsWith(' ') -or $segment.EndsWith('.')) {
            Fail "ZIP entry has trailing space/dot component: $EntryName"
        }
        if ($segment.Contains(':')) {
            Fail "ZIP entry contains ADS-style colon: $EntryName"
        }
        if ($segment.IndexOfAny([char[]]'?*"<>|') -ge 0) {
            Fail "ZIP entry contains Windows-invalid segment character: $EntryName"
        }
        foreach ($character in $segment.ToCharArray()) {
            $code = [int]$character
            if ($code -lt 0x20 -or $code -eq 0x7F) {
                Fail "ZIP entry contains control character: $EntryName"
            }
        }

        $stem = $segment.Split('.', 2)[0]
        if ($ReservedDosNames.Contains($stem)) {
            Fail "ZIP entry has reserved DOS device component: $EntryName"
        }
    }

    return ($segments -join '/')
}

function Get-ImpliedDirectoryPath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $parts = $RelativePath.Split('/')
    if ($parts.Count -le 1) {
        return @()
    }

    $rows = [Collections.Generic.List[string]]::new()
    for ($index = 1; $index -lt $parts.Count; $index++) {
        [void]$rows.Add(($parts[0..($index - 1)] -join '/'))
    }
    return @($rows)
}

if ($ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$') {
    Fail 'ExpectedSha256 must be exactly 64 lowercase hexadecimal characters.'
}
if ($MaxEntries -le 0) {
    Fail 'MaxEntries must be positive.'
}
if ($MaxEntryBytes -le 0 -or $MaxTotalBytes -le 0) {
    Fail 'MaxEntryBytes and MaxTotalBytes must be positive.'
}
if ($MaxCompressionRatio -le 0 -or
    [double]::IsNaN($MaxCompressionRatio) -or
    [double]::IsInfinity($MaxCompressionRatio)) {
    Fail 'MaxCompressionRatio must be positive and finite.'
}

$materializationRootValue = [Environment]::GetEnvironmentVariable(
    'NXB_V11_MATERIALIZATION_ROOT',
    'Process'
)
if ([string]::IsNullOrWhiteSpace($materializationRootValue)) {
    Fail 'NXB_V11_MATERIALIZATION_ROOT is required.'
}

$materializationRoot = Assert-OrdinaryDirectory `
    -Path (Get-FullPathStrict -Path $materializationRootValue -Label 'materialization root') `
    -Label 'materialization root'

$archive = Assert-OrdinaryFile -Path $ArchivePath -Label 'ArchivePath'
$destination = Get-FullPathStrict -Path $DestinationRoot -Label 'DestinationRoot'
$result = Get-FullPathStrict -Path $ResultPath -Label 'ResultPath'

Assert-UnderRoot -Path $destination -Root $materializationRoot -Label 'DestinationRoot'
Assert-UnderRoot -Path $result -Root $materializationRoot -Label 'ResultPath'

if ($result.StartsWith(
    $destination.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
)) {
    Fail 'ResultPath must not be inside DestinationRoot.'
}
if (Test-Path -LiteralPath $destination) {
    Fail "DestinationRoot already exists: $destination"
}
if (Test-Path -LiteralPath $result) {
    Fail "ResultPath already exists: $result"
}

$destinationParent = Assert-OrdinaryDirectory `
    -Path (Split-Path -Parent $destination) `
    -Label 'DestinationRoot parent'
$resultParent = Assert-OrdinaryDirectory `
    -Path (Split-Path -Parent $result) `
    -Label 'ResultPath parent'
Assert-NoReparseAncestorChain `
    -Path $destinationParent `
    -StopRoot $materializationRoot `
    -Label 'DestinationRoot parent'
Assert-NoReparseAncestorChain `
    -Path $resultParent `
    -StopRoot $materializationRoot `
    -Label 'ResultPath parent'

$archiveSha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($archiveSha256 -cne $ExpectedSha256) {
    Fail "Archive SHA-256 mismatch: expected=$ExpectedSha256 actual=$archiveSha256"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

$stream = [IO.File]::Open(
    $archive,
    [IO.FileMode]::Open,
    [IO.FileAccess]::Read,
    [IO.FileShare]::Read
)
$zip = $null
try {
    $zip = [IO.Compression.ZipArchive]::new(
        $stream,
        [IO.Compression.ZipArchiveMode]::Read,
        $false
    )

    $seenExact = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    $seenFolded = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $plan = [Collections.Generic.List[object]]::new()
    $plannedFiles = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    $plannedDirectories = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )

    [long]$totalUncompressed = 0
    [int]$entryCount = 0
    [int]$fileCount = 0

    foreach ($entry in $zip.Entries) {
        $entryCount++
        if ($entryCount -gt $MaxEntries) {
            Fail "Archive entry count exceeds MaxEntries=$MaxEntries."
        }

        $rawName = [string]$entry.FullName
        $isDirectory = $rawName.EndsWith('/', [StringComparison]::Ordinal)
        $relative = Get-RelativeArchivePath `
            -EntryName $rawName `
            -Directory $isDirectory

        if (-not $seenExact.Add($relative)) {
            Fail "Archive duplicate normalized path: $relative"
        }
        if (-not $seenFolded.Add($relative)) {
            Fail "Archive Windows case-fold collision: $relative"
        }

        $unixType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
        if (($entry.ExternalAttributes -band 0x400) -ne 0) {
            Fail "Archive entry advertises reparse metadata: $rawName"
        }

        if ($isDirectory) {
            if ($entry.Length -ne 0) {
                Fail "Directory entry has non-zero uncompressed length: $rawName"
            }
            if ($unixType -ne 0 -and $unixType -ne 0x4000) {
                Fail "Directory entry has non-directory Unix file type: $rawName"
            }
            [void]$plannedDirectories.Add($relative)
            foreach ($implied in @(Get-ImpliedDirectoryPath -RelativePath $relative)) {
                [void]$plannedDirectories.Add($implied)
            }
        }
        else {
            if ($unixType -ne 0 -and $unixType -ne 0x8000) {
                Fail "Archive entry is symlink/device/special file: $rawName"
            }
            if ([long]$entry.Length -gt $MaxEntryBytes) {
                Fail "Archive entry exceeds MaxEntryBytes: $rawName"
            }
            if ([long]$entry.Length -gt 0 -and [long]$entry.CompressedLength -le 0) {
                Fail "Archive entry has invalid zero compressed length: $rawName"
            }

            $ratio = if ([long]$entry.Length -eq 0) {
                [double]0
            }
            else {
                [double]$entry.Length / [double]$entry.CompressedLength
            }
            if ($ratio -gt $MaxCompressionRatio) {
                Fail "Archive entry exceeds compression-ratio budget: $rawName ratio=$ratio"
            }

            if ($totalUncompressed -gt ([long]::MaxValue - [long]$entry.Length)) {
                Fail 'Archive uncompressed byte total overflow.'
            }
            $totalUncompressed += [long]$entry.Length
            if ($totalUncompressed -gt $MaxTotalBytes) {
                Fail "Archive total exceeds MaxTotalBytes=$MaxTotalBytes."
            }

            $fileCount++
            [void]$plannedFiles.Add($relative)
            foreach ($implied in @(Get-ImpliedDirectoryPath -RelativePath $relative)) {
                [void]$plannedDirectories.Add($implied)
            }

            # Opening and reading one byte detects unsupported/encrypted entries
            # before any filesystem write. Empty entries still open successfully.
            $probe = $entry.Open()
            try {
                if ([long]$entry.Length -gt 0) {
                    [void]$probe.ReadByte()
                }
            }
            finally {
                $probe.Dispose()
            }
        }

        [void]$plan.Add([pscustomobject][ordered]@{
            entry = $entry
            relative_path = $relative
            is_directory = [bool]$isDirectory
        })
    }

    # Cross-check the complete planned namespace before the first filesystem write.
    # This catches file-vs-directory conflicts and case-only collisions introduced
    # by implied parent directories (for example `a` plus `a/b.txt`, or A/x + a/y).
    $plannedNamespaceExact = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    $plannedNamespaceFolded = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($directoryPath in $plannedDirectories) {
        if (-not $plannedNamespaceExact.Add($directoryPath)) {
            Fail "Archive duplicate planned directory: $directoryPath"
        }
        if (-not $plannedNamespaceFolded.Add($directoryPath)) {
            Fail "Archive planned directory case-fold collision: $directoryPath"
        }
    }
    foreach ($filePath in $plannedFiles) {
        if (-not $plannedNamespaceExact.Add($filePath)) {
            Fail "Archive file/directory namespace collision: $filePath"
        }
        if (-not $plannedNamespaceFolded.Add($filePath)) {
            Fail "Archive file/directory case-fold collision: $filePath"
        }
    }

    [void][IO.Directory]::CreateDirectory($destination)

    foreach ($row in $plan) {
        $relativeSystem = ([string]$row.relative_path).Replace(
            '/',
            [IO.Path]::DirectorySeparatorChar
        )
        $target = [IO.Path]::GetFullPath((Join-Path $destination $relativeSystem))
        $prefix = $destination.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            Fail "Archive extraction target escaped DestinationRoot: $($row.relative_path)"
        }

        if ([bool]$row.is_directory) {
            [void][IO.Directory]::CreateDirectory($target)
            continue
        }

        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            [void][IO.Directory]::CreateDirectory($parent)
        }

        $entryStream = $row.entry.Open()
        $output = [IO.File]::Open(
            $target,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        try {
            $buffer = [byte[]]::new(131072)
            [long]$written = 0
            while (($read = $entryStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $written += [long]$read
                if ($written -gt $MaxEntryBytes) {
                    Fail "Extraction exceeded MaxEntryBytes: $($row.relative_path)"
                }
                $output.Write($buffer, 0, $read)
            }
            if ($written -ne [long]$row.entry.Length) {
                Fail "Extracted byte length mismatch: $($row.relative_path)"
            }
            $output.Flush($true)
        }
        finally {
            $output.Dispose()
            $entryStream.Dispose()
        }
    }

    $actualFiles = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    $actualDirectories = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    $actualFolded = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $stack = [Collections.Generic.Stack[string]]::new()
    $stack.Push($destination)
    [long]$actualBytes = 0

    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()
        $directoryItem = Get-Item -LiteralPath $directory -Force
        if (($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Fail "Extracted directory is reparse-backed: $directory"
        }

        foreach ($childPath in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
            $child = Get-Item -LiteralPath $childPath -Force
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Fail "Extracted entry is reparse-backed: $childPath"
            }

            $relativeSystem = [IO.Path]::GetRelativePath($destination, $child.FullName)
            $relative = $relativeSystem.Replace('\', '/')
            $relative = Get-RelativeArchivePath `
                -EntryName $relative `
                -Directory ([bool]$child.PSIsContainer)

            if (-not $actualFolded.Add($relative)) {
                Fail "Extracted filesystem case-fold collision: $relative"
            }

            if ($child.PSIsContainer) {
                [void]$actualDirectories.Add($relative)
                $stack.Push($child.FullName)
                continue
            }

            if (-not ($child -is [IO.FileInfo])) {
                Fail "Extracted non-regular filesystem object: $($child.FullName)"
            }

            [void]$actualFiles.Add($relative)
            $actualBytes += [long]$child.Length

            if ($IsWindows) {
                $streams = @(Get-Item -LiteralPath $child.FullName -Stream * -ErrorAction Stop)
                $named = @($streams | Where-Object {
                    [string]$_.Stream -notin @(':$DATA', '$DATA')
                })
                if ($named.Count -ne 0) {
                    Fail "Extracted file has named ADS: $relative / $($named[0].Stream)"
                }
            }
        }
    }

    if ($actualFiles.Count -ne $plannedFiles.Count) {
        Fail "Extracted file count differs from plan: planned=$($plannedFiles.Count) actual=$($actualFiles.Count)"
    }
    if ($actualDirectories.Count -ne $plannedDirectories.Count) {
        Fail "Extracted directory count differs from plan: planned=$($plannedDirectories.Count) actual=$($actualDirectories.Count)"
    }
    foreach ($path in $plannedFiles) {
        if (-not $actualFiles.Contains($path)) {
            Fail "Planned file missing after extraction: $path"
        }
    }
    foreach ($path in $plannedDirectories) {
        if (-not $actualDirectories.Contains($path)) {
            Fail "Planned directory missing after extraction: $path"
        }
    }
    if ($actualBytes -ne $totalUncompressed) {
        Fail "Extracted total bytes mismatch: planned=$totalUncompressed actual=$actualBytes"
    }

    $destinationItem = Get-Item -LiteralPath $destination -Force
    if (($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail 'DestinationRoot became reparse-backed.'
    }

    $destinationRole = switch ($ArchiveKind) {
        'powershell-portable-zip' { 'powershell-portable-runtime' }
        'powershell-nupkg' { 'powershell-module' }
        'python-wheel' { 'python-wheel' }
        default { Fail "Unsupported archive kind: $ArchiveKind" }
    }

    $receipt = [ordered]@{
        authority = $Authority
        archive_kind = $ArchiveKind
        archive_sha256 = $archiveSha256
        entry_count = [long]$entryCount
        file_count = [long]$fileCount
        total_uncompressed_bytes = [long]$totalUncompressed
        destination_root_role = $destinationRole
        verification_passed = $true
        central_directory_preflight_passed = $true
        post_extraction_reconciliation_passed = $true
        reparse_free = $true
        named_ads_free = $true
    }

    $json = $receipt | ConvertTo-Json -Depth 10 -Compress
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($json)
    $resultStream = [IO.File]::Open(
        $result,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try {
        $resultStream.Write($bytes, 0, $bytes.Length)
        $resultStream.Flush($true)
    }
    finally {
        $resultStream.Dispose()
    }
}
finally {
    if ($null -ne $zip) {
        $zip.Dispose()
    }
    $stream.Dispose()
}
