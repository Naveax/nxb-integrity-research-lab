[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$Path,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SchemaPath = (Join-Path `
        (Split-Path -Parent $PSScriptRoot) `
        'schemas\collector-overhead-calibration.schema.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$manifestFull = [IO.Path]::GetFullPath($Path)
$schemaFull = [IO.Path]::GetFullPath($SchemaPath)
if (-not (Test-Path -LiteralPath $schemaFull -PathType Leaf)) {
    throw "Collector overhead calibration schema bulunamadı: $schemaFull"
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
    throw "Python bulunamadı. Collector overhead calibration doğrulaması için Python ve 'jsonschema' paketi gerekir."
}

$validator = Join-Path `
    (Split-Path -Parent $PSScriptRoot) `
    'tools\validate_overhead_calibration.py'
if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
    throw "Collector overhead semantic validator bulunamadı: $validator"
}

$arguments = @(
    $validator,
    '--schema',
    $schemaFull,
    '--manifest',
    $manifestFull
)

$output = & $python.Source @arguments 2>&1
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    throw "Collector overhead calibration doğrulaması başarısız (exit $exitCode):`n$($output -join [Environment]::NewLine)"
}

$output | ForEach-Object { Write-Host $_ }
