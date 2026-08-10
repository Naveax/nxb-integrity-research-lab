[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NxbPlatformV2Administrator {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NxbPlatformV2Property {
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter()][AllowNull()][object]$DefaultValue = $null
    )
    $current = $InputObject
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $DefaultValue }
        if ($current -is [System.Collections.IDictionary]) {
            if ($current.Contains($segment)) { $current = $current[$segment]; continue }
            return $DefaultValue
        }
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) { return $DefaultValue }
        $current = $property.Value
    }
    if ($null -eq $current) { return $DefaultValue }
    return $current
}

function Get-NxbPlatformV2BlockStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Snapshot,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path
    )
    return [string](Get-NxbPlatformV2Property -InputObject $Snapshot -Path "$Path.status" -DefaultValue 'missing')
}

function Test-NxbPlatformV2RequiredBlock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Snapshot,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path
    )
    $status = Get-NxbPlatformV2BlockStatus -Snapshot $Snapshot -Path $Path
    if ($status -cne 'available') { throw "Required platform-binding block unavailable: $Path status=$status" }
}

function Write-NxbPlatformV2CertificationJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory)][object]$InputObject
    )
    [IO.File]::WriteAllText(
        [IO.Path]::GetFullPath($Path),
        (($InputObject | ConvertTo-Json -Depth 32) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

function Invoke-NxbPlatformV2Pester {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$Executable,
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$TestPath,
        [Parameter(Mandatory)][ValidateRange(1,1000)][int]$ExpectedCount,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Label
    )
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("nxb-platform-v2-pester-$([guid]::NewGuid().ToString('N'))")
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $childPath = Join-Path $tempRoot 'run.ps1'
    $resultPath = Join-Path $tempRoot 'result.json'
    @'
param([string]$TestPath,[string]$ResultPath,[int]$ExpectedCount)
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
if ($summary.passed -ne $ExpectedCount -or $summary.total -ne $ExpectedCount -or $summary.failed -ne 0 -or $summary.skipped -ne 0) { exit 1 }
'@ | Set-Content -LiteralPath $childPath -Encoding UTF8
    try {
        $childOutput = @(& $Executable -NoLogo -NoProfile -ExecutionPolicy Bypass -File $childPath -TestPath $TestPath -ResultPath $resultPath -ExpectedCount $ExpectedCount 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        foreach ($line in $childOutput) { Write-Information -MessageData ([string]$line) -InformationAction Continue }
        if ($exitCode -ne 0) { throw "$Label Pester run failed: exit=$exitCode" }
        return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}

if ($env:OS -cne 'Windows_NT') { throw 'SUPERBLOCK 2 V2 certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'SUPERBLOCK 2 V2 certification requires PowerShell 7.' }
if (-not (Test-NxbPlatformV2Administrator)) { throw 'SUPERBLOCK 2 V2 certification requires elevated PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) { throw "Exact-head mismatch. expected=$ExpectedHead actual=$currentHead" }
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'V2 certification requires a clean exact-head worktree.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$repositoryPrefix = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\') + '\'
if ($outputFull.StartsWith($repositoryPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Output must remain outside repository.' }
if (Test-Path -LiteralPath $outputFull) { throw "OutputDirectory already exists: $outputFull" }
$reviewRoot = Join-Path $outputFull 'review'
[IO.Directory]::CreateDirectory($reviewRoot) | Out-Null

$collectorV1Path = Join-Path $PSScriptRoot 'Get-NxbPlatformBindingSnapshot.ps1'
$collectorV2Path = Join-Path $PSScriptRoot 'Get-NxbPlatformBindingSnapshotV2.ps1'
$wrapperPath = Join-Path $PSScriptRoot 'Test-NxbPlatformBindingSnapshot.ps1'
$powerPolicyPath = Join-Path $PSScriptRoot 'Get-NxbActivePowerPolicy.ps1'
$testPath = Join-Path $repositoryRoot 'tests\PlatformBindingSnapshotV2.Tests.ps1'
$validatorPath = Join-Path $repositoryRoot 'tools\validate_platform_binding_snapshot.py'
$schemaPath = Join-Path $repositoryRoot 'schemas\platform-binding-snapshot.schema.json'
$requiredPaths = @($collectorV1Path,$collectorV2Path,$wrapperPath,$powerPolicyPath,$testPath,$validatorPath,$schemaPath,$PSCommandPath)
foreach ($requiredPath in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "V2 component missing: $requiredPath" }
}

Write-Information -MessageData '=== NXB IRL-004 SUPERBLOCK 2 PLATFORM BINDING CERTIFICATION V2 ===' -InformationAction Continue
Write-Information -MessageData '[1/6] Parser/analyzer + dual-runtime V2 20-test contract' -InformationAction Continue
$analyzerPaths = @($collectorV1Path,$collectorV2Path,$wrapperPath,$powerPolicyPath,$testPath,$PSCommandPath)
foreach ($scriptPath in $analyzerPaths) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw ("Parser failed: $scriptPath`n" + (@($parseErrors | ForEach-Object { $_.Message }) -join "`n")) }
}
Import-Module PSScriptAnalyzer -ErrorAction Stop
$findings = @(
    foreach ($scriptPath in $analyzerPaths) { Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error }
)
if ($findings.Count -gt 0) {
    throw ("V2 PSScriptAnalyzer findings: $($findings.Count)`n" + (@($findings | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join "`n"))
}
$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
& $pythonCommand.Source -m py_compile $validatorPath
if ($LASTEXITCODE -ne 0) { throw 'V2 Python syntax check failed.' }

$previousRoot = [Environment]::GetEnvironmentVariable('NXB_PLATFORM_BINDING_REPOSITORY_ROOT','Process')
$env:NXB_PLATFORM_BINDING_REPOSITORY_ROOT = [IO.Path]::GetFullPath($repositoryRoot)
try {
    $pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $ps51Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $ps7 = Invoke-NxbPlatformV2Pester -Executable $pwshPath -TestPath $testPath -ExpectedCount 20 -Label 'PowerShell 7 platform binding V2'
    $ps51 = Invoke-NxbPlatformV2Pester -Executable $ps51Path -TestPath $testPath -ExpectedCount 20 -Label 'Windows PowerShell 5.1 platform binding V2'
}
finally {
    if ($null -eq $previousRoot) { Remove-Item Env:NXB_PLATFORM_BINDING_REPOSITORY_ROOT -ErrorAction SilentlyContinue }
    else { $env:NXB_PLATFORM_BINDING_REPOSITORY_ROOT = $previousRoot }
}

Write-Information -MessageData '[2/6] Collect and independently validate V2 snapshot A' -InformationAction Continue
$snapshotAPath = Join-Path $reviewRoot 'platform-binding-snapshot-a.json'
$validationAPath = Join-Path $reviewRoot 'platform-binding-validation-a.json'
$snapshotA = & $collectorV2Path -OutputPath $snapshotAPath -PassThru
$validationA = & $wrapperPath -InputPath $snapshotAPath -OutputPath $validationAPath -PassThru
if ([string]$validationA.status -cne 'passed') { throw 'V2 snapshot A validation failed.' }

Start-Sleep -Milliseconds 500
Write-Information -MessageData '[3/6] Collect and independently validate V2 snapshot B' -InformationAction Continue
$snapshotBPath = Join-Path $reviewRoot 'platform-binding-snapshot-b.json'
$validationBPath = Join-Path $reviewRoot 'platform-binding-validation-b.json'
$snapshotB = & $collectorV2Path -OutputPath $snapshotBPath -PassThru
$validationB = & $wrapperPath -InputPath $snapshotBPath -OutputPath $validationBPath -PassThru
if ([string]$validationB.status -cne 'passed') { throw 'V2 snapshot B validation failed.' }

Write-Information -MessageData '[4/6] Stable binding + core capability acceptance' -InformationAction Continue
$machineA = [string](Get-NxbPlatformV2Property -InputObject $snapshotA -Path 'identity.machine_id_sha256')
$machineB = [string](Get-NxbPlatformV2Property -InputObject $snapshotB -Path 'identity.machine_id_sha256')
if ($machineA -cne $machineB) { throw 'machine identity changed between snapshots' }
$bootA = [string](Get-NxbPlatformV2Property -InputObject $snapshotA -Path 'identity.boot_utc')
$bootB = [string](Get-NxbPlatformV2Property -InputObject $snapshotB -Path 'identity.boot_utc')
if ($bootA -cne $bootB) { throw 'boot identity changed between snapshots' }
$fingerprintA = [string](Get-NxbPlatformV2Property -InputObject $snapshotA -Path 'binding_fingerprint_sha256')
$fingerprintB = [string](Get-NxbPlatformV2Property -InputObject $snapshotB -Path 'binding_fingerprint_sha256')
if ($fingerprintA -cne $fingerprintB) { throw 'binding fingerprint changed between snapshots' }
if ($fingerprintA -notmatch '^[0-9a-f]{64}$') { throw 'V2 binding fingerprint malformed.' }
if ([string]$validationA.binding_fingerprint_sha256 -cne $fingerprintA -or [string]$validationB.binding_fingerprint_sha256 -cne $fingerprintB) {
    throw 'Independent validator fingerprint does not match V2 collector fingerprint.'
}

foreach ($corePath in @(
    'bindings.devices.pnp_entities','bindings.devices.signed_drivers','bindings.devices.system_drivers',
    'bindings.power.active_power_scheme','bindings.firmware_security.bios','bindings.firmware_security.virtualization'
)) {
    Test-NxbPlatformV2RequiredBlock -Snapshot $snapshotA -Path $corePath
    Test-NxbPlatformV2RequiredBlock -Snapshot $snapshotB -Path $corePath
}
$pnpCount = [int](Get-NxbPlatformV2Property -InputObject $snapshotA -Path 'bindings.devices.pnp_entities.data.total_count' -DefaultValue 0)
$pciCount = [int](Get-NxbPlatformV2Property -InputObject $snapshotA -Path 'bindings.devices.pnp_entities.data.pci_count' -DefaultValue 0)
$signedDriverCount = [int](Get-NxbPlatformV2Property -InputObject $snapshotA -Path 'bindings.devices.signed_drivers.data.total_count' -DefaultValue 0)
$systemDriverCount = [int](Get-NxbPlatformV2Property -InputObject $snapshotA -Path 'bindings.devices.system_drivers.data.total_count' -DefaultValue 0)
$availableProviders = [int](Get-NxbPlatformV2Property -InputObject $validationA -Path 'available_event_provider_count' -DefaultValue 0)
foreach ($requiredCount in @($pnpCount,$pciCount,$signedDriverCount,$systemDriverCount,$availableProviders)) {
    if ($requiredCount -le 0) { throw 'One or more required V2 inventory counts are empty.' }
}

Write-Information -MessageData '[5/6] Conservative V2 certification receipt' -InformationAction Continue
$receipt = [pscustomobject][ordered]@{
    schema_version = 2
    status = 'passed'
    head_sha = $currentHead
    static_validation = [ordered]@{
        ps7 = [ordered]@{ passed=[int]$ps7.passed; total=[int]$ps7.total }
        ps51 = [ordered]@{ passed=[int]$ps51.passed; total=[int]$ps51.total }
        psscriptanalyzer_findings = $findings.Count
        python_syntax = 'passed'
    }
    binding = [ordered]@{
        canonicalization_version = 2
        array_cardinality_preserved = $true
        machine_id_sha256 = $machineA
        boot_utc = $bootA
        binding_fingerprint_sha256 = $fingerprintA
        fingerprint_stable_across_two_snapshots = $true
        independent_fingerprint_validation = $true
    }
    inventory = [ordered]@{
        pnp_device_count = $pnpCount
        pci_device_count = $pciCount
        signed_driver_count = $signedDriverCount
        system_driver_count = $systemDriverCount
        available_event_provider_count = $availableProviders
    }
    optional_surface_status = [ordered]@{
        secure_boot = Get-NxbPlatformV2BlockStatus -Snapshot $snapshotA -Path 'bindings.firmware_security.secure_boot'
        tpm = Get-NxbPlatformV2BlockStatus -Snapshot $snapshotA -Path 'bindings.firmware_security.tpm'
        device_guard = Get-NxbPlatformV2BlockStatus -Snapshot $snapshotA -Path 'bindings.firmware_security.device_guard'
        boot_configuration = Get-NxbPlatformV2BlockStatus -Snapshot $snapshotA -Path 'bindings.firmware_security.boot_configuration'
        battery = Get-NxbPlatformV2BlockStatus -Snapshot $snapshotA -Path 'volatile_state.battery'
        thermal_zones = Get-NxbPlatformV2BlockStatus -Snapshot $snapshotA -Path 'volatile_state.thermal_zones'
    }
    claims = [ordered]@{
        stable_platform_binding_fingerprint = $true
        sanitized_device_driver_inventory = $true
        sanitized_power_firmware_security_snapshot = $true
        platform_event_source_inventory = $true
        pcie_bdf_semantics = $false
        device_lifecycle_semantics = $false
        thermal_representativeness = $false
        power_causality = $false
        firmware_causality = $false
        root_cause_validated = $false
        continuous_trace_completeness = 'not_claimed'
    }
}
$receiptPath = Join-Path $reviewRoot 'platform-binding-certification-receipt.json'
Write-NxbPlatformV2CertificationJson -Path $receiptPath -InputObject $receipt

Write-Information -MessageData '[6/6] Bounded review ZIP + content boundary audit' -InformationAction Continue
$reviewZipPath = Join-Path $outputFull 'platform-binding-review.zip'
Compress-Archive -Path (Join-Path $reviewRoot '*') -DestinationPath $reviewZipPath -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($reviewZipPath)
try {
    foreach ($entry in $archive.Entries) {
        $lowerName = $entry.FullName.ToLowerInvariant()
        if ($lowerName.EndsWith('.etl') -or $lowerName.EndsWith('.exe') -or $lowerName.EndsWith('.obj') -or $lowerName.EndsWith('.pdb') -or $lowerName.Contains('raw-local') -or $lowerName.Contains('bcd-output') -or $lowerName.EndsWith('.tmp')) {
            throw "Forbidden platform-binding review artifact: $($entry.FullName)"
        }
        if ($entry.FullName.EndsWith('.json',[StringComparison]::OrdinalIgnoreCase)) {
            $stream = $entry.Open()
            $reader = [IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false),$true)
            try {
                $text = $reader.ReadToEnd()
                foreach ($forbiddenText in @('"PNPDeviceID"','"SerialNumber"','"computer_name"','"raw_machine_id"','"raw_device_id"')) {
                    if ($text.IndexOf($forbiddenText,[StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "Forbidden review content: entry=$($entry.FullName) token=$forbiddenText" }
                }
            }
            finally { $reader.Dispose(); $stream.Dispose() }
        }
    }
}
finally { $archive.Dispose() }

$reviewSha = (Get-FileHash -LiteralPath $reviewZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$result = [pscustomobject][ordered]@{
    status = 'passed'
    head_sha = $currentHead
    ps7_tests = '20/20'
    ps51_tests = '20/20'
    psscriptanalyzer_findings = $findings.Count
    binding_fingerprint_sha256 = $fingerprintA
    fingerprint_stable = $true
    canonicalization_version = 2
    pnp_device_count = $pnpCount
    pci_device_count = $pciCount
    signed_driver_count = $signedDriverCount
    system_driver_count = $systemDriverCount
    available_event_provider_count = $availableProviders
    secure_boot_status = Get-NxbPlatformV2BlockStatus -Snapshot $snapshotA -Path 'bindings.firmware_security.secure_boot'
    tpm_status = Get-NxbPlatformV2BlockStatus -Snapshot $snapshotA -Path 'bindings.firmware_security.tpm'
    device_guard_status = Get-NxbPlatformV2BlockStatus -Snapshot $snapshotA -Path 'bindings.firmware_security.device_guard'
    thermal_status = Get-NxbPlatformV2BlockStatus -Snapshot $snapshotA -Path 'volatile_state.thermal_zones'
    continuous_trace_completeness = 'not_claimed'
    receipt_sha256 = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    review_zip_sha256 = $reviewSha
    review_zip_path = [IO.Path]::GetFullPath($reviewZipPath)
    local_evidence_root = $outputFull
}
Write-Information -MessageData "SUPERBLOCK 2 V2 certification passed: pnp=$pnpCount pci=$pciCount providers=$availableProviders fingerprint=$fingerprintA" -InformationAction Continue
if ($PassThru) { return $result }
$result | ConvertTo-Json -Depth 16
