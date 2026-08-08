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

function Get-NxbSelectedKeywordRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines
    )

    $rows = [Collections.Generic.List[object]]::new()
    $inSection = $false
    $sectionDetected = $false

    foreach ($line in $Lines) {
        $text = [string]$line
        $trimmed = $text.Trim()

        if (-not $inSection) {
            if ($trimmed -match '(?i)\bValue\b' -and $trimmed -match '(?i)\bKeyword\b') {
                $inSection = $true
                $sectionDetected = $true
            }
            continue
        }

        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed -match '^-{2,}(\s+-{2,})+') { continue }

        $match = [regex]::Match($text, '^\s*(0x[0-9a-fA-F]+)\s+(.+?)\s*$')
        if ($match.Success) {
            $rows.Add([pscustomobject][ordered]@{
                value = $match.Groups[1].Value.ToLowerInvariant()
                text = $match.Groups[2].Value.Trim()
            })
            continue
        }

        if ($rows.Count -gt 0) { $inSection = $false }
    }

    return [pscustomobject][ordered]@{
        section_detected = $sectionDetected
        rows = @($rows)
        row_count = $rows.Count
    }
}

function Get-NxbSelectedTextSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    }
    finally {
        $hash.Dispose()
    }
}

if ($env:OS -cne 'Windows_NT') {
    throw 'Selected provider metadata probe requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Selected provider metadata probe requires PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}
$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'Selected provider metadata probe requires a clean exact-head worktree.'
}

$outputFull = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $outputFull) {
    throw "OutputPath already exists: $outputFull"
}
$outputDirectory = Split-Path -Parent $outputFull
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
}

$logman = Get-Command logman.exe -ErrorAction Stop
$wevtutil = Get-Command wevtutil.exe -ErrorAction Stop

# These identities were observed in the certified SUPERBLOCK 1 native provider inventory.
# They are identity bindings only; no keyword/event semantics are implied here.
$providerSpecs = @(
    [pscustomobject][ordered]@{
        domain = 'network'
        name = 'Microsoft-Windows-Kernel-Network'
        expected_guid = '{7dd42a49-5329-4832-8dfd-43d979153a88}'
    },
    [pscustomobject][ordered]@{
        domain = 'network'
        name = 'Microsoft-Windows-Winsock-AFD'
        expected_guid = '{e53c6823-7bb8-44bb-90dc-3f86090d48a6}'
    },
    [pscustomobject][ordered]@{
        domain = 'network'
        name = 'Microsoft-Windows-DNS-Client'
        expected_guid = '{1c95126e-7eea-49a9-a3fe-a378b03ddb4d}'
    },
    [pscustomobject][ordered]@{
        domain = 'kernel_lifecycle'
        name = 'Microsoft-Windows-Kernel-Process'
        expected_guid = '{22fb2cd6-0e7b-422b-a0c7-2fad1fd0e716}'
    },
    [pscustomobject][ordered]@{
        domain = 'kernel_lifecycle'
        name = 'Microsoft-Windows-Kernel-Registry'
        expected_guid = '{70eb4f03-c1de-4f73-a051-33d13d5413bd}'
    },
    [pscustomobject][ordered]@{
        domain = 'kernel_lifecycle'
        name = 'Microsoft-Windows-Kernel-PnP'
        expected_guid = '{9c205a39-1250-487d-abd7-e831c6290539}'
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

    $logmanText = $logmanLines -join [Environment]::NewLine
    $observedGuids = @(
        [regex]::Matches(
            $logmanText,
            '\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}'
        ) |
            ForEach-Object { $_.Value.ToLowerInvariant() } |
            Sort-Object -Unique
    )
    $expectedGuid = ([string]$providerSpec.expected_guid).ToLowerInvariant()
    $expectedObserved = $observedGuids -contains $expectedGuid
    if (-not $expectedObserved) {
        throw "Expected provider GUID was not observed for $providerName."
    }

    $keywordTable = Get-NxbSelectedKeywordRow -Lines $logmanLines
    $contamination = @(
        $keywordTable.rows |
            Where-Object { [string]$_.text -match '(?i)([a-z]:\\|\.exe(?:\s|$))' }
    )
    if ($contamination.Count -gt 0) {
        throw "Keyword metadata contamination detected for $providerName."
    }

    $publisherLines = @(& $wevtutil.Source gp $providerName /ge:true /gm:false 2>&1)
    $publisherExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    $publisherText = $publisherLines -join [Environment]::NewLine

    $providerResults.Add([pscustomobject][ordered]@{
        domain = [string]$providerSpec.domain
        name = $providerName
        expected_guid = [string]$providerSpec.expected_guid
        expected_guid_observed = $true
        logman = [ordered]@{
            status = 'measured'
            output_sha256 = Get-NxbSelectedTextSha256 -Text $logmanText
            output_line_count = @($logmanLines).Count
            keyword_parser = 'section-v1'
            keyword_status = if ([bool]$keywordTable.section_detected -and [int]$keywordTable.row_count -gt 0) {
                'measured'
            }
            else {
                'unavailable'
            }
            keyword_section_detected = [bool]$keywordTable.section_detected
            keyword_contamination_detected = $false
            keyword_rows = @($keywordTable.rows)
            keyword_row_count = [int]$keywordTable.row_count
        }
        publisher_metadata = [ordered]@{
            status = if ($publisherExit -eq 0) { 'measured' } else { 'unavailable' }
            exit_code = $publisherExit
            output_sha256 = Get-NxbSelectedTextSha256 -Text $publisherText
            output_line_count = @($publisherLines).Count
        }
    })
}

$result = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    head_sha = $currentHead
    collected_utc = [DateTime]::UtcNow.ToString('o')
    provider_count = $providerResults.Count
    providers = @($providerResults)
    claims = [ordered]@{
        provider_identity_validated = $true
        keyword_metadata_observed_where_available = $true
        keyword_semantics_validated = $false
        event_ids_validated = $false
        event_payload_contract_validated = $false
        network_connection_semantics = $false
        network_latency_semantics = $false
        kernel_lifecycle_semantics = $false
        trace_completeness = 'not_claimed'
    }
}

[IO.File]::WriteAllText(
    $outputFull,
    (($result | ConvertTo-Json -Depth 20) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

$postDirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) {
    throw 'Selected provider metadata probe dirtied the exact-head worktree.'
}

Write-Information -MessageData "Selected provider metadata written: $outputFull" -InformationAction Continue
foreach ($providerResult in $providerResults) {
    Write-Information -MessageData (
        '{0}: GUID={1}, keyword_status={2}, keyword_rows={3}, publisher={4}' -f
        $providerResult.name,
        $providerResult.expected_guid_observed,
        $providerResult.logman.keyword_status,
        $providerResult.logman.keyword_row_count,
        $providerResult.publisher_metadata.status
    ) -InformationAction Continue
}
Write-Information -MessageData 'Network/kernel semantic claims enabled: False' -InformationAction Continue

if ($PassThru) { return $result }
