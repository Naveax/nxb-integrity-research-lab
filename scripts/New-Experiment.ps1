[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Root = 'C:\NXB-Lab',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Name,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Hypothesis,

    [Parameter()]
    [string]$TargetVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force

$experimentsRoot = Join-Path $Root 'experiments'
if (-not (Test-Path -LiteralPath $experimentsRoot -PathType Container)) {
    throw "Laboratuvar başlatılmamış: $experimentsRoot"
}

$safeName = ($Name -replace '[^a-zA-Z0-9._-]', '-').Trim('-')
if ([string]::IsNullOrWhiteSpace($safeName)) {
    throw 'Deney adı güvenli bir dizin adı üretemedi.'
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$experimentId = "$stamp-$safeName-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$experimentPath = Join-Path $experimentsRoot $experimentId

if (Test-Path -LiteralPath $experimentPath) {
    throw "Deney dizini zaten var: $experimentPath"
}

@('baseline', 'traces', 'dumps', 'binaries', 'notes', 'logs') | ForEach-Object {
    New-Item -ItemType Directory -Path (Join-Path $experimentPath $_) -Force | Out-Null
}

$manifest = [ordered]@{
    schema_version = 1
    experiment_id  = $experimentId
    name           = $Name
    hypothesis     = $Hypothesis
    created_utc    = [DateTime]::UtcNow.ToString('o')
    completed_utc  = $null
    status         = 'prepared'
    machine        = [ordered]@{
        computer_name = $env:COMPUTERNAME
        user_name     = $env:USERNAME
        os_version    = [Environment]::OSVersion.VersionString
        powershell    = $PSVersionTable.PSVersion.ToString()
    }
    target_version = if ($TargetVersion) { $TargetVersion } else { $null }
    notes          = @()
}

Write-NxbJsonAtomic `
    -Path (Join-Path $experimentPath 'manifest.json') `
    -InputObject $manifest `
    -Depth 16

Write-Host "Deney hazır: $experimentPath"
Write-Output $experimentPath
