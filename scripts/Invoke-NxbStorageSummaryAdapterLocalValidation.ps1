[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-NxbStorageSummaryAdapterPesterRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$Executable,

        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$TestPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Label
    )

    $tempRoot = Join-Path `
        ([IO.Path]::GetTempPath()) `
        ("nxb-storage-summary-adapter-pester-$([guid]::NewGuid().ToString('N'))")
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $childPath = Join-Path $tempRoot 'invoke-pester.ps1'
    $resultPath = Join-Path $tempRoot 'result.json'

    @'
param(
    [Parameter(Mandatory)]
    [string]$TestPath,

    [Parameter(Mandatory)]
    [string]$ResultPath
)

$ErrorActionPreference = 'Stop'
Import-Module Pester -ErrorAction Stop
$result = Invoke-Pester -Path $TestPath -PassThru
$summary = [pscustomobject]@{
    passed = [int]$result.PassedCount
    failed = [int]$result.FailedCount
    skipped = [int]$result.SkippedCount
    total = [int]$result.TotalCount
}
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
if ($summary.failed -ne 0 -or $summary.skipped -ne 0 -or
    $summary.passed -ne $summary.total -or $summary.total -ne 9) {
    exit 1
}
'@ | Set-Content -LiteralPath $childPath -Encoding UTF8

    try {
        $childOutput = @(
            & $Executable `
                -NoLogo `
                -NoProfile `
                -ExecutionPolicy Bypass `
                -File $childPath `
                -TestPath $TestPath `
                -ResultPath $resultPath `
                2>&1
        )
        $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        foreach ($line in $childOutput) {
            Write-Information -MessageData ([string]$line) -InformationAction Continue
        }
        if ($exitCode -ne 0) {
            throw "$Label Pester run failed with exit code $exitCode."
        }
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            throw "$Label Pester result JSON was not produced."
        }

        $summary = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if ([int]$summary.failed -ne 0 -or
            [int]$summary.skipped -ne 0 -or
            [int]$summary.passed -ne 9 -or
            [int]$summary.total -ne 9) {
            throw "$Label Pester result is not clean 9/9."
        }

        return [pscustomobject]@{
            Label = $Label
            Passed = [int]$summary.passed
            Failed = [int]$summary.failed
            Skipped = [int]$summary.skipped
            Total = [int]$summary.total
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

if ($env:OS -cne 'Windows_NT') {
    throw 'Storage summary adapter validation requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Storage summary adapter validation must run in PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}
$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'Storage summary adapter validation requires a clean exact-head worktree.'
}

$adapterPath = Join-Path $PSScriptRoot 'ConvertFrom-NxbStorageEventExport.ps1'
$converterPath = Join-Path $repositoryRoot 'tools\convert_storage_event_export.py'
$summaryValidatorPath = Join-Path $PSScriptRoot 'Test-StorageEtlSummary.ps1'
$summarySemanticValidatorPath = Join-Path $repositoryRoot 'tools\validate_storage_etl_summary.py'
$schemaPath = Join-Path $repositoryRoot 'schemas\storage-etl-summary.schema.json'
$testPath = Join-Path $repositoryRoot 'tests\StorageEventExportAdapter.Tests.ps1'
$runnerPath = $PSCommandPath

foreach ($requiredPath in @(
    $adapterPath,
    $converterPath,
    $summaryValidatorPath,
    $summarySemanticValidatorPath,
    $schemaPath,
    $testPath,
    $runnerPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required storage summary adapter file missing: $requiredPath"
    }
}

foreach ($scriptPath in @(
    $adapterPath,
    $testPath,
    $runnerPath
)) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $scriptPath,
        [ref]$tokens,
        [ref]$errors
    )
    if (@($errors).Count -gt 0) {
        throw (
            "PowerShell parser failed: $scriptPath`n" +
            (@($errors | ForEach-Object { $_.Message }) -join "`n")
        )
    }
}

Import-Module PSScriptAnalyzer -ErrorAction Stop
$findings = @(
    foreach ($scriptPath in @(
        $adapterPath,
        $testPath,
        $runnerPath
    )) {
        Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error
    }
)
if ($findings.Count -gt 0) {
    throw (
        "PSScriptAnalyzer findings: $($findings.Count)`n" +
        (@($findings | ForEach-Object {
            '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message
        }) -join "`n")
    )
}

$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if (-not $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction SilentlyContinue }
if (-not $pythonCommand) { $pythonCommand = Get-Command py.exe -ErrorAction SilentlyContinue }
if (-not $pythonCommand) { $pythonCommand = Get-Command py -ErrorAction SilentlyContinue }
if (-not $pythonCommand) {
    throw 'Python was not found for storage summary adapter validation.'
}

$compileOutput = @(
    & $pythonCommand.Source `
        -m py_compile `
        $converterPath `
        $summarySemanticValidatorPath `
        2>&1
)
$compileExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
if ($compileExit -ne 0) {
    throw (
        "Storage summary adapter Python py_compile failed (exit $compileExit):`n" +
        (@($compileOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    )
}

$pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
$windowsPowerShellPath = Join-Path `
    $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShellPath -PathType Leaf)) {
    throw "Windows PowerShell 5.1 executable missing: $windowsPowerShellPath"
}

$ps7 = Invoke-NxbStorageSummaryAdapterPesterRun `
    -Executable $pwshPath `
    -TestPath $testPath `
    -Label 'PowerShell 7 storage summary adapter'
$ps51 = Invoke-NxbStorageSummaryAdapterPesterRun `
    -Executable $windowsPowerShellPath `
    -TestPath $testPath `
    -Label 'Windows PowerShell 5.1 storage summary adapter'

$postDirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) {
    throw 'Storage summary adapter validation left the exact-head worktree dirty.'
}

$result = [pscustomobject][ordered]@{
    status = 'passed'
    head_sha = $currentHead
    powershell7 = $ps7
    windows_powershell_51 = $ps51
    analyzer_findings = 0
    python_compile = 'passed'
    timing_metrics_enabled = $false
    queue_metrics_enabled = $false
    representative_throughput_enabled = $false
    representative_iops_enabled = $false
}

Write-Information `
    -MessageData "Storage summary adapter validation passed: $currentHead" `
    -InformationAction Continue
Write-Information `
    -MessageData "PowerShell 7 Pester: $($ps7.Passed)/$($ps7.Total)" `
    -InformationAction Continue
Write-Information `
    -MessageData "Windows PowerShell 5.1 Pester: $($ps51.Passed)/$($ps51.Total)" `
    -InformationAction Continue
Write-Information -MessageData 'PSScriptAnalyzer: 0 findings' -InformationAction Continue
Write-Information -MessageData 'Python converter/validator py_compile: PASS' -InformationAction Continue
Write-Information -MessageData 'Timing metrics enabled: False' -InformationAction Continue
Write-Information -MessageData 'Queue metrics enabled: False' -InformationAction Continue
Write-Information -MessageData 'Representative throughput/IOPS enabled: False' -InformationAction Continue

if ($PassThru) {
    return $result
}
