[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,

    [Parameter()]
    [ValidateRange(16, 1024)]
    [int]$RecordLimit = 256,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -cne 'Windows_NT') {
    throw 'SUPERBLOCK 1 native foundation certification requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'SUPERBLOCK 1 native foundation certification requires PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}
$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'SUPERBLOCK 1 native foundation certification requires a clean exact-head worktree.'
}

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$repositoryFull = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\') + '\'
if ($outputFull.StartsWith($repositoryFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Certification output must be outside the repository worktree.'
}
if (Test-Path -LiteralPath $outputFull) {
    throw "OutputDirectory already exists: $outputFull"
}

$rawDirectory = Join-Path $outputFull 'raw-local'
$reviewDirectory = Join-Path $outputFull 'review'
$experimentPath = Join-Path $rawDirectory 'capability-experiment'
$baselineDirectory = Join-Path $experimentPath 'baseline'
[IO.Directory]::CreateDirectory($rawDirectory) | Out-Null
[IO.Directory]::CreateDirectory($reviewDirectory) | Out-Null
[IO.Directory]::CreateDirectory($baselineDirectory) | Out-Null

$foundationValidator = Join-Path $PSScriptRoot 'Invoke-NxbSuperblock1FoundationLocalValidation.ps1'
$gpuInventoryRunner = Join-Path $PSScriptRoot 'Invoke-NxbGpuProviderInventory.ps1'
$gpuMetadataRunner = Join-Path $PSScriptRoot 'Invoke-NxbGpuProviderMetadataProbe.ps1'
$remainingInventoryRunner = Join-Path $PSScriptRoot 'Invoke-NxbRemainingProviderInventory.ps1'
$capabilityCollector = Join-Path $PSScriptRoot 'Get-SystemCapabilities.ps1'
$capabilityValidator = Join-Path $PSScriptRoot 'Test-SystemCapabilities.ps1'

foreach ($requiredPath in @(
    $foundationValidator,
    $gpuInventoryRunner,
    $gpuMetadataRunner,
    $remainingInventoryRunner,
    $capabilityCollector,
    $capabilityValidator
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required certification component missing: $requiredPath"
    }
}

Write-Information -MessageData '=== SUPERBLOCK 1 NATIVE FOUNDATION CERTIFICATION ===' -InformationAction Continue
Write-Information -MessageData '[1/6] Combined static and dual-runtime gate' -InformationAction Continue
$foundation = & $foundationValidator -ExpectedHead $ExpectedHead -PassThru
if ([string]$foundation.status -cne 'passed' -or
    [int]$foundation.powershell7_total -ne 24 -or
    [int]$foundation.windows_powershell_51_total -ne 24 -or
    [int]$foundation.analyzer_findings -ne 0) {
    throw 'Combined SUPERBLOCK foundation gate did not pass cleanly.'
}

$gpuInventoryPath = Join-Path $rawDirectory 'gpu-provider-inventory.json'
$gpuMetadataPath = Join-Path $rawDirectory 'gpu-provider-metadata.json'
$remainingInventoryPath = Join-Path $rawDirectory 'remaining-provider-inventory.json'
$capabilityPath = Join-Path $baselineDirectory 'system-capabilities.json'

Write-Information -MessageData '[2/6] Real GPU provider inventory' -InformationAction Continue
$gpuInventory = & $gpuInventoryRunner `
    -ExpectedHead $ExpectedHead `
    -OutputPath $gpuInventoryPath `
    -PassThru
if ([string]$gpuInventory.status -cne 'passed') {
    throw 'Real GPU provider inventory did not pass.'
}

Write-Information -MessageData '[3/6] Real repaired GPU provider metadata probe' -InformationAction Continue
$gpuMetadata = & $gpuMetadataRunner `
    -ExpectedHead $ExpectedHead `
    -OutputPath $gpuMetadataPath `
    -PassThru
if ([string]$gpuMetadata.status -cne 'passed') {
    throw 'Real GPU provider metadata probe did not pass.'
}
if (@($gpuMetadata.providers).Count -ne 2) {
    throw 'GPU provider metadata probe did not return exactly two bound providers.'
}
foreach ($provider in @($gpuMetadata.providers)) {
    if (-not [bool]$provider.expected_guid_observed -or
        [string]$provider.logman.keyword_parser -cne 'section-v1' -or
        -not [bool]$provider.logman.keyword_section_detected -or
        [bool]$provider.logman.keyword_contamination_detected -or
        [int]$provider.logman.keyword_row_count -lt 1) {
        throw "GPU metadata evidence gate failed for $($provider.name)."
    }
}

Write-Information -MessageData '[4/6] Real remaining-provider inventory' -InformationAction Continue
$remainingInventory = & $remainingInventoryRunner `
    -ExpectedHead $ExpectedHead `
    -OutputPath $remainingInventoryPath `
    -RecordLimit $RecordLimit `
    -PassThru
if ([string]$remainingInventory.status -cne 'passed') {
    throw 'Remaining-provider inventory did not pass.'
}

Write-Information -MessageData '[5/6] Full-system capability snapshot' -InformationAction Continue
$collectedCapabilityPath = & $capabilityCollector -ExperimentPath $experimentPath
if (-not (Test-Path -LiteralPath $capabilityPath -PathType Leaf)) {
    throw "System capability snapshot was not created: $capabilityPath"
}
if ([IO.Path]::GetFullPath([string]$collectedCapabilityPath) -cne [IO.Path]::GetFullPath($capabilityPath)) {
    throw 'System capability collector returned an unexpected output path.'
}

Write-Information -MessageData '[6/6] System-capability JSON Schema validation and bounded receipt' -InformationAction Continue
& $capabilityValidator -ExperimentPath $experimentPath

$capability = Get-Content -LiteralPath $capabilityPath -Raw | ConvertFrom-Json
$requiredCapabilityDomains = @(
    'gpu',
    'network',
    'bus_and_devices',
    'firmware',
    'security',
    'power'
)
$capabilityDomainStatus = [ordered]@{}
foreach ($domain in $requiredCapabilityDomains) {
    $property = $capability.domains.PSObject.Properties[$domain]
    if ($null -eq $property) {
        throw "Capability snapshot missing required domain: $domain"
    }
    $capabilityDomainStatus[$domain] = [string]$property.Value.status
}

$forbiddenGpuClaims = @(
    'keyword_semantics_validated',
    'event_ids_validated',
    'event_payload_contract_validated',
    'present_semantics',
    'submission_semantics',
    'queue_context_semantics',
    'queue_wait_semantics',
    'gpu_execution_duration_semantics'
)
foreach ($claim in $forbiddenGpuClaims) {
    if ([bool]$gpuMetadata.claims.$claim) {
        throw "Premature GPU semantic claim enabled: $claim"
    }
}
if ([string]$gpuMetadata.claims.trace_completeness -cne 'not_claimed') {
    throw 'GPU metadata trace completeness was incorrectly claimed.'
}
foreach ($claim in @(
    'keyword_semantics_validated',
    'event_ids_validated',
    'network_connection_semantics',
    'network_latency_semantics',
    'device_lifecycle_semantics',
    'kernel_lifecycle_semantics',
    'power_thermal_representative'
)) {
    if ([bool]$remainingInventory.claims.$claim) {
        throw "Premature remaining-domain semantic claim enabled: $claim"
    }
}
if ([string]$remainingInventory.claims.trace_completeness -cne 'not_claimed') {
    throw 'Remaining-domain trace completeness was incorrectly claimed.'
}

$rawFiles = [ordered]@{
    gpu_provider_inventory = $gpuInventoryPath
    gpu_provider_metadata = $gpuMetadataPath
    remaining_provider_inventory = $remainingInventoryPath
    system_capabilities = $capabilityPath
}
$rawHashes = [ordered]@{}
foreach ($entry in $rawFiles.GetEnumerator()) {
    $rawHashes[$entry.Key] = (Get-FileHash -LiteralPath $entry.Value -Algorithm SHA256).Hash.ToLowerInvariant()
}

$gpuMetadataReceipt = @(
    foreach ($provider in @($gpuMetadata.providers)) {
        [pscustomobject][ordered]@{
            name = [string]$provider.name
            expected_guid = [string]$provider.expected_guid
            expected_guid_observed = [bool]$provider.expected_guid_observed
            keyword_parser = [string]$provider.logman.keyword_parser
            keyword_row_count = [int]$provider.logman.keyword_row_count
            keyword_contamination_detected = [bool]$provider.logman.keyword_contamination_detected
            publisher_status = [string]$provider.publisher_metadata.status
            logman_output_sha256 = [string]$provider.logman.output_sha256
            publisher_output_sha256 = [string]$provider.publisher_metadata.output_sha256
        }
    }
)

$receipt = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    head_sha = $currentHead
    certified_utc = [DateTime]::UtcNow.ToString('o')
    static_gate = [ordered]@{
        powershell7 = 24
        windows_powershell_51 = 24
        analyzer_findings = 0
        capability_domain_binding = 'passed'
        normalized_event_domain_binding = 'passed'
    }
    gpu_inventory = [ordered]@{
        display_adapter_count = @($gpuInventory.display_adapters).Count
        provider_candidate_count = [int]$gpuInventory.etw_provider_inventory.candidate_count
        graphics_event_channel_count = [int]$gpuInventory.event_channels.candidate_count
    }
    gpu_metadata = $gpuMetadataReceipt
    remaining_provider_counts = [ordered]@{
        network = [int]$remainingInventory.providers.network.candidate_count
        kernel_lifecycle = [int]$remainingInventory.providers.kernel_lifecycle.candidate_count
        device_driver = [int]$remainingInventory.providers.device_driver.candidate_count
        power_thermal = [int]$remainingInventory.providers.power_thermal.candidate_count
    }
    remaining_event_channel_counts = [ordered]@{
        network = [int]$remainingInventory.event_channels.network.candidate_count
        kernel_lifecycle = [int]$remainingInventory.event_channels.kernel_lifecycle.candidate_count
        device_driver = [int]$remainingInventory.event_channels.device_driver.candidate_count
        power_thermal = [int]$remainingInventory.event_channels.power_thermal.candidate_count
    }
    capability_domain_status = $capabilityDomainStatus
    capability_collection_error_count = @($capability.collection_errors).Count
    raw_local_sha256 = $rawHashes
    evidence_policy = [ordered]@{
        raw_inventory_json_in_review_zip = $false
        raw_capability_json_in_review_zip = $false
        review_receipt_contains_counts_statuses_and_hashes_only = $true
    }
    claims = [ordered]@{
        keyword_semantics_validated = $false
        event_ids_validated = $false
        present_semantics = $false
        submission_semantics = $false
        gpu_queue_semantics = $false
        network_connection_semantics = $false
        network_latency_semantics = $false
        device_lifecycle_semantics = $false
        kernel_lifecycle_semantics = $false
        power_thermal_representative = $false
        firmware_security_effect_semantics = $false
        trace_completeness = 'not_claimed'
    }
}

$receiptPath = Join-Path $reviewDirectory 'superblock1-foundation-certification-receipt.json'
[IO.File]::WriteAllText(
    $receiptPath,
    (($receipt | ConvertTo-Json -Depth 20) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

$reviewZipPath = Join-Path $outputFull 'superblock1-foundation-certification-review.zip'
Compress-Archive -LiteralPath $receiptPath -DestinationPath $reviewZipPath -CompressionLevel Optimal

$archive = [IO.Compression.ZipFile]::OpenRead($reviewZipPath)
try {
    $entryNames = @($archive.Entries | ForEach-Object { $_.FullName })
}
finally {
    $archive.Dispose()
}
if ($entryNames.Count -ne 1 -or
    $entryNames[0] -cne [IO.Path]::GetFileName($receiptPath)) {
    throw 'Review ZIP contains unexpected files; raw evidence must remain local.'
}

$receiptSha256 = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
$reviewZipSha256 = (Get-FileHash -LiteralPath $reviewZipPath -Algorithm SHA256).Hash.ToLowerInvariant()

$postDirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) {
    throw 'SUPERBLOCK 1 native foundation certification dirtied the exact-head worktree.'
}

$result = [pscustomobject][ordered]@{
    status = 'passed'
    head_sha = $currentHead
    output_directory = $outputFull
    receipt_path = $receiptPath
    review_zip_path = $reviewZipPath
    receipt_sha256 = $receiptSha256
    review_zip_sha256 = $reviewZipSha256
    gpu_dxgkrnl_keyword_count = [int](@($gpuMetadata.providers | Where-Object name -eq 'Microsoft-Windows-DxgKrnl')[0].logman.keyword_row_count)
    gpu_dxgi_keyword_count = [int](@($gpuMetadata.providers | Where-Object name -eq 'Microsoft-Windows-DXGI')[0].logman.keyword_row_count)
    remaining_provider_counts = $receipt.remaining_provider_counts
    capability_domain_status = $capabilityDomainStatus
    capability_collection_error_count = @($capability.collection_errors).Count
    semantic_claims_enabled = $false
    trace_completeness = 'not_claimed'
}

Write-Information -MessageData "SUPERBLOCK 1 native foundation certification passed: $currentHead" -InformationAction Continue
Write-Information -MessageData "GPU metadata keywords: DxgKrnl=$($result.gpu_dxgkrnl_keyword_count), DXGI=$($result.gpu_dxgi_keyword_count)" -InformationAction Continue
Write-Information -MessageData "Capability collection errors: $($result.capability_collection_error_count)" -InformationAction Continue
Write-Information -MessageData "Review receipt SHA256: $receiptSha256" -InformationAction Continue
Write-Information -MessageData "Review ZIP SHA256: $reviewZipSha256" -InformationAction Continue
Write-Information -MessageData 'Semantic claims enabled: False' -InformationAction Continue
Write-Information -MessageData 'Trace completeness: not_claimed' -InformationAction Continue

if ($PassThru) {
    return $result
}
