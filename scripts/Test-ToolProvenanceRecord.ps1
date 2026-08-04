[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$RecordPath,

    [Parameter()]
    [string]$OverrideToolPath,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.EvidenceStore.psm1') -Force

$record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json
if ([string]$record.record_type -cne 'tool_provenance') {
    throw "Record tool_provenance değil: $RecordPath"
}

$payloadHash = Get-NxbCanonicalJsonHash -InputObject $record.payload
if ($payloadHash -cne [string]$record.payload_sha256) {
    throw 'Tool provenance payload hash uyuşmuyor.'
}

$recordHash = Get-NxbCanonicalJsonHash `
    -InputObject $record `
    -ExcludeRootProperty record_sha256
if ($recordHash -cne [string]$record.record_sha256) {
    throw 'Tool provenance record hash uyuşmuyor.'
}

$toolPath = if ([string]::IsNullOrWhiteSpace($OverrideToolPath)) {
    [string]$record.payload.tool_path
}
else {
    [IO.Path]::GetFullPath($OverrideToolPath)
}

if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
    throw "Tool executable doğrulama için bulunamadı: $toolPath"
}

$toolItem = Get-Item -LiteralPath $toolPath -Force
$actualHash = (Get-FileHash -LiteralPath $toolPath -Algorithm SHA256).Hash.ToLowerInvariant()
$expectedHash = [string]$record.payload.tool_sha256
if ($actualHash -cne $expectedHash) {
    throw "Tool SHA-256 uyuşmuyor: $toolPath"
}
if ([int64]$toolItem.Length -ne [int64]$record.payload.tool_length) {
    throw "Tool byte uzunluğu uyuşmuyor: $toolPath"
}

$result = [pscustomobject]@{
    IsValid = $true
    RecordPath = [IO.Path]::GetFullPath($RecordPath)
    ToolPath = [IO.Path]::GetFullPath($toolPath)
    ToolSha256 = $actualHash
    ToolLength = [int64]$toolItem.Length
    InvocationName = [string]$record.payload.invocation_name
    ArgumentDigestSha256 = [string]$record.payload.argument_digest_sha256
    Status = [string]$record.payload.status
}

if ($PassThru) {
    return $result
}

Write-Host "Tool provenance doğrulandı: $toolPath"
