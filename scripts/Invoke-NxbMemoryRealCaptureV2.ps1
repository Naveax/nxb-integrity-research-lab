[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter()]
    [string]$OutputDirectory,

    [Parameter()]
    [ValidateRange(4, 128)]
    [int]$PrivateMemoryMiB = 32,

    [Parameter()]
    [ValidateRange(1, 64)]
    [int]$MappedFileMiB = 8,

    [Parameter()]
    [ValidateRange(0, 3000)]
    [int]$HoldMilliseconds = 1000,

    [Parameter()]
    [ValidateRange(1, 5000000)]
    [int]$MaxEventCount = 1000000,

    [Parameter()]
    [switch]$CancelExistingSession,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-NxbMemoryXperfPath {
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
            if (-not [string]::IsNullOrWhiteSpace([string]$root)) {
                $candidates.Add((Join-Path `
                    ([string]$root) `
                    'Windows Performance Toolkit\xperf.exe'))
            }
        }
        catch {
            continue
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
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        $full = [IO.Path]::GetFullPath($candidate)
        if (-not $seen.Add($full)) {
            continue
        }
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            return $full
        }
    }

    throw (
        'xperf.exe was not found in PATH, Windows Kits registry roots, or ' +
        'the standard Windows Performance Toolkit directories. Install the ' +
        'Windows Performance Toolkit component of the Windows ADK.'
    )
}

if ($env:OS -cne 'Windows_NT') {
    throw 'Real memory WPR capture V2 requires Windows.'
}

$baseCapture = Join-Path $PSScriptRoot 'Invoke-NxbMemoryRealCapture.ps1'
if (-not (Test-Path -LiteralPath $baseCapture -PathType Leaf)) {
    throw "Base real-capture runner not found: $baseCapture"
}

$xperfPath = Resolve-NxbMemoryXperfPath
$xperfDirectory = Split-Path -Parent $xperfPath
$originalPath = $env:PATH

try {
    $pathEntries = @($originalPath -split ';')
    if ($pathEntries -notcontains $xperfDirectory) {
        $env:PATH = $xperfDirectory + ';' + $originalPath
    }

    $resolved = Get-Command xperf.exe -ErrorAction Stop
    if ([IO.Path]::GetFullPath([string]$resolved.Source) -cne $xperfPath) {
        throw (
            'Resolved xperf.exe does not match the selected Windows ' +
            "Performance Toolkit executable. Selected: $xperfPath; " +
            "resolved: $($resolved.Source)"
        )
    }

    Write-Host "Resolved xperf.exe: $xperfPath"

    $arguments = @{
        ExpectedHead = $ExpectedHead
        PrivateMemoryMiB = $PrivateMemoryMiB
        MappedFileMiB = $MappedFileMiB
        HoldMilliseconds = $HoldMilliseconds
        MaxEventCount = $MaxEventCount
        CancelExistingSession = $CancelExistingSession
        PassThru = $PassThru
    }
    if (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $arguments.OutputDirectory = $OutputDirectory
    }

    & $baseCapture @arguments
}
finally {
    $env:PATH = $originalPath
}
