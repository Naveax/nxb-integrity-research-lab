[CmdletBinding()]
param(
    [Parameter()]
    [string]$Path,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NxbAttr {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Xml.XmlNode]$Node,
        [Parameter(Mandatory)][string]$Name
    )
    $attribute = $Node.Attributes[$Name]
    if ($null -eq $attribute) { return $null }
    return [string]$attribute.Value
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$profilesRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot 'profiles')).TrimEnd('\') + '\'
if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = Join-Path $repositoryRoot 'profiles\Nxb.Superblock1MultiDomain.wprp'
}
$profileFull = [IO.Path]::GetFullPath($Path)
if (-not $profileFull.StartsWith($profilesRoot,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'SUPERBLOCK multi-domain profile must remain under the repository profiles root.'
}
if (-not (Test-Path -LiteralPath $profileFull -PathType Leaf)) {
    throw "SUPERBLOCK multi-domain profile not found: $profileFull"
}
$item = Get-Item -LiteralPath $profileFull -Force
if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'SUPERBLOCK multi-domain profile cannot be reached through a reparse point.'
}
$raw = [IO.File]::ReadAllText($profileFull)
if ($raw -match '(?i)<!DOCTYPE|<!ENTITY') {
    throw 'DTD/entity declarations are not allowed in the SUPERBLOCK multi-domain profile.'
}

$settings = [Xml.XmlReaderSettings]::new()
$settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
$settings.XmlResolver = $null
$reader = [Xml.XmlReader]::Create($profileFull,$settings)
try {
    $document = [Xml.XmlDocument]::new()
    $document.PreserveWhitespace = $true
    $document.XmlResolver = $null
    $document.Load($reader)
}
finally {
    $reader.Dispose()
}

$systemCollectors = @($document.SelectNodes('//Profiles/SystemCollector'))
$eventCollectors = @($document.SelectNodes('//Profiles/EventCollector'))
if ($systemCollectors.Count -ne 2 -or $eventCollectors.Count -ne 2) {
    throw 'SUPERBLOCK profile must define exactly two system and two event collectors.'
}
foreach ($collector in @($systemCollectors) + @($eventCollectors)) {
    $id = Get-NxbAttr $collector 'Id'
    $buffer = $collector.SelectSingleNode('./BufferSize')
    $buffers = $collector.SelectSingleNode('./Buffers')
    if ((Get-NxbAttr $buffer 'Value') -cne '256' -or (Get-NxbAttr $buffers 'Value') -cne '64') {
        throw "Unexpected buffer contract for collector $id."
    }
    $maximum = $collector.SelectSingleNode('./MaximumFileSize')
    if ($id -like '*File') {
        if ($null -eq $maximum -or
            (Get-NxbAttr $maximum 'Value') -cne '128' -or
            (Get-NxbAttr $maximum 'FileMode') -cne 'Circular') {
            throw "File collector $id is not bounded to 128 MiB circular mode."
        }
    }
    elseif ($null -ne $maximum) {
        throw "Memory collector $id must not carry a file-size bound."
    }
}

$systemProviders = @($document.SelectNodes('//Profiles/SystemProvider'))
if ($systemProviders.Count -ne 1 -or
    (Get-NxbAttr $systemProviders[0] 'Id') -cne 'NxbSuperblock1SystemProvider') {
    throw 'SUPERBLOCK profile must define one canonical SystemProvider.'
}
$systemKeywords = @(
    $systemProviders[0].SelectNodes('./Keywords/Keyword') |
        ForEach-Object { Get-NxbAttr $_ 'Value' } |
        Sort-Object
)
$expectedSystemKeywords = @('Loader','NetworkTrace','ProcessThread','Registry') | Sort-Object
if (($systemKeywords -join "`n") -cne ($expectedSystemKeywords -join "`n")) {
    throw 'SUPERBLOCK SystemProvider keyword set drifted.'
}
if (@($systemProviders[0].SelectNodes('./Stacks/Stack')).Count -ne 0) {
    throw 'SUPERBLOCK foundation profile must not enable stack capture.'
}

$eventProviders = @($document.SelectNodes('//Profiles/EventProvider'))
$expectedProviderNames = @(
    'Microsoft-Windows-DxgKrnl',
    'Microsoft-Windows-DXGI',
    'Microsoft-Windows-Kernel-Network',
    'Microsoft-Windows-Winsock-AFD',
    'Microsoft-Windows-DNS-Client',
    'Microsoft-Windows-Kernel-Process',
    'Microsoft-Windows-Kernel-Registry',
    'Microsoft-Windows-Kernel-PnP'
) | Sort-Object
$providerNames = @($eventProviders | ForEach-Object { Get-NxbAttr $_ 'Name' } | Sort-Object)
if (($providerNames -join "`n") -cne ($expectedProviderNames -join "`n")) {
    throw 'SUPERBLOCK event-provider identity set drifted.'
}
foreach ($provider in $eventProviders) {
    if ((Get-NxbAttr $provider 'Strict') -cne 'false') {
        throw "Combined provider $(Get-NxbAttr $provider 'Name') must remain Strict=false; native enableability is measured by the separate enable matrix."
    }
}

$dxg = @($eventProviders | Where-Object { (Get-NxbAttr $_ 'Name') -ceq 'Microsoft-Windows-DxgKrnl' })[0]
$dxgi = @($eventProviders | Where-Object { (Get-NxbAttr $_ 'Name') -ceq 'Microsoft-Windows-DXGI' })[0]
$dxgKeywords = @($dxg.SelectNodes('./Keywords/Keyword') | ForEach-Object { Get-NxbAttr $_ 'Value' } | Sort-Object)
$expectedDxg = @('0x0000000000008000','0x0000000000010000','0x0000000008000000') | Sort-Object
if (($dxgKeywords -join "`n") -cne ($expectedDxg -join "`n")) {
    throw 'Certified DxgKrnl keyword identities drifted.'
}
$dxgiKeywords = @($dxgi.SelectNodes('./Keywords/Keyword') | ForEach-Object { Get-NxbAttr $_ 'Value' })
if ($dxgiKeywords.Count -ne 1 -or $dxgiKeywords[0] -cne '0x0000000000000002') {
    throw 'Certified DXGI keyword identity drifted.'
}
foreach ($provider in $eventProviders) {
    $name = Get-NxbAttr $provider 'Name'
    if ($name -cin @('Microsoft-Windows-DxgKrnl','Microsoft-Windows-DXGI')) { continue }
    if (@($provider.SelectNodes('./Keywords/Keyword')).Count -ne 0) {
        throw "Unvalidated keyword filtering was introduced for provider $name."
    }
}

$profiles = @($document.SelectNodes('//Profiles/Profile'))
if ($profiles.Count -ne 2) { throw 'SUPERBLOCK profile must define exactly File and Memory variants.' }
foreach ($mode in @('File','Memory')) {
    $variant = @($profiles | Where-Object { (Get-NxbAttr $_ 'LoggingMode') -ceq $mode })
    if ($variant.Count -ne 1 -or
        (Get-NxbAttr $variant[0] 'Name') -cne 'NxbSuperblock1MultiDomain' -or
        (Get-NxbAttr $variant[0] 'DetailLevel') -cne 'Verbose') {
        throw "SUPERBLOCK $mode profile variant is missing or malformed."
    }
    $providerRefs = @($variant[0].SelectNodes('./Collectors/EventCollectorId/EventProviders/EventProviderId'))
    if ($providerRefs.Count -ne 8) { throw "SUPERBLOCK $mode profile must bind all eight event providers." }
    if ($null -eq $variant[0].SelectSingleNode('./Collectors/SystemCollectorId')) {
        throw "SUPERBLOCK $mode profile is missing its system collector."
    }
}

$sha = (Get-FileHash -LiteralPath $profileFull -Algorithm SHA256).Hash.ToLowerInvariant()
$result = [pscustomobject][ordered]@{
    status = 'passed'
    path = $profileFull
    relative_path = 'profiles/Nxb.Superblock1MultiDomain.wprp'
    name = 'NxbSuperblock1MultiDomain'
    sha256 = $sha
    length = [int64]$item.Length
    system_keywords = $systemKeywords
    event_provider_names = $providerNames
    event_provider_strict_policy = 'false_with_separate_native_enable_matrix'
    file_system_collector_max_mib = 128
    file_event_collector_max_mib = 128
    semantic_claims_enabled = $false
    trace_completeness = 'not_claimed'
}
if ($PassThru) { return $result }
Write-Output "SUPERBLOCK multi-domain WPR profile contract passed: $sha"
