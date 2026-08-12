Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NxbV1UpdateStageStatePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UpdateRoot)
    return (Join-Path -Path ([IO.Path]::GetFullPath($UpdateRoot)) -ChildPath 'stage-state.json')
}

function Get-NxbV1UpdateStatePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UpdateRoot)
    return (Join-Path -Path ([IO.Path]::GetFullPath($UpdateRoot)) -ChildPath 'update-state.json')
}

function Write-NxbV1UpdateJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$Value)
    $full = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $full
    if ([string]::IsNullOrWhiteSpace($parent) -or -not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Update JSON parent must exist.' }
    [IO.File]::WriteAllText($full,(($Value | ConvertTo-Json -Depth 12)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
}

function Get-NxbV1UpdateStageStateObject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UpdateRoot)
    $path = Get-NxbV1UpdateStageStatePath -UpdateRoot $UpdateRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Update stage state is missing.' }
    $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ([int]$state.schema_version -ne 1 -or [string]$state.contract_id -cne 'nxb-v1-update-stage-state-v1' -or [string]$state.status -cne 'staged') { throw 'Update stage state identity drift.' }
    if (@('stable','beta') -cnotcontains [string]$state.channel) { throw 'Update stage state channel is invalid.' }
    return $state
}

function Get-NxbV1UpdateStateObject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UpdateRoot)
    $path = Get-NxbV1UpdateStatePath -UpdateRoot $UpdateRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ([int]$state.schema_version -ne 1 -or [string]$state.contract_id -cne 'nxb-v1-update-state-v1') { throw 'Update state identity drift.' }
    if (@('stable','beta') -cnotcontains [string]$state.current_channel -or @('stable','beta') -cnotcontains [string]$state.rollback_channel) { throw 'Update state channel identity is invalid.' }
    if ([int]$state.current_release_sequence -lt 0 -or -not (Test-NxbV1InstallerLowerHex -Text ([string]$state.current_release_head) -Length 40)) { throw 'Update state current release identity is invalid.' }
    if (-not (Test-NxbV1InstallerLowerHex -Text ([string]$state.current_package_manifest_sha256) -Length 64)) { throw 'Update state current manifest hash is invalid.' }
    if ([string]$state.current_envelope_sha256 -cne 'none' -and -not (Test-NxbV1InstallerLowerHex -Text ([string]$state.current_envelope_sha256) -Length 64)) { throw 'Update state current envelope hash is invalid.' }
    if ([bool]$state.rollback_available) {
        if ([int]$state.rollback_release_sequence -lt 0 -or -not (Test-NxbV1InstallerLowerHex -Text ([string]$state.rollback_release_head) -Length 40)) { throw 'Update state rollback release identity is invalid.' }
        if (-not (Test-NxbV1InstallerLowerHex -Text ([string]$state.rollback_package_manifest_sha256) -Length 64)) { throw 'Update state rollback manifest hash is invalid.' }
        if ([string]$state.rollback_envelope_sha256 -cne 'none' -and -not (Test-NxbV1InstallerLowerHex -Text ([string]$state.rollback_envelope_sha256) -Length 64)) { throw 'Update state rollback envelope hash is invalid.' }
        if (-not (Test-NxbV1InstallerLowerHex -Text ([string]$state.rollback_tree_sha256) -Length 64)) { throw 'Update state rollback tree hash is invalid.' }
        if ([string]::IsNullOrWhiteSpace([string]$state.rollback_root)) { throw 'Update state rollback root is missing.' }
    }
    return $state
}

function Get-NxbV1UpdateCurrentSequence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UpdateRoot)
    $state = Get-NxbV1UpdateStateObject -UpdateRoot $UpdateRoot
    if ($null -eq $state) { return 0 }
    return [int]$state.current_release_sequence
}
