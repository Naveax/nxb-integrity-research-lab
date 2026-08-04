[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SchemaPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas\system-capabilities.schema.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$capabilityPath = Join-Path $ExperimentPath 'baseline\system-capabilities.json'
if (-not (Test-Path -LiteralPath $capabilityPath -PathType Leaf)) {
    throw "System capability envanteri bulunamadı: $capabilityPath"
}
if (-not (Test-Path -LiteralPath $SchemaPath -PathType Leaf)) {
    throw "System capability schema bulunamadı: $SchemaPath"
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

$arguments = @(
    $validator,
    '--schema',
    $SchemaPath,
    '--manifest',
    $capabilityPath
)

$output = & $python.Source @arguments 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "System capability schema doğrulaması başarısız:`n$($output -join [Environment]::NewLine)"
}

$output | ForEach-Object { Write-Host $_ }
