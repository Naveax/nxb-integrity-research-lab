[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$Path,

    [Parameter(Mandatory)]
    [ValidateSet('record', 'chain-head', 'bundle-manifest')]
    [string]$DocumentType,

    [Parameter()]
    [string]$SchemaPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$schemaNames = @{
    record = 'evidence-store-record.schema.json'
    'chain-head' = 'evidence-chain-head.schema.json'
    'bundle-manifest' = 'evidence-bundle-manifest.schema.json'
}

if ([string]::IsNullOrWhiteSpace($SchemaPath)) {
    $SchemaPath = Join-Path $repositoryRoot (Join-Path 'schemas' $schemaNames[$DocumentType])
}

if (-not (Test-Path -LiteralPath $SchemaPath -PathType Leaf)) {
    throw "Evidence-store schema bulunamadı: $SchemaPath"
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

$validator = Join-Path $repositoryRoot 'tools\validate_manifest.py'
if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
    throw "JSON validator bulunamadı: $validator"
}

$previousErrorActionPreference = $ErrorActionPreference
$nativePreference = Get-Variable `
    -Name PSNativeCommandUseErrorActionPreference `
    -ErrorAction SilentlyContinue
$previousNativePreference = $null
$output = @()
$exitCode = -1

try {
    $ErrorActionPreference = 'Continue'
    if ($null -ne $nativePreference) {
        $previousNativePreference = [bool]$nativePreference.Value
        Set-Variable `
            -Name PSNativeCommandUseErrorActionPreference `
            -Value $false `
            -Scope Local
    }

    $output = @(& $python.Source @(
        $validator,
        '--schema',
        $SchemaPath,
        '--manifest',
        $Path
    ) 2>&1)
    $exitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
    if ($null -ne $nativePreference) {
        Set-Variable `
            -Name PSNativeCommandUseErrorActionPreference `
            -Value $previousNativePreference `
            -Scope Local
    }
}

if ($exitCode -ne 0) {
    $detailLines = @($output | ForEach-Object {
        if ($_ -is [Management.Automation.ErrorRecord]) {
            [string]$_.Exception.Message
        }
        else {
            [string]$_
        }
    })
    $detail = ($detailLines -join [Environment]::NewLine).Trim()
    if ([string]::IsNullOrWhiteSpace($detail)) {
        $detail = "Validator exit code: $exitCode"
    }

    throw "Evidence-store schema doğrulaması başarısız ($DocumentType):`n$detail"
}

$output | ForEach-Object { Write-Host ([string]$_) }
