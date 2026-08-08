[CmdletBinding()]
param(
    [Parameter()]
    [string]$InstallerUrl = 'https://download.microsoft.com/download/2/d/9/2d9c8902-3fcd-48a6-a22a-432b08bed61e/ADK/adksetup.exe',

    [Parameter()]
    [string]$DownloadDirectory,

    [Parameter()]
    [switch]$KeepInstaller,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NxbAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Resolve-NxbInstalledXperf {
    [CmdletBinding()]
    param()

    $command = Get-Command xperf.exe -ErrorAction SilentlyContinue
    if ($null -ne $command -and
        (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
        return [IO.Path]::GetFullPath([string]$command.Source)
    }

    $candidates = [Collections.Generic.List[string]]::new()
    foreach ($registryPath in @(
        'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots'
    )) {
        try {
            $root = (Get-ItemProperty `
                -LiteralPath $registryPath `
                -Name KitsRoot10 `
                -ErrorAction Stop).KitsRoot10
        }
        catch {
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$root)) {
            $candidates.Add((Join-Path `
                ([string]$root) `
                'Windows Performance Toolkit\xperf.exe'))
        }
    }

    foreach ($programFilesRoot in @(
        ${env:ProgramFiles(x86)},
        $env:ProgramFiles
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$programFilesRoot)) {
            $candidates.Add((Join-Path `
                ([string]$programFilesRoot) `
                'Windows Kits\10\Windows Performance Toolkit\xperf.exe'))
        }
    }

    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($candidate in $candidates) {
        $full = [IO.Path]::GetFullPath($candidate)
        if (-not $seen.Add($full)) {
            continue
        }
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            return $full
        }
    }

    return $null
}

if ($env:OS -cne 'Windows_NT') {
    throw 'Windows Performance Toolkit bootstrap requires Windows.'
}
if (-not (Test-NxbAdministrator)) {
    throw 'Run this bootstrap from an elevated PowerShell window.'
}

$alreadyInstalled = Resolve-NxbInstalledXperf
if (-not [string]::IsNullOrWhiteSpace([string]$alreadyInstalled)) {
    Write-Host "Windows Performance Toolkit already installed: $alreadyInstalled"
    if ($PassThru) {
        return [pscustomobject][ordered]@{
            status = 'already_installed'
            xperf_path = $alreadyInstalled
            reboot_required = $false
        }
    }
    return
}

if ([string]::IsNullOrWhiteSpace($DownloadDirectory)) {
    $DownloadDirectory = Join-Path `
        ([IO.Path]::GetTempPath()) `
        ('nxb-wpt-bootstrap-' + [guid]::NewGuid().ToString('N'))
}
$downloadFull = [IO.Path]::GetFullPath($DownloadDirectory)
[IO.Directory]::CreateDirectory($downloadFull) | Out-Null
$installerPath = Join-Path $downloadFull 'adksetup.exe'

try {
    Write-Host 'Downloading official Microsoft Windows ADK installer...'
    Invoke-WebRequest `
        -Uri $InstallerUrl `
        -OutFile $installerPath `
        -UseBasicParsing

    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
        throw 'ADK installer download did not produce a file.'
    }

    $signature = Get-AuthenticodeSignature -FilePath $installerPath
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid) {
        throw "ADK installer Authenticode signature is not valid: $($signature.Status)"
    }
    $subject = [string]$signature.SignerCertificate.Subject
    if ($subject -notmatch '(?i)Microsoft') {
        throw "ADK installer signer is not Microsoft: $subject"
    }

    Write-Host "Verified installer signer: $subject"
    Write-Host 'Installing only OptionId.WindowsPerformanceToolkit...'

    $process = Start-Process `
        -FilePath $installerPath `
        -ArgumentList @(
            '/quiet',
            '/features',
            'OptionId.WindowsPerformanceToolkit'
        ) `
        -Wait `
        -PassThru
    try {
        $exitCode = [int]$process.ExitCode
    }
    finally {
        $process.Dispose()
    }

    if ($exitCode -ne 0 -and $exitCode -ne 3010) {
        throw "Windows ADK WPT installation failed with exit code $exitCode."
    }

    $xperfPath = Resolve-NxbInstalledXperf
    if ([string]::IsNullOrWhiteSpace([string]$xperfPath)) {
        throw (
            'Installer completed but xperf.exe was not found in the expected ' +
            'Windows Performance Toolkit locations.'
        )
    }

    $result = [pscustomobject][ordered]@{
        status = 'installed'
        xperf_path = $xperfPath
        reboot_required = ($exitCode -eq 3010)
        installer_signer = $subject
        installer_sha256 = (
            Get-FileHash -LiteralPath $installerPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    }

    Write-Host "Windows Performance Toolkit installed: $xperfPath"
    if ($result.reboot_required) {
        Write-Warning 'Installer returned 3010; Windows restart is required.'
    }

    if ($PassThru) {
        return $result
    }
}
finally {
    if (-not $KeepInstaller -and
        (Test-Path -LiteralPath $downloadFull -PathType Container)) {
        Remove-Item -LiteralPath $downloadFull -Recurse -Force
    }
}
