[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SchemaPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas\observation-identity.schema.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$identityPath = Join-Path $ExperimentPath 'baseline\observation-identity.json'
if (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
    throw "Observation identity bulunamadı: $identityPath"
}
if (-not (Test-Path -LiteralPath $SchemaPath -PathType Leaf)) {
    throw "Observation identity schema bulunamadı: $SchemaPath"
}

$python = Get-Command python.exe -ErrorAction SilentlyContinue
if (-not $python) {
    $python = Get-Command python -ErrorAction SilentlyContinue
}
if (-not $python) {
    $python = Get-Command py.exe -ErrorAction SilentlyContinue
}
if (-not $python) {
    $python = Get-Command py -ErrorAction SilentlyContinue
}
if (-not $python) {
    throw "Python bulunamadı. JSON Schema doğrulaması için Python ve 'jsonschema' paketi gerekir."
}

$validator = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\validate_manifest.py'
if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
    throw "JSON validator bulunamadı: $validator"
}

$output = & $python.Source @(
    $validator,
    '--schema',
    $SchemaPath,
    '--manifest',
    $identityPath
) 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "Observation identity schema doğrulaması başarısız:`n$($output -join [Environment]::NewLine)"
}

$output | ForEach-Object { Write-Host $_ }
