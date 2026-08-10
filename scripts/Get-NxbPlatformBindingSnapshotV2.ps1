[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NxbPlatformV2Sha256Text {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha256.Dispose() }
}

function ConvertTo-NxbPlatformV2CanonicalNode {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [char] -or $Value -is [bool] -or
        $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or $Value -is [single] -or
        $Value -is [double] -or $Value -is [decimal]) { return $Value }

    if ($Value -is [System.Collections.IDictionary]) {
        $dictionaryResult = [ordered]@{}
        foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)) {
            $dictionaryResult[$key] = ConvertTo-NxbPlatformV2CanonicalNode -Value $Value[$key]
        }
        return $dictionaryResult
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value | ForEach-Object { ConvertTo-NxbPlatformV2CanonicalNode -Value $_ })
        Write-Output -NoEnumerate $items
        return
    }

    $objectResult = [ordered]@{}
    foreach ($name in @($Value.PSObject.Properties.Name | Sort-Object -CaseSensitive)) {
        $objectResult[$name] = ConvertTo-NxbPlatformV2CanonicalNode -Value $Value.PSObject.Properties[$name].Value
    }
    return $objectResult
}

function Write-NxbPlatformV2Json {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory)][object]$InputObject
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $fullPath,
        (($InputObject | ConvertTo-Json -Depth 40) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

$collectorV1 = Join-Path $PSScriptRoot 'Get-NxbPlatformBindingSnapshot.ps1'
if (-not (Test-Path -LiteralPath $collectorV1 -PathType Leaf)) {
    throw "Platform binding V1 collector is missing: $collectorV1"
}

$tempPath = [IO.Path]::GetFullPath($OutputPath) + '.v1.tmp'
try {
    $snapshot = & $collectorV1 -OutputPath $tempPath -PassThru
    if ($null -eq $snapshot) { throw 'Platform binding V1 collector returned no snapshot object.' }

    $fingerprintMaterial = [pscustomobject][ordered]@{
        identity = $snapshot.identity
        bindings = $snapshot.bindings
        event_sources = $snapshot.event_sources
    }
    $canonicalMaterial = ConvertTo-NxbPlatformV2CanonicalNode -Value $fingerprintMaterial
    $canonicalJson = $canonicalMaterial | ConvertTo-Json -Depth 40 -Compress
    $snapshot.binding_fingerprint_sha256 = Get-NxbPlatformV2Sha256Text -Text $canonicalJson

    Write-NxbPlatformV2Json -Path $OutputPath -InputObject $snapshot
}
finally {
    if (Test-Path -LiteralPath $tempPath -PathType Leaf) { Remove-Item -LiteralPath $tempPath -Force }
}

Write-Information -MessageData "NXB platform binding V2 snapshot written: $([IO.Path]::GetFullPath($OutputPath))" -InformationAction Continue
if ($PassThru) { return $snapshot }
Write-Output ([IO.Path]::GetFullPath($OutputPath))
