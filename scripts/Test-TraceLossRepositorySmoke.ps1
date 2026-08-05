[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$schemaPath = Join-Path $repositoryRoot 'schemas\trace-loss-accounting.schema.json'
$fixturePath = Join-Path `
    $repositoryRoot `
    'tests\fixtures\trace-loss-accounting.valid.json'
$requiredFiles = @(
    $schemaPath,
    $fixturePath,
    (Join-Path $repositoryRoot 'tools\validate_trace_loss_accounting.py'),
    (Join-Path $PSScriptRoot 'Test-TraceLossAccounting.ps1'),
    (Join-Path $PSScriptRoot 'Get-NxbWprStatusSnapshot.ps1'),
    (Join-Path $PSScriptRoot 'Get-NxbEtlTraceStatistics.ps1'),
    (Join-Path $PSScriptRoot 'New-NxbTraceLossAccounting.ps1'),
    (Join-Path $PSScriptRoot 'New-NxbTraceLossAccountingFromSources.ps1'),
    (Join-Path $PSScriptRoot 'Stop-PerformanceTraceWithAccounting.ps1'),
    (Join-Path $PSScriptRoot 'Invoke-NxbTraceLossLocalValidation.ps1')
)

foreach ($requiredFile in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Trace-loss repository smoke girdisi bulunamadı: $requiredFile"
    }
}

Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json | Out-Null
Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json | Out-Null

$powerShellFiles = @($requiredFiles | Where-Object { [IO.Path]::GetExtension($_) -eq '.ps1' })
$powerShellFiles += Get-ChildItem `
    -LiteralPath (Join-Path $repositoryRoot 'tests') `
    -Filter '*TraceLoss*.Tests.ps1' `
    -File |
    Select-Object -ExpandProperty FullName
$powerShellFiles += Get-ChildItem `
    -LiteralPath (Join-Path $repositoryRoot 'tests') `
    -Filter '*WprStatus*.Tests.ps1' `
    -File |
    Select-Object -ExpandProperty FullName
$powerShellFiles += Get-ChildItem `
    -LiteralPath (Join-Path $repositoryRoot 'tests') `
    -Filter '*EtlTraceStatistics*.Tests.ps1' `
    -File |
    Select-Object -ExpandProperty FullName

foreach ($powerShellFile in @($powerShellFiles | Sort-Object -Unique)) {
    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $powerShellFile,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null

    if ($parseErrors.Count -gt 0) {
        $messages = @($parseErrors | ForEach-Object {
            "$(Split-Path -Leaf $powerShellFile):$($_.Extent.StartLineNumber): $($_.Message)"
        })
        throw ($messages -join [Environment]::NewLine)
    }
}

& (Join-Path $PSScriptRoot 'Test-TraceLossAccounting.ps1') `
    -Path $fixturePath `
    -SchemaPath $schemaPath

Write-Host 'Trace-loss repository smoke başarılı.'
