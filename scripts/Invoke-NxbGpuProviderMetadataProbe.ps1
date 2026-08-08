[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -cne 'Windows_NT') {
    throw 'GPU provider metadata probe requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'GPU provider metadata probe requires PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}
$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'GPU provider metadata probe requires a clean exact-head worktree.'
}

$logman = Get-Command logman.exe -ErrorAction Stop
$wevtutil = Get-Command wevtutil.exe -ErrorAction Stop

$providerSpecs = @(
    [pscustomobject][ordered]@{
        name = 'Microsoft-Windows-DxgKrnl'
        expected_guid = '{802ec45a-1e99-4b83-9920-87c98277ba9d}'
    },
    [pscustomobject][ordered]@{
        name = 'Microsoft-Windows-DXGI'
        expected_guid = '{ca11c036-0102-4a2d-a6ad-f03cfed5d3c9}'
    }
)

$providerResults = [Collections.Generic.List[object]]::new()

foreach ($providerSpec in $providerSpecs) {
    $providerName = [string]$providerSpec.name

    $logmanLines = @(& $logman.Source query providers -n $providerName 2>&1)
    $logmanExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    if ($logmanExit -ne 0) {
        throw "logman provider query failed for ${providerName}: exit=$logmanExit"
    }

    $logmanText = ($logmanLines -join [Environment]::NewLine)
    $logmanBytes = [Text.Encoding]::UTF8.GetBytes($logmanText)
    $logmanHash = [Security.Cryptography.SHA256]::Create()
    try {
        $logmanSha256 = ([BitConverter]::ToString($logmanHash.ComputeHash($logmanBytes))).Replace('-','').ToLowerInvariant()
    }
    finally {
        $logmanHash.Dispose()
    }

    $guidMatches = [regex]::Matches(
        $logmanText,
        '\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}'
    )
    $observedGuids = @(
        $guidMatches |
            ForEach-Object { $_.Value.ToLowerInvariant() } |
            Sort-Object -Unique
    )

    $expectedGuidLower = ([string]$providerSpec.expected_guid).ToLowerInvariant()
    $guidMatch = $observedGuids -contains $expectedGuidLower

    $keywordRows = [Collections.Generic.List[object]]::new()
    foreach ($line in $logmanLines) {
        $text = [string]$line
        $match = [regex]::Match($text, '^\s*(0x[0-9a-fA-F]+)\s+(.+?)\s*$')
        if (-not $match.Success) { continue }

        $keywordRows.Add([pscustomobject][ordered]@{
            value = $match.Groups[1].Value.ToLowerInvariant()
            text = $match.Groups[2].Value.Trim()
        })
    }

    $publisherLines = @(& $wevtutil.Source gp $providerName /ge:true /gm:false 2>&1)
    $publisherExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    $publisherText = ($publisherLines -join [Environment]::NewLine)
    $publisherBytes = [Text.Encoding]::UTF8.GetBytes($publisherText)
    $publisherHash = [Security.Cryptography.SHA256]::Create()
    try {
        $publisherSha256 = ([BitConverter]::ToString($publisherHash.ComputeHash($publisherBytes))).Replace('-','').ToLowerInvariant()
    }
    finally {
        $publisherHash.Dispose()
    }

    $providerResults.Add([pscustomobject][ordered]@{
        name = $providerName
        expected_guid = [string]$providerSpec.expected_guid
        observed_guids = @($observedGuids)
        expected_guid_observed = [bool]$guidMatch
        logman = [ordered]@{
            status = 'measured'
            output_sha256 = $logmanSha256
            output_line_count = @($logmanLines).Count
            keyword_rows = @($keywordRows)
            keyword_row_count = $keywordRows.Count
        }
        publisher_metadata = [ordered]@{
            status = if ($publisherExit -eq 0) { 'measured' } else { 'unavailable' }
            exit_code = $publisherExit
            output_sha256 = $publisherSha256
            output_line_count = @($publisherLines).Count
        }
    })
}

foreach ($providerResult in $providerResults) {
    if (-not [bool]$providerResult.expected_guid_observed) {
        throw "Expected provider GUID was not observed for $($providerResult.name)."
    }
}

$result = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    head_sha = $currentHead
    collected_utc = [DateTime]::UtcNow.ToString('o')
    providers = @($providerResults)
    claims = [ordered]@{
        provider_identity_validated = $true
        keyword_metadata_observed = $true
        keyword_semantics_validated = $false
        event_ids_validated = $false
        event_payload_contract_validated = $false
        present_semantics = $false
        submission_semantics = $false
        queue_context_semantics = $false
        queue_wait_semantics = $false
        gpu_execution_duration_semantics = $false
        trace_completeness = 'not_claimed'
    }
}

$outputFull = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $outputFull
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
}
if (Test-Path -LiteralPath $outputFull) {
    throw "OutputPath already exists: $outputFull"
}

[IO.File]::WriteAllText(
    $outputFull,
    (($result | ConvertTo-Json -Depth 20) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

$postDirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) {
    throw 'GPU provider metadata probe dirtied the exact-head worktree.'
}

Write-Information -MessageData "GPU provider metadata probe passed: $currentHead" -InformationAction Continue
foreach ($providerResult in $providerResults) {
    Write-Information -MessageData (
        "$($providerResult.name): GUID=$($providerResult.expected_guid_observed), keyword rows=$($providerResult.logman.keyword_row_count), publisher=$($providerResult.publisher_metadata.status)"
    ) -InformationAction Continue
}

if ($PassThru) {
    return $result
}
