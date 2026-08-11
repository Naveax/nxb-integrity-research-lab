[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath,
    [Parameter()][ValidateRange(100,2000)][int]$SettleMilliseconds = 300,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NxbSemanticPowerAdministrator {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NxbSemanticPowerSha256Text {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Invoke-NxbSemanticPowerNative {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )
    $previousErrorActionPreference = $ErrorActionPreference
    $nativePreferenceVariable = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    $nativePreferenceAvailable = ($null -ne $nativePreferenceVariable)
    $previousNativePreference = if ($nativePreferenceAvailable) { [bool]$nativePreferenceVariable.Value } else { $null }
    try {
        $ErrorActionPreference = 'Continue'
        if ($nativePreferenceAvailable) { Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $false -Scope Local }
        $nativeOutput = @(& $Executable @ArgumentList 2>&1)
        $nativeExitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($nativePreferenceAvailable) { Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $previousNativePreference -Scope Local }
    }
    return [pscustomobject][ordered]@{
        exit_code = $nativeExitCode
        output = @($nativeOutput | ForEach-Object { [string]$_ })
    }
}

function Get-NxbSemanticPowerActiveScheme {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PowerCfgPath)
    $native = Invoke-NxbSemanticPowerNative -Executable $PowerCfgPath -ArgumentList @('/getactivescheme')
    if ($native.exit_code -ne 0) { throw ('powercfg /getactivescheme failed: exit={0}' -f $native.exit_code) }
    $guidMatch = [regex]::Match(($native.output -join [Environment]::NewLine),'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if (-not $guidMatch.Success) { throw 'Unable to parse active power scheme GUID.' }
    return $guidMatch.Value.ToLowerInvariant()
}

function Get-NxbSemanticPowerSchemeInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PowerCfgPath)
    $native = Invoke-NxbSemanticPowerNative -Executable $PowerCfgPath -ArgumentList @('/list')
    if ($native.exit_code -ne 0) { throw ('powercfg /list failed: exit={0}' -f $native.exit_code) }
    return @(
        [regex]::Matches(($native.output -join [Environment]::NewLine),'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') |
            ForEach-Object { $_.Value.ToLowerInvariant() } |
            Sort-Object -Unique
    )
}

function Invoke-NxbSemanticPowerRepeat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('A','B')][string]$Repeat,
        [Parameter(Mandatory)][string]$PowerCfgPath,
        [Parameter(Mandatory)][int]$DelayMilliseconds
    )
    $original = Get-NxbSemanticPowerActiveScheme -PowerCfgPath $PowerCfgPath
    $idleOne = Get-NxbSemanticPowerActiveScheme -PowerCfgPath $PowerCfgPath
    Start-Sleep -Milliseconds $DelayMilliseconds
    $idleTwo = Get-NxbSemanticPowerActiveScheme -PowerCfgPath $PowerCfgPath
    $idleStable = ($idleOne -ceq $original -and $idleTwo -ceq $original)
    if (-not $idleStable) { throw ('Power idle control changed unexpectedly in repeat {0}.' -f $Repeat) }

    $temporary = $null
    $created = $false
    $activated = $false
    $restored = $false
    $deleted = $false
    try {
        $duplicate = Invoke-NxbSemanticPowerNative -Executable $PowerCfgPath -ArgumentList @('/duplicatescheme',$original)
        if ($duplicate.exit_code -ne 0) { throw ('powercfg /duplicatescheme failed: exit={0}' -f $duplicate.exit_code) }
        $guidMatches = @([regex]::Matches(($duplicate.output -join [Environment]::NewLine),'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'))
        if ($guidMatches.Count -lt 1) { throw 'Unable to parse duplicated power scheme GUID.' }
        $temporary = $guidMatches[$guidMatches.Count - 1].Value.ToLowerInvariant()
        if ($temporary -ceq $original) { throw 'Temporary power scheme equals original.' }
        $created = (@(Get-NxbSemanticPowerSchemeInventory -PowerCfgPath $PowerCfgPath) -contains $temporary)
        if (-not $created) { throw 'Temporary power scheme was not created.' }

        $activate = Invoke-NxbSemanticPowerNative -Executable $PowerCfgPath -ArgumentList @('/setactive',$temporary)
        if ($activate.exit_code -ne 0) { throw ('Temporary power scheme activation failed: exit={0}' -f $activate.exit_code) }
        Start-Sleep -Milliseconds $DelayMilliseconds
        $activated = ((Get-NxbSemanticPowerActiveScheme -PowerCfgPath $PowerCfgPath) -ceq $temporary)
        if (-not $activated) { throw 'Temporary power scheme was not observed active.' }

        $restore = Invoke-NxbSemanticPowerNative -Executable $PowerCfgPath -ArgumentList @('/setactive',$original)
        if ($restore.exit_code -ne 0) { throw ('Original power scheme restore failed: exit={0}' -f $restore.exit_code) }
        Start-Sleep -Milliseconds $DelayMilliseconds
        $restored = ((Get-NxbSemanticPowerActiveScheme -PowerCfgPath $PowerCfgPath) -ceq $original)
        if (-not $restored) { throw 'Original power scheme was not restored.' }

        $delete = Invoke-NxbSemanticPowerNative -Executable $PowerCfgPath -ArgumentList @('/delete',$temporary)
        if ($delete.exit_code -ne 0) { throw ('Temporary power scheme delete failed: exit={0}' -f $delete.exit_code) }
        $deleted = (@(Get-NxbSemanticPowerSchemeInventory -PowerCfgPath $PowerCfgPath) -notcontains $temporary)
        if (-not $deleted) { throw 'Temporary power scheme remained after delete.' }
    }
    finally {
        if (-not $restored) {
            try {
                $cleanupRestore = Invoke-NxbSemanticPowerNative -Executable $PowerCfgPath -ArgumentList @('/setactive',$original)
                if ($cleanupRestore.exit_code -eq 0) { $restored = ((Get-NxbSemanticPowerActiveScheme -PowerCfgPath $PowerCfgPath) -ceq $original) }
            }
            catch { $restored = $false }
        }
        if (-not [string]::IsNullOrWhiteSpace($temporary) -and -not $deleted) {
            try {
                $cleanupDelete = Invoke-NxbSemanticPowerNative -Executable $PowerCfgPath -ArgumentList @('/delete',$temporary)
                if ($cleanupDelete.exit_code -eq 0) { $deleted = (@(Get-NxbSemanticPowerSchemeInventory -PowerCfgPath $PowerCfgPath) -notcontains $temporary) }
            }
            catch { $deleted = $false }
        }
    }

    return [pscustomobject][ordered]@{
        repeat = $Repeat
        idle_control_stable = $idleStable
        original_scheme_sha256 = Get-NxbSemanticPowerSha256Text -Text $original
        temporary_scheme_sha256 = if ($null -eq $temporary) { $null } else { Get-NxbSemanticPowerSha256Text -Text $temporary }
        temporary_scheme_created = $created
        temporary_scheme_activated = $activated
        original_scheme_restored = $restored
        temporary_scheme_deleted = $deleted
        succeeded = ($idleStable -and $created -and $activated -and $restored -and $deleted)
    }
}

function Invoke-NxbSemanticFirmwareFixture {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$DelayMilliseconds)

    foreach ($commandName in @('New-VM','Get-VM','Get-VMFirmware','Set-VMFirmware','Remove-VM')) {
        if ($null -eq (Get-Command $commandName -ErrorAction SilentlyContinue)) {
            return [pscustomobject][ordered]@{
                status = 'unavailable'
                reason = 'hyper_v_cmdlets_unavailable'
                vm_removed = $true
                host_firmware_changed = $false
                repeats = @()
            }
        }
    }

    $vmName = 'NXB-SEM-' + [Guid]::NewGuid().ToString('N')
    $created = $false
    $removed = $false
    $repeatResult = [System.Collections.Generic.List[object]]::new()
    try {
        $vm = New-VM -Name $vmName -Generation 2 -MemoryStartupBytes 32MB -NoVHD -ErrorAction Stop
        $created = ($null -ne $vm)
        if (-not $created) { throw 'Ephemeral Generation 2 VM was not created.' }
        $initial = [string](Get-VMFirmware -VMName $vmName -ErrorAction Stop).EnableSecureBoot
        if ($initial -notin @('On','Off')) { throw 'Unexpected Hyper-V Secure Boot state.' }
        $alternate = if ($initial -ceq 'On') { 'Off' } else { 'On' }

        foreach ($repeat in @('A','B')) {
            $idleOne = [string](Get-VMFirmware -VMName $vmName -ErrorAction Stop).EnableSecureBoot
            Start-Sleep -Milliseconds $DelayMilliseconds
            $idleTwo = [string](Get-VMFirmware -VMName $vmName -ErrorAction Stop).EnableSecureBoot
            $idleStable = ($idleOne -ceq $initial -and $idleTwo -ceq $initial)
            if (-not $idleStable) { throw ('Virtual firmware idle control changed in repeat {0}.' -f $repeat) }

            Set-VMFirmware -VMName $vmName -EnableSecureBoot $alternate -ErrorAction Stop
            Start-Sleep -Milliseconds $DelayMilliseconds
            $during = [string](Get-VMFirmware -VMName $vmName -ErrorAction Stop).EnableSecureBoot
            $transitionObserved = ($during -ceq $alternate)
            if (-not $transitionObserved) { throw 'Virtual firmware transition was not observed.' }

            Set-VMFirmware -VMName $vmName -EnableSecureBoot $initial -ErrorAction Stop
            Start-Sleep -Milliseconds $DelayMilliseconds
            $restoredState = [string](Get-VMFirmware -VMName $vmName -ErrorAction Stop).EnableSecureBoot
            $restored = ($restoredState -ceq $initial)
            if (-not $restored) { throw 'Virtual firmware state was not restored.' }

            $repeatResult.Add([pscustomobject][ordered]@{
                repeat = $repeat
                idle_control_stable = $idleStable
                initial_secure_boot = $initial
                alternate_secure_boot = $alternate
                transition_observed = $transitionObserved
                restored = $restored
            })
        }
    }
    finally {
        if ($created) {
            try {
                Remove-VM -Name $vmName -Force -ErrorAction Stop
                $removed = ($null -eq (Get-VM -Name $vmName -ErrorAction SilentlyContinue))
            }
            catch { $removed = $false }
        }
    }

    $passed = ($created -and $removed -and $repeatResult.Count -eq 2 -and @($repeatResult | Where-Object { -not [bool]$_.transition_observed -or -not [bool]$_.restored }).Count -eq 0)
    return [pscustomobject][ordered]@{
        status = if ($passed) { 'passed' } else { 'failed' }
        reason = if ($passed) { $null } else { 'virtual_firmware_fixture_failed' }
        generation = 2
        vm_started = $false
        vhd_attached = $false
        network_switch_attached = $false
        vm_removed = $removed
        host_firmware_changed = $false
        repeats = @($repeatResult)
    }
}

if ($env:OS -cne 'Windows_NT') { throw 'Power/firmware semantic experiment requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Power/firmware semantic experiment requires PowerShell 7.' }
if (-not (Test-NxbSemanticPowerAdministrator)) { throw 'Power/firmware semantic experiment requires elevated PowerShell 7.' }

$startedUtc = [DateTime]::UtcNow
$powerCfg = (Get-Command powercfg.exe -ErrorAction Stop).Source
$powerRepeat = @(
    Invoke-NxbSemanticPowerRepeat -Repeat A -PowerCfgPath $powerCfg -DelayMilliseconds $SettleMilliseconds
    Invoke-NxbSemanticPowerRepeat -Repeat B -PowerCfgPath $powerCfg -DelayMilliseconds $SettleMilliseconds
)
$powerValidated = (@($powerRepeat | Where-Object { -not [bool]$_.succeeded }).Count -eq 0)
$firmware = Invoke-NxbSemanticFirmwareFixture -DelayMilliseconds $SettleMilliseconds
$firmwareValidated = ([string]$firmware.status -ceq 'passed')
$endedUtc = [DateTime]::UtcNow

$result = [pscustomobject][ordered]@{
    schema_version = 1
    status = if ($powerValidated -and $firmwareValidated) { 'passed' } elseif ([string]$firmware.status -ceq 'unavailable') { 'unavailable' } else { 'failed' }
    started_utc = $startedUtc.ToString('o')
    ended_utc = $endedUtc.ToString('o')
    scope = 'owned-temporary-power-scheme-and-ephemeral-hyperv-gen2-firmware'
    power = [pscustomobject][ordered]@{
        repeats = $powerRepeat
        cleanup_verified = (@($powerRepeat | Where-Object { -not [bool]$_.original_scheme_restored -or -not [bool]$_.temporary_scheme_deleted }).Count -eq 0)
    }
    firmware = $firmware
    claims = [pscustomobject][ordered]@{
        power_causality = $powerValidated
        firmware_causality = $firmwareValidated
        host_firmware_changed = $false
        generalized_power_causality_claimed = $false
        generalized_firmware_causality_claimed = $false
    }
}

$fullPath = [IO.Path]::GetFullPath($OutputPath)
$parent = Split-Path -Parent $fullPath
if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText($fullPath,(($result | ConvertTo-Json -Depth 20) + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
Write-Information -InformationAction Continue -MessageData ('NXB power/firmware experiment: power={0} firmware={1}' -f $powerValidated,$firmware.status)
if ($PassThru) { return $result }
Write-Output $fullPath
