[CmdletBinding()]
param(
    [Parameter()]
    [string]$Path = (Join-Path (Split-Path -Parent $PSScriptRoot) 'profiles\Nxb.StorageIOQueue.wprp'),

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force

function Get-NxbStorageSingleXmlNode {
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

function Get-NxbStorageRequiredAttribute {
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

function ConvertTo-NxbStoragePositiveInteger {
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

function Test-NxbStorageExactStringSet {
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

function Get-NxbStorageCollectorContract {
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

    $collector = [System.Xml.XmlElement](Get-NxbStorageSingleXmlNode `
        -Context $Profiles `
        -XPath ("./SystemCollector[@Id='{0}']" -f $Id) `
        -Label "SystemCollector $Id")

    if ((Get-NxbStorageRequiredAttribute -Element $collector -Name Name -Label $Id) -cne
        'NT Kernel Logger') {
        throw "$Id Name değeri NT Kernel Logger olmalıdır."
    }

    $bufferSizeNode = [System.Xml.XmlElement](Get-NxbStorageSingleXmlNode `
        -Context $collector `
        -XPath './BufferSize' `
        -Label "$Id BufferSize")
    $bufferSizeKiB = ConvertTo-NxbStoragePositiveInteger `
        -Value (Get-NxbStorageRequiredAttribute `
            -Element $bufferSizeNode `
            -Name Value `
            -Label "$Id BufferSize") `
        -Label "$Id BufferSize"
    if ($bufferSizeKiB -ne 1024) {
        throw "$Id BufferSize değeri 1024 KiB olmalıdır: $bufferSizeKiB"
    }

    $buffersNode = [System.Xml.XmlElement](Get-NxbStorageSingleXmlNode `
        -Context $collector `
        -XPath './Buffers' `
        -Label "$Id Buffers")
    $bufferCount = ConvertTo-NxbStoragePositiveInteger `
        -Value (Get-NxbStorageRequiredAttribute `
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
        $maximumFileSizeMiB = ConvertTo-NxbStoragePositiveInteger `
            -Value (Get-NxbStorageRequiredAttribute `
                -Element $maximumFileSizeNode `
                -Name Value `
                -Label "$Id MaximumFileSize") `
            -Label "$Id MaximumFileSize"
        if ($maximumFileSizeMiB -ne 512) {
            throw "Storage profile MaximumFileSize değeri 512 MiB olmalıdır: $maximumFileSizeMiB"
        }

        $fileMode = Get-NxbStorageRequiredAttribute `
            -Element $maximumFileSizeNode `
            -Name FileMode `
            -Label "$Id MaximumFileSize"
        if ($fileMode -cne 'Circular') {
            throw "Storage profile file mode Circular olmalıdır: $fileMode"
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

function Test-NxbStorageProfileVariant {
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

    $profileElement = [System.Xml.XmlElement](Get-NxbStorageSingleXmlNode `
        -Context $Document `
        -XPath ("/WindowsPerformanceRecorder/Profiles/Profile[@Id='{0}']" -f $Id) `
        -Label "WPR profile variant $Id")

    if ((Get-NxbStorageRequiredAttribute -Element $profileElement -Name Name -Label $Id) -cne
        'NxbStorageIOQueue') {
        throw "$Id beklenen profile name değerini taşımıyor."
    }
    if ((Get-NxbStorageRequiredAttribute -Element $profileElement -Name DetailLevel -Label $Id) -cne
        'Verbose') {
        throw "$Id yalnız Verbose detail level kullanmalıdır."
    }
    if ((Get-NxbStorageRequiredAttribute -Element $profileElement -Name LoggingMode -Label $Id) -cne
        $LoggingMode) {
        throw "$Id logging mode uyuşmuyor. Beklenen: $LoggingMode"
    }

    $collectorReference = [System.Xml.XmlElement](Get-NxbStorageSingleXmlNode `
        -Context $profileElement `
        -XPath './Collectors/SystemCollectorId' `
        -Label "$Id collector reference")
    if ((Get-NxbStorageRequiredAttribute `
        -Element $collectorReference `
        -Name Value `
        -Label "$Id collector reference") -cne $CollectorId) {
        throw "$Id beklenmeyen system collector kullanıyor. Beklenen: $CollectorId"
    }

    $providerReference = [System.Xml.XmlElement](Get-NxbStorageSingleXmlNode `
        -Context $collectorReference `
        -XPath './SystemProviderId' `
        -Label "$Id provider reference")
    if ((Get-NxbStorageRequiredAttribute `
        -Element $providerReference `
        -Name Value `
        -Label "$Id provider reference") -cne 'NxbStorageIOQueueSystemProvider') {
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
    throw "Storage WPR profile bulunamadı: $profileFull"
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
    throw "Storage WPR profile güvenli XML olarak ayrıştırılamadı: $($_.Exception.Message)"
}
finally {
    if ($null -ne $reader) {
        $reader.Dispose()
    }
}

$root = $document.DocumentElement
if ($null -eq $root -or $root.Name -cne 'WindowsPerformanceRecorder') {
    throw 'Storage WPR profile kök elementi WindowsPerformanceRecorder olmalıdır.'
}
if (-not [string]::IsNullOrEmpty($root.NamespaceURI)) {
    throw 'Storage WPR profile beklenmeyen XML namespace içeriyor.'
}
if ((Get-NxbStorageRequiredAttribute -Element $root -Name Version -Label 'WPR root') -cne '1.0') {
    throw 'Storage WPR profile Version değeri 1.0 olmalıdır.'
}

$profiles = Get-NxbStorageSingleXmlNode `
    -Context $document `
    -XPath '/WindowsPerformanceRecorder/Profiles' `
    -Label 'WPR Profiles container'

if ($profiles.SelectNodes('./SystemCollector').Count -ne 2) {
    throw 'Storage profile tam olarak iki File/Memory SystemCollector içermelidir.'
}
if ($profiles.SelectNodes('./SystemProvider').Count -ne 1) {
    throw 'Storage profile tam olarak bir SystemProvider içermelidir.'
}
if ($profiles.SelectNodes('./Profile').Count -ne 2) {
    throw 'Storage profile tam olarak iki File/Memory varyantı içermelidir.'
}
if ($profiles.SelectNodes('./EventCollector | ./EventProvider | ./HeapEventProvider').Count -ne 0) {
    throw 'Minimal storage profile ek Event veya Heap collector/provider içeremez.'
}

$fileCollector = Get-NxbStorageCollectorContract `
    -Profiles $profiles `
    -Id 'NxbStorageIOQueueSystemCollectorFile' `
    -BoundedFile
$memoryCollector = Get-NxbStorageCollectorContract `
    -Profiles $profiles `
    -Id 'NxbStorageIOQueueSystemCollectorMemory'

if ($fileCollector.BufferSizeKiB -ne $memoryCollector.BufferSizeKiB -or
    $fileCollector.Buffers -ne $memoryCollector.Buffers) {
    throw 'Storage File ve Memory collector buffer sözleşmeleri uyuşmuyor.'
}

$provider = [System.Xml.XmlElement](Get-NxbStorageSingleXmlNode `
    -Context $profiles `
    -XPath "./SystemProvider[@Id='NxbStorageIOQueueSystemProvider']" `
    -Label 'Storage SystemProvider')

$expectedKeywords = @(
    'DiskIO',
    'DiskIOInit',
    'FileIO',
    'FileIOInit',
    'Filename',
    'Loader',
    'ProcessThread',
    'SplitIO'
)
$keywordValues = @(
    foreach ($node in $provider.SelectNodes('./Keywords/Keyword')) {
        Get-NxbStorageRequiredAttribute `
            -Element ([System.Xml.XmlElement]$node) `
            -Name Value `
            -Label 'Storage SystemProvider Keyword'
    }
)
[void](Test-NxbStorageExactStringSet `
    -Actual $keywordValues `
    -Expected $expectedKeywords `
    -Label 'Storage SystemProvider keyword set')

if ($keywordValues -contains 'KernelQueue') {
    throw 'Minimal storage profile KernelQueue etkinleştiremez; storage queue semantiği ayrıca doğrulanmalıdır.'
}

$expectedStacks = @(
    'DiskFlushInit',
    'DiskReadInit',
    'DiskWriteInit',
    'FileClose',
    'FileCreate',
    'FileDelete',
    'FileFlush',
    'FileRead',
    'FileRename',
    'FileWrite',
    'SplitIO'
)
$stackValues = @(
    foreach ($node in $provider.SelectNodes('./Stacks/Stack')) {
        Get-NxbStorageRequiredAttribute `
            -Element ([System.Xml.XmlElement]$node) `
            -Name Value `
            -Label 'Storage SystemProvider Stack'
    }
)
[void](Test-NxbStorageExactStringSet `
    -Actual $stackValues `
    -Expected $expectedStacks `
    -Label 'Storage SystemProvider stack set')

[void](Test-NxbStorageProfileVariant `
    -Document $document `
    -Id 'NxbStorageIOQueue.Verbose.File' `
    -LoggingMode File `
    -CollectorId 'NxbStorageIOQueueSystemCollectorFile')
[void](Test-NxbStorageProfileVariant `
    -Document $document `
    -Id 'NxbStorageIOQueue.Verbose.Memory' `
    -LoggingMode Memory `
    -CollectorId 'NxbStorageIOQueueSystemCollectorMemory')

$profileItem = Get-Item -LiteralPath $profileFull
$relativePath = (Get-NxbRelativePath -BasePath $repositoryRoot -ChildPath $profileFull).Replace(
    [IO.Path]::DirectorySeparatorChar,
    [char]'/'
)
$profileHash = (Get-FileHash -LiteralPath $profileFull -Algorithm SHA256).Hash.ToLowerInvariant()
$result = [pscustomobject]@{
    Path = $profileFull
    RelativePath = $relativePath
    Name = 'NxbStorageIOQueue'
    DetailLevel = 'Verbose'
    FileProfileId = 'NxbStorageIOQueue.Verbose.File'
    MemoryProfileId = 'NxbStorageIOQueue.Verbose.Memory'
    FileCollectorId = [string]$fileCollector.Id
    MemoryCollectorId = [string]$memoryCollector.Id
    FileProfileReference = ('{0}!NxbStorageIOQueue.Verbose' -f $relativePath)
    Sha256 = $profileHash
    Length = [int64]$profileItem.Length
    BufferSizeKiB = [int]$fileCollector.BufferSizeKiB
    Buffers = [int]$fileCollector.Buffers
    MaximumFileSizeMiB = [int]$fileCollector.MaximumFileSizeMiB
    FileMode = [string]$fileCollector.FileMode
    Keywords = @($keywordValues)
    Stacks = @($stackValues)
    KernelQueueEnabled = $false
}

if ($PassThru) {
    return $result
}

Write-Information `
    -MessageData "Storage WPR profile valid: $profileFull" `
    -InformationAction Continue
