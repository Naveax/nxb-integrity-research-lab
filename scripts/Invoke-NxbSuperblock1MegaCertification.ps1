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

function Test-NxbMegaAdministrator {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-NxbMegaXperf {
    [CmdletBinding()]
    param()
    $command = Get-Command xperf.exe -ErrorAction SilentlyContinue
    if ($null -ne $command -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
        return [IO.Path]::GetFullPath([string]$command.Source)
    }
    $candidates = [Collections.Generic.List[string]]::new()
    foreach ($registryPath in @(
        'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots'
    )) {
        try {
            $root = (Get-ItemProperty -LiteralPath $registryPath -Name KitsRoot10 -ErrorAction Stop).KitsRoot10
            if (-not [string]::IsNullOrWhiteSpace([string]$root)) {
                $candidates.Add((Join-Path ([string]$root) 'Windows Performance Toolkit\xperf.exe'))
            }
        }
        catch {
            Write-Verbose "Windows Kits registry probe unavailable at ${registryPath}: $($_.Exception.Message)"
        }
    }
    foreach ($programRoot in @(${env:ProgramFiles(x86)},$env:ProgramFiles)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$programRoot)) {
            $candidates.Add((Join-Path ([string]$programRoot) 'Windows Kits\10\Windows Performance Toolkit\xperf.exe'))
        }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw 'xperf.exe was not found in PATH, Windows Kits registry roots, or standard WPT directories.'
}

function Write-NxbMegaJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$InputObject)
    [IO.File]::WriteAllText(
        $Path,
        (($InputObject | ConvertTo-Json -Depth 24) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

if ($env:OS -cne 'Windows_NT') { throw 'SUPERBLOCK mega certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'SUPERBLOCK mega certification requires PowerShell 7.' }
if (-not (Test-NxbMegaAdministrator)) { throw 'SUPERBLOCK mega certification requires elevated PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}
$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'SUPERBLOCK mega certification requires a clean exact-head worktree.'
}
$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputFull) { throw "OutputDirectory already exists: $outputFull" }

$innerRunner = Join-Path $PSScriptRoot 'Invoke-NxbSuperblock1MultiDomainCertification.ps1'
$inventoryRunner = Join-Path $PSScriptRoot 'Get-NxbSuperblock1XperfHeaderInventory.ps1'
foreach ($requiredPath in @($innerRunner,$inventoryRunner,$PSCommandPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required SUPERBLOCK mega component missing: $requiredPath"
    }
}
foreach ($scriptPath in @($innerRunner,$inventoryRunner,$PSCommandPath)) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
    if (@($errors).Count -gt 0) {
        throw "PowerShell parser failed: $scriptPath"
    }
}
Import-Module PSScriptAnalyzer -ErrorAction Stop
$findings = @(
    foreach ($scriptPath in @($innerRunner,$inventoryRunner,$PSCommandPath)) {
        Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error
    }
)
if ($findings.Count -gt 0) {
    throw (
        "SUPERBLOCK mega PSScriptAnalyzer findings: $($findings.Count)`n" +
        (@($findings | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join "`n")
    )
}

$xperfPath = Resolve-NxbMegaXperf
$xperfDirectory = Split-Path -Parent $xperfPath
$originalPath = $env:PATH
if (@($env:PATH -split ';') -notcontains $xperfDirectory) {
    $env:PATH = $xperfDirectory + ';' + $env:PATH
}
try {
    Write-Information -MessageData '=== SUPERBLOCK 1 MEGA CERTIFICATION ===' -InformationAction Continue
    Write-Information -MessageData "Resolved xperf.exe: $xperfPath" -InformationAction Continue
    $inner = & $innerRunner -ExpectedHead $ExpectedHead -OutputDirectory $outputFull -PassThru
    if ([string]$inner.status -cne 'passed' -or
        -not [bool]$inner.real_etl_capture_executed -or
        [bool]$inner.semantic_claims_enabled -or
        [string]$inner.trace_completeness -cne 'not_claimed') {
        throw 'Inner multi-domain certification did not pass conservatively.'
    }

    Write-Information -MessageData '=== DETERMINISTIC HEADER-NORMALIZATION REPLAY ===' -InformationAction Continue
    $replayPath = Join-Path $outputFull 'raw-local\superblock1-xperf-header-inventory-replay.json'
    $replay = & $inventoryRunner -InputPath ([string]$inner.dumper_path_local) -OutputPath $replayPath -PassThru
    if ([string]$replay.status -cne 'passed') { throw 'Header replay did not pass.' }
    $sourceInventorySha = (Get-FileHash -LiteralPath ([string]$inner.header_inventory_path_local) -Algorithm SHA256).Hash.ToLowerInvariant()
    $replayInventorySha = (Get-FileHash -LiteralPath $replayPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $byteIdentical = $sourceInventorySha -ceq $replayInventorySha
    if (-not $byteIdentical) {
        throw "Header inventory replay is not byte-identical. source=$sourceInventorySha replay=$replayInventorySha"
    }

    $megaReviewRoot = Join-Path $outputFull 'mega-review'
    [IO.Directory]::CreateDirectory($megaReviewRoot) | Out-Null
    $replayReceiptPath = Join-Path $megaReviewRoot 'superblock1-header-replay-receipt.json'
    $replayReceipt = [pscustomobject][ordered]@{
        schema_version = 1
        status = 'passed'
        head_sha = $currentHead
        source_dumper_sha256 = (Get-FileHash -LiteralPath ([string]$inner.dumper_path_local) -Algorithm SHA256).Hash.ToLowerInvariant()
        source_inventory_sha256 = $sourceInventorySha
        replay_inventory_sha256 = $replayInventorySha
        byte_identical = $byteIdentical
        header_count = [int]$replay.header_count
        candidate_counts = $replay.candidate_counts
        claims = [ordered]@{
            deterministic_header_normalization = $true
            event_name_implies_semantics = $false
            domain_hint_implies_semantics = $false
            event_ids_validated = $false
            trace_completeness = 'not_claimed'
        }
    }
    Write-NxbMegaJson -Path $replayReceiptPath -InputObject $replayReceipt

    Copy-Item -LiteralPath ([string]$inner.receipt_path) -Destination (Join-Path $megaReviewRoot 'superblock1-multi-domain-certification-receipt.json') -Force
    Copy-Item -LiteralPath ([string]$inner.header_inventory_path_local) -Destination (Join-Path $megaReviewRoot 'superblock1-xperf-header-inventory.json') -Force
    $traceQualityPath = Join-Path $outputFull 'review\superblock1-trace-quality.json'
    if (Test-Path -LiteralPath $traceQualityPath -PathType Leaf) {
        Copy-Item -LiteralPath $traceQualityPath -Destination (Join-Path $megaReviewRoot 'superblock1-trace-quality.json') -Force
    }

    $megaReviewZip = Join-Path $outputFull 'superblock1-mega-certification-review.zip'
    Compress-Archive -Path (Join-Path $megaReviewRoot '*') -DestinationPath $megaReviewZip -Force
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($megaReviewZip)
    try {
        foreach ($entry in $archive.Entries) {
            $lower = $entry.FullName.ToLowerInvariant()
            if ($lower.EndsWith('.etl') -or $lower.Contains('xperf-dumper') -or $lower.Contains('selected-provider-metadata') -or $lower.Contains('system-capabilities')) {
                throw "Forbidden raw evidence entered SUPERBLOCK mega review ZIP: $($entry.FullName)"
            }
        }
    }
    finally {
        $archive.Dispose()
    }

    $postDirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) {
        throw 'SUPERBLOCK mega certification dirtied the exact-head worktree.'
    }
    $result = [pscustomobject][ordered]@{
        status = 'passed'
        head_sha = $currentHead
        output_directory = $outputFull
        inner_receipt_sha256 = [string]$inner.receipt_sha256
        inner_review_zip_sha256 = [string]$inner.review_zip_sha256
        header_inventory_source_sha256 = $sourceInventorySha
        header_inventory_replay_sha256 = $replayInventorySha
        header_inventory_byte_identical = $byteIdentical
        header_count = [int]$inner.header_count
        candidate_counts = $inner.candidate_counts
        events_lost = [uint64]$inner.events_lost
        buffers_lost = [uint64]$inner.buffers_lost
        buffers_written = [uint64]$inner.buffers_written
        mega_review_zip_path = $megaReviewZip
        mega_review_zip_sha256 = (Get-FileHash -LiteralPath $megaReviewZip -Algorithm SHA256).Hash.ToLowerInvariant()
        raw_etl_path_local = [string]$inner.etl_path_local
        raw_dumper_path_local = [string]$inner.dumper_path_local
        deterministic_header_replay = $true
        semantic_claims_enabled = $false
        trace_completeness = 'not_claimed'
    }
    Write-Information -MessageData "SUPERBLOCK mega certification passed: $currentHead" -InformationAction Continue
    Write-Information -MessageData "Header inventory byte-identical replay: $byteIdentical" -InformationAction Continue
    Write-Information -MessageData "EventsLost=$($result.events_lost) BuffersLost=$($result.buffers_lost) BuffersWritten=$($result.buffers_written)" -InformationAction Continue
    Write-Information -MessageData "Mega review ZIP SHA256: $($result.mega_review_zip_sha256)" -InformationAction Continue
    Write-Information -MessageData 'Raw ETL/full dumper stay local; semantic claims remain disabled.' -InformationAction Continue
    if ($PassThru) { return $result }
}
finally {
    $env:PATH = $originalPath
}
