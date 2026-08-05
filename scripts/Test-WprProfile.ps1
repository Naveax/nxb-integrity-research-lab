[CmdletBinding()]
param(
    [Parameter()]
    [string]$Path = (Join-Path (Split-Path -Parent $PSScriptRoot) 'profiles\Nxb.MinimalCpuScheduler.wprp'),

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force

function Get-NxbSingleXmlNode {
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

function Get-NxbRequiredXmlAttribute {
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

function ConvertTo-NxbRequiredInteger {
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

function Test-NxbExactStringSet {
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

function Test-NxbProfileVariant {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Xml.XmlDocument]$Document,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Id,

        [Parameter(Mandatory)]
        [ValidateSet('File', 'Memory')]
        [string]$LoggingMode
    )

    $profile = [System.Xml.XmlElement](Get-NxbSingleXmlNode `
        -Context $Document `
        -XPath ("/WindowsPerformanceRecorder/Profiles/Profile[@Id='{0}']" -f $Id) `
        -Label "WPR profile variant $Id")

    if ((Get-NxbRequiredXmlAttribute -Element $profile -Name Name -Label $Id) -cne
        'NxbMinimalCpuScheduler') {
        throw "$Id beklenen profile name değerini taşımıyor."
    }
    if ((Get-NxbRequiredXmlAttribute -Element $profile -Name DetailLevel -Label $Id) -cne
        'Verbose') {
        throw "$Id yalnız Verbose detail level kullanmalıdır."
    }
    if ((Get-NxbRequiredXmlAttribute -Element $profile -Name LoggingMode -Label $Id) -cne
        $LoggingMode) {
        throw "$Id logging mode uyuşmuyor. Beklenen: $LoggingMode"
    }

    $collectorReference = [System.Xml.XmlElement](Get-NxbSingleXmlNode `
        -Context $profile `
        -XPath './Collectors/SystemCollectorId' `
        -Label "$Id collector reference")
    if ((Get-NxbRequiredXmlAttribute `
        -Element $collectorReference `
        -Name Value `
        -Label "$Id collector reference") -cne 'NxbMinimalCpuSchedulerSystemCollector') {
        throw "$Id beklenmeyen system collector kullanıyor."
    }

    $providerReference = [System.Xml.XmlElement](Get-NxbSingleXmlNode `
        -Context $collectorReference `
        -XPath './SystemProviderId' `
        -Label "$Id provider reference")
    if ((Get-NxbRequiredXmlAttribute `
        -Element $providerReference `
        -Name Value `
        -Label "$Id provider reference") -cne 'NxbMinimalCpuSchedulerSystemProvider') {
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
    throw "WPR profile güvenli XML olarak ayrıştırılamadı: $($_.Exception.Message)"
}
finally {
    if ($null -ne $reader) {
        $reader.Dispose()
    }
}

$root = $document.DocumentElement
if ($null -eq $root -or $root.Name -cne 'WindowsPerformanceRecorder') {
    throw 'WPR profile kök elementi WindowsPerformanceRecorder olmalıdır.'
}
if (-not [string]::IsNullOrEmpty($root.NamespaceURI)) {
    throw 'WPR profile beklenmeyen XML namespace içeriyor.'
}
if ((Get-NxbRequiredXmlAttribute -Element $root -Name Version -Label 'WPR root') -cne '1.0') {
    throw 'WPR profile Version değeri 1.0 olmalıdır.'
}

$profiles = Get-NxbSingleXmlNode `
    -Context $document `
    -XPath '/WindowsPerformanceRecorder/Profiles' `
    -Label 'WPR Profiles container'

$collectorNodes = $profiles.SelectNodes('./SystemCollector')
if ($collectorNodes.Count -ne 1) {
    throw "Minimal profile tam olarak bir SystemCollector içermelidir; bulunan: $($collectorNodes.Count)"
}
$collector = [System.Xml.XmlElement]$collectorNodes.Item(0)
if ((Get-NxbRequiredXmlAttribute -Element $collector -Name Id -Label 'SystemCollector') -cne
    'NxbMinimalCpuSchedulerSystemCollector') {
    throw 'Minimal profile beklenmeyen SystemCollector Id içeriyor.'
}
if ((Get-NxbRequiredXmlAttribute -Element $collector -Name Name -Label 'SystemCollector') -cne
    'NT Kernel Logger') {
    throw 'Minimal profile SystemCollector Name değeri NT Kernel Logger olmalıdır.'
}

$bufferSizeNode = [System.Xml.XmlElement](Get-NxbSingleXmlNode `
    -Context $collector `
    -XPath './BufferSize' `
    -Label 'SystemCollector BufferSize')
$bufferSizeKiB = ConvertTo-NxbRequiredInteger `
    -Value (Get-NxbRequiredXmlAttribute -Element $bufferSizeNode -Name Value -Label 'BufferSize') `
    -Label 'BufferSize'
if ($bufferSizeKiB -ne 1024) {
    throw "Minimal profile BufferSize değeri 1024 KiB olmalıdır: $bufferSizeKiB"
}

$buffersNode = [System.Xml.XmlElement](Get-NxbSingleXmlNode `
    -Context $collector `
    -XPath './Buffers' `
    -Label 'SystemCollector Buffers')
$bufferCount = ConvertTo-NxbRequiredInteger `
    -Value (Get-NxbRequiredXmlAttribute -Element $buffersNode -Name Value -Label 'Buffers') `
    -Label 'Buffers'
if ($bufferCount -ne 64) {
    throw "Minimal profile Buffers değeri 64 olmalıdır: $bufferCount"
}

$maximumFileSizeNode = [System.Xml.XmlElement](Get-NxbSingleXmlNode `
    -Context $collector `
    -XPath './MaximumFileSize' `
    -Label 'SystemCollector MaximumFileSize')
$maximumFileSizeMiB = ConvertTo-NxbRequiredInteger `
    -Value (Get-NxbRequiredXmlAttribute `
        -Element $maximumFileSizeNode `
        -Name Value `
        -Label 'MaximumFileSize') `
    -Label 'MaximumFileSize'
if ($maximumFileSizeMiB -ne 512) {
    throw "Minimal profile MaximumFileSize değeri 512 MiB olmalıdır: $maximumFileSizeMiB"
}
$fileMode = Get-NxbRequiredXmlAttribute `
    -Element $maximumFileSizeNode `
    -Name FileMode `
    -Label 'MaximumFileSize'
if ($fileMode -cne 'Circular') {
    throw "Minimal profile file mode Circular olmalıdır: $fileMode"
}

$providerNodes = $profiles.SelectNodes('./SystemProvider')
if ($providerNodes.Count -ne 1) {
    throw "Minimal profile tam olarak bir SystemProvider içermelidir; bulunan: $($providerNodes.Count)"
}
$provider = [System.Xml.XmlElement]$providerNodes.Item(0)
if ((Get-NxbRequiredXmlAttribute -Element $provider -Name Id -Label 'SystemProvider') -cne
    'NxbMinimalCpuSchedulerSystemProvider') {
    throw 'Minimal profile beklenmeyen SystemProvider Id içeriyor.'
}

$expectedKeywords = @(
    'CpuConfig',
    'CSwitch',
    'DPC',
    'Interrupt',
    'KernelQueue',
    'Loader',
    'ProcessThread',
    'ReadyThread',
    'SampledProfile',
    'ThreadPriority'
)
$keywordValues = @(
    foreach ($node in $provider.SelectNodes('./Keywords/Keyword')) {
        Get-NxbRequiredXmlAttribute `
            -Element ([System.Xml.XmlElement]$node) `
            -Name Value `
            -Label 'SystemProvider Keyword'
    }
)
[void](Test-NxbExactStringSet `
    -Actual $keywordValues `
    -Expected $expectedKeywords `
    -Label 'SystemProvider keyword set')

$expectedStacks = @(
    'CSwitch',
    'DpcExecute',
    'ImageLoad',
    'ProcessCreate',
    'ReadyThread',
    'SampledProfile',
    'ThreadCreate',
    'ThreadSetBasePriority',
    'ThreadSetPriority'
)
$stackValues = @(
    foreach ($node in $provider.SelectNodes('./Stacks/Stack')) {
        Get-NxbRequiredXmlAttribute `
            -Element ([System.Xml.XmlElement]$node) `
            -Name Value `
            -Label 'SystemProvider Stack'
    }
)
[void](Test-NxbExactStringSet `
    -Actual $stackValues `
    -Expected $expectedStacks `
    -Label 'SystemProvider stack set')

$profileNodes = $profiles.SelectNodes('./Profile')
if ($profileNodes.Count -ne 2) {
    throw "Minimal profile tam olarak iki File/Memory varyantı içermelidir; bulunan: $($profileNodes.Count)"
}

[void](Test-NxbProfileVariant `
    -Document $document `
    -Id 'NxbMinimalCpuScheduler.Verbose.File' `
    -LoggingMode File)
[void](Test-NxbProfileVariant `
    -Document $document `
    -Id 'NxbMinimalCpuScheduler.Verbose.Memory' `
    -LoggingMode Memory)

$profileItem = Get-Item -LiteralPath $profileFull
$relativePath = (Get-NxbRelativePath -BasePath $repositoryRoot -ChildPath $profileFull).Replace(
    [IO.Path]::DirectorySeparatorChar,
    [char]'/'
)
$profileHash = (Get-FileHash -LiteralPath $profileFull -Algorithm SHA256).Hash.ToLowerInvariant()
$result = [pscustomobject]@{
    Path = $profileFull
    RelativePath = $relativePath
    Name = 'NxbMinimalCpuScheduler'
    DetailLevel = 'Verbose'
    FileProfileId = 'NxbMinimalCpuScheduler.Verbose.File'
    MemoryProfileId = 'NxbMinimalCpuScheduler.Verbose.Memory'
    FileProfileReference = ('{0}!NxbMinimalCpuScheduler.Verbose' -f $profileFull)
    Sha256 = $profileHash
    Length = [int64]$profileItem.Length
    BufferSizeKiB = $bufferSizeKiB
    Buffers = $bufferCount
    MaximumFileSizeMiB = $maximumFileSizeMiB
    FileMode = $fileMode
    Keywords = $expectedKeywords
    Stacks = $expectedStacks
}

if ($PassThru) {
    return $result
}

Write-Host "WPR profile sözleşmesi geçerli: $relativePath"
