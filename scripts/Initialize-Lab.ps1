[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Root = 'C:\NXB-Lab',

    [Parameter(Mandatory)]
    [ValidateSet('Controller', 'Target')]
    [string]$Role
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$directories = @(
    $Root,
    (Join-Path $Root 'experiments'),
    (Join-Path $Root 'symbols'),
    (Join-Path $Root 'tools'),
    (Join-Path $Root 'exports')
)

foreach ($directory in $directories) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

$configPath = Join-Path $Root 'lab.config.json'
if (-not (Test-Path -LiteralPath $configPath)) {
    $config = [ordered]@{
        schema_version = 1
        lab_id         = [guid]::NewGuid().ToString()
        role           = $Role
        machine_name   = $env:COMPUTERNAME
        created_utc    = [DateTime]::UtcNow.ToString('o')
        experiments    = (Join-Path $Root 'experiments')
        symbols        = (Join-Path $Root 'symbols')
    }

    $config | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $configPath -Encoding UTF8
}

Write-Host "Laboratuvar hazır: $Root"
Write-Host "Rol: $Role"
Write-Output $Root
