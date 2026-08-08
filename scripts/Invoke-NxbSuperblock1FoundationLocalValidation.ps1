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

function Assert-NxbSuperblockValidationResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Result,

        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [int]$ExpectedTests
    )

    if ([string]$Result.status -cne 'passed') {
        throw "$Label status is not passed."
    }
    if ([string]$Result.head_sha -cne $ExpectedHead.ToLowerInvariant()) {
        throw "$Label exact-head mismatch: $($Result.head_sha)"
    }
    if ([int]$Result.analyzer_findings -ne 0) {
        throw "$Label PSScriptAnalyzer findings are non-zero."
    }

    foreach ($runtime in @('powershell7','windows_powershell_51')) {
        $summary = $Result.$runtime
        if ([int]$summary.Passed -ne $ExpectedTests -or
            [int]$summary.Total -ne $ExpectedTests -or
            [int]$summary.Failed -ne 0 -or
            [int]$summary.Skipped -ne 0) {
            throw "$Label $runtime Pester gate is not clean."
        }
    }
}

if ($env:OS -cne 'Windows_NT') {
    throw 'SUPERBLOCK 1 foundation validation requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'SUPERBLOCK 1 foundation validation requires PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}
$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'SUPERBLOCK 1 foundation validation requires a clean exact-head worktree.'
}

$gpuInventoryValidator = Join-Path `
    $PSScriptRoot `
    'Invoke-NxbGpuProviderInventoryLocalValidation.ps1'
$gpuMetadataValidator = Join-Path `
    $PSScriptRoot `
    'Invoke-NxbGpuProviderMetadataProbeLocalValidation.ps1'
$remainingValidator = Join-Path `
    $PSScriptRoot `
    'Invoke-NxbRemainingProviderInventoryLocalValidation.ps1'
$capabilitySchemaPath = Join-Path `
    $repositoryRoot `
    'schemas\system-capabilities.schema.json'
$eventSchemaPath = Join-Path `
    $repositoryRoot `
    'schemas\observability-event.schema.json'

foreach ($requiredPath in @(
    $gpuInventoryValidator,
    $gpuMetadataValidator,
    $remainingValidator,
    $capabilitySchemaPath,
    $eventSchemaPath,
    $PSCommandPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required SUPERBLOCK 1 foundation file missing: $requiredPath"
    }
}

$tokens = $null
$errors = $null
[void][Management.Automation.Language.Parser]::ParseFile(
    $PSCommandPath,
    [ref]$tokens,
    [ref]$errors
)
if (@($errors).Count -gt 0) {
    throw (
        'SUPERBLOCK 1 foundation runner parser failed.' + "`n" +
        (@($errors | ForEach-Object { $_.Message }) -join "`n")
    )
}

Import-Module PSScriptAnalyzer -ErrorAction Stop
$runnerFindings = @(
    Invoke-ScriptAnalyzer -Path $PSCommandPath -Severity Warning,Error
)
if ($runnerFindings.Count -gt 0) {
    throw (
        "SUPERBLOCK 1 runner analyzer findings: $($runnerFindings.Count)`n" +
        (@($runnerFindings | ForEach-Object {
            '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message
        }) -join "`n")
    )
}

$capabilitySchema = Get-Content -LiteralPath $capabilitySchemaPath -Raw |
    ConvertFrom-Json
$capabilityDomains = @($capabilitySchema.properties.domains.required)
foreach ($domain in @(
    'gpu',
    'network',
    'bus_and_devices',
    'firmware',
    'security',
    'power'
)) {
    if ($capabilityDomains -notcontains $domain) {
        throw "System capability schema missing SUPERBLOCK domain: $domain"
    }
}

$eventSchema = Get-Content -LiteralPath $eventSchemaPath -Raw |
    ConvertFrom-Json
$eventDomains = @($eventSchema.properties.domain.enum)
foreach ($domain in @(
    'gpu',
    'network',
    'bus',
    'device',
    'kernel',
    'driver',
    'power',
    'thermal',
    'firmware',
    'security'
)) {
    if ($eventDomains -notcontains $domain) {
        throw "Observability event schema missing SUPERBLOCK domain: $domain"
    }
}

Write-Information -MessageData '=== SUPERBLOCK 1 FOUNDATION LOCAL VALIDATION ===' -InformationAction Continue
Write-Information -MessageData '[1/3] GPU provider inventory contract' -InformationAction Continue
$gpuInventory = & $gpuInventoryValidator `
    -ExpectedHead $ExpectedHead `
    -PassThru
Assert-NxbSuperblockValidationResult `
    -Result $gpuInventory `
    -Label 'GPU provider inventory' `
    -ExpectedTests 8

Write-Information -MessageData '[2/3] GPU provider metadata contract' -InformationAction Continue
$gpuMetadata = & $gpuMetadataValidator `
    -ExpectedHead $ExpectedHead `
    -PassThru
Assert-NxbSuperblockValidationResult `
    -Result $gpuMetadata `
    -Label 'GPU provider metadata' `
    -ExpectedTests 8

Write-Information -MessageData '[3/3] Remaining provider/capability contract' -InformationAction Continue
$remaining = & $remainingValidator `
    -ExpectedHead $ExpectedHead `
    -PassThru
Assert-NxbSuperblockValidationResult `
    -Result $remaining `
    -Label 'Remaining provider inventory' `
    -ExpectedTests 8

$postDirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) {
    throw 'SUPERBLOCK 1 foundation validation dirtied the exact-head worktree.'
}

$result = [pscustomobject][ordered]@{
    status = 'passed'
    head_sha = $currentHead
    powershell7_total = 24
    windows_powershell_51_total = 24
    analyzer_findings = 0
    capability_schema_domains = @(
        'gpu',
        'network',
        'bus_and_devices',
        'firmware',
        'security',
        'power'
    )
    normalized_event_domains = @(
        'gpu',
        'network',
        'bus',
        'device',
        'kernel',
        'driver',
        'power',
        'thermal',
        'firmware',
        'security'
    )
    gpu_inventory = $gpuInventory
    gpu_metadata = $gpuMetadata
    remaining_domains = $remaining
    real_host_inventory_executed = $false
    real_gpu_metadata_executed = $false
    semantic_claims_enabled = $false
    trace_completeness = 'not_claimed'
}

Write-Information -MessageData "SUPERBLOCK 1 foundation validation passed: $currentHead" -InformationAction Continue
Write-Information -MessageData 'PowerShell 7 Pester: 24/24' -InformationAction Continue
Write-Information -MessageData 'Windows PowerShell 5.1 Pester: 24/24' -InformationAction Continue
Write-Information -MessageData 'PSScriptAnalyzer findings: 0' -InformationAction Continue
Write-Information -MessageData 'Capability/event domain integration: PASS' -InformationAction Continue
Write-Information -MessageData 'Real host inventory executed: False' -InformationAction Continue
Write-Information -MessageData 'Semantic claims enabled: False' -InformationAction Continue

if ($PassThru) {
    return $result
}
