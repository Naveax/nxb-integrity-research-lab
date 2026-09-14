[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PolicyPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$BoundedCaptureSessionId,

    [Parameter()]
    [switch]$CancelExistingSession,

    [Parameter()]
    [string]$WprExecutablePath,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Nxb.EvidenceStore.psm1') -Force

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$experimentFull = Get-NxbFullPath -Path $ExperimentPath
$policyFull = [IO.Path]::GetFullPath($PolicyPath)
$expected = $ExpectedHead.ToLowerInvariant()

$parsedSessionId = [Guid]::Empty
if (-not [Guid]::TryParse($BoundedCaptureSessionId,[ref]$parsedSessionId)) {
    throw 'BoundedCaptureSessionId is not a valid GUID.'
}
$sessionId = $parsedSessionId.ToString('D')

if (-not (Test-Path -LiteralPath $policyFull -PathType Leaf)) {
    throw ("Adaptive policy bulunamadı: {0}" -f $policyFull)
}
$policy = Read-NxbJson -Path $policyFull
if ([int]$policy.schema_version -ne 1) { throw 'Unsupported adaptive observability policy schema.' }
$policyFingerprint = Get-NxbCanonicalJsonHash -InputObject $policy

$gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
if ($null -eq $gitCommand) { $gitCommand = Get-Command git -ErrorAction Stop }
$git = [string]$gitCommand.Source
$currentHead = (@(& $git -C $repositoryRoot rev-parse HEAD 2>&1) -join [Environment]::NewLine).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $expected) {
    throw ('Bounded memory WPR exact-head mismatch: expected={0} actual={1}' -f $expected,$currentHead)
}
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all 2>&1)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'Bounded memory WPR requires a clean exact-head repository worktree.'
}

$manifestPath = Join-Path $experimentFull 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Manifest bulunamadı: $manifestPath"
}
$manifest = Read-NxbJson -Path $manifestPath
if ([string]$manifest.status -ne 'prepared') {
    throw "Bounded memory WPR yalnız prepared deneyde başlatılabilir. Mevcut durum: $($manifest.status)"
}

$profileMetadata = & (Join-Path $PSScriptRoot 'Test-WprProfile.ps1') -PassThru
$memoryBudgetKiB = [int64]$profileMetadata.BufferSizeKiB * [int64]$profileMetadata.Buffers
if ($memoryBudgetKiB -le 0 -or ($memoryBudgetKiB % 1024) -ne 0) {
    throw 'Memory WPR buffer budget geçersiz veya MiB olarak tam temsil edilemiyor.'
}
$memoryBudgetMiB = [int]($memoryBudgetKiB / 1024)
if ($memoryBudgetMiB -ne 64) {
    throw ("Bounded memory WPR budget drift: expected=64 MiB actual={0} MiB" -f $memoryBudgetMiB)
}

try {
    $wprPath = Resolve-NxbExecutablePath -Name 'wpr.exe' -ExplicitPath $WprExecutablePath
}
catch {
    throw "wpr.exe bulunamadı. Windows ADK içindeki Windows Performance Toolkit kurulmalı. $($_.Exception.Message)"
}

$sessionPath = Join-Path $experimentFull 'trace-session.json'
if (Test-Path -LiteralPath $sessionPath) {
    throw "Bu deneyde trace-session.json zaten var: $sessionPath"
}

if ($CancelExistingSession) {
    $cancelOutput = & $wprPath -cancel 2>&1
    $cancelExitCode = $LASTEXITCODE
    $noRunningTraceProfilesExitCode = -984076288 # 0xC5583000
    if ($cancelExitCode -ne 0 -and $cancelExitCode -ne $noRunningTraceProfilesExitCode) {
        throw "Mevcut WPR oturumu iptal edilemedi (exit $cancelExitCode): $($cancelOutput -join [Environment]::NewLine)"
    }
}

# Custom WPR profile selection uses the same Name.Detail reference for File and Memory
# variants. Omitting -filemode is the contract that selects the committed Memory variant.
$startProfileArgument = [string]$profileMetadata.FileProfileReference
$startOutput = & $wprPath -start $startProfileArgument 2>&1
$startExitCode = $LASTEXITCODE
if ($startExitCode -ne 0) {
    throw "Bounded memory WPR başlatılamadı (exit $startExitCode): $($startOutput -join [Environment]::NewLine)"
}

$profileProvenance = [ordered]@{
    type                     = 'repository_wprp'
    relative_path            = [string]$profileMetadata.RelativePath
    sha256                   = [string]$profileMetadata.Sha256
    length                   = [int64]$profileMetadata.Length
    name                     = [string]$profileMetadata.Name
    detail_level             = [string]$profileMetadata.DetailLevel
    logging_mode             = 'Memory'
    bounded                  = $true
    buffer_size_kib          = [int]$profileMetadata.BufferSizeKiB
    buffers                  = [int]$profileMetadata.Buffers
    memory_buffer_budget_mib = $memoryBudgetMiB
    maximum_file_size_mib    = $null
    file_mode                = $null
    memory_profile_id        = [string]$profileMetadata.MemoryProfileId
    overwrite_model          = 'bounded-memory-buffer-reuse'
    keywords                 = @($profileMetadata.Keywords)
    stacks                   = @($profileMetadata.Stacks)
}
$profileProvenanceSha256 = Get-NxbCanonicalJsonHash -InputObject $profileProvenance

$session = [ordered]@{
    started_utc                    = [DateTime]::UtcNow.ToString('o')
    profile                        = 'NxbMinimalCpuScheduler'
    mode                           = 'memory'
    capture_role                   = 'bounded-pretrigger-ring'
    bounded_capture_session_id     = $sessionId
    expected_head                  = $expected
    policy_id                      = [string]$policy.policy_id
    policy_fingerprint_sha256      = $policyFingerprint
    profile_provenance             = $profileProvenance
    profile_provenance_sha256      = $profileProvenanceSha256
    status                         = 'recording'
    wpr_executable                 = $wprPath
}

try {
    Write-NxbJsonAtomic -Path $sessionPath -InputObject $session -Depth 20
    Set-NxbExperimentState -ExperimentPath $experimentFull -State recording -Confirm:$false | Out-Null
}
catch {
    $rollbackOutput = & $wprPath -cancel 2>&1
    $rollbackExitCode = $LASTEXITCODE
    if ($rollbackExitCode -ne 0) {
        Write-Warning "Bounded memory WPR rollback iptali başarısız (exit $rollbackExitCode): $($rollbackOutput -join [Environment]::NewLine)"
    }
    if (Test-Path -LiteralPath $sessionPath) {
        Remove-Item -LiteralPath $sessionPath -Force
    }
    throw
}

$result = [pscustomobject][ordered]@{
    status = 'recording'
    experiment_path = $experimentFull
    session_path = $sessionPath
    session_id = $sessionId
    expected_head = $expected
    policy_fingerprint_sha256 = $policyFingerprint
    logging_mode = 'Memory'
    memory_buffer_budget_mib = $memoryBudgetMiB
    profile_sha256 = [string]$profileMetadata.Sha256
    profile_provenance_sha256 = $profileProvenanceSha256
}

if ($PassThru) { return $result }
Write-Host ("Bounded memory WPR pre-trigger ring başlatıldı: {0} MiB" -f $memoryBudgetMiB)
