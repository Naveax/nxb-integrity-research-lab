[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$BindingFingerprintSha256,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ProviderMetadataFingerprintSha256,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$L3ReviewZipSha256,
    [Parameter()][ValidateRange(100,5000)][int]$InterPhaseDelayMilliseconds = 750,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NxbL4Property {
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter()][AllowNull()][object]$DefaultValue = $null
    )
    if ($null -eq $InputObject) { return $DefaultValue }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }
    return $property.Value
}

function Get-NxbL4Sha256Text {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha256.Dispose() }
}

function Write-NxbL4Json {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory)][object]$InputObject
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $fullPath,
        (($InputObject | ConvertTo-Json -Depth 40) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

function Get-NxbL4PnpSnapshot {
    [CmdletBinding()]
    param()
    $records = @()
    foreach ($device in @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop)) {
        $rawIdentity = [string](Get-NxbL4Property -InputObject $device -Name 'PNPDeviceID' -DefaultValue '')
        if ([string]::IsNullOrWhiteSpace($rawIdentity)) {
            $rawIdentity = [string](Get-NxbL4Property -InputObject $device -Name 'DeviceID' -DefaultValue '')
        }
        if ([string]::IsNullOrWhiteSpace($rawIdentity)) { continue }
        $identityHash = Get-NxbL4Sha256Text -Text $rawIdentity
        $classGuid = ([string](Get-NxbL4Property -InputObject $device -Name 'ClassGuid' -DefaultValue '')).ToLowerInvariant()
        $status = [string](Get-NxbL4Property -InputObject $device -Name 'Status' -DefaultValue '')
        $errorCode = [int](Get-NxbL4Property -InputObject $device -Name 'ConfigManagerErrorCode' -DefaultValue -1)
        $material = '{0}`t{1}`t{2}`t{3}' -f $identityHash,$classGuid,$status,$errorCode
        $records += Get-NxbL4Sha256Text -Text $material
    }
    $ordered = @($records | Sort-Object)
    $fingerprint = Get-NxbL4Sha256Text -Text ($ordered -join "`n")
    return [pscustomobject][ordered]@{
        device_count = [int]$ordered.Count
        record_hashes = $ordered
        inventory_fingerprint_sha256 = $fingerprint
    }
}

function Get-NxbL4ActivePowerSchemeGuid {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PowerCfgPath)
    $text = @(& $PowerCfgPath /getactivescheme 2>&1) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0) { throw "powercfg /getactivescheme failed: exit=$LASTEXITCODE" }
    $guidMatch = [regex]::Match($text,'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if (-not $guidMatch.Success) { throw 'Unable to parse active power scheme GUID.' }
    return $guidMatch.Value.ToLowerInvariant()
}

function Get-NxbL4PowerSchemeGuidInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PowerCfgPath)
    $text = @(& $PowerCfgPath /list 2>&1) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0) { throw "powercfg /list failed: exit=$LASTEXITCODE" }
    $values = @(
        [regex]::Matches($text,'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') |
            ForEach-Object { $_.Value.ToLowerInvariant() } |
            Sort-Object -Unique
    )
    return $values
}

function Invoke-NxbL4PnpRepeat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('A','B')][string]$Repeat,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PnpUtilPath,
        [Parameter(Mandatory)][ValidateRange(100,5000)][int]$DelayMilliseconds
    )
    $before = Get-NxbL4PnpSnapshot
    & $PnpUtilPath /scan-devices *> $null
    $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    if ($exitCode -ne 0) { throw "pnputil /scan-devices failed in repeat ${Repeat}: exit=$exitCode" }
    Start-Sleep -Milliseconds $DelayMilliseconds
    $after = Get-NxbL4PnpSnapshot
    return [pscustomobject][ordered]@{
        repeat = $Repeat
        stimulus = 'pnputil_scan_devices'
        exit_code = $exitCode
        succeeded = $true
        before = $before
        after = $after
        inventory_stable = ([string]$before.inventory_fingerprint_sha256 -ceq [string]$after.inventory_fingerprint_sha256)
        device_disable_used = $false
        device_remove_used = $false
        device_install_used = $false
    }
}

function Invoke-NxbL4PowerRepeat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('A','B')][string]$Repeat,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PowerCfgPath,
        [Parameter(Mandatory)][ValidateRange(100,5000)][int]$DelayMilliseconds
    )
    $originalGuid = Get-NxbL4ActivePowerSchemeGuid -PowerCfgPath $PowerCfgPath
    $originalHash = Get-NxbL4Sha256Text -Text $originalGuid
    $temporaryGuid = $null
    $temporaryHash = $null
    $created = $false
    $activated = $false
    $restored = $false
    $deleted = $false
    $duringGuid = $null
    $restoredGuid = $null
    try {
        $beforeGuid = Get-NxbL4ActivePowerSchemeGuid -PowerCfgPath $PowerCfgPath
        if ($beforeGuid -cne $originalGuid) { throw 'Active power scheme changed before controlled transition.' }

        $duplicateText = @(& $PowerCfgPath /duplicatescheme $originalGuid 2>&1) -join [Environment]::NewLine
        if ($LASTEXITCODE -ne 0) { throw "powercfg /duplicatescheme failed: exit=$LASTEXITCODE" }
        $guidMatches = [regex]::Matches($duplicateText,'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
        if ($guidMatches.Count -lt 1) { throw 'Unable to parse temporary power scheme GUID.' }
        $temporaryGuid = $guidMatches[$guidMatches.Count - 1].Value.ToLowerInvariant()
        if ($temporaryGuid -ceq $originalGuid) { throw 'Temporary power scheme unexpectedly equals original scheme.' }
        $temporaryHash = Get-NxbL4Sha256Text -Text $temporaryGuid
        $created = $true

        $afterCreateInventory = @(Get-NxbL4PowerSchemeGuidInventory -PowerCfgPath $PowerCfgPath)
        if ($afterCreateInventory -notcontains $temporaryGuid) { throw 'Temporary power scheme was not visible after creation.' }

        & $PowerCfgPath /setactive $temporaryGuid *> $null
        if ($LASTEXITCODE -ne 0) { throw "powercfg temporary /setactive failed: exit=$LASTEXITCODE" }
        Start-Sleep -Milliseconds $DelayMilliseconds
        $duringGuid = Get-NxbL4ActivePowerSchemeGuid -PowerCfgPath $PowerCfgPath
        $activated = ($duringGuid -ceq $temporaryGuid)
        if (-not $activated) { throw 'Temporary power scheme was not observed active.' }

        & $PowerCfgPath /setactive $originalGuid *> $null
        if ($LASTEXITCODE -ne 0) { throw "powercfg original /setactive failed: exit=$LASTEXITCODE" }
        Start-Sleep -Milliseconds $DelayMilliseconds
        $restoredGuid = Get-NxbL4ActivePowerSchemeGuid -PowerCfgPath $PowerCfgPath
        $restored = ($restoredGuid -ceq $originalGuid)
        if (-not $restored) { throw 'Original power scheme was not observed restored.' }

        & $PowerCfgPath /delete $temporaryGuid *> $null
        if ($LASTEXITCODE -ne 0) { throw "powercfg temporary /delete failed: exit=$LASTEXITCODE" }
        $afterDeleteInventory = @(Get-NxbL4PowerSchemeGuidInventory -PowerCfgPath $PowerCfgPath)
        $deleted = ($afterDeleteInventory -notcontains $temporaryGuid)
        if (-not $deleted) { throw 'Temporary power scheme remained visible after deletion.' }
    }
    finally {
        if ($created -and -not $restored) {
            try {
                & $PowerCfgPath /setactive $originalGuid *> $null
                $restoredGuid = Get-NxbL4ActivePowerSchemeGuid -PowerCfgPath $PowerCfgPath
                $restored = ($restoredGuid -ceq $originalGuid)
            }
            catch { $restored = $false }
        }
        if ($created -and -not $deleted -and -not [string]::IsNullOrWhiteSpace($temporaryGuid)) {
            try {
                & $PowerCfgPath /delete $temporaryGuid *> $null
                $afterDeleteInventory = @(Get-NxbL4PowerSchemeGuidInventory -PowerCfgPath $PowerCfgPath)
                $deleted = ($afterDeleteInventory -notcontains $temporaryGuid)
            }
            catch { $deleted = $false }
        }
    }
    $beforeHash = Get-NxbL4Sha256Text -Text $originalGuid
    $duringHash = $null
    if ($null -ne $duringGuid) { $duringHash = Get-NxbL4Sha256Text -Text $duringGuid }
    $restoredHash = $null
    if ($null -ne $restoredGuid) { $restoredHash = Get-NxbL4Sha256Text -Text $restoredGuid }
    return [pscustomobject][ordered]@{
        repeat = $Repeat
        stimulus = 'temporary_power_scheme_direct_state'
        original_scheme_guid_sha256 = $originalHash
        temporary_scheme_guid_sha256 = $temporaryHash
        before_active_scheme_guid_sha256 = $beforeHash
        during_active_scheme_guid_sha256 = $duringHash
        restored_active_scheme_guid_sha256 = $restoredHash
        temporary_scheme_created = $created
        temporary_scheme_activated = $activated
        original_scheme_restored = $restored
        temporary_scheme_deleted = $deleted
        succeeded = ($created -and $activated -and $restored -and $deleted)
        firmware_state_changed = $false
        secure_boot_changed = $false
        tpm_state_changed = $false
        device_guard_changed = $false
    }
}

if ($env:OS -cne 'Windows_NT') { throw 'L4 direct-state transitions require Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'L4 direct-state transitions require PowerShell 7.' }

$pnpUtil = (Get-Command pnputil.exe -ErrorAction Stop).Source
$powerCfg = (Get-Command powercfg.exe -ErrorAction Stop).Source

$pnpRepeats = @(
    Invoke-NxbL4PnpRepeat -Repeat A -PnpUtilPath $pnpUtil -DelayMilliseconds $InterPhaseDelayMilliseconds
    Invoke-NxbL4PnpRepeat -Repeat B -PnpUtilPath $pnpUtil -DelayMilliseconds $InterPhaseDelayMilliseconds
)
$powerRepeats = @(
    Invoke-NxbL4PowerRepeat -Repeat A -PowerCfgPath $powerCfg -DelayMilliseconds $InterPhaseDelayMilliseconds
    Invoke-NxbL4PowerRepeat -Repeat B -PowerCfgPath $powerCfg -DelayMilliseconds $InterPhaseDelayMilliseconds
)

$pnpExecutionValidated = (@($pnpRepeats | Where-Object { -not [bool]$_.succeeded }).Count -eq 0)
$pnpInventoryStableBoth = (@($pnpRepeats | Where-Object { -not [bool]$_.inventory_stable }).Count -eq 0)
$powerMappingValidated = (@($powerRepeats | Where-Object {
    -not [bool]$_.succeeded -or
    [string]$_.before_active_scheme_guid_sha256 -cne [string]$_.original_scheme_guid_sha256 -or
    [string]$_.during_active_scheme_guid_sha256 -cne [string]$_.temporary_scheme_guid_sha256 -or
    [string]$_.restored_active_scheme_guid_sha256 -cne [string]$_.original_scheme_guid_sha256
}).Count -eq 0)

$result = [pscustomobject][ordered]@{
    schema_version = 1
    captured_utc = [DateTime]::UtcNow.ToString('o')
    binding_fingerprint_sha256 = $BindingFingerprintSha256.ToLowerInvariant()
    provider_metadata_fingerprint_sha256 = $ProviderMetadataFingerprintSha256.ToLowerInvariant()
    l3_review_zip_sha256 = $L3ReviewZipSha256.ToLowerInvariant()
    pnp = [pscustomobject][ordered]@{
        repeat_count = [int]$pnpRepeats.Count
        execution_validated = $pnpExecutionValidated
        inventory_stable_both = $pnpInventoryStableBoth
        repeats = $pnpRepeats
    }
    power = [pscustomobject][ordered]@{
        repeat_count = [int]$powerRepeats.Count
        direct_state_mapping_validated = $powerMappingValidated
        repeats = $powerRepeats
    }
    claims = [pscustomobject][ordered]@{
        pnp_rescan_execution_validated = $pnpExecutionValidated
        pnp_devnode_inventory_stability_observed = $pnpInventoryStableBoth
        pnp_lifecycle_semantics = $false
        power_policy_transition_mapping = $powerMappingValidated
        power_causality = $false
        firmware_causality = $false
        raw_pnp_identifier_exposed = $false
        continuous_trace_completeness = 'not_claimed'
    }
}

Write-NxbL4Json -Path $OutputPath -InputObject $result
Write-Information -MessageData ("NXB L4 direct-state transitions written: {0} pnp_stable={1} power_mapping={2}" -f ([IO.Path]::GetFullPath($OutputPath)),$pnpInventoryStableBoth,$powerMappingValidated) -InformationAction Continue
if ($PassThru) { return $result }
Write-Output ([IO.Path]::GetFullPath($OutputPath))
