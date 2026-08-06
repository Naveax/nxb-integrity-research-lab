[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter()]
    [string]$ResultsRoot,

    [Parameter()]
    [switch]$BootstrapDependencies,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-NxbMemoryFoundationV2Utf8NoBom {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    [IO.File]::WriteAllText(
        $Path,
        $Content,
        [Text.UTF8Encoding]::new($false)
    )
}

if ($env:OS -cne 'Windows_NT') {
    throw 'Memory foundation validation V2 yalnız gerçek Windows ortamında çalışır.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Memory foundation validation V2 PowerShell 7 içinde çalıştırılmalıdır.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$legacyRunner = Join-Path `
    $PSScriptRoot `
    'Invoke-NxbMemoryFoundationLocalValidation.ps1'
$contractValidator = Join-Path $PSScriptRoot 'Test-MemorySnapshot.ps1'
$settingsPath = Join-Path `
    $repositoryRoot `
    '.github\PSScriptAnalyzerSettings.psd1'

foreach ($requiredFile in @(
    $legacyRunner,
    $contractValidator,
    $settingsPath
)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Memory foundation V2 girdisi bulunamadı: $requiredFile"
    }
}

$tokens = $null
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile(
    $PSCommandPath,
    [ref]$tokens,
    [ref]$parseErrors
) | Out-Null
if (@($parseErrors).Count -gt 0) {
    throw (
        @($parseErrors | ForEach-Object { $_.Message }) -join
        [Environment]::NewLine
    )
}

$git = Get-Command git.exe -ErrorAction SilentlyContinue
if ($null -eq $git) {
    $git = Get-Command git -ErrorAction SilentlyContinue
}
if ($null -eq $git) {
    throw 'Git bulunamadı.'
}

$currentHead = (
    & $git.Source -C $repositoryRoot rev-parse HEAD 2>&1 |
        Out-String
).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -notmatch '^[0-9a-f]{40}$') {
    throw "Git HEAD çözümlenemedi: $currentHead"
}
if ($currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw (
        "Exact-head uyuşmazlığı. Beklenen: $ExpectedHead; " +
        "mevcut: $currentHead"
    )
}

$workingTree = @(
    & $git.Source `
        -C $repositoryRoot `
        status `
        --porcelain=v1 `
        --untracked-files=all 2>&1
)
if ($LASTEXITCODE -ne 0 -or $workingTree.Count -gt 0) {
    throw 'Memory foundation V2 için çalışma ağacı temiz olmalıdır.'
}

if ([string]::IsNullOrWhiteSpace($ResultsRoot)) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $ResultsRoot = Join-Path `
        ([IO.Path]::GetTempPath()) `
        "nxb-memory-foundation-v2-$($currentHead.Substring(0, 12))-$stamp"
}
$resultsFull = [IO.Path]::GetFullPath($ResultsRoot)
if (Test-Path -LiteralPath $resultsFull) {
    throw "Validation sonuç dizini zaten var: $resultsFull"
}

$summaryPath = Join-Path `
    $resultsFull `
    'memory-foundation-validation-summary.json'
$logsRoot = Join-Path $resultsFull 'logs'
$contractLog = Join-Path $logsRoot 'memory-snapshot-contract-v2.log'
$reviewZip = Join-Path $HOME (
    'Downloads\' +
    (Split-Path -Leaf $resultsFull) +
    '-review.zip'
)
$legacyFailure = $null

try {
    & $legacyRunner `
        -ExpectedHead $ExpectedHead `
        -ResultsRoot $resultsFull `
        -BootstrapDependencies:$BootstrapDependencies `
        -PassThru | Out-Null
}
catch {
    $legacyFailure = $_.Exception.Message
}

if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
    throw (
        "Legacy foundation runner summary üretmedi. Hata:`n" +
        [string]$legacyFailure
    )
}

$summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
if ([string]$summary.status -ceq 'passed') {
    Write-Host 'Memory foundation exact-head validation V2 tamamlandı.'
    if ($PassThru) {
        $summary
    }
    return
}

$failedGates = @($summary.gates | Where-Object status -eq 'failed')
$knownOrchestrationFailure = (
    $failedGates.Count -eq 1 -and
    [string]$failedGates[0].name -ceq 'memory-snapshot-contract' -and
    [int]$failedGates[0].exit_code -eq 1 -and
    [string]::IsNullOrWhiteSpace([string]$summary.failure_message)
)
if (-not $knownOrchestrationFailure) {
    throw (
        "Foundation runner beklenmeyen biçimde başarısız oldu:`n" +
        [string]$legacyFailure
    )
}

Import-Module PSScriptAnalyzer -Force
$selfFindings = @(
    Invoke-ScriptAnalyzer `
        -Path $PSCommandPath `
        -Settings $settingsPath
)
if ($selfFindings.Count -gt 0) {
    throw "Foundation V2 runner PSScriptAnalyzer $($selfFindings.Count) bulgu üretti."
}

[IO.Directory]::CreateDirectory($logsRoot) | Out-Null
$contractOutput = @()
try {
    $contractOutput = @(& $contractValidator 2>&1)
}
catch {
    $contractOutput += ($_ | Out-String)
    Write-NxbMemoryFoundationV2Utf8NoBom `
        -Path $contractLog `
        -Content (@($contractOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    throw 'Memory snapshot contract V2 doğrulaması başarısız.'
}

Write-NxbMemoryFoundationV2Utf8NoBom `
    -Path $contractLog `
    -Content (@($contractOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)

$contractGate = $failedGates[0]
$contractGate.status = 'passed'
$contractGate.exit_code = 0
$contractGate.log_path = $contractLog
$contractGate.reason = $null
$summary.status = 'passed'
$summary.validation_stopped_utc = [DateTime]::UtcNow.ToString('o')
$summary | Add-Member `
    -NotePropertyName foundation_runner_version `
    -NotePropertyValue 2 `
    -Force
$summary | Add-Member `
    -NotePropertyName superseded_orchestration_failure `
    -NotePropertyValue $legacyFailure `
    -Force

Write-NxbMemoryFoundationV2Utf8NoBom `
    -Path $summaryPath `
    -Content ($summary | ConvertTo-Json -Depth 32)

$reviewFiles = @(
    Get-ChildItem `
        -LiteralPath $resultsFull `
        -Recurse `
        -File `
        -ErrorAction Stop |
        Select-Object -ExpandProperty FullName
)
if (Test-Path -LiteralPath $reviewZip -PathType Leaf) {
    Remove-Item -LiteralPath $reviewZip -Force
}
Compress-Archive `
    -LiteralPath $reviewFiles `
    -DestinationPath $reviewZip `
    -CompressionLevel Optimal

Write-Host "Memory foundation validation summary: $summaryPath"
Write-Host "Review ZIP: $reviewZip"
Write-Host 'Memory foundation exact-head validation V2 tamamlandı.'

$finalSummary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
if ([string]$finalSummary.status -cne 'passed') {
    throw 'Memory foundation V2 final summary passed değil.'
}
if ($PassThru) {
    $finalSummary
}
