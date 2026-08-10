[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$DiscoveryPath,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$L2ReviewZipPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$BindingFingerprintSha256,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ProviderMetadataFingerprintSha256,
    [Parameter()][ValidateRange(4,64)][int]$MaxFamilySurfaces = 32,
    [Parameter()][ValidateRange(1000,10000)][int]$IdleWindowMilliseconds = 3000,
    [Parameter()][ValidateRange(1000,10000)][int]$PostStimulusMilliseconds = 3000,
    [Parameter()][ValidateRange(1,512)][int]$MaxEventsPerLog = 256,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NxbL3Property {
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

function Get-NxbL3OrdinalHexKey {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Value)
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-NxbL3Sha256Text {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha256.Dispose() }
}

function Write-NxbL3Json {
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

function Get-NxbL3ZipJson {
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

function Get-NxbL3ShapeKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$EventRecord)
    $id = [int](Get-NxbL3Property -InputObject $EventRecord -Name 'Id' -DefaultValue 0)
    $version = [int](Get-NxbL3Property -InputObject $EventRecord -Name 'Version' -DefaultValue 0)
    $level = [string](Get-NxbL3Property -InputObject $EventRecord -Name 'LevelDisplayName' -DefaultValue '')
    $task = [string](Get-NxbL3Property -InputObject $EventRecord -Name 'TaskDisplayName' -DefaultValue '')
    $opcode = [string](Get-NxbL3Property -InputObject $EventRecord -Name 'OpcodeDisplayName' -DefaultValue '')
    return ('{0}|{1}|{2}|{3}|{4}' -f $id,$version,$level,$task,$opcode)
}

function Get-NxbL3SurfaceObservation {
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
        $shapeCandidates = @(
            $events |
                Group-Object { Get-NxbL3ShapeKey -EventRecord $_ } |
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
                }
        )
        $shapes = @(
            $shapeCandidates |
                Sort-Object `
                    id,version,
                    @{ Expression = { Get-NxbL3OrdinalHexKey -Value $_.level }; Ascending = $true },
                    @{ Expression = { Get-NxbL3OrdinalHexKey -Value $_.task }; Ascending = $true },
                    @{ Expression = { Get-NxbL3OrdinalHexKey -Value $_.opcode }; Ascending = $true }
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

function Get-NxbL3ActivePowerSchemeGuid {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PowerCfgPath)
    $text = @(& $PowerCfgPath /getactivescheme 2>&1) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0) { throw "powercfg /getactivescheme failed: exit=$LASTEXITCODE" }
    $guidMatch = [regex]::Match($text,'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if (-not $guidMatch.Success) { throw 'Unable to parse active power scheme GUID.' }
    return $guidMatch.Value.ToLowerInvariant()
}

function Invoke-NxbL3PnpRescan {
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

function Invoke-NxbL3TemporaryPowerTransition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PowerCfgPath)
    $originalGuid = Get-NxbL3ActivePowerSchemeGuid -PowerCfgPath $PowerCfgPath
    $originalHash = Get-NxbL3Sha256Text -Text $originalGuid
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
        $restored = ((Get-NxbL3ActivePowerSchemeGuid -PowerCfgPath $PowerCfgPath) -ceq $originalGuid)
        if (-not $restored) { throw 'Original power scheme was not restored.' }

        & $PowerCfgPath /delete $temporaryGuid *> $null
        if ($LASTEXITCODE -ne 0) { throw "powercfg temporary /delete failed: exit=$LASTEXITCODE" }
        $deleted = $true
    }
    finally {
        if ($created -and -not $restored) {
            try {
                & $PowerCfgPath /setactive $originalGuid *> $null
                $restored = ((Get-NxbL3ActivePowerSchemeGuid -PowerCfgPath $PowerCfgPath) -ceq $originalGuid)
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

function Invoke-NxbL3Scenario {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ScenarioId,
        [Parameter(Mandatory)][ValidateSet('idle','pnp_rescan','power_transition')][string]$ScenarioType,
        [Parameter(Mandatory)][ValidateSet('A','B')][string]$Repeat,
        [Parameter(Mandatory)][object[]]$Surfaces,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PnpUtilPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PowerCfgPath,
        [Parameter(Mandatory)][ValidateRange(1000,10000)][int]$IdleMilliseconds,
        [Parameter(Mandatory)][ValidateRange(1000,10000)][int]$PostMilliseconds,
        [Parameter(Mandatory)][ValidateRange(1,512)][int]$MaxEvents
    )
    $start = [DateTime]::UtcNow
    $stimulusReceipt = $null
    if ($ScenarioType -ceq 'idle') {
        Start-Sleep -Milliseconds $IdleMilliseconds
        $stimulusReceipt = [pscustomobject][ordered]@{ stimulus='idle_control'; executed=$true; succeeded=$true }
    }
    elseif ($ScenarioType -ceq 'pnp_rescan') {
        $stimulusReceipt = Invoke-NxbL3PnpRescan -PnpUtilPath $PnpUtilPath
        if (-not [bool]$stimulusReceipt.succeeded) { throw "PnP rescan failed in $ScenarioId" }
        Start-Sleep -Milliseconds $PostMilliseconds
    }
    else {
        $stimulusReceipt = Invoke-NxbL3TemporaryPowerTransition -PowerCfgPath $PowerCfgPath
        if (-not [bool]$stimulusReceipt.succeeded) { throw "Temporary power transition failed in $ScenarioId" }
        Start-Sleep -Milliseconds $PostMilliseconds
    }
    $end = [DateTime]::UtcNow
    $observations = @(
        foreach ($surface in @($Surfaces)) {
            Get-NxbL3SurfaceObservation `
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

if ($env:OS -cne 'Windows_NT') { throw 'Discovery-backed controlled transition replay requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Discovery-backed controlled transition replay requires PowerShell 7.' }

$discovery = Get-Content -LiteralPath ([IO.Path]::GetFullPath($DiscoveryPath)) -Raw | ConvertFrom-Json
if ($null -eq $discovery) { throw 'Discovery JSON could not be read.' }
if ([string]$discovery.binding_fingerprint_sha256 -cne $BindingFingerprintSha256) { throw 'Discovery binding fingerprint mismatch.' }
if ([string]$discovery.provider_metadata_fingerprint_sha256 -cne $ProviderMetadataFingerprintSha256) { throw 'Discovery metadata fingerprint mismatch.' }
if ([string]$discovery.fingerprint_contract -cne 'ordinal_tsv_v1') { throw 'Discovery fingerprint contract mismatch.' }

$l2Receipt = Get-NxbL3ZipJson -ZipPath ([IO.Path]::GetFullPath($L2ReviewZipPath)) -EntryName 'platform-transition-certification-receipt.json'
if ([string]$l2Receipt.status -cne 'passed') { throw 'L2 predecessor receipt is not passed.' }

$pnpSurfaceCandidates = @($discovery.surfaces | Where-Object { $_.status -ceq 'available' -and @($_.families) -contains 'pnp' })
$powerSurfaceCandidates = @($discovery.surfaces | Where-Object { $_.status -ceq 'available' -and @($_.families) -contains 'power' })
$pnpSurfaces = @($pnpSurfaceCandidates | Select-Object -First $MaxFamilySurfaces)
$powerSurfaces = @($powerSurfaceCandidates | Select-Object -First $MaxFamilySurfaces)
if ($pnpSurfaces.Count -lt 1) { throw 'No usable discovered PnP-family surface.' }
if ($powerSurfaces.Count -lt 1) { throw 'No usable discovered power-family surface.' }

$pnpUtilPath = (Get-Command pnputil.exe -ErrorAction Stop).Source
$powerCfgPath = (Get-Command powercfg.exe -ErrorAction Stop).Source
$scenarioDefinitions = @(
    @{ id='idle_pnp_a'; type='idle'; repeat='A'; family='pnp' },
    @{ id='pnp_rescan_a'; type='pnp_rescan'; repeat='A'; family='pnp' },
    @{ id='idle_pnp_b'; type='idle'; repeat='B'; family='pnp' },
    @{ id='pnp_rescan_b'; type='pnp_rescan'; repeat='B'; family='pnp' },
    @{ id='idle_power_a'; type='idle'; repeat='A'; family='power' },
    @{ id='power_transition_a'; type='power_transition'; repeat='A'; family='power' },
    @{ id='idle_power_b'; type='idle'; repeat='B'; family='power' },
    @{ id='power_transition_b'; type='power_transition'; repeat='B'; family='power' }
)
$scenarios = @(
    foreach ($definition in $scenarioDefinitions) {
        $surfaces = if ([string]$definition.family -ceq 'pnp') { $pnpSurfaces } else { $powerSurfaces }
        Invoke-NxbL3Scenario `
            -ScenarioId ([string]$definition.id) `
            -ScenarioType ([string]$definition.type) `
            -Repeat ([string]$definition.repeat) `
            -Surfaces $surfaces `
            -PnpUtilPath $pnpUtilPath `
            -PowerCfgPath $powerCfgPath `
            -IdleMilliseconds $IdleWindowMilliseconds `
            -PostMilliseconds $PostStimulusMilliseconds `
            -MaxEvents $MaxEventsPerLog
    }
)

$result = [pscustomobject][ordered]@{
    schema_version = 1
    captured_utc = [DateTime]::UtcNow.ToString('o')
    binding_fingerprint_sha256 = $BindingFingerprintSha256.ToLowerInvariant()
    provider_metadata_fingerprint_sha256 = $ProviderMetadataFingerprintSha256.ToLowerInvariant()
    discovery_fingerprint_sha256 = [string]$discovery.discovery_fingerprint_sha256
    l2_review_zip_sha256 = (Get-FileHash -LiteralPath ([IO.Path]::GetFullPath($L2ReviewZipPath)) -Algorithm SHA256).Hash.ToLowerInvariant()
    observation_contract = [pscustomobject][ordered]@{
        scenario_count = 8
        pnp_stimulus = 'pnputil_scan_devices'
        power_stimulus = 'temporary_duplicate_activate_restore_delete'
        discovery_backed_surface_selection = $true
        max_family_surfaces = $MaxFamilySurfaces
        idle_window_milliseconds = $IdleWindowMilliseconds
        post_stimulus_milliseconds = $PostStimulusMilliseconds
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
        discovery_backed_surface_replay = $true
        event_id_semantics = $false
        event_task_opcode_semantics = $false
        device_lifecycle_semantics = $false
        power_causality = $false
        firmware_causality = $false
        root_cause_validated = $false
        continuous_trace_completeness = 'not_claimed'
    }
}

Write-NxbL3Json -Path $OutputPath -InputObject $result
Write-Information -MessageData "NXB L3 discovery-backed transition replay written: $([IO.Path]::GetFullPath($OutputPath)) pnp_surfaces=$($pnpSurfaces.Count) power_surfaces=$($powerSurfaces.Count)" -InformationAction Continue
if ($PassThru) { return $result }
Write-Output ([IO.Path]::GetFullPath($OutputPath))
