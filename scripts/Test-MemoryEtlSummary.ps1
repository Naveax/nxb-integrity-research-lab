[CmdletBinding()]
param(
    [Parameter()]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$Path = (Join-Path `
        (Split-Path -Parent $PSScriptRoot) `
        'tests\fixtures\memory-etl-summary.valid.json'),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SchemaPath = (Join-Path `
        (Split-Path -Parent $PSScriptRoot) `
        'schemas\memory-etl-summary.schema.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$manifestFull = [IO.Path]::GetFullPath($Path)
$schemaFull = [IO.Path]::GetFullPath($SchemaPath)
if (-not (Test-Path -LiteralPath $schemaFull -PathType Leaf)) {
    throw "Memory ETL summary schema not found: $schemaFull"
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
    throw "Python not found. Memory ETL summary validation requires Python and jsonschema."
}

$validator = Join-Path `
    (Split-Path -Parent $PSScriptRoot) `
    'tools\validate_memory_etl_summary.py'
if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
    throw "Memory ETL semantic validator not found: $validator"
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
    throw (
        "Memory ETL summary validation failed (exit $exitCode):`n" +
        ($outputText -join [Environment]::NewLine)
    )
}

$outputText | ForEach-Object { Write-Host $_ }
