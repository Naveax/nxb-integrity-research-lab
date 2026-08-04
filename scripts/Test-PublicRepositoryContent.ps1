[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryFull = [IO.Path]::GetFullPath($RepositoryRoot)
$policyPath = Join-Path $repositoryFull 'config\public-repository-policy.json'
if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
    throw "Public repository policy bulunamadı: $policyPath"
}

$policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
$allowed = @{}
foreach ($path in $policy.allowed_paths) {
    $allowed[[string]$path] = $true
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
    $relativePaths = @($tracked | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
else {
    $relativePaths = Get-ChildItem -LiteralPath $repositoryFull -File -Recurse -Force |
        Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
        ForEach-Object {
            $root = $repositoryFull.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            $_.FullName.Substring($root.Length).Replace('\', '/')
        }
}

$issues = [System.Collections.Generic.List[string]]::new()
$privateKeyMarker = '-----BEGIN ' + 'PRIVATE KEY-----'
$encryptedPrivateKeyMarker = '-----BEGIN ENCRYPTED ' + 'PRIVATE KEY-----'

foreach ($relativePathRaw in $relativePaths) {
    $relativePath = ([string]$relativePathRaw).Replace('\', '/')
    if ($allowed.ContainsKey($relativePath)) {
        continue
    }

    $fullPath = Join-Path $repositoryFull $relativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        $issues.Add("Tracked dosya bulunamadı: $relativePath")
        continue
    }

    $item = Get-Item -LiteralPath $fullPath -Force
    if ($item.Length -gt [long]$policy.maximum_tracked_file_bytes) {
        $issues.Add("Tracked dosya boyut sınırını aşıyor: $relativePath ($($item.Length) bytes)")
    }

    $extension = [IO.Path]::GetExtension($relativePath).ToLowerInvariant()
    if (@($policy.blocked_extensions) -contains $extension) {
        $issues.Add("Public repoda engellenmiş uzantı: $relativePath")
    }

    $segments = $relativePath.Split('/')
    foreach ($segment in $segments) {
        if (@($policy.blocked_path_segments) -contains $segment.ToLowerInvariant()) {
            $issues.Add("Public repoda engellenmiş yol segmenti: $relativePath")
            break
        }
    }

    if ($item.Length -le 2097152) {
        try {
            $text = Get-Content -LiteralPath $fullPath -Raw -ErrorAction Stop
            if ($text.Contains($privateKeyMarker) -or $text.Contains($encryptedPrivateKeyMarker)) {
                $issues.Add("Private key içeriği tespit edildi: $relativePath")
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

Write-Host "Public repository content guard başarılı: $($relativePaths.Count) tracked dosya denetlendi."
