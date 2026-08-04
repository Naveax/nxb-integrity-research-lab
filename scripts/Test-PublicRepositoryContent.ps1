[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),

    [Parameter()]
    [string[]]$AdditionalRelativePath = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force

$repositoryFull = Get-NxbFullPath -Path $RepositoryRoot
$policyPath = Join-Path $repositoryFull 'config\public-repository-policy.json'
if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
    throw "Public repository policy bulunamadı: $policyPath"
}

$policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
$allowed = @{}
foreach ($path in $policy.allowed_paths) {
    $normalizedAllowedPath = ([string]$path).Replace('\', '/')
    $allowed[$normalizedAllowedPath] = $true
}

$git = Get-Command git.exe -ErrorAction SilentlyContinue
if (-not $git) {
    $git = Get-Command git -ErrorAction SilentlyContinue
}

if ($git) {
    $tracked = & $git.Source -C $repositoryFull ls-files 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-files başarısız: $($tracked -join [Environment]::NewLine)"
    }

    $trackedPaths = @($tracked | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
else {
    $trackedPaths = @(Get-NxbSafeChildItem -RootPath $repositoryFull |
        Where-Object {
            -not $_.PSIsContainer -and
            $_.FullName -notmatch '[\\/]\.git[\\/]'
        } |
        ForEach-Object {
            Get-NxbRelativePath -BasePath $repositoryFull -ChildPath $_.FullName
        })
}

$combinedPaths = [System.Collections.Generic.List[string]]::new()
foreach ($candidate in @($trackedPaths) + @($AdditionalRelativePath)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
        [void]$combinedPaths.Add(([string]$candidate).Replace('\', '/'))
    }
}
$relativePaths = @($combinedPaths | Sort-Object -Unique)

$issues = [System.Collections.Generic.List[string]]::new()
$privateKeyMarker = '-----BEGIN ' + 'PRIVATE KEY-----'
$encryptedPrivateKeyMarker = '-----BEGIN ENCRYPTED ' + 'PRIVATE KEY-----'

foreach ($relativePath in $relativePaths) {
    if ($allowed.ContainsKey($relativePath)) {
        continue
    }

    $fullPath = Get-NxbFullPath -Path (Join-Path $repositoryFull $relativePath)
    try {
        [void](Get-NxbRelativePath -BasePath $repositoryFull -ChildPath $fullPath)
    }
    catch {
        [void]$issues.Add("Repository kökü dışındaki aday yol: $relativePath")
        continue
    }

    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        [void]$issues.Add("Aday dosya bulunamadı: $relativePath")
        continue
    }

    try {
        [void](Test-NxbPathSafety -Path $fullPath -RootPath $repositoryFull)
    }
    catch {
        [void]$issues.Add("Güvensiz repository yolu: $relativePath ($($_.Exception.Message))")
        continue
    }

    $item = Get-Item -LiteralPath $fullPath -Force
    if ($item.Length -gt [long]$policy.maximum_tracked_file_bytes) {
        [void]$issues.Add("Tracked dosya boyut sınırını aşıyor: $relativePath ($($item.Length) bytes)")
    }

    $extension = [IO.Path]::GetExtension($relativePath).ToLowerInvariant()
    if (@($policy.blocked_extensions) -contains $extension) {
        [void]$issues.Add("Public repoda engellenmiş uzantı: $relativePath")
    }

    $segments = $relativePath.Split('/')
    foreach ($segment in $segments) {
        if (@($policy.blocked_path_segments) -contains $segment.ToLowerInvariant()) {
            [void]$issues.Add("Public repoda engellenmiş yol segmenti: $relativePath")
            break
        }
    }

    if ($item.Length -le 2097152) {
        try {
            $text = Get-Content -LiteralPath $fullPath -Raw -ErrorAction Stop
            if ($text.Contains($privateKeyMarker) -or $text.Contains($encryptedPrivateKeyMarker)) {
                [void]$issues.Add("Private key içeriği tespit edildi: $relativePath")
            }
        }
        catch {
            Write-Verbose "Metin taraması atlandı: $relativePath ($($_.Exception.Message))"
        }
    }
}

if ($issues.Count -gt 0) {
    throw ("Public repository content guard başarısız:`n- " + ($issues -join "`n- "))
}

Write-Host "Public repository content guard başarılı: $($relativePaths.Count) aday dosya denetlendi."
