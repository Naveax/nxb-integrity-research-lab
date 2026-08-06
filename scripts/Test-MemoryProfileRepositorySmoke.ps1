[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$profilePath = Join-Path $repositoryRoot 'profiles\Nxb.MemoryWorkingSet.wprp'
$profileValidatorPath = Join-Path $PSScriptRoot 'Test-NxbMemoryWprProfile.ps1'
$profileTestPath = Join-Path $repositoryRoot 'tests\MemoryWprProfile.Tests.ps1'
$smokeTestPath = Join-Path `
    $repositoryRoot `
    'tests\MemoryProfileRepositorySmoke.Tests.ps1'
$profileValidationPath = Join-Path `
    $PSScriptRoot `
    'Invoke-NxbMemoryProfileLocalValidation.ps1'
$memorySchemaPath = Join-Path `
    $repositoryRoot `
    'schemas\memory-snapshot.schema.json'
$memoryFixturePath = Join-Path `
    $repositoryRoot `
    'tests\fixtures\memory-snapshot.valid.json'
$memoryValidatorPath = Join-Path $PSScriptRoot 'Test-MemorySnapshot.ps1'
$memoryPythonValidatorPath = Join-Path `
    $repositoryRoot `
    'tools\validate_memory_snapshot.py'
$memoryTestPath = Join-Path $repositoryRoot 'tests\MemorySnapshot.Tests.ps1'

$requiredFiles = @(
    $profilePath,
    $profileValidatorPath,
    $profileTestPath,
    $smokeTestPath,
    $profileValidationPath,
    $memorySchemaPath,
    $memoryFixturePath,
    $memoryValidatorPath,
    $memoryPythonValidatorPath,
    $memoryTestPath
)
foreach ($requiredFile in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Memory foundation repository smoke girdisi bulunamadı: $requiredFile"
    }
}

$powerShellFiles = @(
    $profileValidatorPath,
    $profileTestPath,
    $smokeTestPath,
    $profileValidationPath,
    $memoryValidatorPath,
    $memoryTestPath
)
foreach ($powerShellFile in $powerShellFiles) {
    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $powerShellFile,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null

    if (@($parseErrors).Count -gt 0) {
        $messages = @($parseErrors | ForEach-Object {
            "$(Split-Path -Leaf $powerShellFile):$($_.Extent.StartLineNumber): $($_.Message)"
        })
        throw ($messages -join [Environment]::NewLine)
    }
}

Get-Content -LiteralPath $memorySchemaPath -Raw | ConvertFrom-Json | Out-Null
Get-Content -LiteralPath $memoryFixturePath -Raw | ConvertFrom-Json | Out-Null

$result = & $profileValidatorPath -PassThru
if ([string]$result.RelativePath -cne 'profiles/Nxb.MemoryWorkingSet.wprp' -or
    [string]$result.Name -cne 'NxbMemoryWorkingSet' -or
    [int]$result.BufferSizeKiB -ne 1024 -or
    [int]$result.Buffers -ne 64 -or
    [int]$result.MaximumFileSizeMiB -ne 512 -or
    [string]$result.FileMode -cne 'Circular' -or
    [bool]$result.ReferenceSetEnabled -or
    @($result.Keywords).Count -ne 11 -or
    @($result.Stacks).Count -ne 9) {
    throw 'Memory profile repository smoke sözleşmesini karşılamıyor.'
}

foreach ($requiredKeyword in @(
    'AllFaults',
    'HardFaults',
    'MemoryInfo',
    'MemoryInfoWS',
    'ProcessCounter',
    'VAMap',
    'VirtualAllocation'
)) {
    if (@($result.Keywords) -notcontains $requiredKeyword) {
        throw "Memory profile zorunlu keyword içermiyor: $requiredKeyword"
    }
}

# Argümansız çağrı kanonik fixture/schema varsayılanlarını doğrular.
& $memoryValidatorPath

Write-Host 'Memory profile and snapshot repository smoke başarılı.'
