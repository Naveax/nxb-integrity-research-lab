[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [string]$WprExecutablePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Nxb.EvidenceStore.psm1') -Force

function Get-NxbTraceProfileIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Session,

        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$RepositoryRoot
    )

    $result = [ordered]@{
        status = 'invalid'
        expected_provenance_sha256 = $null
        actual_provenance_sha256 = $null
        current_profile_sha256 = $null
        current_profile_length = $null
        reason = $null
    }

    try {
        $profileProperty = $Session.PSObject.Properties['profile']
        $provenanceProperty = $Session.PSObject.Properties['profile_provenance']
        $sealProperty = $Session.PSObject.Properties['profile_provenance_sha256']
        if ($null -eq $profileProperty -or [string]::IsNullOrWhiteSpace([string]$profileProperty.Value)) {
            throw 'Trace session profile alanı eksik.'
        }
        if ($null -eq $provenanceProperty -or $null -eq $provenanceProperty.Value) {
            throw 'Trace session profile_provenance alanı eksik.'
        }
        if ($null -eq $sealProperty -or
            [string]$sealProperty.Value -notmatch '^[0-9a-f]{64}$') {
            throw 'Trace session profile_provenance_sha256 alanı eksik veya geçersiz.'
        }

        $provenance = $provenanceProperty.Value
        $expectedSeal = [string]$sealProperty.Value
        $actualSeal = Get-NxbCanonicalJsonHash -InputObject $provenance
        $result.expected_provenance_sha256 = $expectedSeal
        $result.actual_provenance_sha256 = $actualSeal
        if ($actualSeal -cne $expectedSeal) {
            throw 'Trace session profile provenance canonical SHA-256 değeri uyuşmuyor.'
        }

        $typeProperty = $provenance.PSObject.Properties['type']
        if ($null -eq $typeProperty -or [string]::IsNullOrWhiteSpace([string]$typeProperty.Value)) {
            throw 'Trace session profile provenance type alanı eksik.'
        }

        switch ([string]$typeProperty.Value) {
            'repository_wprp' {
                if ([string]$profileProperty.Value -cne 'NxbMinimalCpuScheduler') {
                    throw 'Repository WPRP provenance beklenmeyen capture profile ile eşleşiyor.'
                }

                $relativeProperty = $provenance.PSObject.Properties['relative_path']
                $hashProperty = $provenance.PSObject.Properties['sha256']
                $lengthProperty = $provenance.PSObject.Properties['length']
                if ($null -eq $relativeProperty -or
                    [string]::IsNullOrWhiteSpace([string]$relativeProperty.Value)) {
                    throw 'Repository WPRP relative_path alanı eksik.'
                }
                if ($null -eq $hashProperty -or
                    [string]$hashProperty.Value -notmatch '^[0-9a-f]{64}$') {
                    throw 'Repository WPRP sha256 alanı eksik veya geçersiz.'
                }
                if ($null -eq $lengthProperty -or [int64]$lengthProperty.Value -le 0) {
                    throw 'Repository WPRP length alanı eksik veya geçersiz.'
                }

                $relativePath = [string]$relativeProperty.Value
                if ([IO.Path]::IsPathRooted($relativePath) -or $relativePath -match '^[A-Za-z]:') {
                    throw 'Repository WPRP relative_path mutlak olamaz.'
                }

                $profilesRoot = Join-Path $RepositoryRoot 'profiles'
                $profileFull = Get-NxbFullPath -Path (Join-Path $RepositoryRoot $relativePath)
                [void](Get-NxbRelativePath -BasePath $profilesRoot -ChildPath $profileFull)
                $currentProfile = & (Join-Path $PSScriptRoot 'Test-WprProfile.ps1') `
                    -Path $profileFull `
                    -PassThru

                $result.current_profile_sha256 = [string]$currentProfile.Sha256
                $result.current_profile_length = [int64]$currentProfile.Length
                if ([string]$currentProfile.RelativePath -cne $relativePath) {
                    throw 'Repository WPRP canonical relative path değeri değişti.'
                }
                if ([string]$currentProfile.Sha256 -cne [string]$hashProperty.Value) {
                    throw 'Repository WPRP dosya SHA-256 değeri başlangıç provenance değeriyle uyuşmuyor.'
                }
                if ([int64]$currentProfile.Length -ne [int64]$lengthProperty.Value) {
                    throw 'Repository WPRP dosya uzunluğu başlangıç provenance değeriyle uyuşmuyor.'
                }
            }
            'builtin' {
                if ([string]$profileProperty.Value -cne 'GeneralProfile') {
                    throw 'Built-in provenance beklenmeyen capture profile ile eşleşiyor.'
                }

                $nameProperty = $provenance.PSObject.Properties['name']
                $boundedProperty = $provenance.PSObject.Properties['bounded']
                if ($null -eq $nameProperty -or [string]$nameProperty.Value -cne 'GeneralProfile') {
                    throw 'Built-in provenance GeneralProfile kimliğini taşımıyor.'
                }
                if ($null -eq $boundedProperty -or [bool]$boundedProperty.Value) {
                    throw 'Built-in GeneralProfile provenance bounded olarak işaretlenemez.'
                }
            }
            default {
                throw "Desteklenmeyen trace profile provenance type: $($typeProperty.Value)"
            }
        }

        $result.status = 'valid'
    }
    catch {
        $result.reason = $_.Exception.Message
    }

    return [pscustomobject]$result
}

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
$manifestPath = Join-Path $experimentFull 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Manifest bulunamadı: $manifestPath"
}

$manifest = Read-NxbJson -Path $manifestPath
if ([string]$manifest.status -ne 'recording') {
    throw "WPR yalnız recording deneyde durdurulabilir. Mevcut durum: $($manifest.status)"
}

$sessionPath = Join-Path $experimentFull 'trace-session.json'
if (-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)) {
    throw "Trace session manifesti bulunamadı: $sessionPath"
}

$session = Read-NxbJson -Path $sessionPath
if ([string]$session.status -ne 'recording') {
    throw "Trace session recording değil: $($session.status)"
}

try {
    $wprPath = Resolve-NxbExecutablePath -Name 'wpr.exe' -ExplicitPath $WprExecutablePath
}
catch {
    throw "wpr.exe bulunamadı. $($_.Exception.Message)"
}

$traces = Join-Path $experimentFull 'traces'
New-Item -ItemType Directory -Path $traces -Force | Out-Null
$etl = Join-Path $traces 'performance.etl'

$stagingRoot = [IO.Path]::GetTempPath()
if ([string]::IsNullOrWhiteSpace($stagingRoot) -or
    -not (Test-Path -LiteralPath $stagingRoot -PathType Container)) {
    throw "WPR staging dizini bulunamadı: $stagingRoot"
}
$stagingEtl = Join-Path `
    $stagingRoot `
    ("nxb-wpr-stop-{0}.etl" -f [guid]::NewGuid().ToString('N'))

try {
    $stopOutput = & $wprPath -stop $stagingEtl 2>&1
    $stopExitCode = $LASTEXITCODE
    if ($stopExitCode -ne 0) {
        throw "WPR durdurulamadı (exit $stopExitCode): $($stopOutput -join [Environment]::NewLine)"
    }
    if (-not (Test-Path -LiteralPath $stagingEtl -PathType Leaf)) {
        throw "WPR başarı kodu döndürdü ancak staging ETL oluşturulmadı: $stagingEtl"
    }

    Move-Item `
        -LiteralPath $stagingEtl `
        -Destination $etl `
        -Force
}
finally {
    if (Test-Path -LiteralPath $stagingEtl -PathType Leaf) {
        Remove-Item -LiteralPath $stagingEtl -Force
    }
}

if (-not (Test-Path -LiteralPath $etl -PathType Leaf)) {
    $failedUtc = [DateTime]::UtcNow.ToString('o')
    $failureMessage = "WPR başarı kodu döndürdü ancak ETL oluşturulmadı: $etl"

    try {
        $session.status = 'failed'
        $session | Add-Member -MemberType NoteProperty -Name failed_utc -Value $failedUtc -Force
        $session | Add-Member -MemberType NoteProperty -Name failure_reason -Value $failureMessage -Force
        Write-NxbJsonAtomic -Path $sessionPath -InputObject $session -Depth 16
    }
    catch {
        Write-Warning "Trace session failed durumu yazılamadı: $($_.Exception.Message)"
    }

    try {
        Set-NxbExperimentState `
            -ExperimentPath $experimentFull `
            -State failed `
            -Updates @{
                failed_utc     = $failedUtc
                failure_reason = $failureMessage
            } `
            -Confirm:$false | Out-Null
    }
    catch {
        Write-Warning "Deney failed durumuna alınamadı: $($_.Exception.Message)"
    }

    throw $failureMessage
}

try {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $profileIntegrity = Get-NxbTraceProfileIntegrity `
        -Session $session `
        -RepositoryRoot $repositoryRoot
    $hash = Get-FileHash -LiteralPath $etl -Algorithm SHA256
    $stoppedUtc = [DateTime]::UtcNow.ToString('o')
    $profileSealProperty = $session.PSObject.Properties['profile_provenance_sha256']
    $profileSeal = if ($null -eq $profileSealProperty) {
        $null
    }
    else {
        [string]$profileSealProperty.Value
    }

    $traceMetadata = [ordered]@{
        path                      = $etl
        sha256                    = $hash.Hash
        length                    = (Get-Item -LiteralPath $etl).Length
        stopped_utc               = $stoppedUtc
        wpr_executable             = $wprPath
        profile                    = [string]$session.profile
        profile_provenance         = $session.profile_provenance
        profile_provenance_sha256  = $profileSeal
        profile_integrity          = $profileIntegrity
    }

    Write-NxbJsonAtomic `
        -Path (Join-Path $traces 'performance.etl.json') `
        -InputObject $traceMetadata `
        -Depth 16

    $session | Add-Member -MemberType NoteProperty -Name stopped_utc -Value $stoppedUtc -Force
    $session | Add-Member -MemberType NoteProperty -Name etl -Value $etl -Force
    $session | Add-Member `
        -MemberType NoteProperty `
        -Name profile_integrity `
        -Value $profileIntegrity `
        -Force

    if ([string]$profileIntegrity.status -cne 'valid') {
        throw "Trace profile provenance doğrulaması başarısız: $($profileIntegrity.reason)"
    }

    $session.status = 'stopped'
    Write-NxbJsonAtomic -Path $sessionPath -InputObject $session -Depth 16

    Set-NxbExperimentState `
        -ExperimentPath $experimentFull `
        -State stopped `
        -Confirm:$false | Out-Null
}
catch {
    $finalizationError = $_.Exception.Message
    $failedUtc = [DateTime]::UtcNow.ToString('o')
    $failureMessage = "WPR durdu ancak trace finalization başarısız: $finalizationError"

    try {
        $session.status = 'failed'
        $session | Add-Member -MemberType NoteProperty -Name failed_utc -Value $failedUtc -Force
        $session | Add-Member -MemberType NoteProperty -Name failure_reason -Value $failureMessage -Force
        Write-NxbJsonAtomic -Path $sessionPath -InputObject $session -Depth 16
    }
    catch {
        Write-Warning "Trace session failed durumu yazılamadı: $($_.Exception.Message)"
    }

    try {
        Set-NxbExperimentState `
            -ExperimentPath $experimentFull `
            -State failed `
            -Updates @{
                failed_utc     = $failedUtc
                failure_reason = $failureMessage
            } `
            -Confirm:$false | Out-Null
    }
    catch {
        Write-Warning "Deney failed durumuna alınamadı: $($_.Exception.Message)"
    }

    throw $failureMessage
}

Write-Host "WPR kaydı tamamlandı: $etl"
