[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath,
    [Parameter()][ValidateRange(100,2000)][int]$InterSnapshotDelayMilliseconds = 250,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NxbSemanticPcieSha256Text {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Get-NxbSemanticPciePropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [Parameter(Mandatory)][string]$KeyName
    )
    $row = @($Rows | Where-Object { [string]$_.KeyName -ceq $KeyName } | Select-Object -First 1)
    if ($row.Count -ne 1) { return $null }
    return $row[0].Data
}

function Get-NxbSemanticPcieLocationTuple {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$LocationPaths)
    $candidate = @()
    foreach ($pathValue in @($LocationPaths)) {
        $text = [string]$pathValue
        foreach ($pathMatch in @([regex]::Matches($text,'(?i)PCI\(([0-9a-f]{2})([0-9a-f]{2})\)'))) {
            $candidate += [pscustomobject][ordered]@{
                device = [Convert]::ToInt32($pathMatch.Groups[1].Value,16)
                function = [Convert]::ToInt32($pathMatch.Groups[2].Value,16)
            }
        }
    }
    if ($candidate.Count -eq 0) { return $null }
    return $candidate[$candidate.Count - 1]
}

function Test-NxbSemanticPcieTupleMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(0,31)][int]$ExpectedDevice,
        [Parameter(Mandatory)][ValidateRange(0,7)][int]$ExpectedFunction,
        [Parameter(Mandatory)][ValidateRange(0,31)][int]$ObservedDevice,
        [Parameter(Mandatory)][ValidateRange(0,7)][int]$ObservedFunction
    )
    return ($ExpectedDevice -eq $ObservedDevice -and $ExpectedFunction -eq $ObservedFunction)
}

function Get-NxbSemanticPcieSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateRange(1,3)][int]$Index)

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($device in @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop)) {
        $instanceId = [string]$device.PNPDeviceID
        if ([string]::IsNullOrWhiteSpace($instanceId) -or
            -not $instanceId.StartsWith('PCI\',[StringComparison]::OrdinalIgnoreCase)) { continue }

        try {
            $properties = @(Get-PnpDeviceProperty -InstanceId $instanceId -KeyName @(
                'DEVPKEY_Device_BusNumber',
                'DEVPKEY_Device_Address',
                'DEVPKEY_Device_LocationPaths'
            ) -ErrorAction Stop)
            $busValue = Get-NxbSemanticPciePropertyValue -Rows $properties -KeyName 'DEVPKEY_Device_BusNumber'
            $addressValue = Get-NxbSemanticPciePropertyValue -Rows $properties -KeyName 'DEVPKEY_Device_Address'
            $locationValue = Get-NxbSemanticPciePropertyValue -Rows $properties -KeyName 'DEVPKEY_Device_LocationPaths'
            if ($null -eq $busValue -or $null -eq $addressValue) { continue }

            $bus = [int64]$busValue
            $address = [int64]$addressValue
            if ($address -lt 0) { continue }
            $deviceNumber = [int](($address -shr 16) -band 0xffff)
            $functionNumber = [int]($address -band 0xffff)
            $rangeValid = (
                $bus -ge 0 -and $bus -le 255 -and
                $deviceNumber -ge 0 -and $deviceNumber -le 31 -and
                $functionNumber -ge 0 -and $functionNumber -le 7
            )
            if (-not $rangeValid) { continue }

            $locationTuple = Get-NxbSemanticPcieLocationTuple -LocationPaths $locationValue
            $locationAvailable = ($null -ne $locationTuple)
            $locationMatches = $false
            if ($locationAvailable) {
                $locationMatches = Test-NxbSemanticPcieTupleMatch `
                    -ExpectedDevice $deviceNumber `
                    -ExpectedFunction $functionNumber `
                    -ObservedDevice ([int]$locationTuple.device) `
                    -ObservedFunction ([int]$locationTuple.function)
            }
            $rows.Add([pscustomobject][ordered]@{
                device_id_sha256 = Get-NxbSemanticPcieSha256Text -Text $instanceId
                bus = $bus
                device = $deviceNumber
                function = $functionNumber
                bdf = ('{0:x2}:{1:x2}.{2:x1}' -f $bus,$deviceNumber,$functionNumber)
                address_decode_valid = $true
                location_path_cross_check_available = $locationAvailable
                location_path_cross_check_matches = $locationMatches
            })
        }
        catch {
            Write-Verbose -Message ('PCIe property query skipped for one device: {0}' -f $_.Exception.GetType().FullName)
        }
    }

    $orderedRows = @($rows | Sort-Object device_id_sha256)
    $material = @($orderedRows | ForEach-Object {
        '{0}`t{1}`t{2}`t{3}`t{4}`t{5}' -f $_.device_id_sha256,$_.bus,$_.device,$_.function,$_.address_decode_valid,$_.location_path_cross_check_matches
    }) -join "`n"
    return [pscustomobject][ordered]@{
        index = $Index
        captured_utc = [DateTime]::UtcNow.ToString('o')
        record_count = [int]$orderedRows.Count
        fingerprint_sha256 = Get-NxbSemanticPcieSha256Text -Text $material
        records = $orderedRows
    }
}

if ($env:OS -cne 'Windows_NT') { throw 'PCIe BDF semantic experiment requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'PCIe BDF semantic experiment requires PowerShell 7.' }
if ($null -eq (Get-Command Get-PnpDeviceProperty -ErrorAction SilentlyContinue)) {
    throw 'Get-PnpDeviceProperty is required for PCIe BDF semantic validation.'
}

$startedUtc = [DateTime]::UtcNow
$snapshot = @()
foreach ($index in 1..3) {
    $snapshot += Get-NxbSemanticPcieSnapshot -Index $index
    if ($index -lt 3) { Start-Sleep -Milliseconds $InterSnapshotDelayMilliseconds }
}

$allRecords = @($snapshot | ForEach-Object { @($_.records) })
$identitySet = @($allRecords.device_id_sha256 | Sort-Object -Unique)
$stable = [System.Collections.Generic.List[object]]::new()
foreach ($identityHash in $identitySet) {
    $perSnapshot = @($snapshot | ForEach-Object { @($_.records | Where-Object { [string]$_.device_id_sha256 -ceq $identityHash }) })
    if ($perSnapshot.Count -ne 3) { continue }
    $bdfSet = @($perSnapshot.bdf | Sort-Object -Unique)
    if ($bdfSet.Count -ne 1) { continue }
    if (@($perSnapshot | Where-Object { -not [bool]$_.address_decode_valid }).Count -gt 0) { continue }
    if (@($perSnapshot | Where-Object { -not [bool]$_.location_path_cross_check_available -or -not [bool]$_.location_path_cross_check_matches }).Count -gt 0) { continue }
    $stable.Add([pscustomobject][ordered]@{
        device_id_sha256 = $identityHash
        bdf = [string]$bdfSet[0]
        bus = [int]$perSnapshot[0].bus
        device = [int]$perSnapshot[0].device
        function = [int]$perSnapshot[0].function
        repeated_snapshots = 3
        address_decode_valid = $true
        location_path_cross_check_matches = $true
    })
}

$negativeControl = [System.Collections.Generic.List[object]]::new()
foreach ($mapping in $stable) {
    $wrongDevice = ([int]$mapping.device + 1) % 32
    $wrongFunction = [int]$mapping.function
    $wrongTupleAccepted = Test-NxbSemanticPcieTupleMatch `
        -ExpectedDevice ([int]$mapping.device) `
        -ExpectedFunction ([int]$mapping.function) `
        -ObservedDevice $wrongDevice `
        -ObservedFunction $wrongFunction
    $negativeControl.Add([pscustomobject][ordered]@{
        device_id_sha256 = [string]$mapping.device_id_sha256
        deliberately_wrong_tuple = ('{0:x2}.{1:x1}' -f $wrongDevice,$wrongFunction)
        mismatch_rejected = (-not $wrongTupleAccepted)
    })
}
$negativeControlPassed = ($stable.Count -gt 0 -and $negativeControl.Count -eq $stable.Count -and @($negativeControl | Where-Object { -not [bool]$_.mismatch_rejected }).Count -eq 0)

$endedUtc = [DateTime]::UtcNow
$validated = ($stable.Count -gt 0 -and $negativeControlPassed)
$result = [pscustomobject][ordered]@{
    schema_version = 1
    status = if ($validated) { 'passed' } else { 'failed' }
    started_utc = $startedUtc.ToString('o')
    ended_utc = $endedUtc.ToString('o')
    scope = 'bounded-same-boot-pcie-bdf-inventory'
    raw_device_instance_ids_reviewable = $false
    raw_location_paths_reviewable = $false
    snapshot_count = 3
    stable_mapping_count = [int]$stable.Count
    stable_mappings = @($stable | ForEach-Object {
        [pscustomobject][ordered]@{
            device_id_sha256 = [string]$_.device_id_sha256
            bus = [int]$_.bus
            device = [int]$_.device
            function = [int]$_.function
            bdf = [string]$_.bdf
            repeated_snapshots = [int]$_.repeated_snapshots
            address_decode_valid = [bool]$_.address_decode_valid
            location_path_cross_check_matches = [bool]$_.location_path_cross_check_matches
        }
    })
    negative_controls = [pscustomobject][ordered]@{
        synthetic_mismatched_tuple_count = [int]$negativeControl.Count
        rejected_count = @($negativeControl | Where-Object { [bool]$_.mismatch_rejected }).Count
        passed = $negativeControlPassed
        controls = @($negativeControl)
    }
    snapshots = @($snapshot | ForEach-Object {
        [pscustomobject][ordered]@{
            index = [int]$_.index
            captured_utc = [string]$_.captured_utc
            record_count = [int]$_.record_count
            fingerprint_sha256 = [string]$_.fingerprint_sha256
        }
    })
    claims = [pscustomobject][ordered]@{
        pcie_bdf_semantics = $validated
        bounded_same_boot_only = $true
        cross_boot_bdf_stability_claimed = $false
    }
}

$fullPath = [IO.Path]::GetFullPath($OutputPath)
$parent = Split-Path -Parent $fullPath
if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText($fullPath,(($result | ConvertTo-Json -Depth 16) + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
if (-not $validated) { throw 'PCIe BDF semantic experiment produced no stable independently cross-checked mapping with a passing mismatch negative control.' }
Write-Information -InformationAction Continue -MessageData ('NXB PCIe BDF semantic experiment passed: stable_mappings={0} negative_controls={1}' -f $stable.Count,$negativeControl.Count)
if ($PassThru) { return $result }
Write-Output $fullPath
