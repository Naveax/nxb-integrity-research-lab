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

function Invoke-NxbStorageContractPesterRun {
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
        ("nxb-storage-contract-pester-$([guid]::NewGuid().ToString('N'))")
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
if ($summary.failed -ne 0 -or $summary.skipped -ne 0 -or $summary.passed -le 0) {
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
            [int]$summary.passed -le 0 -or
            [int]$summary.passed -ne [int]$summary.total) {
            throw "$Label Pester result is not clean."
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
    throw 'Storage evidence contract validation requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Storage evidence contract validation must run in PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}

$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'Storage evidence validation requires a clean exact-head worktree.'
}

$summarySchemaPath = Join-Path $repositoryRoot 'schemas\storage-etl-summary.schema.json'
$eventSchemaPath = Join-Path $repositoryRoot 'schemas\storage-event.schema.json'
$summaryPythonValidatorPath = Join-Path $repositoryRoot 'tools\validate_storage_etl_summary.py'
$eventPythonValidatorPath = Join-Path $repositoryRoot 'tools\validate_storage_event.py'
$summaryWrapperPath = Join-Path $PSScriptRoot 'Test-StorageEtlSummary.ps1'
$eventWrapperPath = Join-Path $PSScriptRoot 'Test-StorageEvent.ps1'
$summaryTestPath = Join-Path $repositoryRoot 'tests\StorageEtlSummary.Tests.ps1'
$eventTestPath = Join-Path $repositoryRoot 'tests\StorageEvent.Tests.ps1'
$summaryFixturePath = Join-Path $repositoryRoot 'tests\fixtures\storage-etl-summary.valid.json'
$eventFixturePath = Join-Path $repositoryRoot 'tests\fixtures\storage-event.valid.json'
$runnerPath = $PSCommandPath

foreach ($requiredPath in @(
    $summarySchemaPath,
    $eventSchemaPath,
    $summaryPythonValidatorPath,
    $eventPythonValidatorPath,
    $summaryWrapperPath,
    $eventWrapperPath,
    $summaryTestPath,
    $eventTestPath,
    $summaryFixturePath,
    $eventFixturePath,
    $runnerPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required storage evidence file missing: $requiredPath"
    }
}

foreach ($scriptPath in @(
    $summaryWrapperPath,
    $eventWrapperPath,
    $summaryTestPath,
    $eventTestPath,
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
        $summaryWrapperPath,
        $eventWrapperPath,
        $summaryTestPath,
        $eventTestPath,
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
    throw 'Python was not found for storage evidence validation.'
}

$compileOutput = @(
    & $pythonCommand.Source `
        -m py_compile `
        $summaryPythonValidatorPath `
        $eventPythonValidatorPath `
        2>&1
)
$compileExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
if ($compileExit -ne 0) {
    throw (
        "Storage Python validator py_compile failed (exit $compileExit):`n" +
        (@($compileOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    )
}

$schemaCheckCode = @'
import json, sys
from jsonschema import Draft202012Validator
for path in sys.argv[1:]:
    with open(path, 'r', encoding='utf-8-sig') as handle:
        schema = json.load(handle)
    Draft202012Validator.check_schema(schema)
'@
$schemaOutput = @(
    & $pythonCommand.Source `
        -c $schemaCheckCode `
        $summarySchemaPath `
        $eventSchemaPath `
        2>&1
)
$schemaExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
if ($schemaExit -ne 0) {
    throw (
        "Storage JSON Schema self-validation failed (exit $schemaExit):`n" +
        (@($schemaOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    )
}

$summaryFixtureOutput = @(& $summaryWrapperPath -Path $summaryFixturePath 2>&1)
foreach ($line in $summaryFixtureOutput) {
    Write-Information -MessageData ([string]$line) -InformationAction Continue
}
$eventFixtureOutput = @(& $eventWrapperPath -Path $eventFixturePath 2>&1)
foreach ($line in $eventFixtureOutput) {
    Write-Information -MessageData ([string]$line) -InformationAction Continue
}

$pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
$windowsPowerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShellPath -PathType Leaf)) {
    throw "Windows PowerShell 5.1 executable missing: $windowsPowerShellPath"
}

$ps7Summary = Invoke-NxbStorageContractPesterRun `
    -Executable $pwshPath `
    -TestPath $summaryTestPath `
    -Label 'PowerShell 7 summary'
$ps7Event = Invoke-NxbStorageContractPesterRun `
    -Executable $pwshPath `
    -TestPath $eventTestPath `
    -Label 'PowerShell 7 event'
$ps51Summary = Invoke-NxbStorageContractPesterRun `
    -Executable $windowsPowerShellPath `
    -TestPath $summaryTestPath `
    -Label 'Windows PowerShell 5.1 summary'
$ps51Event = Invoke-NxbStorageContractPesterRun `
    -Executable $windowsPowerShellPath `
    -TestPath $eventTestPath `
    -Label 'Windows PowerShell 5.1 event'

$postDirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) {
    throw 'Storage evidence validation left the exact-head worktree dirty.'
}

$result = [pscustomobject]@{
    status = 'passed'
    head_sha = $currentHead
    summary_schema_path = 'schemas/storage-etl-summary.schema.json'
    event_schema_path = 'schemas/storage-event.schema.json'
    summary_python_validator_path = 'tools/validate_storage_etl_summary.py'
    event_python_validator_path = 'tools/validate_storage_event.py'
    summary_fixture_path = 'tests/fixtures/storage-etl-summary.valid.json'
    event_fixture_path = 'tests/fixtures/storage-event.valid.json'
    powershell7_summary = $ps7Summary
    powershell7_event = $ps7Event
    windows_powershell_51_summary = $ps51Summary
    windows_powershell_51_event = $ps51Event
    analyzer_findings = 0
    python_compile = 'passed'
    schema_self_validation = 'passed'
    canonical_summary_fixture_validation = 'passed'
    canonical_event_fixture_validation = 'passed'
    queue_semantics_claimed = $false
    trace_completeness_claimed = $false
}

Write-Information -MessageData "Storage evidence exact-head validation passed: $currentHead" -InformationAction Continue
Write-Information -MessageData "PowerShell 7 summary Pester: $($ps7Summary.Passed)/$($ps7Summary.Total)" -InformationAction Continue
Write-Information -MessageData "PowerShell 7 event Pester: $($ps7Event.Passed)/$($ps7Event.Total)" -InformationAction Continue
Write-Information -MessageData "Windows PowerShell 5.1 summary Pester: $($ps51Summary.Passed)/$($ps51Summary.Total)" -InformationAction Continue
Write-Information -MessageData "Windows PowerShell 5.1 event Pester: $($ps51Event.Passed)/$($ps51Event.Total)" -InformationAction Continue
Write-Information -MessageData 'PSScriptAnalyzer: 0 findings' -InformationAction Continue
Write-Information -MessageData 'Python semantic validators py_compile: PASS' -InformationAction Continue
Write-Information -MessageData 'JSON Schema self-validation: PASS' -InformationAction Continue
Write-Information -MessageData 'Canonical storage summary fixture: PASS' -InformationAction Continue
Write-Information -MessageData 'Canonical storage event fixture: PASS' -InformationAction Continue
Write-Information -MessageData 'Storage queue semantics claimed: False' -InformationAction Continue
Write-Information -MessageData 'Trace completeness claimed: False' -InformationAction Continue

if ($PassThru) {
    return $result
}
