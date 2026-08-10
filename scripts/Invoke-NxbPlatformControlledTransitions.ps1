[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$L1ReviewZipPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$BindingFingerprintSha256,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ProviderMetadataFingerprintSha256,
    [Parameter()][ValidateRange(500,5000)][int]$IdleWindowMilliseconds = 1500,
    [Parameter()][ValidateRange(500,5000)][int]$PostStimulusMilliseconds = 1500,
    [Parameter()][ValidateRange(1,512)][int]$MaxEventsPerLog = 256,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NxbTransitionProperty {
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

function Get-NxbTransitionSha256Text {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha256.Dispose() }
}

function Write-NxbTransitionJson {
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

function Get-NxbTransitionZipJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$ZipPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EntryName
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($ZipPath))
    try {
        $entry = $archive.Entries | Where-Object { $_.FullName -ceq $EntryName } | Select-Object -First 1
        if ($null -eq $entry) { throw "Required ZIP entry missing: $EntryName" }
        $stream = $entry.Open()
        $reader = [IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false),$true)
        try { return ($reader.ReadToEnd() | ConvertFrom-Json) }
        finally { $reader.Dispose(); $stream.Dispose() }
    }
    finally { $archive.Dispose() }
}

function Get-NxbTransitionShapeKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$EventRecord)
    $id = [int](Get-NxbTransitionProperty -InputObject $EventRecord -Name 'Id' -DefaultValue 0)
    $version = [int](Get-NxbTransitionProperty -InputObject $EventRecord -Name 'Version' -DefaultValue 0)
    $level = [string](Get-NxbTransitionProperty -InputObject $EventRecord -Name 'LevelDisplayName' -DefaultValue '')
    $task = [string](Get-NxbTransitionProperty -InputObject $EventRecord -Name 'TaskDisplayName' -DefaultValue '')
    $opcode = [string](Get-NxbTransitionProperty -InputObject $EventRecord -Name 'OpcodeDisplayName' -DefaultValue '')
    return ('{0}|{1}|{2}|{3}|{4}' -f $id,$version,$level,$task,$opcode)
}

function Get-NxbTransitionSurfaceObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ProviderName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LogName,
        [Parameter(Mandatory)][DateTime]$StartTimeUtc,
        [Parameter(Mandatory)][DateTime]$EndTimeUtc,
        [Parameter(Mandatory)][ValidateRange(1,512)][int]$MaxEvents
    )
    try {
        $events = @(
            Get-WinEvent -FilterHashtable @{
                LogName = $LogName
                ProviderName = $ProviderName
                StartTime = $StartTimeUtc
                EndTime = $EndTimeUtc
            } -MaxEvents $MaxEvents -ErrorAction Stop
        )
        $shapes = @(
            $events |
                Group-Object { Get-NxbTransitionShapeKey -EventRecord $_ } |
                ForEach-Object {
                    $parts = $_.Name.Split('|',5)
                    [pscustomobject][ordered]@{
                        id = [int]$parts[0]
                        version = [int]$parts[1]
                        level = $parts[2]
                        task = $parts[3]
                        opcode = $parts[4]
                        count = [int]$_.Count
                    }
                } |
                Sort-Object id,version,level,task,opcode
        )
        return [pscustomobject][ordered]@{
            provider_name = $ProviderName
            log_name = $LogName
            status = 'available'
            sampled_event_count = [int]$events.Count
            shapes = $shapes
            reason = $null
        }
    }
    catch {
        $fqid = [string]$_.FullyQualifiedErrorId
        if ($fqid.StartsWith('NoMatchingEventsFound',[StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject][ordered]@{
                provider_name = $ProviderName
                log_name = $LogName
                status = 'available'
                sampled_event_count = 0
                shapes = @()
                reason = $null
            }
        }
        return [pscustomobject][ordered]@{
            provider_name = $ProviderName
            log_name = $LogName
            status = 'unavailable'
            sampled_event_count = $null
            shapes = @()
            reason = 'bounded_query_failed'
        }
    }
}

function Get-NxbTransitionActivePowerSchemeGuid {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PowerCfgPath)
    $text = @(& $PowerCfgPath /getactivescheme 2>&1) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0) { throw "powercfg /getactivescheme failed: exit=$LASTEXITCODE" }
    $match = [regex]::Match($text,'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if (-not $match.Success) { throw 'Unable to parse active power scheme GUID.' }
    return $match.Value.ToLowerInvariant()
}

function Invoke-NxbTransitionPnpRescan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PnpUtilPath)
    & $PnpUtilPath /scan-devices *> $null
    $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    return [pscustomobject][ordered]@{
        stimulus = 'pnp_rescan'
        executed = $true
        exit_code = $exitCode
        succeeded = ($exitCode -eq 0)
        device_disable_used = $false
        device_remove_used = $false
        device_install_used = $false
    }
}

function Invoke-NxbTransitionTemporaryPowerScheme {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PowerCfgPath)
    $originalGuid = Get-NxbTransitionActivePowerSchemeGuid -PowerCfgPath $PowerCfgPath
    $originalHash = Get-NxbTransitionSha256Text -Text $originalGuid
    $temporaryGuid = $null
    $created = $false
    $activated = $false
    $restored = $false
    $deleted = $false
    try {
        $duplicateText = @(& $PowerCfgPath /duplicatescheme $originalGuid 2>&1) -join [Environment]::NewLine
        if ($LASTEXITCODE -ne 0) { throw "powercfg /duplicatescheme failed: exit=$LASTEXITCODE" }
        $guidMatches = [regex]::Matches($duplicateText,'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
        if ($guidMatches.Count -lt 1) { throw 'Unable to parse temporary power scheme GUID.' }
        $temporaryGuid = $guidMatches[$guidMatches.Count - 1].Value.ToLowerInvariant()
        if ($temporaryGuid -ceq $originalGuid) { throw 'Temporary power scheme GUID unexpectedly equals original GUID.' }
        $created = $true

        & $PowerCfgPath /setactive $temporaryGuid *> $null
        if ($LASTEXITCODE -ne 0) { throw "powercfg temporary /setactive failed: exit=$LASTEXITCODE" }
        $activated = $true
        Start-Sleep -Milliseconds 500

        & $PowerCfgPath /setactive $originalGuid *> $null
        if ($LASTEXITCODE -ne 0) { throw "powercfg original /setactive failed: exit=$LASTEXITCODE" }
        $restored = ((Get-NxbTransitionActivePowerSchemeGuid -PowerCfgPath $PowerCfgPath) -ceq $originalGuid)
        if (-not $restored) { throw 'Original power scheme was not restored.' }

        & $PowerCfgPath /delete $temporaryGuid *> $null
        if ($LASTEXITCODE -ne 0) { throw "powercfg temporary /delete failed: exit=$LASTEXITCODE" }
        $deleted = $true
    }
    finally {
        if ($created -and -not $restored) {
            try {
                & $PowerCfgPath /setactive $originalGuid *> $null
                $restored = ((Get-NxbTransitionActivePowerSchemeGuid -PowerCfgPath $PowerCfgPath) -ceq $originalGuid)
            }
            catch { $restored = $false }
        }
        if ($created -and -not $deleted -and -not [string]::IsNullOrWhiteSpace($temporaryGuid)) {
            try {
                & $PowerCfgPath /delete $temporaryGuid *> $null
                if ($LASTEXITCODE -eq 0) { $deleted = $true }
            }
            catch { $deleted = $false }
        }
    }
    return [pscustomobject][ordered]@{
        stimulus = 'temporary_power_scheme_transition'
        executed = $true
        original_scheme_guid_sha256 = $originalHash
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

function Invoke-NxbTransitionScenario {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ScenarioId,
        [Parameter(Mandatory)][ValidateSet('idle','pnp_rescan','power_transition')][string]$ScenarioType,
        [Parameter(Mandatory)][ValidateSet('A','B')][string]$Repeat,
        [Parameter(Mandatory)][object[]]$Surfaces,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PnpUtilPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PowerCfgPath,
        [Parameter(Mandatory)][ValidateRange(500,5000)][int]$IdleMilliseconds,
        [Parameter(Mandatory)][ValidateRange(500,5000)][int]$PostMilliseconds,
        [Parameter(Mandatory)][ValidateRange(1,512)][int]$MaxEvents
    )
    $start = [DateTime]::UtcNow
    $stimulusReceipt = $null
    if ($ScenarioType -ceq 'idle') {
        Start-Sleep -Milliseconds $IdleMilliseconds
        $stimulusReceipt = [pscustomobject][ordered]@{
            stimulus = 'idle_control'
            executed = $true
            succeeded = $true
        }
    }
    elseif ($ScenarioType -ceq 'pnp_rescan') {
        $stimulusReceipt = Invoke-NxbTransitionPnpRescan -PnpUtilPath $PnpUtilPath
        if (-not [bool]$stimulusReceipt.succeeded) { throw "PnP rescan failed in $ScenarioId" }
        Start-Sleep -Milliseconds $PostMilliseconds
    }
    else {
        $stimulusReceipt = Invoke-NxbTransitionTemporaryPowerScheme -PowerCfgPath $PowerCfgPath
        if (-not [bool]$stimulusReceipt.succeeded) { throw "Temporary power transition failed in $ScenarioId" }
        Start-Sleep -Milliseconds $PostMilliseconds
    }
    $end = [DateTime]::UtcNow
    $observations = @(
        foreach ($surface in @($Surfaces)) {
            Get-NxbTransitionSurfaceObservation `
                -ProviderName ([string]$surface.provider_name) `
                -LogName ([string]$surface.log_name) `
                -StartTimeUtc $start `
                -EndTimeUtc $end `
                -MaxEvents $MaxEvents
        }
    )
    return [pscustomobject][ordered]@{
        scenario_id = $ScenarioId
        scenario_type = $ScenarioType
        repeat = $Repeat
        start_utc = $start.ToString('o')
        end_utc = $end.ToString('o')
        stimulus = $stimulusReceipt
        surface_count = [int]$observations.Count
        observations = $observations
    }
}

if ($env:OS -cne 'Windows_NT') { throw 'Controlled transition observation requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Controlled transition observation requires PowerShell 7.' }

$l1Zip = [IO.Path]::GetFullPath($L1ReviewZipPath)
$l1Receipt = Get-NxbTransitionZipJson -ZipPath $l1Zip -EntryName 'platform-event-certification-receipt.json'
$l1Baseline = Get-NxbTransitionZipJson -ZipPath $l1Zip -EntryName 'platform-event-baseline-a.json'
if ([string]$l1Receipt.status -cne 'passed') { throw 'L1 predecessor receipt is not passed.' }
if ([string]$l1Receipt.l0_binding.binding_fingerprint_sha256 -cne $BindingFingerprintSha256) { throw 'L1 binding fingerprint mismatch.' }
if ([string]$l1Receipt.metadata.provider_metadata_fingerprint_sha256 -cne $ProviderMetadataFingerprintSha256) { throw 'L1 provider metadata fingerprint mismatch.' }

$pnpProviders = @('Microsoft-Windows-Kernel-PnP','Microsoft-Windows-UserPnp')
$powerProviders = @('Microsoft-Windows-Kernel-Power','Microsoft-Windows-Kernel-Processor-Power')
$pnpSurfaces = @(
    foreach ($provider in @($l1Baseline.providers)) {
        if ($pnpProviders -notcontains [string]$provider.provider_name) { continue }
        foreach ($log in @($provider.logs)) {
            if ([string]$log.status -ceq 'available') {
                [pscustomobject][ordered]@{ provider_name=[string]$provider.provider_name; log_name=[string]$log.log_name }
            }
        }
    }
)
$powerSurfaces = @(
    foreach ($provider in @($l1Baseline.providers)) {
        if ($powerProviders -notcontains [string]$provider.provider_name) { continue }
        foreach ($log in @($provider.logs)) {
            if ([string]$log.status -ceq 'available') {
                [pscustomobject][ordered]@{ provider_name=[string]$provider.provider_name; log_name=[string]$log.log_name }
            }
        }
    }
)
if ($pnpSurfaces.Count -lt 1) { throw 'No L1-readable PnP event surface is available.' }
if ($powerSurfaces.Count -lt 1) { throw 'No L1-readable power event surface is available.' }

$pnpUtilPath = (Get-Command pnputil.exe -ErrorAction Stop).Source
$powerCfgPath = (Get-Command powercfg.exe -ErrorAction Stop).Source

$scenarios = @(
    Invoke-NxbTransitionScenario -ScenarioId 'idle_pnp_a' -ScenarioType 'idle' -Repeat 'A' -Surfaces $pnpSurfaces -PnpUtilPath $pnpUtilPath -PowerCfgPath $powerCfgPath -IdleMilliseconds $IdleWindowMilliseconds -PostMilliseconds $PostStimulusMilliseconds -MaxEvents $MaxEventsPerLog
    Invoke-NxbTransitionScenario -ScenarioId 'pnp_rescan_a' -ScenarioType 'pnp_rescan' -Repeat 'A' -Surfaces $pnpSurfaces -PnpUtilPath $pnpUtilPath -PowerCfgPath $powerCfgPath -IdleMilliseconds $IdleWindowMilliseconds -PostMilliseconds $PostStimulusMilliseconds -MaxEvents $MaxEventsPerLog
    Invoke-NxbTransitionScenario -ScenarioId 'idle_pnp_b' -ScenarioType 'idle' -Repeat 'B' -Surfaces $pnpSurfaces -PnpUtilPath $pnpUtilPath -PowerCfgPath $powerCfgPath -IdleMilliseconds $IdleWindowMilliseconds -PostMilliseconds $PostStimulusMilliseconds -MaxEvents $MaxEventsPerLog
    Invoke-NxbTransitionScenario -ScenarioId 'pnp_rescan_b' -ScenarioType 'pnp_rescan' -Repeat 'B' -Surfaces $pnpSurfaces -PnpUtilPath $pnpUtilPath -PowerCfgPath $powerCfgPath -IdleMilliseconds $IdleWindowMilliseconds -PostMilliseconds $PostStimulusMilliseconds -MaxEvents $MaxEventsPerLog
    Invoke-NxbTransitionScenario -ScenarioId 'idle_power_a' -ScenarioType 'idle' -Repeat 'A' -Surfaces $powerSurfaces -PnpUtilPath $pnpUtilPath -PowerCfgPath $powerCfgPath -IdleMilliseconds $IdleWindowMilliseconds -PostMilliseconds $PostStimulusMilliseconds -MaxEvents $MaxEventsPerLog
    Invoke-NxbTransitionScenario -ScenarioId 'power_transition_a' -ScenarioType 'power_transition' -Repeat 'A' -Surfaces $powerSurfaces -PnpUtilPath $pnpUtilPath -PowerCfgPath $powerCfgPath -IdleMilliseconds $IdleWindowMilliseconds -PostMilliseconds $PostStimulusMilliseconds -MaxEvents $MaxEventsPerLog
    Invoke-NxbTransitionScenario -ScenarioId 'idle_power_b' -ScenarioType 'idle' -Repeat 'B' -Surfaces $powerSurfaces -PnpUtilPath $pnpUtilPath -PowerCfgPath $powerCfgPath -IdleMilliseconds $IdleWindowMilliseconds -PostMilliseconds $PostStimulusMilliseconds -MaxEvents $MaxEventsPerLog
    Invoke-NxbTransitionScenario -ScenarioId 'power_transition_b' -ScenarioType 'power_transition' -Repeat 'B' -Surfaces $powerSurfaces -PnpUtilPath $pnpUtilPath -PowerCfgPath $powerCfgPath -IdleMilliseconds $IdleWindowMilliseconds -PostMilliseconds $PostStimulusMilliseconds -MaxEvents $MaxEventsPerLog
)

$result = [pscustomobject][ordered]@{
    schema_version = 1
    captured_utc = [DateTime]::UtcNow.ToString('o')
    binding_fingerprint_sha256 = $BindingFingerprintSha256.ToLowerInvariant()
    provider_metadata_fingerprint_sha256 = $ProviderMetadataFingerprintSha256.ToLowerInvariant()
    l1_review_zip_sha256 = (Get-FileHash -LiteralPath $l1Zip -Algorithm SHA256).Hash.ToLowerInvariant()
    observation_contract = [pscustomobject][ordered]@{
        scenario_count = 8
        pnp_stimulus = 'pnputil_scan_devices'
        power_stimulus = 'temporary_duplicate_activate_restore_delete'
        idle_window_milliseconds = $IdleWindowMilliseconds
        post_stimulus_milliseconds = $PostStimulusMilliseconds
        max_events_per_log = $MaxEventsPerLog
        raw_event_message_exposed = $false
        raw_event_xml_exposed = $false
        raw_event_payload_exposed = $false
        device_disable_used = $false
        firmware_security_mutation_used = $false
        wpr_used = $false
    }
    pnp_surface_count = [int]$pnpSurfaces.Count
    power_surface_count = [int]$powerSurfaces.Count
    scenarios = $scenarios
    claims = [pscustomobject][ordered]@{
        controlled_stimuli_executed = $true
        matched_idle_controls_captured = $true
        event_id_semantics = $false
        event_task_opcode_semantics = $false
        device_lifecycle_semantics = $false
        power_causality = $false
        firmware_causality = $false
        root_cause_validated = $false
        continuous_trace_completeness = 'not_claimed'
    }
}

Write-NxbTransitionJson -Path $OutputPath -InputObject $result
Write-Information -MessageData "NXB controlled transition observations written: $([IO.Path]::GetFullPath($OutputPath))" -InformationAction Continue
if ($PassThru) { return $result }
Write-Output ([IO.Path]::GetFullPath($OutputPath))
