Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NxbFullPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    return [IO.Path]::GetFullPath($Path)
}

function Get-NxbRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$BasePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ChildPath
    )

    $baseFull = Get-NxbFullPath -Path $BasePath
    $childFull = Get-NxbFullPath -Path $ChildPath
    $separator = [IO.Path]::DirectorySeparatorChar

    if (-not $baseFull.EndsWith([string]$separator)) {
        $baseFull += $separator
    }

    if (-not $childFull.StartsWith($baseFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Yol deney kökünün dışında: $childFull"
    }

    return $childFull.Substring($baseFull.Length)
}

function Test-NxbPathSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ })]
        [string]$Path
    )

    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Reparse point kanıt yolu olarak kabul edilmez: $($item.FullName)"
    }

    return $true
}

function Read-NxbJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$Path
    )

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Write-NxbJsonAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter()]
        [ValidateRange(2, 100)]
        [int]$Depth = 16
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temporaryPath = "$Path.tmp.$([guid]::NewGuid().ToString('N'))"
    try {
        $InputObject | ConvertTo-Json -Depth $Depth |
            Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Test-NxbStateTransition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('prepared', 'recording', 'stopped', 'finalized', 'failed')]
        [string]$From,

        [Parameter(Mandatory)]
        [ValidateSet('prepared', 'recording', 'stopped', 'finalized', 'failed')]
        [string]$To
    )

    $allowed = @{
        prepared  = @('recording', 'finalized', 'failed')
        recording = @('stopped', 'failed')
        stopped   = @('finalized', 'failed')
        finalized = @()
        failed    = @()
    }

    return $allowed[$From] -contains $To
}

function Set-NxbExperimentState {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$ExperimentPath,

        [Parameter(Mandatory)]
        [ValidateSet('prepared', 'recording', 'stopped', 'finalized', 'failed')]
        [string]$State,

        [Parameter()]
        [hashtable]$Updates = @{},

        [Parameter()]
        [switch]$AllowSameState
    )

    $manifestPath = Join-Path $ExperimentPath 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Manifest bulunamadı: $manifestPath"
    }

    $manifest = Read-NxbJson -Path $manifestPath
    $currentState = [string]$manifest.status

    if ($currentState -eq $State) {
        if (-not $AllowSameState) {
            throw "Deney zaten '$State' durumunda."
        }
    }
    elseif (-not (Test-NxbStateTransition -From $currentState -To $State)) {
        throw "İzin verilmeyen deney durum geçişi: $currentState -> $State"
    }

    $manifest.status = $State
    foreach ($entry in $Updates.GetEnumerator()) {
        $property = $manifest.PSObject.Properties[$entry.Key]
        if ($null -eq $property) {
            $manifest | Add-Member -MemberType NoteProperty -Name $entry.Key -Value $entry.Value
        }
        else {
            $manifest.($entry.Key) = $entry.Value
        }
    }

    if ($PSCmdlet.ShouldProcess($manifestPath, "Deney durumunu '$State' olarak yaz")) {
        Write-NxbJsonAtomic -Path $manifestPath -InputObject $manifest -Depth 16
    }

    return $manifest
}

function Get-NxbEvidenceFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$ExperimentPath
    )

    $experimentFull = Get-NxbFullPath -Path $ExperimentPath
    $excludedNames = @('manifest.json', 'evidence.sha256')

    $files = Get-ChildItem -LiteralPath $experimentFull -File -Recurse -Force |
        Where-Object { $excludedNames -notcontains $_.Name } |
        Sort-Object FullName

    foreach ($file in $files) {
        [void](Test-NxbPathSafety -Path $file.FullName)
        [void](Get-NxbRelativePath -BasePath $experimentFull -ChildPath $file.FullName)
    }

    return $files
}

Export-ModuleMember -Function @(
    'Get-NxbFullPath',
    'Get-NxbRelativePath',
    'Test-NxbPathSafety',
    'Read-NxbJson',
    'Write-NxbJsonAtomic',
    'Test-NxbStateTransition',
    'Set-NxbExperimentState',
    'Get-NxbEvidenceFile'
)
