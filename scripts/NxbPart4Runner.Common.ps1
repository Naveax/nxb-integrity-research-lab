Set-StrictMode -Version Latest

function Get-NxbPart4Sha256Text {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Get-NxbPart4FileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-NxbPart4AtomicJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$InputObject)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $tempPath = $fullPath + '.tmp-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($tempPath,(($InputObject | ConvertTo-Json -Depth 48) + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tempPath -Destination $fullPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) { Remove-Item -LiteralPath $tempPath -Force }
    }
}

function Read-NxbPart4Json {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ('Required JSON file missing: {0}' -f $Path) }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Get-NxbPart4Shard {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskId,[Parameter(Mandatory)][ValidateRange(1,64)][int]$ShardCount)
    $hash = Get-NxbPart4Sha256Text -Text $TaskId
    $prefix = [Convert]::ToUInt32($hash.Substring(0,8),16)
    return [int]($prefix % [uint32]$ShardCount)
}

function Get-NxbPart4RunId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$ExactHead,
        [Parameter(Mandatory)][string]$ConfigSha256,
        [Parameter(Mandatory)][string]$ScopeSha256,
        [Parameter(Mandatory)][string]$ContractId
    )
    $material = @($Repository,$ExactHead,$ConfigSha256,$ScopeSha256,$ContractId) -join "`n"
    return 'run-' + (Get-NxbPart4Sha256Text -Text $material).Substring(0,32)
}

function Get-NxbPart4CheckpointFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Checkpoint)
    $completed = @($Checkpoint.completed_task_ids | ForEach-Object { [string]$_ } | Sort-Object) -join ','
    $attemptMaterial = @($Checkpoint.attempts.PSObject.Properties | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Name,[int]$_.Value }) -join ','
    $backoffMaterial = @($Checkpoint.not_before_tick.PSObject.Properties | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Name,[int]$_.Value }) -join ','
    $domainMaterial = @($Checkpoint.domain_last_served_tick.PSObject.Properties | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Name,[int]$_.Value }) -join ','
    $material = @(
        [string]$Checkpoint.run_id,
        [string]$Checkpoint.exact_head,
        [string]$Checkpoint.config_sha256,
        [string]$Checkpoint.scope_sha256,
        [string][int]$Checkpoint.checkpoint_sequence,
        [string][int]$Checkpoint.tick,
        [string][int]$Checkpoint.budget_consumed,
        [string]$Checkpoint.stop_mode,
        $completed,$attemptMaterial,$backoffMaterial,$domainMaterial
    ) -join "`n"
    return Get-NxbPart4Sha256Text -Text $material
}

function Write-NxbPart4Checkpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$Checkpoint)
    $Checkpoint.checkpoint_fingerprint_sha256 = Get-NxbPart4CheckpointFingerprint -Checkpoint $Checkpoint
    Write-NxbPart4AtomicJson -Path $Path -InputObject $Checkpoint
}

function Test-NxbPart4CheckpointBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Checkpoint,[Parameter(Mandatory)][object]$Manifest)
    foreach ($name in @('run_id','exact_head','config_sha256','scope_sha256')) {
        if ([string]$Checkpoint.PSObject.Properties[$name].Value -cne [string]$Manifest.PSObject.Properties[$name].Value) {
            throw ('Checkpoint binding mismatch: {0}' -f $name)
        }
    }
    $expected = Get-NxbPart4CheckpointFingerprint -Checkpoint $Checkpoint
    if ([string]$Checkpoint.checkpoint_fingerprint_sha256 -cne $expected) { throw 'Checkpoint fingerprint mismatch.' }
    return $true
}

function Get-NxbPart4SchedulerScore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Task,
        [Parameter(Mandatory)][object]$Checkpoint,
        [Parameter(Mandatory)][object]$Policy,
        [Parameter(Mandatory)][hashtable]$DomainTarget,
        [Parameter(Mandatory)][hashtable]$DomainCompleted
    )
    $domain = [string]$Task.domain
    $completed = [int]$DomainCompleted[$domain]
    $target = [int]$DomainTarget[$domain]
    $coverageDeficit = [Math]::Max(0,$target - $completed)
    $lastServed = [int]$Checkpoint.domain_last_served_tick.PSObject.Properties[$domain].Value
    $fairnessCredit = [Math]::Max(0,[int]$Checkpoint.tick - $lastServed)
    $attemptProperty = $Checkpoint.attempts.PSObject.Properties[[string]$Task.task_id]
    $attempts = if ($null -eq $attemptProperty) { 0 } else { [int]$attemptProperty.Value }
    return (
        ([int]$Task.base_priority * [int]$Policy.scheduler.base_priority_weight) +
        ($coverageDeficit * [int]$Policy.scheduler.coverage_deficit_weight) +
        ($fairnessCredit * [int]$Policy.scheduler.fairness_credit_weight) -
        ($completed * [int]$Policy.scheduler.saturation_penalty_weight) -
        ($attempts * [int]$Policy.scheduler.retry_penalty_weight)
    )
}

function Get-NxbPart4BackoffTick {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$CurrentTick,[Parameter(Mandatory)][int]$Attempt,[Parameter(Mandatory)][object]$Policy)
    $base = [int]$Policy.scheduler.base_backoff_ticks
    $maximum = [int]$Policy.scheduler.maximum_backoff_ticks
    $delay = [Math]::Min($maximum,$base * [Math]::Pow(2,[Math]::Max(0,$Attempt - 1)))
    return $CurrentTick + [int]$delay
}
