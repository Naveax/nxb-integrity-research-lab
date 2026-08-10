[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$InputPath,
    [Parameter()][string]$OutputPath,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$validatorPath = Join-Path $repositoryRoot 'tools\validate_platform_binding_snapshot.py'
if (-not (Test-Path -LiteralPath $validatorPath -PathType Leaf)) {
    throw "Platform binding Python validator is missing: $validatorPath"
}

$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }

$temporaryOutput = $false
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path ([IO.Path]::GetTempPath()) ("nxb-platform-binding-validation-$([guid]::NewGuid().ToString('N')).json")
    $temporaryOutput = $true
}
$inputFull = [IO.Path]::GetFullPath($InputPath)
$outputFull = [IO.Path]::GetFullPath($OutputPath)
$outputParent = Split-Path -Parent $outputFull
if (-not [string]::IsNullOrWhiteSpace($outputParent)) { [IO.Directory]::CreateDirectory($outputParent) | Out-Null }

try {
    $validationOutput = @(
        & $pythonCommand.Source $validatorPath --input $inputFull --output $outputFull 2>&1
    )
    $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    foreach ($line in $validationOutput) {
        Write-Information -MessageData ([string]$line) -InformationAction Continue
    }
    if ($exitCode -ne 0) {
        throw "Platform binding validation failed: exit=$exitCode"
    }
    if (-not (Test-Path -LiteralPath $outputFull -PathType Leaf)) {
        throw 'Platform binding validator produced no summary.'
    }
    $summary = Get-Content -LiteralPath $outputFull -Raw | ConvertFrom-Json
    if ([string]$summary.status -cne 'passed') {
        throw 'Platform binding validation summary is not passed.'
    }
    if ($PassThru) { return $summary }
    Write-Output $outputFull
}
finally {
    if ($temporaryOutput -and (Test-Path -LiteralPath $outputFull)) {
        Remove-Item -LiteralPath $outputFull -Force -ErrorAction SilentlyContinue
    }
}
