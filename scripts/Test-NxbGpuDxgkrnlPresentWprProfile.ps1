[CmdletBinding()]
param(
    [Parameter()]
    [string]$Path = (Join-Path (Split-Path -Parent $PSScriptRoot) 'profiles\Nxb.GpuDxgkrnlPresent.wprp'),

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NxbGpuProfileNode {
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
        throw "$Label must occur exactly once; found $count."
    }
    return $nodes.Item(0)
}

function Get-NxbGpuProfileAttribute {
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
        throw "$Label requires attribute '$Name'."
    }
    return $value
}

function Test-NxbGpuExactSet {
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

    $actualSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($value in $Actual) {
        if (-not $actualSet.Add($value)) {
            throw "$Label contains duplicate value: $value"
        }
    }

    $expectedSet = [Collections.Generic.HashSet[string]]::new($Expected,[StringComparer]::OrdinalIgnoreCase)
    if ($actualSet.Count -ne $expectedSet.Count) {
        throw "$Label count mismatch. Expected $($expectedSet.Count), found $($actualSet.Count)."
    }
    foreach ($value in $Expected) {
        if (-not $actualSet.Contains($value)) {
            throw "$Label missing required value: $value"
        }
    }
    return $true
}

$fullPath = [IO.Path]::GetFullPath($Path)
if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    throw "GPU WPR profile not found: $fullPath"
}

$settings = [System.Xml.XmlReaderSettings]::new()
$settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
$settings.XmlResolver = $null
$reader = $null
$document = [System.Xml.XmlDocument]::new()
$document.XmlResolver = $null
try {
    $reader = [System.Xml.XmlReader]::Create($fullPath,$settings)
    $document.Load($reader)
}
finally {
    if ($null -ne $reader) { $reader.Dispose() }
}

$root = $document.DocumentElement
if ($null -eq $root -or $root.Name -cne 'WindowsPerformanceRecorder') {
    throw 'GPU WPR profile root must be WindowsPerformanceRecorder.'
}
if ((Get-NxbGpuProfileAttribute -Element $root -Name Version -Label 'WPR root') -cne '1.0') {
    throw 'GPU WPR profile Version must be 1.0.'
}

$profiles = Get-NxbGpuProfileNode -Context $document -XPath '/WindowsPerformanceRecorder/Profiles' -Label 'Profiles'
if ($profiles.SelectNodes('./EventCollector').Count -ne 2) {
    throw 'GPU profile must define exactly two event collectors.'
}
if ($profiles.SelectNodes('./EventProvider').Count -ne 2) {
    throw 'GPU profile must define exactly two event providers.'
}
if ($profiles.SelectNodes('./Profile').Count -ne 2) {
    throw 'GPU profile must define exactly two File/Memory variants.'
}
if ($profiles.SelectNodes('./SystemCollector | ./SystemProvider | ./HeapEventProvider').Count -ne 0) {
    throw 'GPU foundation profile must not enable unrelated system or heap providers.'
}

$fileCollector = [System.Xml.XmlElement](Get-NxbGpuProfileNode -Context $profiles -XPath "./EventCollector[@Id='NxbGpuDxgkrnlPresentEventCollectorFile']" -Label 'file collector')
$memoryCollector = [System.Xml.XmlElement](Get-NxbGpuProfileNode -Context $profiles -XPath "./EventCollector[@Id='NxbGpuDxgkrnlPresentEventCollectorMemory']" -Label 'memory collector')
foreach ($collector in @($fileCollector,$memoryCollector)) {
    $bufferSize = [System.Xml.XmlElement](Get-NxbGpuProfileNode -Context $collector -XPath './BufferSize' -Label 'BufferSize')
    $buffers = [System.Xml.XmlElement](Get-NxbGpuProfileNode -Context $collector -XPath './Buffers' -Label 'Buffers')
    if ([int](Get-NxbGpuProfileAttribute -Element $bufferSize -Name Value -Label 'BufferSize') -ne 256) {
        throw 'GPU collector BufferSize must be 256 KiB.'
    }
    if ([int](Get-NxbGpuProfileAttribute -Element $buffers -Name Value -Label 'Buffers') -ne 64) {
        throw 'GPU collector Buffers must be 64.'
    }
}

$maxNode = [System.Xml.XmlElement](Get-NxbGpuProfileNode -Context $fileCollector -XPath './MaximumFileSize' -Label 'MaximumFileSize')
if ([int](Get-NxbGpuProfileAttribute -Element $maxNode -Name Value -Label 'MaximumFileSize') -ne 256) {
    throw 'GPU file profile MaximumFileSize must be 256 MiB.'
}
if ((Get-NxbGpuProfileAttribute -Element $maxNode -Name FileMode -Label 'MaximumFileSize') -cne 'Circular') {
    throw 'GPU file profile must use Circular file mode.'
}
if ($memoryCollector.SelectNodes('./MaximumFileSize').Count -ne 0) {
    throw 'GPU memory collector must not define MaximumFileSize.'
}

$dxg = [System.Xml.XmlElement](Get-NxbGpuProfileNode -Context $profiles -XPath "./EventProvider[@Id='NxbGpuDxgKrnlEventProvider']" -Label 'DxgKrnl provider')
$dxgi = [System.Xml.XmlElement](Get-NxbGpuProfileNode -Context $profiles -XPath "./EventProvider[@Id='NxbGpuDxgiEventProvider']" -Label 'DXGI provider')
if ((Get-NxbGpuProfileAttribute -Element $dxg -Name Name -Label 'DxgKrnl provider') -cne 'Microsoft-Windows-DxgKrnl') {
    throw 'Unexpected DxgKrnl provider name.'
}
if ((Get-NxbGpuProfileAttribute -Element $dxgi -Name Name -Label 'DXGI provider') -cne 'Microsoft-Windows-DXGI') {
    throw 'Unexpected DXGI provider name.'
}
foreach ($provider in @($dxg,$dxgi)) {
    if ((Get-NxbGpuProfileAttribute -Element $provider -Name Strict -Label 'GPU provider') -cne 'true') {
        throw 'GPU providers must be Strict=true for fail-closed capture.'
    }
    if ($provider.HasAttribute('Stack') -and $provider.GetAttribute('Stack') -ceq 'true') {
        throw 'GPU foundation profile must not capture provider-wide stacks.'
    }
}

$dxgKeywords = @($dxg.SelectNodes('./Keywords/Keyword') | ForEach-Object { $_.GetAttribute('Value') })
[void](Test-NxbGpuExactSet -Actual $dxgKeywords -Expected @(
    '0x0000000000008000',
    '0x0000000000010000',
    '0x0000000008000000'
) -Label 'DxgKrnl keyword set')

$dxgiKeywords = @($dxgi.SelectNodes('./Keywords/Keyword') | ForEach-Object { $_.GetAttribute('Value') })
[void](Test-NxbGpuExactSet -Actual $dxgiKeywords -Expected @('0x0000000000000002') -Label 'DXGI keyword set')

foreach ($variant in @(
    @{ Id='NxbGpuDxgkrnlPresent.Verbose.File'; Mode='File'; Collector='NxbGpuDxgkrnlPresentEventCollectorFile' },
    @{ Id='NxbGpuDxgkrnlPresent.Verbose.Memory'; Mode='Memory'; Collector='NxbGpuDxgkrnlPresentEventCollectorMemory' }
)) {
    $profileNode = [System.Xml.XmlElement](Get-NxbGpuProfileNode -Context $profiles -XPath ("./Profile[@Id='{0}']" -f $variant.Id) -Label $variant.Id)
    if ((Get-NxbGpuProfileAttribute -Element $profileNode -Name Name -Label $variant.Id) -cne 'NxbGpuDxgkrnlPresent') {
        throw "$($variant.Id) unexpected profile Name."
    }
    if ((Get-NxbGpuProfileAttribute -Element $profileNode -Name DetailLevel -Label $variant.Id) -cne 'Verbose') {
        throw "$($variant.Id) must be Verbose."
    }
    if ((Get-NxbGpuProfileAttribute -Element $profileNode -Name LoggingMode -Label $variant.Id) -cne $variant.Mode) {
        throw "$($variant.Id) logging mode mismatch."
    }
    $collectorRef = [System.Xml.XmlElement](Get-NxbGpuProfileNode -Context $profileNode -XPath './Collectors/EventCollectorId' -Label "$($variant.Id) collector")
    if ($collectorRef.GetAttribute('Value') -cne $variant.Collector) {
        throw "$($variant.Id) collector reference mismatch."
    }
    $providerIds = @($collectorRef.SelectNodes('./EventProviders/EventProviderId') | ForEach-Object { $_.GetAttribute('Value') })
    [void](Test-NxbGpuExactSet -Actual $providerIds -Expected @('NxbGpuDxgKrnlEventProvider','NxbGpuDxgiEventProvider') -Label "$($variant.Id) provider references")
}

$sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
$result = [pscustomobject][ordered]@{
    status = 'passed'
    path = $fullPath
    sha256 = $sha256
    profile_name = 'NxbGpuDxgkrnlPresent'
    file_profile = 'NxbGpuDxgkrnlPresent.Verbose.File'
    memory_profile = 'NxbGpuDxgkrnlPresent.Verbose.Memory'
    buffer_size_kib = 256
    buffers = 64
    maximum_file_size_mib = 256
    file_mode = 'Circular'
    dxgkrnl_keywords = @($dxgKeywords)
    dxgi_keywords = @($dxgiKeywords)
    claims = [ordered]@{
        keyword_identity_observed = $true
        keyword_semantics_validated = $false
        event_ids_validated = $false
        event_payload_contract_validated = $false
        present_semantics = $false
        submission_semantics = $false
        queue_context_semantics = $false
        queue_wait_semantics = $false
        gpu_execution_duration_semantics = $false
        trace_completeness = 'not_claimed'
    }
}

if ($PassThru) { return $result }
Write-Information -MessageData "GPU DXGKRNL present WPR profile contract passed: $sha256" -InformationAction Continue
