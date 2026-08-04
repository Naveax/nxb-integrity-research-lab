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

function Resolve-NxbExecutablePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter()]
        [string]$ExplicitPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $resolved = Get-NxbFullPath -Path $ExplicitPath
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "Executable bulunamadı: $resolved"
        }

        return $resolved
    }

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Executable bulunamadı: $Name"
    }

    return [string]$command.Source
}

function Test-NxbPathSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ })]
        [string]$Path,

        [Parameter()]
        [string]$RootPath
    )

    $pathFull = Get-NxbFullPath -Path $Path
    $rootFull = $null

    if (-not [string]::IsNullOrWhiteSpace($RootPath)) {
        $rootFull = Get-NxbFullPath -Path $RootPath
        if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
            throw "Güvenlik kökü bulunamadı: $rootFull"
        }

        if (-not $pathFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
            [void](Get-NxbRelativePath -BasePath $rootFull -ChildPath $pathFull)
        }
    }

    $current = $pathFull
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse point kanıt yolu olarak kabul edilmez: $($item.FullName)"
            }
        }

        if ($null -ne $rootFull -and $current.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }

        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent.Equals($current, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }

        $current = $parent
    }

    return $true
}

function Get-NxbSafeChildItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$RootPath
    )

    $rootFull = Get-NxbFullPath -Path $RootPath
    [void](Test-NxbPathSafety -Path $rootFull -RootPath $rootFull)

    $pending = [System.Collections.Generic.Stack[string]]::new()
    $result = [System.Collections.Generic.List[object]]::new()
    $pending.Push($rootFull)

    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($child in @(Get-ChildItem -LiteralPath $directory -Force)) {
            [void](Test-NxbPathSafety -Path $child.FullName -RootPath $rootFull)
            [void]$result.Add($child)

            if ($child.PSIsContainer) {
                $pending.Push($child.FullName)
            }
        }
    }

    return @($result)
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
    $items = Get-NxbSafeChildItem -RootPath $experimentFull

    $files = @($items |
        Where-Object { -not $_.PSIsContainer -and $excludedNames -notcontains $_.Name } |
        Sort-Object FullName)

    foreach ($file in $files) {
        [void](Get-NxbRelativePath -BasePath $experimentFull -ChildPath $file.FullName)
    }

    return $files
}

Export-ModuleMember -Function @(
    'Get-NxbFullPath',
    'Get-NxbRelativePath',
    'Resolve-NxbExecutablePath',
    'Test-NxbPathSafety',
    'Get-NxbSafeChildItem',
    'Read-NxbJson',
    'Write-NxbJsonAtomic',
    'Test-NxbStateTransition',
    'Set-NxbExperimentState',
    'Get-NxbEvidenceFile'
)
