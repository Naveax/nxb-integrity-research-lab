[CmdletBinding()]
param([Parameter()][switch]$PassThru)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NxbSemanticHardeningAdministrator {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NxbSemanticHardeningCommandPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        $pathProperty = $command.PSObject.Properties['Path']
        if ($null -ne $pathProperty -and -not [string]::IsNullOrWhiteSpace([string]$pathProperty.Value)) {
            return [string]$pathProperty.Value
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$command.Source)) { return [string]$command.Source }
    }

    if ($Name -ceq 'xperf.exe') {
        foreach ($candidate in @(
            "${env:ProgramFiles(x86)}\Windows Kits\10\Windows Performance Toolkit\xperf.exe",
            "$env:ProgramFiles\Windows Kits\10\Windows Performance Toolkit\xperf.exe"
        )) {
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
            $directory = Split-Path -Parent $candidate
            $pathEntries = @($env:PATH -split [IO.Path]::PathSeparator)
            if (@($pathEntries | Where-Object { [string]::Equals($_,$directory,[StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) {
                $env:PATH = $directory + [IO.Path]::PathSeparator + $env:PATH
            }
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}

if ($env:OS -cne 'Windows_NT') { throw 'Part 2 host capability preflight requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Part 2 host capability preflight requires PowerShell 7.' }
if (-not (Test-NxbSemanticHardeningAdministrator)) { throw 'Part 2 host capability preflight requires elevated PowerShell 7.' }

$commandResult = [ordered]@{}
foreach ($commandName in @('git.exe','pwsh.exe','python.exe','wpr.exe','xperf.exe','powercfg.exe','Get-PnpDeviceProperty')) {
    $resolved = Get-NxbSemanticHardeningCommandPath -Name $commandName
    if ([string]::IsNullOrWhiteSpace($resolved) -and $commandName -ceq 'python.exe') {
        $resolved = Get-NxbSemanticHardeningCommandPath -Name 'python'
    }
    $commandResult[$commandName] = [pscustomobject][ordered]@{
        available = (-not [string]::IsNullOrWhiteSpace($resolved))
        path = $resolved
    }
}

$windowsPowerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$windowsPowerShellAvailable = (Test-Path -LiteralPath $windowsPowerShellPath -PathType Leaf)
$pesterAvailable = (@(Get-Module -ListAvailable -Name Pester).Count -gt 0)

$softwareDeviceDll = Join-Path $env:SystemRoot 'System32\CfgMgr32.dll'
$softwareDeviceApiAvailable = (Test-Path -LiteralPath $softwareDeviceDll -PathType Leaf)

$hyperVCommands = [ordered]@{}
foreach ($commandName in @('New-VM','Get-VM','Get-VMHost','Get-VMFirmware','Set-VMFirmware','Remove-VM')) {
    $hyperVCommands[$commandName] = ($null -ne (Get-Command $commandName -ErrorAction SilentlyContinue))
}
$hyperVCmdletsAvailable = (@($hyperVCommands.Values | Where-Object { -not [bool]$_ }).Count -eq 0)
$vmmsService = Get-Service -Name vmms -ErrorAction SilentlyContinue
$vmmsAvailable = ($null -ne $vmmsService)
$vmmsRunning = ($vmmsAvailable -and [string]$vmmsService.Status -ceq 'Running')
$vmHostQueryable = $false
if ($hyperVCmdletsAvailable -and $vmmsRunning) {
    try {
        $vmHost = Get-VMHost -ErrorAction Stop
        $vmHostQueryable = ($null -ne $vmHost)
    }
    catch { $vmHostQueryable = $false }
}

$vsWhereCandidates = @(
    "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe",
    "$env:ProgramFiles\Microsoft Visual Studio\Installer\vswhere.exe"
)
$vsWherePath = @($vsWhereCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
$vcBuildToolsAvailable = $false
$vcInstallationPath = $null
if ($vsWherePath.Count -eq 1) {
    $previousErrorActionPreference = $ErrorActionPreference
    $nativePreferenceVariable = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    $nativePreferenceAvailable = ($null -ne $nativePreferenceVariable)
    $previousNativePreference = if ($nativePreferenceAvailable) { [bool]$nativePreferenceVariable.Value } else { $null }
    $vsOutput = @()
    $vsExit = 1
    try {
        $ErrorActionPreference = 'Continue'
        if ($nativePreferenceAvailable) { Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $false -Scope Local }
        $vsOutput = @(& $vsWherePath[0] -latest -products '*' -requires 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' -property installationPath 2>&1)
        $vsExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($nativePreferenceAvailable) { Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $previousNativePreference -Scope Local }
    }
    if ($vsExit -eq 0) {
        $vcInstallationPath = (@($vsOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine).Trim()
        $vcBuildToolsAvailable = (-not [string]::IsNullOrWhiteSpace($vcInstallationPath))
    }
}

$pnpProviderReadable = $false
$pnpLogCount = 0
try {
    $provider = Get-WinEvent -ListProvider 'Microsoft-Windows-Kernel-PnP' -ErrorAction Stop
    $pnpLogCount = @($provider.LogLinks | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.LogName) }).Count
    $pnpProviderReadable = $true
}
catch { $pnpProviderReadable = $false }

$requiredCommandNames = @('git.exe','pwsh.exe','python.exe','wpr.exe','xperf.exe','powercfg.exe','Get-PnpDeviceProperty')
$missingCommands = @($requiredCommandNames | Where-Object { -not [bool]$commandResult[$_].available })
$blockers = [System.Collections.Generic.List[string]]::new()
foreach ($missing in $missingCommands) { $blockers.Add('missing_command:' + $missing) }
if (-not $windowsPowerShellAvailable) { $blockers.Add('windows_powershell_5_1_unavailable') }
if (-not $pesterAvailable) { $blockers.Add('pester_module_unavailable') }
if (-not $softwareDeviceApiAvailable) { $blockers.Add('software_device_api_unavailable') }
if (-not $hyperVCmdletsAvailable) { $blockers.Add('hyper_v_cmdlets_unavailable') }
if (-not $vmmsRunning) { $blockers.Add('hyper_v_vmms_not_running') }
if (-not $vmHostQueryable) { $blockers.Add('hyper_v_host_not_queryable') }
if (-not $vcBuildToolsAvailable) { $blockers.Add('visual_cpp_build_tools_unavailable') }
if (-not $pnpProviderReadable) { $blockers.Add('kernel_pnp_provider_unreadable') }

$result = [pscustomobject][ordered]@{
    schema_version = 1
    status = if ($blockers.Count -eq 0) { 'passed' } else { 'blocked' }
    commands = [pscustomobject]$commandResult
    cross_runtime = [pscustomobject][ordered]@{
        windows_powershell_5_1_available = $windowsPowerShellAvailable
        windows_powershell_path = if ($windowsPowerShellAvailable) { $windowsPowerShellPath } else { $null }
        pester_available = $pesterAvailable
    }
    software_device_api = [pscustomobject][ordered]@{
        available = $softwareDeviceApiAvailable
        dll_path = if ($softwareDeviceApiAvailable) { $softwareDeviceDll } else { $null }
    }
    hyper_v = [pscustomobject][ordered]@{
        cmdlets_available = $hyperVCmdletsAvailable
        vmms_available = $vmmsAvailable
        vmms_running = $vmmsRunning
        host_queryable = $vmHostQueryable
        commands = [pscustomobject]$hyperVCommands
    }
    build_tools = [pscustomobject][ordered]@{
        vswhere_path = if ($vsWherePath.Count -eq 1) { [string]$vsWherePath[0] } else { $null }
        vc_tools_available = $vcBuildToolsAvailable
        installation_path = $vcInstallationPath
    }
    pnp_event_surface = [pscustomobject][ordered]@{
        kernel_pnp_provider_readable = $pnpProviderReadable
        linked_log_count = $pnpLogCount
    }
    process_local_path_normalization = [pscustomobject][ordered]@{
        xperf_path = [string]$commandResult['xperf.exe'].path
        persistent_path_modified = $false
    }
    blockers = @($blockers)
}

if ([string]$result.status -cne 'passed') {
    throw ('Part 2 host capability preflight blocked: {0}. No Windows feature enablement, reboot, persistent PATH change, host-firmware mutation, or service start was attempted.' -f (@($blockers) -join ', '))
}
Write-Information -InformationAction Continue -MessageData 'NXB Part 2 host capability preflight passed.'
if ($PassThru) { return $result }
Write-Output ($result | ConvertTo-Json -Depth 12)
