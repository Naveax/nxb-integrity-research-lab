[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [string[]]$TargetPaths = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$baseline = Join-Path $ExperimentPath 'baseline'
New-Item -ItemType Directory -Path $baseline -Force | Out-Null

function Invoke-Capture {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    $output = Join-Path $baseline $Name
    try {
        & $Action | Out-File -LiteralPath $output -Encoding utf8 -Width 4096
    }
    catch {
        "ERROR: $($_.Exception.Message)" |
            Out-File -LiteralPath $output -Encoding utf8
    }
}

Invoke-Capture 'computer-info.txt' {
    Get-ComputerInfo | Format-List *
}

Invoke-Capture 'processors.txt' {
    Get-CimInstance Win32_Processor | Format-List *
}

Invoke-Capture 'video-controllers.txt' {
    Get-CimInstance Win32_VideoController | Format-List *
}

Invoke-Capture 'signed-drivers.txt' {
    Get-CimInstance Win32_PnPSignedDriver |
        Sort-Object DeviceName |
        Select-Object DeviceName, DriverVersion, DriverDate, Manufacturer, InfName, IsSigned |
        Format-Table -AutoSize
}

Invoke-Capture 'services.txt' {
    Get-Service |
        Sort-Object Name |
        Select-Object Status, StartType, Name, DisplayName |
        Format-Table -AutoSize
}

Invoke-Capture 'processes.txt' {
    Get-Process |
        Sort-Object ProcessName |
        Select-Object ProcessName, Id, CPU, WorkingSet64, Path |
        Format-Table -AutoSize
}

Invoke-Capture 'network.txt' {
    Get-NetAdapter | Format-List *
    Get-NetIPConfiguration | Format-List *
}

Invoke-Capture 'bcdedit.txt' {
    & bcdedit.exe /enum all 2>&1
}

Invoke-Capture 'driverquery.csv' {
    & driverquery.exe /v /fo csv 2>&1
}

Invoke-Capture 'filter-drivers.txt' {
    & fltmc.exe 2>&1
}

Invoke-Capture 'kernel-services.txt' {
    & sc.exe query type= driver state= all 2>&1
}

$hashRows = [System.Collections.Generic.List[object]]::new()
foreach ($targetPath in $TargetPaths) {
    if (-not (Test-Path -LiteralPath $targetPath)) {
        $hashRows.Add([pscustomobject]@{
            Path = $targetPath
            Length = $null
            LastWriteTimeUtc = $null
            SHA256 = 'NOT_FOUND'
        })
        continue
    }

    $items = if (Test-Path -LiteralPath $targetPath -PathType Container) {
        Get-ChildItem -LiteralPath $targetPath -File -Recurse -Force -ErrorAction SilentlyContinue
    }
    else {
        Get-Item -LiteralPath $targetPath -Force
    }

    foreach ($item in $items) {
        try {
            $hash = Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256
            $hashRows.Add([pscustomobject]@{
                Path = $item.FullName
                Length = $item.Length
                LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
                SHA256 = $hash.Hash
            })
        }
        catch {
            $hashRows.Add([pscustomobject]@{
                Path = $item.FullName
                Length = $item.Length
                LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
                SHA256 = "ERROR: $($_.Exception.Message)"
            })
        }
    }
}

$hashRows |
    Sort-Object Path |
    Export-Csv -LiteralPath (Join-Path $baseline 'target-hashes.csv') -NoTypeInformation -Encoding utf8

& (Join-Path $PSScriptRoot 'Get-SystemCapabilities.ps1') `
    -ExperimentPath $ExperimentPath | Out-Null

Write-Host "Baseline tamamlandı: $baseline"
