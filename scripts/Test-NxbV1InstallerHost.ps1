[CmdletBinding()]
param(
    [Parameter()][string]$OutputPath,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$policyPath = Join-Path -Path $repositoryRoot -ChildPath 'config\nxb-v1-installer-policy.json'
$policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json

function Invoke-NxbV1InstallerNative {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Executable,[Parameter(Mandatory)][string[]]$ArgumentList)
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
    return [pscustomobject][ordered]@{ exit_code=$nativeExitCode; output=(@($nativeOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) }
}

$windowsHost = ($env:OS -ceq 'Windows_NT')
$isCore = ($PSVersionTable.PSEdition -ceq 'Core')
$psMajor = [int]$PSVersionTable.PSVersion.Major
$pythonAvailable = $false
$pythonVersion = ''
$pythonPath = ''
$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction SilentlyContinue }
if ($null -ne $pythonCommand) {
    $pythonPath = [string]$pythonCommand.Source
    $pythonRun = Invoke-NxbV1InstallerNative -Executable $pythonPath -ArgumentList @('--version')
    if ($pythonRun.exit_code -eq 0 -and $pythonRun.output -match '(?i)Python\s+(?<major>\d+)\.(?<minor>\d+)(?:\.(?<patch>\d+))?') {
        $major = [int]$Matches['major']
        $minor = [int]$Matches['minor']
        $pythonVersion = $pythonRun.output.Trim()
        $pythonAvailable = ($major -gt [int]$policy.minimum_python_major -or ($major -eq [int]$policy.minimum_python_major -and $minor -ge [int]$policy.minimum_python_minor))
    }
}

$wprCommand = Get-Command wpr.exe -ErrorAction SilentlyContinue
$xperfCommand = Get-Command xperf.exe -ErrorAction SilentlyContinue
$wptPairAvailable = $false
$wprPath = ''
$xperfPath = ''
if ($null -ne $xperfCommand) {
    $xperfPath = [string]$xperfCommand.Source
    $xperfDirectory = Split-Path -Parent $xperfPath
    $pairedWpr = Join-Path -Path $xperfDirectory -ChildPath 'wpr.exe'
    if (Test-Path -LiteralPath $pairedWpr -PathType Leaf) {
        $wprPath = [IO.Path]::GetFullPath($pairedWpr)
        $wptPairAvailable = $true
    }
}
if (-not $wptPairAvailable -and $null -ne $wprCommand) { $wprPath = [string]$wprCommand.Source }

$isAdmin = $false
if ($windowsHost) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    finally { $identity.Dispose() }
}

$statusPassed = ($windowsHost -and $isCore -and $psMajor -ge [int]$policy.minimum_powershell_major -and $pythonAvailable)
$statusText = 'failed'
if ($statusPassed) { $statusText = 'passed' }
$receipt = [pscustomobject][ordered]@{
    schema_version=1
    status=$statusText
    authority='nxb-v1-installer-host-preflight-v1'
    windows=$windowsHost
    powershell_core=$isCore
    powershell_version=[string]$PSVersionTable.PSVersion
    python_available=$pythonAvailable
    python_version=$pythonVersion
    python_path=$pythonPath
    wpt_matched_pair_available=$wptPairAvailable
    wpr_path=$wprPath
    xperf_path=$xperfPath
    administrator=$isAdmin
    created_utc=[DateTime]::UtcNow.ToString('o')
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $outputFull = [IO.Path]::GetFullPath($OutputPath)
    $outputParent = Split-Path -Parent $outputFull
    if ([string]::IsNullOrWhiteSpace($outputParent) -or -not (Test-Path -LiteralPath $outputParent -PathType Container)) { throw 'Host preflight output parent must exist.' }
    [IO.File]::WriteAllText($outputFull,(($receipt | ConvertTo-Json -Depth 6)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
}
if (-not $statusPassed) { throw 'NXB v1 installer host preflight failed.' }
if ($PassThru) { $receipt }
if (-not $PassThru) { Write-Information ('NXB v1 installer host preflight passed: PS={0} Python={1} WPTPair={2} Admin={3}' -f [string]$receipt.powershell_version,$pythonVersion,$wptPairAvailable,$isAdmin) }
