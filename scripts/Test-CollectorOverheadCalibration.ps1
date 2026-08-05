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

$previousErrorActionPreference = $ErrorActionPreference
$nativePreferenceVariable = Get-Variable `
    -Name PSNativeCommandUseErrorActionPreference `
    -ErrorAction SilentlyContinue
$nativePreferenceAvailable = $null -ne $nativePreferenceVariable
$previousNativePreference = if ($nativePreferenceAvailable) {
    [bool]$nativePreferenceVariable.Value
}
else {
    $null
}

$output = @()
$exitCode = 1
try {
    $ErrorActionPreference = 'Continue'
    if ($nativePreferenceAvailable) {
        Set-Variable `
            -Name PSNativeCommandUseErrorActionPreference `
            -Value $false `
            -Scope Local
    }

    $output = @(& $python.Source @arguments 2>&1)
    $exitCode = if ($null -eq $LASTEXITCODE) {
        1
    }
    else {
        [int]$LASTEXITCODE
    }
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
    if ($nativePreferenceAvailable) {
        Set-Variable `
            -Name PSNativeCommandUseErrorActionPreference `
            -Value $previousNativePreference `
            -Scope Local
    }
}

$outputText = @($output | ForEach-Object { [string]$_ })
if ($exitCode -ne 0) {
    throw "Collector overhead calibration doğrulaması başarısız (exit $exitCode):`n$($outputText -join [Environment]::NewLine)"
}

$outputText | ForEach-Object { Write-Host $_ }
