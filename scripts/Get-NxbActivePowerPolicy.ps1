[CmdletBinding()]
param(
    [Parameter()]
    [string]$PowerCfgExecutablePath,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force

try {
    $powerCfgPath = Resolve-NxbExecutablePath `
        -Name 'powercfg.exe' `
        -ExplicitPath $PowerCfgExecutablePath
}
catch {
    throw "powercfg.exe bulunamadı. $($_.Exception.Message)"
}

$output = & $powerCfgPath /getactivescheme 2>&1
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    throw "Aktif power policy okunamadı (exit $exitCode): $($output -join [Environment]::NewLine)"
}

$text = $output -join ' '
$match = [regex]::Match(
    $text,
    '(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:\s+\(([^)]*)\))?'
)
if (-not $match.Success) {
    throw "Aktif power policy çıktısı ayrıştırılamadı: $text"
}

$policy = [ordered]@{
    status      = 'available'
    scheme_guid = $match.Groups[1].Value.ToLowerInvariant()
    name         = if ($match.Groups[2].Success) {
        $match.Groups[2].Value.Trim()
    }
    else {
        $null
    }
    source       = $powerCfgPath
}

if ($PassThru) {
    return [pscustomobject]$policy
}

$policy | ConvertTo-Json -Depth 8
