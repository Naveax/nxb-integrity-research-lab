[CmdletBinding()]
param(
    [Parameter()]
    [string]$Path = (Join-Path (Split-Path -Parent $PSScriptRoot) 'profiles\Nxb.MemoryWorkingSet.wprp'),

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force

function Get-NxbMemorySingleXmlNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Xml.XmlNode]$Context,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$XPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Label
    )

    $nodes = $Context.SelectNodes($XPath)
    if ($null -eq $nodes -or $nodes.Count -ne 1) {
        $count = if ($null -eq $nodes) { 0 } else { $nodes.Count }
        throw "$Label tam olarak bir kez bulunmalıdır; bulunan: $count"
    }

    return $nodes.Item(0)
}

function Get-NxbMemoryRequiredAttribute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Xml.XmlElement]$Element,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Label
    )

    $value = $Element.GetAttribute($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "$Label için '$Name' özniteliği zorunludur."
    }

    return $value
}

function ConvertTo-NxbMemoryPositiveInteger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Value,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Label
    )

    $parsed = 0
    if (-not [int]::TryParse(
        $Value,
        [Globalization.NumberStyles]::None,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$parsed
    )) {
        throw "$Label geçerli bir pozitif tam sayı değil: $Value"
    }
    if ($parsed -le 0) {
        throw "$Label sıfırdan büyük olmalıdır: $parsed"
    }

    return $parsed
}

function Test-NxbMemoryExactStringSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Actual,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Expected,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Label
    )

    $actualSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($value in $Actual) {
        if (-not $actualSet.Add($value)) {
            throw "$Label yinelenen değer içeriyor: $value"
        }
    }

    $expectedSet = [Collections.Generic.HashSet[string]]::new(
        $Expected,
        [StringComparer]::Ordinal
    )
    if ($actualSet.Count -ne $expectedSet.Count) {
        throw "$Label öğe sayısı uyuşmuyor. Beklenen: $($expectedSet.Count), bulunan: $($actualSet.Count)"
    }

    foreach ($value in $Expected) {
        if (-not $actualSet.Contains($value)) {
            throw "$Label zorunlu değeri içermiyor: $value"
        }
    }

    return $true
}

function Get-NxbMemoryCollectorContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Xml.XmlNode]$Profiles,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Id,

        [Parameter()]
        [switch]$BoundedFile
    )

    $collector = [System.Xml.XmlElement](Get-NxbMemorySingleXmlNode `
        -Context $Profiles `
        -XPath ("./SystemCollector[@Id='{0}']" -f $Id) `
        -Label "SystemCollector $Id")

    if ((Get-NxbMemoryRequiredAttribute -Element $collector -Name Name -Label $Id) -cne
        'NT Kernel Logger') {
        throw "$Id Name değeri NT Kernel Logger olmalıdır."
    }

    $bufferSizeNode = [System.Xml.XmlElement](Get-NxbMemorySingleXmlNode `
        -Context $collector `
        -XPath './BufferSize' `
        -Label "$Id BufferSize")
    $bufferSizeKiB = ConvertTo-NxbMemoryPositiveInteger `
        -Value (Get-NxbMemoryRequiredAttribute `
            -Element $bufferSizeNode `
            -Name Value `
            -Label "$Id BufferSize") `
        -Label "$Id BufferSize"
    if ($bufferSizeKiB -ne 1024) {
        throw "$Id BufferSize değeri 1024 KiB olmalıdır: $bufferSizeKiB"
    }

    $buffersNode = [System.Xml.XmlElement](Get-NxbMemorySingleXmlNode `
        -Context $collector `
        -XPath './Buffers' `
        -Label "$Id Buffers")
    $bufferCount = ConvertTo-NxbMemoryPositiveInteger `
        -Value (Get-NxbMemoryRequiredAttribute `
            -Element $buffersNode `
            -Name Value `
            -Label "$Id Buffers") `
        -Label "$Id Buffers"
    if ($bufferCount -ne 64) {
        throw "$Id Buffers değeri 64 olmalıdır: $bufferCount"
    }

    $maximumFileSizeMiB = $null
    $fileMode = $null
    $maximumFileSizeNodes = $collector.SelectNodes('./MaximumFileSize')
    if ($BoundedFile) {
        if ($maximumFileSizeNodes.Count -ne 1) {
            throw "$Id tam olarak bir MaximumFileSize içermelidir."
        }

        $maximumFileSizeNode = [System.Xml.XmlElement]$maximumFileSizeNodes.Item(0)
        $maximumFileSizeMiB = ConvertTo-NxbMemoryPositiveInteger `
            -Value (Get-NxbMemoryRequiredAttribute `
                -Element $maximumFileSizeNode `
                -Name Value `
                -Label "$Id MaximumFileSize") `
            -Label "$Id MaximumFileSize"
        if ($maximumFileSizeMiB -ne 512) {
            throw "Memory profile MaximumFileSize değeri 512 MiB olmalıdır: $maximumFileSizeMiB"
        }

        $fileMode = Get-NxbMemoryRequiredAttribute `
            -Element $maximumFileSizeNode `
            -Name FileMode `
            -Label "$Id MaximumFileSize"
        if ($fileMode -cne 'Circular') {
            throw "Memory profile file mode Circular olmalıdır: $fileMode"
        }
    }
    elseif ($maximumFileSizeNodes.Count -ne 0) {
        throw "$Id memory collector MaximumFileSize içeremez."
    }

    return [pscustomobject]@{
        Id = $Id
        BufferSizeKiB = $bufferSizeKiB
        Buffers = $bufferCount
        MaximumFileSizeMiB = $maximumFileSizeMiB
        FileMode = $fileMode
    }
}

function Test-NxbMemoryProfileVariant {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Xml.XmlDocument]$Document,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Id,

        [Parameter(Mandatory)]
        [ValidateSet('File', 'Memory')]
        [string]$LoggingMode,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CollectorId
    )

    $profileElement = [System.Xml.XmlElement](Get-NxbMemorySingleXmlNode `
        -Context $Document `
        -XPath ("/WindowsPerformanceRecorder/Profiles/Profile[@Id='{0}']" -f $Id) `
        -Label "WPR profile variant $Id")

    if ((Get-NxbMemoryRequiredAttribute -Element $profileElement -Name Name -Label $Id) -cne
        'NxbMemoryWorkingSet') {
        throw "$Id beklenen profile name değerini taşımıyor."
    }
    if ((Get-NxbMemoryRequiredAttribute -Element $profileElement -Name DetailLevel -Label $Id) -cne
        'Verbose') {
        throw "$Id yalnız Verbose detail level kullanmalıdır."
    }
    if ((Get-NxbMemoryRequiredAttribute -Element $profileElement -Name LoggingMode -Label $Id) -cne
        $LoggingMode) {
        throw "$Id logging mode uyuşmuyor. Beklenen: $LoggingMode"
    }

    $collectorReference = [System.Xml.XmlElement](Get-NxbMemorySingleXmlNode `
        -Context $profileElement `
        -XPath './Collectors/SystemCollectorId' `
        -Label "$Id collector reference")
    if ((Get-NxbMemoryRequiredAttribute `
        -Element $collectorReference `
        -Name Value `
        -Label "$Id collector reference") -cne $CollectorId) {
        throw "$Id beklenmeyen system collector kullanıyor. Beklenen: $CollectorId"
    }

    $providerReference = [System.Xml.XmlElement](Get-NxbMemorySingleXmlNode `
        -Context $collectorReference `
        -XPath './SystemProviderId' `
        -Label "$Id provider reference")
    if ((Get-NxbMemoryRequiredAttribute `
        -Element $providerReference `
        -Name Value `
        -Label "$Id provider reference") -cne 'NxbMemoryWorkingSetSystemProvider') {
        throw "$Id beklenmeyen system provider kullanıyor."
    }

    return $true
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$profilesRoot = Join-Path $repositoryRoot 'profiles'
$profileFull = Get-NxbFullPath -Path $Path

if (-not (Test-Path -LiteralPath $profilesRoot -PathType Container)) {
    throw "Repository profile kökü bulunamadı: $profilesRoot"
}
if (-not (Test-Path -LiteralPath $profileFull -PathType Leaf)) {
    throw "WPR profile bulunamadı: $profileFull"
}

[void](Get-NxbRelativePath -BasePath $profilesRoot -ChildPath $profileFull)
[void](Test-NxbPathSafety -Path $profileFull -RootPath $profilesRoot)

$settings = [System.Xml.XmlReaderSettings]::new()
$settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
$settings.XmlResolver = $null
$reader = $null
$document = [System.Xml.XmlDocument]::new()
$document.XmlResolver = $null
try {
    $reader = [System.Xml.XmlReader]::Create($profileFull, $settings)
    $document.Load($reader)
}
catch {
    throw "Memory WPR profile güvenli XML olarak ayrıştırılamadı: $($_.Exception.Message)"
}
finally {
    if ($null -ne $reader) {
        $reader.Dispose()
    }
}

$root = $document.DocumentElement
if ($null -eq $root -or $root.Name -cne 'WindowsPerformanceRecorder') {
    throw 'Memory WPR profile kök elementi WindowsPerformanceRecorder olmalıdır.'
}
if (-not [string]::IsNullOrEmpty($root.NamespaceURI)) {
    throw 'Memory WPR profile beklenmeyen XML namespace içeriyor.'
}
if ((Get-NxbMemoryRequiredAttribute -Element $root -Name Version -Label 'WPR root') -cne '1.0') {
    throw 'Memory WPR profile Version değeri 1.0 olmalıdır.'
}

$profiles = Get-NxbMemorySingleXmlNode `
    -Context $document `
    -XPath '/WindowsPerformanceRecorder/Profiles' `
    -Label 'WPR Profiles container'

if ($profiles.SelectNodes('./SystemCollector').Count -ne 2) {
    throw 'Memory profile tam olarak iki File/Memory SystemCollector içermelidir.'
}
if ($profiles.SelectNodes('./SystemProvider').Count -ne 1) {
    throw 'Memory profile tam olarak bir SystemProvider içermelidir.'
}
if ($profiles.SelectNodes('./Profile').Count -ne 2) {
    throw 'Memory profile tam olarak iki File/Memory varyantı içermelidir.'
}
if ($profiles.SelectNodes('./EventCollector | ./EventProvider | ./HeapEventProvider').Count -ne 0) {
    throw 'Minimal memory profile ek Event veya Heap collector/provider içeremez.'
}

$fileCollector = Get-NxbMemoryCollectorContract `
    -Profiles $profiles `
    -Id 'NxbMemoryWorkingSetSystemCollectorFile' `
    -BoundedFile
$memoryCollector = Get-NxbMemoryCollectorContract `
    -Profiles $profiles `
    -Id 'NxbMemoryWorkingSetSystemCollectorMemory'

if ($fileCollector.BufferSizeKiB -ne $memoryCollector.BufferSizeKiB -or
    $fileCollector.Buffers -ne $memoryCollector.Buffers) {
    throw 'Memory File ve Memory collector buffer sözleşmeleri uyuşmuyor.'
}

$provider = [System.Xml.XmlElement](Get-NxbMemorySingleXmlNode `
    -Context $profiles `
    -XPath "./SystemProvider[@Id='NxbMemoryWorkingSetSystemProvider']" `
    -Label 'Memory SystemProvider')

$expectedKeywords = @(
    'AllFaults',
    'CpuConfig',
    'HardFaults',
    'Loader',
    'Memory',
    'MemoryInfo',
    'MemoryInfoWS',
    'ProcessCounter',
    'ProcessThread',
    'VAMap',
    'VirtualAllocation'
)
$keywordValues = @(
    foreach ($node in $provider.SelectNodes('./Keywords/Keyword')) {
        Get-NxbMemoryRequiredAttribute `
            -Element ([System.Xml.XmlElement]$node) `
            -Name Value `
            -Label 'Memory SystemProvider Keyword'
    }
)
[void](Test-NxbMemoryExactStringSet `
    -Actual $keywordValues `
    -Expected $expectedKeywords `
    -Label 'Memory SystemProvider keyword set')

if ($keywordValues -contains 'ReferenceSet') {
    throw 'Minimal memory profile ReferenceSet etkinleştiremez.'
}

$expectedStacks = @(
    'HardFault',
    'ImageLoad',
    'PagefaultHard',
    'PagefileMappedSectionCreate',
    'PagefileMappedSectionDelete',
    'ProcessCreate',
    'UnMapFile',
    'VirtualAllocation',
    'VirtualFree'
)
$stackValues = @(
    foreach ($node in $provider.SelectNodes('./Stacks/Stack')) {
        Get-NxbMemoryRequiredAttribute `
            -Element ([System.Xml.XmlElement]$node) `
            -Name Value `
            -Label 'Memory SystemProvider Stack'
    }
)
[void](Test-NxbMemoryExactStringSet `
    -Actual $stackValues `
    -Expected $expectedStacks `
    -Label 'Memory SystemProvider stack set')

[void](Test-NxbMemoryProfileVariant `
    -Document $document `
    -Id 'NxbMemoryWorkingSet.Verbose.File' `
    -LoggingMode File `
    -CollectorId 'NxbMemoryWorkingSetSystemCollectorFile')
[void](Test-NxbMemoryProfileVariant `
    -Document $document `
    -Id 'NxbMemoryWorkingSet.Verbose.Memory' `
    -LoggingMode Memory `
    -CollectorId 'NxbMemoryWorkingSetSystemCollectorMemory')

$profileItem = Get-Item -LiteralPath $profileFull
$relativePath = (Get-NxbRelativePath -BasePath $repositoryRoot -ChildPath $profileFull).Replace(
    [IO.Path]::DirectorySeparatorChar,
    [char]'/'
)
$profileHash = (Get-FileHash -LiteralPath $profileFull -Algorithm SHA256).Hash.ToLowerInvariant()
$result = [pscustomobject]@{
    Path = $profileFull
    RelativePath = $relativePath
    Name = 'NxbMemoryWorkingSet'
    DetailLevel = 'Verbose'
    FileProfileId = 'NxbMemoryWorkingSet.Verbose.File'
    MemoryProfileId = 'NxbMemoryWorkingSet.Verbose.Memory'
    FileCollectorId = [string]$fileCollector.Id
    MemoryCollectorId = [string]$memoryCollector.Id
    FileProfileReference = ('{0}!NxbMemoryWorkingSet.Verbose' -f $relativePath)
    Sha256 = $profileHash
    Length = [int64]$profileItem.Length
    BufferSizeKiB = [int]$fileCollector.BufferSizeKiB
    Buffers = [int]$fileCollector.Buffers
    MaximumFileSizeMiB = [int]$fileCollector.MaximumFileSizeMiB
    FileMode = [string]$fileCollector.FileMode
    Keywords = @($keywordValues)
    Stacks = @($stackValues)
    ReferenceSetEnabled = $false
}

if ($PassThru) {
    return $result
}

Write-Host "Memory WPR profile valid: $profileFull"
