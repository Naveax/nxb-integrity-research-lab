#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$CertifiedHead,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateRange(1,[long]::MaxValue)][long]$NativeRunId,
    [Parameter()][ValidateSet('CurrentUser','LocalMachine')][string]$CertificateStoreLocation,
    [Parameter()][string]$CertificateThumbprint,
    [Parameter()][string]$OutputRoot,
    [Parameter(Mandatory)][switch]$ConfirmProductionRelease
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$NativeExitUnset = [int]::MinValue

function Assert-Nxb {
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-NxbSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-NxbJsonNew {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$Value)
    Assert-Nxb (-not (Test-Path -LiteralPath $Path)) ('JSON output already exists: {0}' -f $Path)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $stream = [IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        $writer = [IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false))
        try {
            $writer.Write(($Value | ConvertTo-Json -Depth 100) + [Environment]::NewLine)
            $writer.Flush()
            $stream.Flush($true)
        }
        finally { $writer.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Invoke-NxbNative {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter()][string]$WorkingDirectory
    )
    $global:LASTEXITCODE = $NativeExitUnset
    $previousNativePreference = $null
    $nativeVariable = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    if ($null -ne $nativeVariable) {
        $previousNativePreference = [bool]$nativeVariable.Value
        Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $false -Scope Local
    }
    try {
        if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { $lines = @(& $Executable @ArgumentList 2>&1) }
        else {
            Push-Location $WorkingDirectory
            try { $lines = @(& $Executable @ArgumentList 2>&1) }
            finally { Pop-Location }
        }
        $exit = $global:LASTEXITCODE
    }
    finally {
        if ($null -ne $nativeVariable) { Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $previousNativePreference -Scope Local }
    }
    if ($exit -eq $NativeExitUnset) { throw ('Native command did not set LASTEXITCODE: {0}' -f $Executable) }
    return [pscustomobject][ordered]@{
        exit_code = [int]$exit
        output = (($lines | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    }
}

function Invoke-NxbGit {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$ArgumentList,[Parameter()][string]$WorkingDirectory)
    $run = Invoke-NxbNative -Executable $script:Git -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory
    if ($run.exit_code -ne 0) { throw ('git failed: {0}{1}{2}' -f ($ArgumentList -join ' '),[Environment]::NewLine,$run.output) }
    return [string]$run.output
}

function Invoke-NxbGhJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Endpoint)
    $run = Invoke-NxbNative -Executable $script:Gh -ArgumentList @('api',$Endpoint)
    if ($run.exit_code -ne 0) { throw ('gh api failed: {0}{1}{2}' -f $Endpoint,[Environment]::NewLine,$run.output) }
    try { return ($run.output | ConvertFrom-Json -Depth 100) }
    catch { throw ('gh api returned invalid JSON for {0}: {1}' -f $Endpoint,$_.Exception.Message) }
}

function Get-NxbRemoteHead {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Branch)
    $line = Invoke-NxbGit -ArgumentList @('ls-remote','--heads',$script:Origin,('refs/heads/{0}' -f $Branch))
    if ($line -notmatch '^(?<sha>[0-9a-fA-F]{40})\s+') { throw ('Unable to parse remote branch head: {0}' -f $Branch) }
    return $Matches.sha.ToLowerInvariant()
}

function Get-NxbTrackedPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $raw = Invoke-NxbGit -WorkingDirectory $RepositoryRoot -ArgumentList @('ls-files')
    return @($raw -split '\r?\n' | ForEach-Object { ([string]$_).Replace('\','/').Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
}

function Get-NxbLiteralTrackedDependency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][hashtable]$TrackedMap
    )
    $source = Join-Path $RepositoryRoot $RelativePath.Replace('/',[IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { return @() }
    $extension = [IO.Path]::GetExtension($source).ToLowerInvariant()
    if (@('.ps1','.psm1','.psd1','.py','.json','.toml','.yaml','.yml','.md','.txt') -cnotcontains $extension) { return @() }
    try { $content = Get-Content -LiteralPath $source -Raw -Encoding UTF8 }
    catch { return @() }
    $sourceDir = [IO.Path]::GetDirectoryName($RelativePath.Replace('/',[IO.Path]::DirectorySeparatorChar))
    $result = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($match in [regex]::Matches($content,'[''\"](?<value>[^''\"\r\n]{1,320})[''\"]')) {
        $literal = [string]$match.Groups['value'].Value
        if ([string]::IsNullOrWhiteSpace($literal) -or $literal.Contains('$') -or $literal.Contains('*')) { continue }
        $normalized = $literal.Replace('\','/').Trim()
        while ($normalized.StartsWith('./',[StringComparison]::Ordinal)) { $normalized = $normalized.Substring(2) }
        if ($normalized.StartsWith('../',[StringComparison]::Ordinal) -or $normalized.StartsWith('/',[StringComparison]::Ordinal) -or $normalized -match '^[A-Za-z]:') { continue }
        $candidates = [Collections.Generic.List[string]]::new()
        $candidates.Add($normalized)
        if (-not [string]::IsNullOrWhiteSpace($sourceDir)) {
            try {
                $combined = Join-Path $sourceDir $literal
                $candidateFull = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $combined))
                $repoFull = [IO.Path]::GetFullPath($RepositoryRoot)
                $trimChars = [char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
                $prefix = $repoFull.TrimEnd($trimChars) + [IO.Path]::DirectorySeparatorChar
                if ($candidateFull.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { $candidates.Add($candidateFull.Substring($prefix.Length).Replace([IO.Path]::DirectorySeparatorChar,[char]'/')) }
            }
            catch { Write-Verbose ('Literal dependency candidate skipped: {0}' -f $_.Exception.Message) }
        }
        foreach ($candidateObject in $candidates) {
            $candidate = [string]$candidateObject
            if ($TrackedMap.ContainsKey($candidate)) { [void]$result.Add($candidate) }
        }
    }
    return @($result | Sort-Object)
}

function Copy-NxbRuntimeClosurePackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][int]$MaximumPackageFiles,
        [Parameter(Mandatory)][string]$ReceiptPath
    )
    Assert-Nxb (-not (Test-Path -LiteralPath $Destination)) 'Package destination must be absent.'
    $tracked = @(Get-NxbTrackedPath -RepositoryRoot $RepositoryRoot)
    Assert-Nxb ($tracked.Count -gt 0) 'git ls-files returned no tracked files.'
    $trackedMap = @{}
    foreach ($path in $tracked) { $trackedMap[$path] = $true }
    $selected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $shippingSeeds = @(
        'scripts/nxb.ps1',
        'scripts/Invoke-NxbV1Installer.ps1',
        'scripts/Invoke-NxbV1Updater.ps1',
        'scripts/Export-NxbV1PackageManifest.ps1',
        'scripts/Invoke-NxbV1ReleaseManifestSigning.ps1'
    )
    foreach ($seed in $shippingSeeds) {
        Assert-Nxb ($trackedMap.ContainsKey($seed)) ('Required runtime seed is not tracked: {0}' -f $seed)
        [void]$selected.Add($seed)
    }
    $iterations = 0
    while ($true) {
        $iterations++
        Assert-Nxb ($iterations -le 64) 'Runtime dependency closure did not converge.'
        $added = 0
        foreach ($relative in @($selected | Sort-Object)) {
            foreach ($dependency in @(Get-NxbLiteralTrackedDependency -RepositoryRoot $RepositoryRoot -RelativePath ([string]$relative) -TrackedMap $trackedMap)) {
                if ($selected.Add([string]$dependency)) { $added++ }
            }
        }
        if ($added -eq 0) { break }
    }
    $paths = @($selected | Sort-Object)
    Assert-Nxb ($paths.Count -le $MaximumPackageFiles) ('Runtime package exceeds signing budget: files={0} maximum={1}' -f $paths.Count,$MaximumPackageFiles)
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    [int64]$bytes = 0
    foreach ($relative in $paths) {
        $source = Join-Path $RepositoryRoot $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
        $item = Get-Item -LiteralPath $source -Force
        Assert-Nxb (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) ('Runtime package source is a reparse point: {0}' -f $relative)
        $destinationPath = Join-Path $Destination $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destinationPath)) | Out-Null
        [IO.File]::Copy($source,$destinationPath,$false)
        $bytes += [int64]$item.Length
    }
    Write-NxbJsonNew -Path $ReceiptPath -Value ([pscustomobject][ordered]@{
        schema_version=1; status='passed'; authority='nxb-v1-production-runtime-package-surface-v3'; source_head=$ExpectedHead.ToLowerInvariant();
        tracked_file_count=$tracked.Count; selected_file_count=$paths.Count; excluded_file_count=($tracked.Count-$paths.Count); maximum_package_files=$MaximumPackageFiles;
        shipping_seeds=$shippingSeeds; dependency_iterations=$iterations; selected_paths=$paths; package_bytes_copied=$bytes
    })
    return [pscustomobject][ordered]@{ paths=$paths; bytes=$bytes; receipt_path=$ReceiptPath; receipt_sha256=(Get-NxbSha256 -Path $ReceiptPath) }
}

function Export-NxbDeterministicZip {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Output)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Assert-Nxb (-not (Test-Path -LiteralPath $Output)) ('ZIP output already exists: {0}' -f $Output)
    $rootFull = [IO.Path]::GetFullPath($Root)
    $trimChars = [char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $prefix = $rootFull.TrimEnd($trimChars) + [IO.Path]::DirectorySeparatorChar
    $rows = @(Get-ChildItem -LiteralPath $rootFull -File -Recurse -Force | ForEach-Object {
        $full = [IO.Path]::GetFullPath($_.FullName)
        [pscustomobject]@{ full=$full; relative=$full.Substring($prefix.Length).Replace([IO.Path]::DirectorySeparatorChar,[char]'/') }
    } | Sort-Object relative)
    $stream = [IO.File]::Open($Output,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true,[Text.UTF8Encoding]::new($false))
        try {
            foreach ($row in $rows) {
                $entry = $archive.CreateEntry([string]$row.relative,[IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = [DateTimeOffset]::new(2000,1,1,0,0,0,[TimeSpan]::Zero)
                $source = [IO.File]::OpenRead([string]$row.full)
                $destination = $entry.Open()
                try { $source.CopyTo($destination) }
                finally { $destination.Dispose(); $source.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-NxbProductionSignerCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CommonPath)
    . $CommonPath
    $result = [Collections.Generic.List[object]]::new()
    foreach ($locationName in @('CurrentUser','LocalMachine')) {
        $location = [Security.Cryptography.X509Certificates.StoreLocation][Enum]::Parse([Security.Cryptography.X509Certificates.StoreLocation],$locationName,$true)
        $store = [Security.Cryptography.X509Certificates.X509Store]::new('My',$location)
        try {
            $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
            foreach ($certificate in @($store.Certificates)) {
                if (-not $certificate.HasPrivateKey) { continue }
                $now = [DateTime]::UtcNow
                if ($now -lt $certificate.NotBefore.ToUniversalTime() -or $now -gt $certificate.NotAfter.ToUniversalTime()) { continue }
                $rsa = $null
                try {
                    $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
                    if ($null -eq $rsa -or $rsa.KeySize -lt 3072) { continue }
                    if (-not (Test-NxbV1SigningRsaProtected -Rsa $rsa)) { continue }
                    $public = Get-NxbV1SigningPublicKey -Rsa $rsa
                    $result.Add([pscustomobject][ordered]@{
                        store_location=$locationName; store_name='My'; thumbprint=$certificate.Thumbprint.Replace(' ','').ToUpperInvariant(); subject=$certificate.Subject;
                        not_before_utc=$certificate.NotBefore.ToUniversalTime().ToString('o'); not_after_utc=$certificate.NotAfter.ToUniversalTime().ToString('o');
                        key_size_bits=[int]$rsa.KeySize; public_fingerprint=[string]$public.fingerprint
                    })
                }
                finally { if ($null -ne $rsa) { $rsa.Dispose() } }
            }
        }
        catch { Write-Information ('Signer store scan skipped {0}\My: {1}' -f $locationName,$_.Exception.Message) }
        finally { $store.Close(); $store.Dispose() }
    }
    return @($result)
}

function Save-NxbGitHubArtifactArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][long]$ArtifactId,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$ExpectedDigest,
        [Parameter(Mandatory)][string]$Token
    )
    Assert-Nxb ($ExpectedDigest -cmatch '^sha256:[0-9a-f]{64}$') ('GitHub artifact digest is unavailable or malformed: {0}' -f $ExpectedDigest)
    Assert-Nxb (-not (Test-Path -LiteralPath $OutputPath)) ('Artifact archive output already exists: {0}' -f $OutputPath)
    $headers = @{ Authorization=('Bearer {0}' -f $Token); Accept='application/vnd.github+json'; 'X-GitHub-Api-Version'='2022-11-28'; 'User-Agent'='NXB-v1-production-release' }
    $uri = 'https://api.github.com/repos/{0}/actions/artifacts/{1}/zip' -f $script:Repository,$ArtifactId
    Invoke-WebRequest -Uri $uri -Headers $headers -OutFile $OutputPath -MaximumRedirection 10 | Out-Null
    $actual = Get-NxbSha256 -Path $OutputPath
    Assert-Nxb ($actual -ceq $ExpectedDigest.Substring(7)) ('Downloaded artifact ZIP digest mismatch: artifact={0} expected={1} actual=sha256:{2}' -f $ArtifactId,$ExpectedDigest,$actual)
    return $actual
}

function Get-NxbPredecessorExpectedAssetMap {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Policy)
    $map = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($Policy.predecessor.assets)) {
        $name = [string]$entry.name
        $sha = [string]$entry.sha256
        Assert-Nxb (-not [string]::IsNullOrWhiteSpace($name)) 'Frozen predecessor asset name is empty.'
        Assert-Nxb ($sha -cmatch '^[0-9a-f]{64}$') ('Frozen predecessor asset SHA-256 is malformed: {0}' -f $name)
        Assert-Nxb (-not $map.ContainsKey($name)) ('Frozen predecessor asset policy contains a duplicate: {0}' -f $name)
        $map.Add($name,$sha)
    }
    Assert-Nxb ($map.Count -eq 11) ('Frozen predecessor asset policy count drift: {0}' -f $map.Count)
    return $map
}

function Save-NxbGitHubReleaseAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][long]$AssetId,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][string]$Token
    )
    Assert-Nxb ($ExpectedSha256 -cmatch '^[0-9a-f]{64}$') 'Expected GitHub Release asset SHA-256 is malformed.'
    Assert-Nxb (-not (Test-Path -LiteralPath $OutputPath)) ('Release asset output already exists: {0}' -f $OutputPath)
    $headers = @{ Authorization=('Bearer {0}' -f $Token); Accept='application/octet-stream'; 'X-GitHub-Api-Version'='2022-11-28'; 'User-Agent'='NXB-v1-production-release' }
    $uri = 'https://api.github.com/repos/{0}/releases/assets/{1}' -f $script:Repository,$AssetId
    Invoke-WebRequest -Uri $uri -Headers $headers -OutFile $OutputPath -MaximumRedirection 10 | Out-Null
    $actual = Get-NxbSha256 -Path $OutputPath
    Assert-Nxb ($actual -ceq $ExpectedSha256) ('Downloaded frozen predecessor asset SHA mismatch: asset={0} expected={1} actual={2}' -f $AssetId,$ExpectedSha256,$actual)
    return $actual
}

function Test-NxbPackageRootAgainstManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][object]$Manifest)
    try {
        if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $false }
        $rootFull = [IO.Path]::GetFullPath($Root)
        $trimChars = [char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
        $prefix = $rootFull.TrimEnd($trimChars) + [IO.Path]::DirectorySeparatorChar
        $rows = @($Manifest.files)
        if ([int]$Manifest.file_count -ne $rows.Count) { return $false }
        $expected = [Collections.Generic.Dictionary[string,bool]]::new([StringComparer]::Ordinal)
        foreach ($row in $rows) {
            $relative = [string]$row.path
            if ([string]::IsNullOrWhiteSpace($relative) -or $relative -match '(^/|^[A-Za-z]:|(^|/)\.\.(/|$)|\\)') { return $false }
            if ($expected.ContainsKey($relative)) { return $false }
            $expected.Add($relative,$true)
            $full = [IO.Path]::GetFullPath((Join-Path $rootFull $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)))
            if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { return $false }
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $false }
            $item = Get-Item -LiteralPath $full -Force
            if ([int64]$item.Length -ne [int64]$row.bytes -or (Get-NxbSha256 -Path $full) -cne [string]$row.sha256) { return $false }
        }
        $actual = @(Get-ChildItem -LiteralPath $rootFull -File -Recurse -Force)
        if ($actual.Count -ne $expected.Count) { return $false }
        foreach ($file in $actual) {
            $full = [IO.Path]::GetFullPath($file.FullName)
            $relative = $full.Substring($prefix.Length).Replace([IO.Path]::DirectorySeparatorChar,[char]'/')
            if (-not $expected.ContainsKey($relative)) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Resolve-NxbExtractedPackageRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ExtractRoot,[Parameter(Mandatory)][object]$Manifest)
    $rootFull = [IO.Path]::GetFullPath($ExtractRoot)
    $candidates = [Collections.Generic.List[string]]::new()
    $candidates.Add($rootFull)
    $topFiles = @(Get-ChildItem -LiteralPath $rootFull -File -Force)
    $topDirs = @(Get-ChildItem -LiteralPath $rootFull -Directory -Force)
    if ($topFiles.Count -eq 0 -and $topDirs.Count -eq 1) { $candidates.Add([IO.Path]::GetFullPath($topDirs[0].FullName)) }
    $matchingRoots = @($candidates | Where-Object { Test-NxbPackageRootAgainstManifest -Root $_ -Manifest $Manifest })
    Assert-Nxb ($matchingRoots.Count -eq 1) ('Frozen predecessor package root resolution failed: matches={0}' -f $matchingRoots.Count)
    return [string]$matchingRoots[0]
}

function Test-NxbHostedReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Receipt,[Parameter(Mandatory)][string]$Head,[Parameter(Mandatory)][object]$Policy)
    return (
        [string]$Receipt.status -ceq 'passed' -and [string]$Receipt.authority -ceq 'nxb-v1-ci-hosted-v1' -and [string]$Receipt.head_sha -ceq $Head -and
        [int]$Receipt.ps7_passed -eq [int]$Policy.ci.ps7_passed -and [int]$Receipt.ps7_total -eq [int]$Policy.ci.ps7_total -and [int]$Receipt.ps7_not_run -eq [int]$Policy.ci.ps7_not_run -and
        [int]$Receipt.ps51_passed -eq [int]$Policy.ci.ps51_passed -and [int]$Receipt.ps51_total -eq [int]$Policy.ci.ps51_total -and [int]$Receipt.ps51_not_run -eq [int]$Policy.ci.ps51_not_run -and
        [string]$Receipt.ps51_excluded_tag -ceq [string]$Policy.ci.ps51_excluded_tag -and [int]$Receipt.ps51_expected_excluded -eq [int]$Policy.ci.ps51_not_run -and
        [string]$Receipt.pester_version -ceq [string]$Policy.ci.versions.pester -and [string]$Receipt.psscriptanalyzer_version -ceq [string]$Policy.ci.versions.psscriptanalyzer -and
        [string]$Receipt.pyyaml_version -ceq [string]$Policy.ci.versions.pyyaml -and [string]$Receipt.jsonschema_version -ceq [string]$Policy.ci.versions.jsonschema -and
        [int]$Receipt.known_error_findings -eq 0 -and [int]$Receipt.analyzer_findings -eq 0 -and [bool]$Receipt.public_repository_guard -and [bool]$Receipt.repository_smoke -and -not [bool]$Receipt.production_release_updated
    )
}

function Test-NxbNativeReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Receipt,[Parameter(Mandatory)][string]$Head,[Parameter(Mandatory)][object]$Policy)
    return (
        [string]$Receipt.status -ceq 'passed' -and [string]$Receipt.authority -ceq 'nxb-v1-ci-native-v1' -and [string]$Receipt.head_sha -ceq $Head -and
        [string]$Receipt.ps7 -ceq ('{0}/{1}' -f [int]$Policy.ci.ps7_passed,[int]$Policy.ci.ps7_total) -and [int]$Receipt.ps7_not_run -eq [int]$Policy.ci.ps7_not_run -and
        [string]$Receipt.ps51 -ceq ('{0}/{1}' -f [int]$Policy.ci.ps51_passed,[int]$Policy.ci.ps51_total) -and [int]$Receipt.ps51_not_run -eq [int]$Policy.ci.ps51_not_run -and
        [string]$Receipt.ps51_excluded_tag -ceq [string]$Policy.ci.ps51_excluded_tag -and [bool]$Receipt.native_profile_parser -and [bool]$Receipt.native_calibration_valid -and
        [int]$Receipt.repetition_count -eq [int]$Policy.ci.native_repetition_count -and [int]$Receipt.warmup_count -eq [int]$Policy.ci.native_warmup_count -and
        [string]$Receipt.pester_version -ceq [string]$Policy.ci.versions.pester -and [string]$Receipt.psscriptanalyzer_version -ceq [string]$Policy.ci.versions.psscriptanalyzer -and
        [string]$Receipt.pyyaml_version -ceq [string]$Policy.ci.versions.pyyaml -and [string]$Receipt.jsonschema_version -ceq [string]$Policy.ci.versions.jsonschema -and
        [int]$Receipt.review_entries -eq [int]$Policy.ci.native_review_entries -and -not [bool]$Receipt.production_private_key_used -and -not [bool]$Receipt.production_release_updated -and
        -not [bool]$Receipt.production_tag_created -and -not [bool]$Receipt.production_merge_performed
    )
}

function Get-NxbPredecessorReleaseSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Policy)
    $release = Invoke-NxbGhJson -Endpoint ('repos/{0}/releases/{1}' -f $script:Repository,[long]$Policy.predecessor.github_release_id)
    Assert-Nxb ([long]$release.id -eq [long]$Policy.predecessor.github_release_id) 'Frozen predecessor GitHub Release ID drift.'
    Assert-Nxb ([string]$release.tag_name -ceq [string]$Policy.predecessor.tag) 'Frozen predecessor GitHub Release tag drift.'
    Assert-Nxb (-not [bool]$release.draft -and -not [bool]$release.prerelease) 'Frozen predecessor GitHub Release state drift.'
    $assets = @($release.assets | ForEach-Object { [pscustomobject][ordered]@{ id=[long]$_.id; name=[string]$_.name; size=[long]$_.size; digest=[string]$_.digest } } | Sort-Object name)
    $expectedAssetMap = Get-NxbPredecessorExpectedAssetMap -Policy $Policy
    Assert-Nxb ($assets.Count -eq $expectedAssetMap.Count) ('Frozen predecessor asset set drift: expected={0} actual={1}' -f $expectedAssetMap.Count,$assets.Count)
    $seen = [Collections.Generic.Dictionary[string,bool]]::new([StringComparer]::Ordinal)
    foreach ($asset in $assets) {
        $name = [string]$asset.name
        Assert-Nxb (-not $seen.ContainsKey($name)) ('Frozen predecessor GitHub Release contains duplicate asset name: {0}' -f $name)
        Assert-Nxb ($expectedAssetMap.ContainsKey($name)) ('Frozen predecessor GitHub Release contains unexpected asset: {0}' -f $name)
        Assert-Nxb ([string]$asset.digest -ceq ('sha256:' + $expectedAssetMap[$name])) ('Frozen predecessor asset digest drift: {0}' -f $name)
        $seen.Add($name,$true)
    }
    Assert-Nxb ($seen.Count -eq $expectedAssetMap.Count) 'Frozen predecessor asset set is incomplete.'
    Assert-Nxb ($expectedAssetMap['nxb-v1.0.0.zip'] -ceq [string]$Policy.predecessor.package_sha256) 'Frozen predecessor package hash policy drift.'
    Assert-Nxb ($expectedAssetMap['production-final-closure-receipt.json'] -ceq [string]$Policy.predecessor.final_closure_sha256) 'Frozen predecessor final-closure hash policy drift.'
    return [pscustomobject][ordered]@{ release_id=[long]$release.id; tag=[string]$release.tag_name; draft=[bool]$release.draft; prerelease=[bool]$release.prerelease; assets=$assets }
}

Assert-Nxb $ConfirmProductionRelease.IsPresent 'Production release requires explicit -ConfirmProductionRelease.'
if ($env:OS -cne 'Windows_NT') { throw 'NXB v1 production release requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core' -or [int]$PSVersionTable.PSVersion.Major -lt 7) { throw 'NXB v1 production release requires PowerShell 7.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try {
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    Assert-Nxb ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'NXB v1 production release requires elevated Administrator PowerShell 7.'
}
finally { $identity.Dispose() }

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
if ($null -eq $gitCommand) { $gitCommand = Get-Command git -ErrorAction Stop }
$script:Git = [string]$gitCommand.Source
$ghCommand = Get-Command gh.exe -ErrorAction SilentlyContinue
if ($null -eq $ghCommand) { $ghCommand = Get-Command gh -ErrorAction Stop }
$script:Gh = [string]$ghCommand.Source
$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
$python = [string]$pythonCommand.Source

$policyPath = Join-Path $repositoryRoot 'config\nxb-v1-production-release-policy.json'
$successorPath = Join-Path $repositoryRoot 'config\nxb-v1-successor-policy.json'
$signingPolicyPath = Join-Path $repositoryRoot 'config\nxb-v1-production-signing-policy.json'
$releaseIntegrationPolicyPath = Join-Path $repositoryRoot 'config\nxb-v1-release-integration-policy.json'
$ciPolicyPath = Join-Path $repositoryRoot 'config\nxb-v1-ci-policy.json'
foreach ($required in @($policyPath,$successorPath,$signingPolicyPath,$releaseIntegrationPolicyPath,$ciPolicyPath)) { Assert-Nxb (Test-Path -LiteralPath $required -PathType Leaf) ('Required production policy missing: {0}' -f $required) }
$policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
$successor = Get-Content -LiteralPath $successorPath -Raw | ConvertFrom-Json
$signingPolicy = Get-Content -LiteralPath $signingPolicyPath -Raw | ConvertFrom-Json
$releaseIntegrationPolicy = Get-Content -LiteralPath $releaseIntegrationPolicyPath -Raw | ConvertFrom-Json
$ciPolicy = Get-Content -LiteralPath $ciPolicyPath -Raw | ConvertFrom-Json
Assert-Nxb ([int]$policy.schema_version -eq 1 -and [string]$policy.contract_id -ceq 'nxb-v1-production-release-v1') 'Production release policy identity drift.'
Assert-Nxb ([string]$policy.target_version -ceq '1.0.1' -and [string]$policy.tag -ceq 'v1.0.1' -and [int]$policy.release_sequence -eq 2) 'Production release version/sequence drift.'
Assert-Nxb ([string]$successor.predecessor.head -ceq [string]$policy.predecessor.head -and [string]$successor.predecessor.production_signer_fingerprint -ceq [string]$policy.predecessor.production_signer_fingerprint) 'Successor/predecessor production policy drift.'
Assert-Nxb ([string]$signingPolicy.target_version -ceq [string]$policy.target_version -and [string]$signingPolicy.certified_implementation_head -ceq [string]$policy.implementation.certified_head) 'Production signing policy binding drift.'
Assert-Nxb ([string]$releaseIntegrationPolicy.target_version -ceq [string]$policy.target_version -and [string]$releaseIntegrationPolicy.certified_implementation_head -ceq [string]$policy.predecessor.head) 'Release integration production-predecessor binding drift.'
Assert-Nxb ([string]$ciPolicy.target_version -ceq [string]$policy.target_version) 'CI target version drift.'
$script:Repository = [string]$policy.repository
$script:Origin = [string]$policy.origin
$certified = $CertifiedHead.ToLowerInvariant()
$expected = $ExpectedHead.ToLowerInvariant()

Write-Information '=== NXB V1.0.1 PRODUCTION RELEASE ==='
Write-Information '[1/18] Exact integrated-head, merge-tree and remote CAS gate'
Invoke-NxbGit -WorkingDirectory $repositoryRoot -ArgumentList @('fetch','--no-tags','origin',[string]$policy.branches.main,[string]$policy.branches.release,[string]$policy.branches.historical_certified) | Out-Null
$currentHead = Invoke-NxbGit -WorkingDirectory $repositoryRoot -ArgumentList @('rev-parse','HEAD')
Assert-Nxb ($currentHead -ceq $expected) ('Local production head mismatch: expected={0} actual={1}' -f $expected,$currentHead)
Assert-Nxb ([string]::IsNullOrWhiteSpace((Invoke-NxbGit -WorkingDirectory $repositoryRoot -ArgumentList @('status','--porcelain=v1','--untracked-files=all')))) 'Production release requires a clean worktree.'
$integratedTree = Invoke-NxbGit -WorkingDirectory $repositoryRoot -ArgumentList @('rev-parse',($expected + '^{tree}'))
$certifiedTree = Invoke-NxbGit -WorkingDirectory $repositoryRoot -ArgumentList @('rev-parse',($certified + '^{tree}'))
Assert-Nxb ($integratedTree -ceq $certifiedTree) 'Integrated merge tree differs from exact certified repair tree.'
$parentLine = Invoke-NxbGit -WorkingDirectory $repositoryRoot -ArgumentList @('rev-list','--parents','-n','1',$expected)
$parentTokens = @($parentLine -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
Assert-Nxb ($parentTokens.Count -ge 3) 'Production integrated head is not a merge commit.'
Assert-Nxb (@($parentTokens | Select-Object -Skip 1 | Where-Object { $_ -ceq $certified }).Count -eq 1) 'Certified repair head is not a direct parent of production merge head.'
$predecessorAncestor = Invoke-NxbNative -Executable $script:Git -WorkingDirectory $repositoryRoot -ArgumentList @('merge-base','--is-ancestor',[string]$policy.predecessor.head,$expected)
Assert-Nxb ($predecessorAncestor.exit_code -eq 0) 'Frozen v1.0.0 predecessor is not an ancestor of production head.'
Assert-Nxb ((Get-NxbRemoteHead -Branch ([string]$policy.branches.main)) -ceq $expected) 'Remote main is not exact production head.'
Assert-Nxb ((Get-NxbRemoteHead -Branch ([string]$policy.branches.release)) -ceq $expected) 'Remote v1.0.1 release branch is not exact production head.'
Assert-Nxb ((Get-NxbRemoteHead -Branch ([string]$policy.branches.historical_certified)) -ceq [string]$policy.predecessor.historical_certified_pointer) 'Historical Phase-7 pointer drifted.'
$successorTagStart = Invoke-NxbGit -ArgumentList @('ls-remote','--tags',$script:Origin,('refs/tags/{0}' -f [string]$policy.tag),('refs/tags/{0}^{{}}' -f [string]$policy.tag))
Assert-Nxb ([string]::IsNullOrWhiteSpace($successorTagStart)) 'v1.0.1 tag already exists; refuse duplicate or rewrite.'
$predecessorTag = Invoke-NxbGit -ArgumentList @('ls-remote','--tags',$script:Origin,('refs/tags/{0}^{{}}' -f [string]$policy.predecessor.tag))
Assert-Nxb ($predecessorTag -match ('^{0}\s+' -f [regex]::Escape([string]$policy.predecessor.head))) 'Frozen predecessor tag peeled target drift.'

Write-Information '[2/18] Snapshot frozen predecessor GitHub Release authority'
$predecessorSnapshot = Get-NxbPredecessorReleaseSnapshot -Policy $policy

Write-Information '[3/18] Exact-head workflow_dispatch CI and job closure'
$run = Invoke-NxbGhJson -Endpoint ('repos/{0}/actions/runs/{1}' -f $script:Repository,$NativeRunId)
Assert-Nxb ([string]$run.name -ceq [string]$policy.ci.workflow_name -and [string]$run.event -ceq [string]$policy.ci.required_event -and [string]$run.head_sha -ceq $certified -and [string]$run.conclusion -ceq 'success') 'Canonical native CI run identity/conclusion mismatch.'
$jobsDocument = Invoke-NxbGhJson -Endpoint ('repos/{0}/actions/runs/{1}/jobs?per_page=100' -f $script:Repository,$NativeRunId)
$jobs = @($jobsDocument.jobs | Where-Object { [int]$_.run_attempt -eq [int]$run.run_attempt })
foreach ($requiredJobObject in @($policy.ci.required_jobs)) {
    $requiredJob = [string]$requiredJobObject
    $match = @($jobs | Where-Object { [string]$_.name -ceq $requiredJob })
    Assert-Nxb ($match.Count -eq 1 -and [string]$match[0].conclusion -ceq 'success') ('Required CI job did not close SUCCESS: {0}' -f $requiredJob)
}
$nativeJob = @($jobs | Where-Object { [string]$_.name -ceq 'nxb-v1 / native-wpt' })[0]
$actualLabels = @($nativeJob.labels | ForEach-Object { [string]$_ } | Sort-Object)
$expectedLabels = @($policy.ci.native_runner_labels | ForEach-Object { [string]$_ } | Sort-Object)
Assert-Nxb ($actualLabels.Count -eq $expectedLabels.Count -and @(Compare-Object -ReferenceObject $expectedLabels -DifferenceObject $actualLabels).Count -eq 0) 'Native runner label identity drift.'
Assert-Nxb ([string]$nativeJob.runner_name -ceq [string]$policy.ci.native_runner_name) 'Native runner name identity drift.'

Write-Information '[4/18] Download and independently audit hosted/native CI artifact archives'
$artifactDocument = Invoke-NxbGhJson -Endpoint ('repos/{0}/actions/runs/{1}/artifacts?per_page=100' -f $script:Repository,$NativeRunId)
$hostedArtifactName = [string]$policy.ci.hosted_artifact_prefix + $certified
$nativeArtifactName = [string]$policy.ci.native_artifact_prefix + $certified
$hostedArtifact = @($artifactDocument.artifacts | Where-Object { [string]$_.name -ceq $hostedArtifactName -and -not [bool]$_.expired })
$nativeArtifact = @($artifactDocument.artifacts | Where-Object { [string]$_.name -ceq $nativeArtifactName -and -not [bool]$_.expired })
Assert-Nxb ($hostedArtifact.Count -eq 1 -and $nativeArtifact.Count -eq 1) 'Expected exact-head hosted/native artifacts were not found uniquely.'
$ghTokenRun = Invoke-NxbNative -Executable $script:Gh -ArgumentList @('auth','token')
Assert-Nxb ($ghTokenRun.exit_code -eq 0 -and -not [string]::IsNullOrWhiteSpace($ghTokenRun.output)) 'Unable to obtain authenticated GitHub token for artifact audit.'
$ghToken = $ghTokenRun.output.Trim()
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $HOME 'Downloads' }
$outputParent = [IO.Path]::GetFullPath($OutputRoot)
[IO.Directory]::CreateDirectory($outputParent) | Out-Null
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$releaseRoot = Join-Path $outputParent ('NXB-V1.0.1-Production-Release-{0}-{1}' -f $expected.Substring(0,8),$stamp)
Assert-Nxb (-not (Test-Path -LiteralPath $releaseRoot)) 'Production release output root already exists.'
[IO.Directory]::CreateDirectory($releaseRoot) | Out-Null
$ciRoot = Join-Path $releaseRoot 'ci-evidence'
[IO.Directory]::CreateDirectory($ciRoot) | Out-Null
$hostedArchive = Join-Path $ciRoot 'hosted-artifact.zip'
$nativeArchive = Join-Path $ciRoot 'native-artifact.zip'
$hostedArchiveSha = Save-NxbGitHubArtifactArchive -ArtifactId ([long]$hostedArtifact[0].id) -OutputPath $hostedArchive -ExpectedDigest ([string]$hostedArtifact[0].digest) -Token $ghToken
$nativeArchiveSha = Save-NxbGitHubArtifactArchive -ArtifactId ([long]$nativeArtifact[0].id) -OutputPath $nativeArchive -ExpectedDigest ([string]$nativeArtifact[0].digest) -Token $ghToken

$predecessorExpectedAssets = Get-NxbPredecessorExpectedAssetMap -Policy $policy
$predecessorAssetRoot = Join-Path $releaseRoot 'predecessor-assets'
[IO.Directory]::CreateDirectory($predecessorAssetRoot) | Out-Null
$predecessorPackageAsset = @($predecessorSnapshot.assets | Where-Object { [string]$_.name -ceq 'nxb-v1.0.0.zip' })
$predecessorManifestAsset = @($predecessorSnapshot.assets | Where-Object { [string]$_.name -ceq 'package-manifest.json' })
Assert-Nxb ($predecessorPackageAsset.Count -eq 1 -and $predecessorManifestAsset.Count -eq 1) 'Frozen predecessor package/manifest assets are not unique.'
$predecessorPackageZip = Join-Path $predecessorAssetRoot 'nxb-v1.0.0.zip'
$predecessorManifestPath = Join-Path $predecessorAssetRoot 'package-manifest.json'
[void](Save-NxbGitHubReleaseAsset -AssetId ([long]$predecessorPackageAsset[0].id) -OutputPath $predecessorPackageZip -ExpectedSha256 $predecessorExpectedAssets['nxb-v1.0.0.zip'] -Token $ghToken)
[void](Save-NxbGitHubReleaseAsset -AssetId ([long]$predecessorManifestAsset[0].id) -OutputPath $predecessorManifestPath -ExpectedSha256 $predecessorExpectedAssets['package-manifest.json'] -Token $ghToken)
$predecessorManifest = Get-Content -LiteralPath $predecessorManifestPath -Raw | ConvertFrom-Json
Assert-Nxb ([string]$predecessorManifest.release_version -ceq '1.0.0' -and [string]$predecessorManifest.source_head -ceq [string]$policy.predecessor.head) 'Predecessor package manifest identity drift.'
$predecessorExtractRoot = Join-Path $predecessorAssetRoot 'package-extracted'
Expand-Archive -LiteralPath $predecessorPackageZip -DestinationPath $predecessorExtractRoot
$predecessorPackageRoot = Resolve-NxbExtractedPackageRoot -ExtractRoot $predecessorExtractRoot -Manifest $predecessorManifest
Assert-Nxb (Test-NxbPackageRootAgainstManifest -Root $predecessorPackageRoot -Manifest $predecessorManifest) 'Frozen predecessor package bytes do not match pinned manifest.'
$ghToken = $null
$hostedExtract = Join-Path $ciRoot 'hosted'
$nativeExtract = Join-Path $ciRoot 'native'
Expand-Archive -LiteralPath $hostedArchive -DestinationPath $hostedExtract
Expand-Archive -LiteralPath $nativeArchive -DestinationPath $nativeExtract
$hostedReceiptPath = Join-Path $hostedExtract 'hosted-ci-receipt.json'
$nativeReceiptPath = Join-Path $nativeExtract 'native-ci-receipt.json'
$embeddedHostedPath = Join-Path $nativeExtract 'hosted\hosted-ci-receipt.json'
$nativeCalibrationPath = Join-Path $nativeExtract 'native-calibration.json'
$nativeReviewZip = Join-Path $nativeExtract 'native-ci-review.zip'
foreach ($required in @($hostedReceiptPath,$nativeReceiptPath,$embeddedHostedPath,$nativeCalibrationPath,$nativeReviewZip)) { Assert-Nxb (Test-Path -LiteralPath $required -PathType Leaf) ('CI artifact evidence missing: {0}' -f $required) }
$hostedReceipt = Get-Content -LiteralPath $hostedReceiptPath -Raw | ConvertFrom-Json
$nativeReceipt = Get-Content -LiteralPath $nativeReceiptPath -Raw | ConvertFrom-Json
$embeddedHosted = Get-Content -LiteralPath $embeddedHostedPath -Raw | ConvertFrom-Json
Assert-Nxb (Test-NxbHostedReceipt -Receipt $hostedReceipt -Head $certified -Policy $policy) 'Hosted CI receipt contract failed.'
Assert-Nxb (Test-NxbHostedReceipt -Receipt $embeddedHosted -Head $certified -Policy $policy) 'Native replayed hosted receipt contract failed.'
Assert-Nxb (Test-NxbNativeReceipt -Receipt $nativeReceipt -Head $certified -Policy $policy) 'Native CI receipt contract failed.'
Assert-Nxb ([string]$nativeReceipt.hosted_receipt_sha256 -ceq (Get-NxbSha256 -Path $embeddedHostedPath)) 'Native receipt hosted-replay SHA binding mismatch.'
Assert-Nxb ([string]$nativeReceipt.native_calibration_sha256 -ceq (Get-NxbSha256 -Path $nativeCalibrationPath)) 'Native receipt calibration SHA binding mismatch.'
$reviewExtract = Join-Path $ciRoot 'native-review'
Expand-Archive -LiteralPath $nativeReviewZip -DestinationPath $reviewExtract
$reviewBindings = [ordered]@{
    'hosted-ci-receipt.json'=$embeddedHostedPath; 'native-calibration.json'=$nativeCalibrationPath; 'native-ci-receipt.json'=$nativeReceiptPath;
    'native-profile-parser.txt'=(Join-Path $nativeExtract 'native-profile-parser.txt'); 'pester-ps51.xml'=(Join-Path $nativeExtract 'hosted\pester-ps51.xml');
    'pester-ps7.xml'=(Join-Path $nativeExtract 'hosted\pester-ps7.xml'); 'ps51-summary.json'=(Join-Path $nativeExtract 'hosted\ps51-summary.json')
}
Assert-Nxb (@(Get-ChildItem -LiteralPath $reviewExtract -File -Recurse).Count -eq [int]$policy.ci.native_review_entries) 'Native review ZIP entry-count drift.'
foreach ($binding in $reviewBindings.GetEnumerator()) {
    $reviewPath = Join-Path $reviewExtract ([string]$binding.Key).Replace('/',[IO.Path]::DirectorySeparatorChar)
    $sourcePath = [string]$binding.Value
    Assert-Nxb ((Test-Path -LiteralPath $reviewPath -PathType Leaf) -and (Test-Path -LiteralPath $sourcePath -PathType Leaf)) ('Native review binding file missing: {0}' -f [string]$binding.Key)
    Assert-Nxb ((Get-NxbSha256 -Path $reviewPath) -ceq (Get-NxbSha256 -Path $sourcePath)) ('Native review entry is not byte-identical: {0}' -f [string]$binding.Key)
}
$ciAuditPath = Join-Path $releaseRoot 'ci-authority-audit.json'
Write-NxbJsonNew -Path $ciAuditPath -Value ([pscustomobject][ordered]@{
    schema_version=1; status='passed'; authority='nxb-v1-production-ci-audit-v1'; certified_head=$certified; integrated_head=$expected; run_id=$NativeRunId; run_attempt=[int]$run.run_attempt;
    hosted_artifact_id=[long]$hostedArtifact[0].id; hosted_artifact_sha256=$hostedArchiveSha; native_artifact_id=[long]$nativeArtifact[0].id; native_artifact_sha256=$nativeArchiveSha;
    hosted_receipt_sha256=(Get-NxbSha256 -Path $hostedReceiptPath); native_receipt_sha256=(Get-NxbSha256 -Path $nativeReceiptPath); native_review_zip_sha256=(Get-NxbSha256 -Path $nativeReviewZip);
    native_calibration_sha256=(Get-NxbSha256 -Path $nativeCalibrationPath); native_runner_name=[string]$nativeJob.runner_name
})

Write-Information '[5/18] Fresh integrated-head successor and release-integration authorities'
$certRoot = Join-Path $releaseRoot 'certifications'
[IO.Directory]::CreateDirectory($certRoot) | Out-Null
$successorRun = Invoke-NxbNative -Executable $python -WorkingDirectory $repositoryRoot -ArgumentList @((Join-Path $repositoryRoot 'tools\validate_v1_successor.py'),'--repository-root',$repositoryRoot,'--expected-head',$expected)
Assert-Nxb ($successorRun.exit_code -eq 0) ('Successor validator failed on integrated head: {0}' -f $successorRun.output)
$releaseIntegrationOutput = Join-Path $certRoot 'release-integration'
& (Join-Path $repositoryRoot 'scripts\Invoke-NxbV1ReleaseIntegrationCertification.ps1') -ExpectedHead $expected -OutputDirectory $releaseIntegrationOutput | Out-Null

Write-Information '[6/18] Fresh signing, installer and update certification authorities'
foreach ($authority in @(
    [pscustomobject]@{ name='production-signing'; path=(Join-Path $repositoryRoot 'scripts\Invoke-NxbV1ProductionSigningCertification.ps1') },
    [pscustomobject]@{ name='installer'; path=(Join-Path $repositoryRoot 'scripts\Invoke-NxbV1InstallerCertification.ps1') },
    [pscustomobject]@{ name='update'; path=(Join-Path $repositoryRoot 'scripts\Invoke-NxbV1UpdateCertification.ps1') }
)) {
    $out = Join-Path $certRoot ([string]$authority.name)
    & ([string]$authority.path) -ExpectedHead $expected -OutputDirectory $out | Out-Null
}

Write-Information '[7/18] Build bounded runtime package and v1.0.1 package manifest'
$artifactRoot = Join-Path $releaseRoot 'artifact-root'
$packageRoot = Join-Path $artifactRoot 'package'
$updateRoot = Join-Path $artifactRoot 'update'
$distRoot = Join-Path $artifactRoot 'dist'
$operationsRoot = Join-Path $artifactRoot 'operations'
foreach ($directory in @($artifactRoot,$updateRoot,$distRoot,$operationsRoot)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
$maximumReleaseArtifacts = [int]$signingPolicy.release_manifest.maximum_artifacts
$reservedSignedArtifacts = 5
$maximumPackageFiles = $maximumReleaseArtifacts - $reservedSignedArtifacts
$packageSurfacePath = Join-Path $releaseRoot 'runtime-package-surface-receipt.json'
$runtimePackage = Copy-NxbRuntimeClosurePackage -RepositoryRoot $repositoryRoot -Destination $packageRoot -MaximumPackageFiles $maximumPackageFiles -ReceiptPath $packageSurfacePath
$manifestPath = Join-Path $releaseRoot ([string]$policy.package.manifest_name)
& (Join-Path $repositoryRoot 'scripts\Export-NxbV1PackageManifest.ps1') -PackageRoot $packageRoot -SourceHead $expected -OutputPath $manifestPath | Out-Null
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
Assert-Nxb ([string]$manifest.release_version -ceq [string]$policy.target_version -and [string]$manifest.source_head -ceq $expected -and [int]$manifest.file_count -eq @($runtimePackage.paths).Count) 'Production package manifest identity/count drift.'
$manifestSha = Get-NxbSha256 -Path $manifestPath

Write-Information '[8/18] Integrated CLI and portable installer smoke'
foreach ($commandName in @('status','version')) {
    $cli = Invoke-NxbNative -Executable (Get-Command pwsh.exe).Source -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $repositoryRoot 'scripts\nxb.ps1'),'-Command',$commandName,'-Json','-CliProcess','-NonInteractive')
    Assert-Nxb ($cli.exit_code -eq 0) ('Integrated CLI smoke failed: {0}' -f $commandName)
}
$portableRoot = Join-Path $releaseRoot 'portable-smoke'
$portableStageReceipt = Join-Path $releaseRoot 'portable-stage-receipt.json'
$portableUninstallReceipt = Join-Path $releaseRoot 'portable-uninstall-receipt.json'
& (Join-Path $repositoryRoot 'scripts\Invoke-NxbV1Installer.ps1') -Action Stage -Mode Portable -PackageRoot $packageRoot -ManifestPath $manifestPath -InstallRoot $portableRoot -ReceiptPath $portableStageReceipt -Confirm:$false | Out-Null
$installedVersion = Invoke-NxbNative -Executable (Get-Command pwsh.exe).Source -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $portableRoot 'scripts\nxb.ps1'),'-Command','version','-Json','-CliProcess','-NonInteractive')
Assert-Nxb ($installedVersion.exit_code -eq 0 -and $installedVersion.output -match '1\.0\.1') 'Installed portable CLI version smoke failed.'
& (Join-Path $repositoryRoot 'scripts\Invoke-NxbV1Installer.ps1') -Action Uninstall -Mode Portable -PackageRoot $packageRoot -ManifestPath $manifestPath -InstallRoot $portableRoot -ReceiptPath $portableUninstallReceipt -Confirm:$false | Out-Null
Assert-Nxb (-not (Test-Path -LiteralPath $portableRoot)) 'Portable uninstall did not remove managed install root.'

Write-Information '[9/18] Release notes, update metadata, operational policies and deterministic ZIP'
$releaseNotesPath = Join-Path $releaseRoot ([string]$policy.package.release_notes_name)
$releaseNotes = @"
NXB v1.0.1

Frozen predecessor: $([string]$policy.predecessor.head)
Certified successor head: $certified
Integrated production head: $expected
Integrated production tree: $integratedTree
Canonical native CI run: $NativeRunId

Production closure:
- Exact-head hosted and self-hosted Windows native WPT authority passed on the certified successor head.
- The integrated merge commit directly preserves that certified head and has a byte-identical tree.
- Package manifest is bound to v1.0.1 and the integrated production head.
- Production signing uses only the protected Windows Certificate Store signer matching the frozen predecessor public fingerprint.
- Signed updater validation is Stage-only before public release; auto_apply remains false.
- v1.0.0 tag, Release assets, receipts and historical Phase-7 pointer remain immutable.

No production private key is stored in the repository or release assets.
"@
[IO.File]::WriteAllText($releaseNotesPath,$releaseNotes,[Text.UTF8Encoding]::new($false))
$rotationPath = Join-Path $operationsRoot 'production-key-rotation-policy.txt'
[IO.File]::WriteAllText($rotationPath,"NXB v1 production signing key rotation policy`n`nSigner rotation is not implicit. A replacement signer requires an explicit successor release authority, new trusted fingerprint, custody review, revocation review, and new immutable receipts. Never rewrite an existing release in place.`n",[Text.UTF8Encoding]::new($false))
$revocationPath = Join-Path $operationsRoot 'production-revocation-policy.txt'
[IO.File]::WriteAllText($revocationPath,"NXB v1 production signing certificate revocation policy`n`nOn suspected or confirmed compromise, stop release signing, revoke the certificate through the issuing PKI, remove it from trust for successor releases, record affected release scope, and publish a successor security/update decision. Historical bytes and receipts remain immutable evidence.`n",[Text.UTF8Encoding]::new($false))
$descriptorPath = Join-Path $updateRoot 'update-descriptor.json'
Write-NxbJsonNew -Path $descriptorPath -Value ([pscustomobject][ordered]@{
    schema_version=1; contract_id='nxb-v1-update-descriptor-v1'; channel=[string]$policy.channel; release_version=[string]$policy.target_version; release_sequence=[int]$policy.release_sequence;
    release_head=$expected; certified_implementation_head=[string]$policy.implementation.certified_head; package_manifest_sha256=$manifestSha; created_utc=[DateTime]::UtcNow.ToString('o')
})
$packageZip = Join-Path $distRoot ([string]$policy.package.zip_name)
Export-NxbDeterministicZip -Root $packageRoot -Output $packageZip

Write-Information '[10/18] Production signer fingerprint and protected-key gate'
$signingCommon = Join-Path $repositoryRoot 'scripts\NxbV1ProductionSigning.Common.ps1'
$candidates = @(Get-NxbProductionSignerCandidate -CommonPath $signingCommon | Where-Object { [string]$_.public_fingerprint -ceq [string]$policy.predecessor.production_signer_fingerprint })
if (-not [string]::IsNullOrWhiteSpace($CertificateStoreLocation)) { $candidates = @($candidates | Where-Object { [string]$_.store_location -ceq $CertificateStoreLocation }) }
if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
    $normalizedThumbprint = $CertificateThumbprint.Replace(' ','').ToUpperInvariant()
    $candidates = @($candidates | Where-Object { [string]$_.thumbprint -ceq $normalizedThumbprint })
}
$signerGatePath = Join-Path $releaseRoot 'production-signer-gate.json'
if ($candidates.Count -ne 1) {
    Write-NxbJsonNew -Path $signerGatePath -Value ([pscustomobject][ordered]@{ schema_version=1; status='blocked'; authority='nxb-v1-production-signer-gate-v2'; expected_public_fingerprint=[string]$policy.predecessor.production_signer_fingerprint; candidate_count=$candidates.Count; candidates=$candidates; no_key_generated=$true; no_private_key_exported=$true })
    throw ('Production signer gate requires exactly one protected certificate matching frozen public fingerprint. actual={0}' -f $candidates.Count)
}
$selected = $candidates[0]
Write-NxbJsonNew -Path $signerGatePath -Value ([pscustomobject][ordered]@{ schema_version=1; status='passed'; authority='nxb-v1-production-signer-gate-v2'; expected_public_fingerprint=[string]$policy.predecessor.production_signer_fingerprint; selected=$selected; no_key_generated=$true; no_private_key_exported=$true })
$trustPath = Join-Path $updateRoot 'update-trust.json'
Write-NxbJsonNew -Path $trustPath -Value ([pscustomobject][ordered]@{ schema_version=1; contract_id='nxb-v1-update-trust-v1'; channel=[string]$policy.channel; trusted_signer_fingerprint=[string]$selected.public_fingerprint; minimum_release_sequence=[int]$policy.release_sequence; allow_downgrade=$false; revoked_release_heads=@() })

Write-Information '[11/18] Production signature envelope and independent production-mode verification'
$artifactPaths = [Collections.Generic.List[string]]::new()
foreach ($file in @($manifest.files)) { $artifactPaths.Add('package/' + [string]$file.path) }
$artifactPaths.Add('update/update-descriptor.json')
$artifactPaths.Add('update/update-trust.json')
$artifactPaths.Add('dist/' + [string]$policy.package.zip_name)
$artifactPaths.Add('operations/production-key-rotation-policy.txt')
$artifactPaths.Add('operations/production-revocation-policy.txt')
Assert-Nxb ($artifactPaths.Count -eq (@($manifest.files).Count + $reservedSignedArtifacts) -and $artifactPaths.Count -le $maximumReleaseArtifacts) 'Production signed artifact accounting drift.'
$envelopePath = Join-Path $releaseRoot 'signature-envelope.json'
$envelopePipeline = @(& (Join-Path $repositoryRoot 'scripts\Invoke-NxbV1ReleaseManifestSigning.ps1') -SignerMode ProductionWindowsCertificateStore -ReleaseHead $expected -CertifiedImplementationHead ([string]$policy.implementation.certified_head) -PackageManifestPath $manifestPath -ReleaseNotesPath $releaseNotesPath -ArtifactRoot $artifactRoot -ArtifactPath @($artifactPaths) -OutputPath $envelopePath -StoreLocation ([string]$selected.store_location) -StoreName 'My' -Thumbprint ([string]$selected.thumbprint) -PassThru)
$envelope = $null
foreach ($item in $envelopePipeline) { if ($null -ne $item -and $null -ne $item.PSObject.Properties['signature_b64']) { $envelope=$item } }
Assert-Nxb ($null -ne $envelope -and [string]$envelope.signer_mode -ceq 'production-windows-certificate-store' -and [bool]$envelope.production_signer_claimed -and [string]$envelope.public_key.fingerprint -ceq [string]$policy.predecessor.production_signer_fingerprint) 'Production envelope signer/fingerprint boundary failed.'
$productionIndependentPath = Join-Path $releaseRoot 'production-signing-independent.json'
$productionIndependentRun = Invoke-NxbNative -Executable $python -ArgumentList @((Join-Path $repositoryRoot 'tools\validate_v1_production_signing.py'),'--policy',$signingPolicyPath,'--envelope',$envelopePath,'--expected-release-head',$expected,'--expected-certified-head',([string]$policy.implementation.certified_head),'--expected-signer-mode','production-windows-certificate-store','--expected-production-fingerprint',([string]$policy.predecessor.production_signer_fingerprint),'--output',$productionIndependentPath)
Assert-Nxb ($productionIndependentRun.exit_code -eq 0) ('Independent production signer verification failed: {0}' -f $productionIndependentRun.output)
$productionIndependent = Get-Content -LiteralPath $productionIndependentPath -Raw | ConvertFrom-Json
Assert-Nxb ([string]$productionIndependent.status -ceq 'passed' -and [string]$productionIndependent.authority -ceq 'nxb-v1-production-signing-independent-v2' -and [string]$productionIndependent.expected_signer_mode -ceq 'production-windows-certificate-store' -and [int]$productionIndependent.requirements_validated -eq 12 -and [int]$productionIndependent.negative_controls_validated -eq 8 -and @($productionIndependent.failures).Count -eq 0) 'Independent production signing closure is not 12/12 + 8/8.'

Write-Information '[12/18] Frozen v1.0.0 -> production-signed v1.0.1 Stage-only updater smoke'
$updateInstallRoot = Join-Path $releaseRoot 'update-smoke-install'
$updateStateRoot = Join-Path $releaseRoot 'update-smoke-state'
[IO.Directory]::CreateDirectory($updateStateRoot) | Out-Null
$updateInstallReceipt = Join-Path $releaseRoot 'update-smoke-install-receipt.json'
$updateStageReceipt = Join-Path $releaseRoot 'update-smoke-stage-receipt.json'
$updateUninstallReceipt = Join-Path $releaseRoot 'update-smoke-uninstall-receipt.json'
$predecessorTransitionReceiptPath = Join-Path $releaseRoot 'predecessor-transition-stage-receipt.json'
& (Join-Path $repositoryRoot 'scripts\Invoke-NxbV1Installer.ps1') -Action Install -Mode PerUser -PackageRoot $predecessorPackageRoot -ManifestPath $predecessorManifestPath -InstallRoot $updateInstallRoot -ReceiptPath $updateInstallReceipt -Confirm:$false | Out-Null
$predecessorStatePath = Join-Path $updateInstallRoot '.nxb-install-state.json'
Assert-Nxb (Test-Path -LiteralPath $predecessorStatePath -PathType Leaf) 'Predecessor install state is missing before Stage.'
$predecessorState = Get-Content -LiteralPath $predecessorStatePath -Raw | ConvertFrom-Json
Assert-Nxb ([string]$predecessorState.release_version -ceq '1.0.0' -and [string]$predecessorState.source_head -ceq [string]$policy.predecessor.head -and [string]$predecessorState.package_manifest_sha256 -ceq (Get-NxbSha256 -Path $predecessorManifestPath)) 'Predecessor install-state identity drift before Stage.'
& (Join-Path $repositoryRoot 'scripts\Invoke-NxbV1Updater.ps1') -Action Stage -InstallRoot $updateInstallRoot -UpdateRoot $updateStateRoot -ReceiptPath $updateStageReceipt -PackageRoot $packageRoot -ManifestPath $manifestPath -DescriptorPath $descriptorPath -EnvelopePath $envelopePath -TrustPath $trustPath -Confirm:$false | Out-Null
$stageReceipt = Get-Content -LiteralPath $updateStageReceipt -Raw | ConvertFrom-Json
Assert-Nxb ([string]$stageReceipt.status -ceq 'passed' -and [int]$stageReceipt.release_sequence -eq [int]$policy.release_sequence -and [string]$stageReceipt.release_head -ceq $expected -and -not [bool]$stageReceipt.auto_apply -and -not [bool]$stageReceipt.production_release_updated) 'Production signed Stage-only updater smoke failed.'
$postStageState = Get-Content -LiteralPath $predecessorStatePath -Raw | ConvertFrom-Json
Assert-Nxb ([string]$postStageState.release_version -ceq '1.0.0' -and [string]$postStageState.source_head -ceq [string]$policy.predecessor.head -and [string]$postStageState.package_manifest_sha256 -ceq [string]$predecessorState.package_manifest_sha256) 'Stage-only smoke mutated predecessor install state.'
Write-NxbJsonNew -Path $predecessorTransitionReceiptPath -Value ([pscustomobject][ordered]@{
    schema_version=1; status='passed'; authority='nxb-v1-predecessor-update-stage-smoke-v1'; predecessor_version='1.0.0'; predecessor_head=[string]$policy.predecessor.head;
    predecessor_package_sha256=(Get-NxbSha256 -Path $predecessorPackageZip); predecessor_manifest_sha256=(Get-NxbSha256 -Path $predecessorManifestPath); successor_version=[string]$policy.target_version;
    successor_head=$expected; release_sequence=[int]$stageReceipt.release_sequence; stage_receipt_sha256=(Get-NxbSha256 -Path $updateStageReceipt); install_state_preserved=$true;
    auto_apply=[bool]$stageReceipt.auto_apply; production_release_updated=[bool]$stageReceipt.production_release_updated
})
& (Join-Path $repositoryRoot 'scripts\Invoke-NxbV1Installer.ps1') -Action Uninstall -Mode PerUser -PackageRoot $predecessorPackageRoot -ManifestPath $predecessorManifestPath -InstallRoot $updateInstallRoot -ReceiptPath $updateUninstallReceipt -Confirm:$false | Out-Null
if (Test-Path -LiteralPath $updateStateRoot) { Remove-Item -LiteralPath $updateStateRoot -Recurse -Force }

Write-Information '[13/18] Production readiness and public evidence bundle'
$readinessPath = Join-Path $releaseRoot 'production-readiness-receipt.json'
Write-NxbJsonNew -Path $readinessPath -Value ([pscustomobject][ordered]@{
    schema_version=1; status='passed'; authority='nxb-v1-production-readiness-v2'; release_version=[string]$policy.target_version; certified_head=$certified; release_head=$expected; release_tree=$integratedTree;
    native_run_id=$NativeRunId; ci_authority_audit_sha256=(Get-NxbSha256 -Path $ciAuditPath); runtime_package_surface_receipt_sha256=(Get-NxbSha256 -Path $packageSurfacePath);
    package_manifest_sha256=$manifestSha; package_zip_sha256=(Get-NxbSha256 -Path $packageZip); release_notes_sha256=(Get-NxbSha256 -Path $releaseNotesPath); signature_envelope_sha256=(Get-NxbSha256 -Path $envelopePath);
    signer_fingerprint=[string]$envelope.public_key.fingerprint; production_signer_claimed=[bool]$envelope.production_signer_claimed; independent_production_signing_sha256=(Get-NxbSha256 -Path $productionIndependentPath);
    portable_stage_receipt_sha256=(Get-NxbSha256 -Path $portableStageReceipt); portable_uninstall_receipt_sha256=(Get-NxbSha256 -Path $portableUninstallReceipt); update_stage_receipt_sha256=(Get-NxbSha256 -Path $updateStageReceipt); predecessor_transition_stage_receipt_sha256=(Get-NxbSha256 -Path $predecessorTransitionReceiptPath);
    update_auto_apply=[bool]$stageReceipt.auto_apply; update_production_release_updated=[bool]$stageReceipt.production_release_updated; production_merge_performed=$true; tag_created=$false; github_release_created=$false; freeze_ready=$true
})
$publicEvidenceRoot = Join-Path $releaseRoot 'public-evidence'
[IO.Directory]::CreateDirectory($publicEvidenceRoot) | Out-Null
$evidenceRows = [ordered]@{
    'ci-authority-audit.json'=$ciAuditPath; 'runtime-package-surface-receipt.json'=$packageSurfacePath; 'package-manifest.json'=$manifestPath; 'signature-envelope.json'=$envelopePath;
    'production-signing-independent.json'=$productionIndependentPath; 'production-readiness-receipt.json'=$readinessPath; 'portable-stage-receipt.json'=$portableStageReceipt;
    'portable-uninstall-receipt.json'=$portableUninstallReceipt; 'update-stage-receipt.json'=$updateStageReceipt; 'predecessor-transition-stage-receipt.json'=$predecessorTransitionReceiptPath; 'production-signer-gate.json'=$signerGatePath
}
$evidenceManifestEntries = [Collections.Generic.List[object]]::new()
foreach ($row in $evidenceRows.GetEnumerator()) {
    $destination = Join-Path $publicEvidenceRoot ([string]$row.Key)
    [IO.File]::Copy([string]$row.Value,$destination,$false)
    $evidenceManifestEntries.Add([pscustomobject][ordered]@{ name=[string]$row.Key; sha256=(Get-NxbSha256 -Path $destination); bytes=[long](Get-Item -LiteralPath $destination).Length })
}
Write-NxbJsonNew -Path (Join-Path $publicEvidenceRoot 'evidence-hashes.json') -Value ([pscustomobject][ordered]@{ schema_version=1; status='passed'; authority='nxb-v1-public-evidence-hash-manifest-v2'; release_head=$expected; entries=@($evidenceManifestEntries) })
$publicEvidenceZip = Join-Path $releaseRoot ([string]$policy.package.public_evidence_zip_name)
Export-NxbDeterministicZip -Root $publicEvidenceRoot -Output $publicEvidenceZip

Write-Information '[14/18] Final pre-tag CAS, signer and predecessor immutability gate'
Assert-Nxb ((Get-NxbRemoteHead -Branch ([string]$policy.branches.main)) -ceq $expected) 'main moved before tag.'
Assert-Nxb ((Get-NxbRemoteHead -Branch ([string]$policy.branches.release)) -ceq $expected) 'release branch moved before tag.'
Assert-Nxb ((Get-NxbRemoteHead -Branch ([string]$policy.branches.historical_certified)) -ceq [string]$policy.predecessor.historical_certified_pointer) 'historical certified pointer moved before tag.'
$predecessorBeforeTag = Get-NxbPredecessorReleaseSnapshot -Policy $policy
Assert-Nxb ((($predecessorBeforeTag | ConvertTo-Json -Depth 20 -Compress)) -ceq (($predecessorSnapshot | ConvertTo-Json -Depth 20 -Compress))) 'Frozen predecessor GitHub Release changed during production preparation.'
$ghAuth = Invoke-NxbNative -Executable $script:Gh -ArgumentList @('auth','status','--hostname','github.com')
Assert-Nxb ($ghAuth.exit_code -eq 0) 'GitHub CLI authentication gate failed before tag.'

Write-Information '[15/18] Create and push immutable annotated v1.0.1 tag'
$localTag = Invoke-NxbGit -WorkingDirectory $repositoryRoot -ArgumentList @('tag','--list',[string]$policy.tag)
Assert-Nxb ([string]::IsNullOrWhiteSpace($localTag)) 'Local v1.0.1 tag already exists.'
Invoke-NxbGit -WorkingDirectory $repositoryRoot -ArgumentList @('tag','-a',[string]$policy.tag,$expected,'-m','NXB v1.0.1 production release') | Out-Null
Invoke-NxbGit -WorkingDirectory $repositoryRoot -ArgumentList @('push','origin',('refs/tags/{0}' -f [string]$policy.tag)) | Out-Null
$peeled = Invoke-NxbGit -ArgumentList @('ls-remote','--tags',$script:Origin,('refs/tags/{0}^{{}}' -f [string]$policy.tag))
Assert-Nxb ($peeled -match ('^{0}\s+' -f [regex]::Escape($expected))) 'v1.0.1 annotated tag peeled target is not exact production head.'

Write-Information '[16/18] Create GitHub Release and re-download every canonical asset'
$releaseAssetsByName = [ordered]@{
    ([string]$policy.package.zip_name)=$packageZip; ([string]$policy.package.manifest_name)=$manifestPath; ([string]$policy.package.release_notes_name)=$releaseNotesPath;
    'signature-envelope.json'=$envelopePath; 'update-descriptor.json'=$descriptorPath; 'update-trust.json'=$trustPath; 'production-readiness-receipt.json'=$readinessPath;
    ([string]$policy.package.public_evidence_zip_name)=$publicEvidenceZip; 'production-key-rotation-policy.txt'=$rotationPath; 'production-revocation-policy.txt'=$revocationPath
}
$expectedAssetNames = @($policy.release_assets | ForEach-Object { [string]$_ } | Sort-Object)
$actualAssetNames = @($releaseAssetsByName.Keys | ForEach-Object { [string]$_ } | Sort-Object)
Assert-Nxb ($expectedAssetNames.Count -eq $actualAssetNames.Count -and @(Compare-Object -ReferenceObject $expectedAssetNames -DifferenceObject $actualAssetNames).Count -eq 0) 'Production release asset policy/map drift.'
$releaseArguments = [Collections.Generic.List[string]]::new()
foreach ($argument in @('release','create',[string]$policy.tag,'--repo',$script:Repository,'--title','NXB v1.0.1','--notes-file',$releaseNotesPath,'--verify-tag')) { $releaseArguments.Add([string]$argument) }
foreach ($assetName in $actualAssetNames) { $releaseArguments.Add([string]$releaseAssetsByName[$assetName]) }
$releaseCreate = Invoke-NxbNative -Executable $script:Gh -ArgumentList @($releaseArguments)
Assert-Nxb ($releaseCreate.exit_code -eq 0) ('GitHub Release creation failed: {0}' -f $releaseCreate.output)
$verifyRoot = Join-Path $releaseRoot 'release-download-verify'
[IO.Directory]::CreateDirectory($verifyRoot) | Out-Null
$downloadRun = Invoke-NxbNative -Executable $script:Gh -ArgumentList @('release','download',[string]$policy.tag,'--repo',$script:Repository,'--dir',$verifyRoot)
Assert-Nxb ($downloadRun.exit_code -eq 0) ('GitHub Release asset download failed: {0}' -f $downloadRun.output)
foreach ($assetName in $actualAssetNames) {
    $localAsset = [string]$releaseAssetsByName[$assetName]
    $downloaded = Join-Path $verifyRoot $assetName
    Assert-Nxb (Test-Path -LiteralPath $downloaded -PathType Leaf) ('Downloaded release asset missing: {0}' -f $assetName)
    Assert-Nxb ((Get-NxbSha256 -Path $downloaded) -ceq (Get-NxbSha256 -Path $localAsset)) ('Downloaded release asset SHA mismatch: {0}' -f $assetName)
}

Write-Information '[17/18] Final release/predecessor closure receipt'
$releaseViewRun = Invoke-NxbNative -Executable $script:Gh -ArgumentList @('release','view',[string]$policy.tag,'--repo',$script:Repository,'--json','databaseId,tagName,isDraft,isPrerelease,url')
Assert-Nxb ($releaseViewRun.exit_code -eq 0) ('GitHub Release view failed: {0}' -f $releaseViewRun.output)
$releaseView = $releaseViewRun.output | ConvertFrom-Json
Assert-Nxb ([string]$releaseView.tagName -ceq [string]$policy.tag -and -not [bool]$releaseView.isDraft -and -not [bool]$releaseView.isPrerelease) 'GitHub Release final state drift.'
Assert-Nxb ((Get-NxbRemoteHead -Branch ([string]$policy.branches.main)) -ceq $expected -and (Get-NxbRemoteHead -Branch ([string]$policy.branches.release)) -ceq $expected) 'Final main/release CAS drift.'
Assert-Nxb ((Get-NxbRemoteHead -Branch ([string]$policy.branches.historical_certified)) -ceq [string]$policy.predecessor.historical_certified_pointer) 'Historical certified pointer changed during release.'
$predecessorFinal = Get-NxbPredecessorReleaseSnapshot -Policy $policy
Assert-Nxb ((($predecessorFinal | ConvertTo-Json -Depth 20 -Compress)) -ceq (($predecessorSnapshot | ConvertTo-Json -Depth 20 -Compress))) 'Frozen v1.0.0 GitHub Release changed during v1.0.1 publication.'
$finalReceiptPath = Join-Path $releaseRoot ([string]$policy.final_asset)
Write-NxbJsonNew -Path $finalReceiptPath -Value ([pscustomobject][ordered]@{
    schema_version=1; status='passed'; authority='nxb-v1-production-final-closure-v2'; release_version=[string]$policy.target_version; certified_head=$certified; release_head=$expected; release_tree=$integratedTree;
    predecessor_head=[string]$policy.predecessor.head; predecessor_release_id=[long]$policy.predecessor.github_release_id; predecessor_unchanged=$true; historical_certified_pointer=[string]$policy.predecessor.historical_certified_pointer; certified_pointer_moved=$false;
    native_run_id=$NativeRunId; hosted_artifact_sha256=$hostedArchiveSha; native_artifact_sha256=$nativeArchiveSha; ci_authority_audit_sha256=(Get-NxbSha256 -Path $ciAuditPath);
    tag=[string]$policy.tag; tag_peeled_target=$expected; github_release_id=[string]$releaseView.databaseId; github_release_url=[string]$releaseView.url; github_release_draft=[bool]$releaseView.isDraft; github_release_prerelease=[bool]$releaseView.isPrerelease;
    package_manifest_sha256=(Get-NxbSha256 -Path $manifestPath); package_zip_sha256=(Get-NxbSha256 -Path $packageZip); signature_envelope_sha256=(Get-NxbSha256 -Path $envelopePath); signer_fingerprint=[string]$envelope.public_key.fingerprint;
    production_readiness_receipt_sha256=(Get-NxbSha256 -Path $readinessPath); public_evidence_zip_sha256=(Get-NxbSha256 -Path $publicEvidenceZip); downloaded_asset_audit=$true; all_asset_hashes_match=$true;
    production_private_key_exported=$false; production_private_key_in_repository=$false; auto_apply=$false; frozen=$true; created_utc=[DateTime]::UtcNow.ToString('o')
})
$finalSha = Get-NxbSha256 -Path $finalReceiptPath

Write-Information '[18/18] Upload final closure receipt and verify exact bytes'
$finalUpload = Invoke-NxbNative -Executable $script:Gh -ArgumentList @('release','upload',[string]$policy.tag,$finalReceiptPath,'--repo',$script:Repository)
Assert-Nxb ($finalUpload.exit_code -eq 0) ('Final closure receipt upload failed: {0}' -f $finalUpload.output)
$finalVerifyRoot = Join-Path $releaseRoot 'final-receipt-download-verify'
[IO.Directory]::CreateDirectory($finalVerifyRoot) | Out-Null
$finalDownload = Invoke-NxbNative -Executable $script:Gh -ArgumentList @('release','download',[string]$policy.tag,'--repo',$script:Repository,'--pattern',[string]$policy.final_asset,'--dir',$finalVerifyRoot)
Assert-Nxb ($finalDownload.exit_code -eq 0) 'Final closure receipt re-download failed.'
$downloadedFinal = Join-Path $finalVerifyRoot ([string]$policy.final_asset)
Assert-Nxb ((Get-NxbSha256 -Path $downloadedFinal) -ceq $finalSha) 'Final closure receipt uploaded bytes do not match local canonical bytes.'
$finalReleaseSnapshot = Invoke-NxbGhJson -Endpoint ('repos/{0}/releases/tags/{1}' -f $script:Repository,[string]$policy.tag)
Assert-Nxb ([long]$finalReleaseSnapshot.id -eq [long]$releaseView.databaseId) 'Final GitHub Release ID drift.'
$expectedFinalAssets = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
foreach ($assetName in $actualAssetNames) { $expectedFinalAssets.Add([string]$assetName,(Get-NxbSha256 -Path ([string]$releaseAssetsByName[$assetName]))) }
$expectedFinalAssets.Add([string]$policy.final_asset,$finalSha)
$finalAssets = @($finalReleaseSnapshot.assets | ForEach-Object { [pscustomobject][ordered]@{ name=[string]$_.name; digest=[string]$_.digest } })
Assert-Nxb ($finalAssets.Count -eq $expectedFinalAssets.Count) ('Final GitHub Release asset set drift: expected={0} actual={1}' -f $expectedFinalAssets.Count,$finalAssets.Count)
$finalSeen = [Collections.Generic.Dictionary[string,bool]]::new([StringComparer]::Ordinal)
foreach ($asset in $finalAssets) {
    $name = [string]$asset.name
    Assert-Nxb (-not $finalSeen.ContainsKey($name)) ('Final GitHub Release contains duplicate asset name: {0}' -f $name)
    Assert-Nxb ($expectedFinalAssets.ContainsKey($name)) ('Final GitHub Release contains unexpected asset: {0}' -f $name)
    Assert-Nxb ([string]$asset.digest -ceq ('sha256:' + $expectedFinalAssets[$name])) ('Final GitHub Release asset digest drift: {0}' -f $name)
    $finalSeen.Add($name,$true)
}
Assert-Nxb ($finalSeen.Count -eq $expectedFinalAssets.Count) 'Final GitHub Release asset set is incomplete.'

Write-Information ''
Write-Information '=== NXB V1.0.1 PRODUCTION RELEASE CLOSED ==='
Write-Information ('Certified head:        {0}' -f $certified)
Write-Information ('Integrated head:       {0}' -f $expected)
Write-Information ('Integrated tree:       {0}' -f $integratedTree)
Write-Information ('Tag:                   {0}' -f [string]$policy.tag)
Write-Information ('Signer fingerprint:    {0}' -f [string]$envelope.public_key.fingerprint)
Write-Information ('Package ZIP SHA256:    {0}' -f (Get-NxbSha256 -Path $packageZip))
Write-Information ('Final closure SHA256:  {0}' -f $finalSha)
Write-Information ('Release root:          {0}' -f $releaseRoot)
Write-Information 'Frozen v1.0.0 authority and historical Phase-7 pointer preserved.'
