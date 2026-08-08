[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -cne 'Windows_NT') {
    throw 'SUPERBLOCK capture/adapter certification requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'SUPERBLOCK capture/adapter certification requires PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}
$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'SUPERBLOCK capture/adapter certification requires a clean exact-head worktree.'
}

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$repositoryFull = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\') + '\'
if ($outputFull.StartsWith($repositoryFull,[StringComparison]::OrdinalIgnoreCase)) {
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

$localValidator = Join-Path $PSScriptRoot 'Invoke-NxbSuperblock1CaptureAdapterLocalValidation.ps1'
$metadataProbe = Join-Path $PSScriptRoot 'Invoke-NxbSelectedProviderMetadataProbe.ps1'
$capabilityCollector = Join-Path $PSScriptRoot 'Get-SystemCapabilities.ps1'
$capabilityValidator = Join-Path $PSScriptRoot 'Test-SystemCapabilities.ps1'
$capabilityAdapter = Join-Path $PSScriptRoot 'ConvertTo-NxbSuperblock1CapabilityAdapter.ps1'
foreach ($requiredPath in @(
    $localValidator,
    $metadataProbe,
    $capabilityCollector,
    $capabilityValidator,
    $capabilityAdapter
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required capture/adapter component missing: $requiredPath"
    }
}

Write-Information -MessageData '=== SUPERBLOCK 1 CAPTURE/ADAPTER CERTIFICATION ===' -InformationAction Continue
Write-Information -MessageData '[1/5] Combined dual-runtime static gate' -InformationAction Continue
$local = & $localValidator -ExpectedHead $ExpectedHead -PassThru
if ([string]$local.status -cne 'passed' -or
    [int]$local.powershell7.passed -ne 17 -or
    [int]$local.powershell7.total -ne 17 -or
    [int]$local.windows_powershell_51.passed -ne 17 -or
    [int]$local.windows_powershell_51.total -ne 17 -or
    [int]$local.analyzer_findings -ne 0) {
    throw 'Combined capture/adapter local validation did not pass cleanly.'
}

$metadataPath = Join-Path $rawDirectory 'selected-provider-metadata.json'
Write-Information -MessageData '[2/5] Real selected network/kernel provider metadata' -InformationAction Continue
$metadata = & $metadataProbe -ExpectedHead $ExpectedHead -OutputPath $metadataPath -PassThru
if ([string]$metadata.status -cne 'passed' -or [int]$metadata.provider_count -ne 6) {
    throw 'Selected provider metadata probe did not return six validated provider identities.'
}
foreach ($providerRecord in @($metadata.providers)) {
    if (-not [bool]$providerRecord.expected_guid_observed -or
        [bool]$providerRecord.logman.keyword_contamination_detected) {
        throw "Selected provider evidence gate failed for $($providerRecord.name)."
    }
}

$capabilityPath = Join-Path $baselineDirectory 'system-capabilities.json'
Write-Information -MessageData '[3/5] Fresh full-system capability snapshot' -InformationAction Continue
$collectedCapabilityPath = & $capabilityCollector -ExperimentPath $experimentPath
if (-not (Test-Path -LiteralPath $capabilityPath -PathType Leaf)) {
    throw "System capability snapshot was not created: $capabilityPath"
}
if ([IO.Path]::GetFullPath([string]$collectedCapabilityPath) -cne [IO.Path]::GetFullPath($capabilityPath)) {
    throw 'System capability collector returned an unexpected output path.'
}
& $capabilityValidator -ExperimentPath $experimentPath

$adapterPath = Join-Path $rawDirectory 'superblock1-capability-adapter.json'
Write-Information -MessageData '[4/5] Device/power/firmware capability adapter' -InformationAction Continue
$adapter = & $capabilityAdapter -CapabilityPath $capabilityPath -OutputPath $adapterPath -PassThru
if ([string]$adapter.status -cne 'passed') {
    throw 'Capability adapter did not pass.'
}
foreach ($domainName in @('network','device_driver','firmware','security','power')) {
    if ($null -eq $adapter.domains.PSObject.Properties[$domainName]) {
        throw "Capability adapter missing required domain: $domainName"
    }
}

Write-Information -MessageData '[5/5] Bounded review receipt and evidence-policy gate' -InformationAction Continue
$capability = Get-Content -LiteralPath $capabilityPath -Raw | ConvertFrom-Json
$providerReceipt = @(
    foreach ($providerRecord in @($metadata.providers)) {
        [pscustomobject][ordered]@{
            domain = [string]$providerRecord.domain
            name = [string]$providerRecord.name
            expected_guid = [string]$providerRecord.expected_guid
            expected_guid_observed = [bool]$providerRecord.expected_guid_observed
            keyword_status = [string]$providerRecord.logman.keyword_status
            keyword_row_count = [int]$providerRecord.logman.keyword_row_count
            keyword_contamination_detected = [bool]$providerRecord.logman.keyword_contamination_detected
            publisher_status = [string]$providerRecord.publisher_metadata.status
            logman_output_sha256 = [string]$providerRecord.logman.output_sha256
            publisher_output_sha256 = [string]$providerRecord.publisher_metadata.output_sha256
        }
    }
)

$receipt = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    head_sha = $currentHead
    certified_utc = [DateTime]::UtcNow.ToString('o')
    static_gate = [ordered]@{
        powershell7 = [ordered]@{
            passed = [int]$local.powershell7.passed
            total = [int]$local.powershell7.total
        }
        windows_powershell_51 = [ordered]@{
            passed = [int]$local.windows_powershell_51.passed
            total = [int]$local.windows_powershell_51.total
        }
        analyzer_findings = 0
    }
    selected_provider_metadata = $providerReceipt
    capability_collection_error_count = @($capability.collection_errors).Count
    capability_adapter = [ordered]@{
        network = $adapter.domains.network
        device_driver = $adapter.domains.device_driver
        firmware = $adapter.domains.firmware
        security = $adapter.domains.security
        power = $adapter.domains.power
        missing_is_zero = [bool]$adapter.evidence_policy.missing_is_zero
        unavailable_counts_are_null = [bool]$adapter.evidence_policy.unavailable_counts_are_null
    }
    raw_local_sha256 = [ordered]@{
        selected_provider_metadata = (Get-FileHash -LiteralPath $metadataPath -Algorithm SHA256).Hash.ToLowerInvariant()
        system_capabilities = (Get-FileHash -LiteralPath $capabilityPath -Algorithm SHA256).Hash.ToLowerInvariant()
        capability_adapter = (Get-FileHash -LiteralPath $adapterPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    evidence_policy = [ordered]@{
        raw_provider_metadata_in_review_zip = $false
        raw_capability_json_in_review_zip = $false
        raw_capability_adapter_in_review_zip = $false
        review_receipt_contains_bounded_status_counts_and_hashes_only = $true
    }
    claims = [ordered]@{
        keyword_semantics_validated = $false
        event_ids_validated = $false
        network_connection_semantics = $false
        network_latency_semantics = $false
        kernel_lifecycle_semantics = $false
        device_lifecycle_semantics = $false
        power_thermal_representative = $false
        firmware_security_effect_semantics = $false
        real_etl_capture_executed = $false
        trace_completeness = 'not_claimed'
    }
}

$receiptPath = Join-Path $reviewDirectory 'superblock1-capture-adapter-certification-receipt.json'
[IO.File]::WriteAllText(
    $receiptPath,
    (($receipt | ConvertTo-Json -Depth 20) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

$reviewZipPath = Join-Path $outputFull 'superblock1-capture-adapter-certification-review.zip'
Compress-Archive -LiteralPath $receiptPath -DestinationPath $reviewZipPath -CompressionLevel Optimal
$archive = [IO.Compression.ZipFile]::OpenRead($reviewZipPath)
try {
    $entryNames = @($archive.Entries | ForEach-Object { $_.FullName })
}
finally {
    $archive.Dispose()
}
if ($entryNames.Count -ne 1 -or $entryNames[0] -cne [IO.Path]::GetFileName($receiptPath)) {
    throw 'Review ZIP contains unexpected files; raw evidence must remain local.'
}

$receiptSha256 = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
$reviewZipSha256 = (Get-FileHash -LiteralPath $reviewZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$postDirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) {
    throw 'SUPERBLOCK capture/adapter certification dirtied the exact-head worktree.'
}

$result = [pscustomobject][ordered]@{
    status = 'passed'
    head_sha = $currentHead
    output_directory = $outputFull
    receipt_path = $receiptPath
    review_zip_path = $reviewZipPath
    receipt_sha256 = $receiptSha256
    review_zip_sha256 = $reviewZipSha256
    selected_provider_metadata = $providerReceipt
    capability_adapter = $receipt.capability_adapter
    capability_collection_error_count = $receipt.capability_collection_error_count
    real_etl_capture_executed = $false
    semantic_claims_enabled = $false
    trace_completeness = 'not_claimed'
}

Write-Information -MessageData "SUPERBLOCK capture/adapter certification passed: $currentHead" -InformationAction Continue
foreach ($providerRecord in $providerReceipt) {
    Write-Information -MessageData (
        '{0}: keyword_status={1}, keyword_rows={2}, publisher={3}' -f
        $providerRecord.name,
        $providerRecord.keyword_status,
        $providerRecord.keyword_row_count,
        $providerRecord.publisher_status
    ) -InformationAction Continue
}
Write-Information -MessageData "Capability collection errors: $($result.capability_collection_error_count)" -InformationAction Continue
Write-Information -MessageData "Review receipt SHA256: $receiptSha256" -InformationAction Continue
Write-Information -MessageData "Review ZIP SHA256: $reviewZipSha256" -InformationAction Continue
Write-Information -MessageData 'Real ETL capture executed: False' -InformationAction Continue
Write-Information -MessageData 'Semantic claims enabled: False' -InformationAction Continue
Write-Information -MessageData 'Trace completeness: not_claimed' -InformationAction Continue

if ($PassThru) { return $result }
