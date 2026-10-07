param(
    [Parameter(Mandatory = $true)]
    [string]$InputJsonPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputCanonicalJsonPath,

    [Parameter(Mandatory = $true)]
    [string]$SchemaPath,

    [Parameter(Mandatory = $true)]
    [string]$EvidenceStoreModulePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'PowerShell 7 required'
}

$ExpectedContractId = 'nxb-artifact-tree-manifest-v1'
$ExpectedSchemaId = 'urn:nxb:schema:nxb-artifact-tree-manifest:v1'
$ExpectedSchemaSha256 = @(
    '208f84e22e7604c252a95307b5009acf7f524d89d51d609c96aed40b1bfe492f',
    '8952dfcee0732679249d5de2a0e5eabacd8ab1cce2698974c6f5c48b322a4785'
)
$ExpectedEvidenceStoreSha256 = @(
    '207a3e379e411fa6761f21cf01810135572d87033779ec8f791fa0befcd17cd7',
    'baa711b12592dff95d1155953f183454f44af31e72f61b05d6388add9555d4f3'
)
$RootRolePattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
$Sha256Pattern = '^[0-9a-f]{64}$'

$ReservedDosNames = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
foreach ($name in @(
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
)) {
    [void]$ReservedDosNames.Add($name)
}

function Fail {
    param([Parameter(Mandatory = $true)][string]$Message)
    throw $Message
}

function Get-FullPathStrict {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Fail "$Label is empty."
    }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.Equals($Path, [StringComparison]::OrdinalIgnoreCase)) {
        Fail "$Label must be an absolute normalized path: $Path"
    }
    return $full
}

function Assert-OrdinaryFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $full = Get-FullPathStrict -Path $Path -Label $Label
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Fail "$Label is not an existing file: $full"
    }
    $item = Get-Item -LiteralPath $full -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "$Label is reparse-backed: $full"
    }
    return $full
}

function Assert-OrdinaryDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $full = Get-FullPathStrict -Path $Path -Label $Label
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        Fail "$Label is not an existing directory: $full"
    }
    $item = Get-Item -LiteralPath $full -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "$Label is reparse-backed: $full"
    }
    return $full
}

function Read-Utf8JsonDocument {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF) {
        Fail "$Label must not contain a UTF-8 BOM."
    }

    try {
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        return [System.Text.Json.JsonDocument]::Parse([string]$text)
    }
    catch {
        Fail "$Label is not strict UTF-8 JSON: $($_.Exception.Message)"
    }
}

function Get-JsonObjectPropertyMap {
    param(
        [Parameter(Mandatory = $true)][System.Text.Json.JsonElement]$Element,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($Element.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
        Fail "$Label must be a JSON object."
    }

    $properties = [Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($property in $Element.EnumerateObject()) {
        if ($properties.ContainsKey([string]$property.Name)) {
            Fail "$Label contains duplicate property: $($property.Name)"
        }
        $properties.Add([string]$property.Name, $property.Value.Clone())
    }
    return $properties
}

function Assert-ExactPropertySet {
    param(
        [Parameter(Mandatory = $true)][Collections.Generic.Dictionary[string, object]]$Properties,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($Properties.Count -ne $Expected.Count) {
        Fail "$Label property count mismatch: expected=$($Expected.Count) actual=$($Properties.Count)"
    }
    foreach ($name in $Expected) {
        if (-not $Properties.ContainsKey($name)) {
            Fail "$Label missing required property: $name"
        }
    }
}

function Get-JsonString {
    param(
        [Parameter(Mandatory = $true)][object]$ElementObject,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $element = [System.Text.Json.JsonElement]$ElementObject
    if ($element.ValueKind -ne [System.Text.Json.JsonValueKind]::String) {
        Fail "$Label must be a JSON string."
    }
    return [string]$element.GetString()
}

function Get-JsonInt64 {
    param(
        [Parameter(Mandatory = $true)][object]$ElementObject,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $element = [System.Text.Json.JsonElement]$ElementObject
    if ($element.ValueKind -ne [System.Text.Json.JsonValueKind]::Number) {
        Fail "$Label must be a JSON integer."
    }

    [long]$value = 0
    if (-not $element.TryGetInt64([ref]$value)) {
        Fail "$Label must fit signed Int64 and contain no fractional/exponent form."
    }

    $raw = $element.GetRawText()
    if ($raw -cnotmatch '^(0|[1-9][0-9]*)$') {
        Fail "$Label must use unsigned shortest base-10 integer form."
    }
    return $value
}

function Test-JsonBooleanFalse {
    param([Parameter(Mandatory = $true)][object]$ElementObject)
    return ([System.Text.Json.JsonElement]$ElementObject).ValueKind -eq [System.Text.Json.JsonValueKind]::False
}

function Assert-SchemaContract {
    param([Parameter(Mandatory = $true)][System.Text.Json.JsonElement]$Root)

    $props = Get-JsonObjectPropertyMap -Element $Root -Label 'schema root'
    foreach ($required in @('$schema', '$id', 'title', 'type', 'additionalProperties', 'required', 'properties')) {
        if (-not $props.ContainsKey($required)) {
            Fail "schema root missing property: $required"
        }
    }

    if ((Get-JsonString $props['$schema'] 'schema.$schema') -cne 'https://json-schema.org/draft/2020-12/schema') {
        Fail 'schema.$schema drift.'
    }
    if ((Get-JsonString $props['$id'] 'schema.$id') -cne $ExpectedSchemaId) {
        Fail 'schema.$id drift.'
    }
    if ((Get-JsonString $props['type'] 'schema.type') -cne 'object') {
        Fail 'schema.type drift.'
    }
    if (-not (Test-JsonBooleanFalse $props['additionalProperties'])) {
        Fail 'schema.additionalProperties must be false.'
    }

    $requiredElement = [System.Text.Json.JsonElement]$props['required']
    if ($requiredElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) {
        Fail 'schema.required must be an array.'
    }
    $requiredNames = @($requiredElement.EnumerateArray() | ForEach-Object {
        if ($_.ValueKind -ne [System.Text.Json.JsonValueKind]::String) {
            Fail 'schema.required contains non-string.'
        }
        [string]$_.GetString()
    })
    $expectedRequired = @('contract_id', 'root_role', 'file_count', 'total_bytes', 'files')
    if ($requiredNames.Count -ne $expectedRequired.Count) {
        Fail 'schema.required cardinality drift.'
    }
    foreach ($name in $expectedRequired) {
        if ($name -notin $requiredNames) {
            Fail "schema.required missing: $name"
        }
    }

    $schemaProperties = Get-JsonObjectPropertyMap `
        -Element ([System.Text.Json.JsonElement]$props['properties']) `
        -Label 'schema.properties'
    Assert-ExactPropertySet `
        -Properties $schemaProperties `
        -Expected $expectedRequired `
        -Label 'schema.properties'

    $contractSchema = Get-JsonObjectPropertyMap `
        -Element ([System.Text.Json.JsonElement]$schemaProperties['contract_id']) `
        -Label 'schema.properties.contract_id'
    if (-not $contractSchema.ContainsKey('const') -or
        (Get-JsonString $contractSchema['const'] 'schema contract const') -cne $ExpectedContractId) {
        Fail 'schema contract_id const drift.'
    }

    $roleSchema = Get-JsonObjectPropertyMap `
        -Element ([System.Text.Json.JsonElement]$schemaProperties['root_role']) `
        -Label 'schema.properties.root_role'
    if (-not $roleSchema.ContainsKey('pattern') -or
        (Get-JsonString $roleSchema['pattern'] 'schema root_role pattern') -cne $RootRolePattern) {
        Fail 'schema root_role pattern drift.'
    }
}

function Assert-RelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrEmpty($Path) -or $Path.StartsWith('/')) {
        Fail "manifest relative_path invalid: $Path"
    }
    if ($Path.Contains('\')) {
        Fail "manifest relative_path contains backslash: $Path"
    }
    if ($Path.Normalize([Text.NormalizationForm]::FormC) -cne $Path) {
        Fail "manifest relative_path is not NFC: $Path"
    }

    foreach ($character in $Path.ToCharArray()) {
        $code = [int]$character
        if ($code -lt 0x20 -or $code -eq 0x7F) {
            Fail "manifest relative_path contains control character: $Path"
        }
    }

    $parts = $Path.Split('/')
    foreach ($part in $parts) {
        if ([string]::IsNullOrEmpty($part) -or $part -in @('.', '..')) {
            Fail "manifest relative_path contains empty/dot/traversal segment: $Path"
        }
        if ($part.EndsWith(' ') -or $part.EndsWith('.')) {
            Fail "manifest relative_path has trailing space/dot segment: $Path"
        }
        if ($part.Contains(':')) {
            Fail "manifest relative_path contains ADS-style colon: $Path"
        }
        $stem = $part.Split('.', 2)[0]
        if ($ReservedDosNames.Contains($stem)) {
            Fail "manifest relative_path has reserved DOS device segment: $Path"
        }
    }
}

$inputPath = Assert-OrdinaryFile -Path $InputJsonPath -Label 'InputJsonPath'
$schema = Assert-OrdinaryFile -Path $SchemaPath -Label 'SchemaPath'
$module = Assert-OrdinaryFile -Path $EvidenceStoreModulePath -Label 'EvidenceStoreModulePath'

$schemaSha = (Get-FileHash -LiteralPath $schema -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ExpectedSchemaSha256 -cnotcontains $schemaSha) {
    Fail "Schema raw SHA-256 drift: expected one of $($ExpectedSchemaSha256 -join ',') actual=$schemaSha"
}

$output = Get-FullPathStrict `
    -Path $OutputCanonicalJsonPath `
    -Label 'OutputCanonicalJsonPath'
if (Test-Path -LiteralPath $output) {
    Fail "OutputCanonicalJsonPath already exists: $output"
}
[void](Assert-OrdinaryDirectory -Path (Split-Path -Parent $output) -Label 'output parent')

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $schema)
$expectedModulePath = [IO.Path]::GetFullPath(
    (Join-Path $repositoryRoot 'scripts\Nxb.EvidenceStore.psm1')
)
if (-not $module.Equals($expectedModulePath, [StringComparison]::OrdinalIgnoreCase)) {
    Fail "EvidenceStoreModulePath is not the exact shared module in the seed worktree: $module"
}
$moduleSha = (Get-FileHash -LiteralPath $module -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ExpectedEvidenceStoreSha256 -cnotcontains $moduleSha) {
    Fail "EvidenceStore raw SHA-256 drift: expected one of $($ExpectedEvidenceStoreSha256 -join ',') actual=$moduleSha"
}

$schemaDocument = Read-Utf8JsonDocument -Path $schema -Label 'schema'
$inputDocument = Read-Utf8JsonDocument -Path $inputPath -Label 'input manifest'
try {
    Assert-SchemaContract -Root $schemaDocument.RootElement

    $rootProps = Get-JsonObjectPropertyMap `
        -Element $inputDocument.RootElement `
        -Label 'manifest root'
    Assert-ExactPropertySet `
        -Properties $rootProps `
        -Expected @('contract_id', 'root_role', 'file_count', 'total_bytes', 'files') `
        -Label 'manifest root'

    $contractId = Get-JsonString $rootProps['contract_id'] 'manifest.contract_id'
    if ($contractId -cne $ExpectedContractId) {
        Fail "manifest.contract_id drift: $contractId"
    }

    $rootRole = Get-JsonString $rootProps['root_role'] 'manifest.root_role'
    if ($rootRole -cnotmatch $RootRolePattern) {
        Fail "manifest.root_role invalid: $rootRole"
    }

    $fileCount = Get-JsonInt64 $rootProps['file_count'] 'manifest.file_count'
    $totalBytes = Get-JsonInt64 $rootProps['total_bytes'] 'manifest.total_bytes'

    $filesElement = [System.Text.Json.JsonElement]$rootProps['files']
    if ($filesElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) {
        Fail 'manifest.files must be an array.'
    }

    $files = [Collections.Generic.List[object]]::new()
    $seenExact = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenFolded = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $previousUtf8Hex = $null
    [long]$observedTotal = 0

    foreach ($fileElement in $filesElement.EnumerateArray()) {
        $fileProps = Get-JsonObjectPropertyMap `
            -Element $fileElement `
            -Label 'manifest.files[]'
        Assert-ExactPropertySet `
            -Properties $fileProps `
            -Expected @('relative_path', 'byte_length', 'sha256') `
            -Label 'manifest.files[]'

        $relativePath = Get-JsonString $fileProps['relative_path'] 'manifest.files[].relative_path'
        Assert-RelativePath -Path $relativePath

        if (-not $seenExact.Add($relativePath)) {
            Fail "manifest duplicate path: $relativePath"
        }
        if (-not $seenFolded.Add($relativePath)) {
            Fail "manifest Windows case-fold collision: $relativePath"
        }

        $utf8Hex = [Convert]::ToHexString([Text.UTF8Encoding]::new($false, $true).GetBytes($relativePath))
        if ($null -ne $previousUtf8Hex -and
            [StringComparer]::Ordinal.Compare($previousUtf8Hex, $utf8Hex) -ge 0) {
            Fail "manifest.files is not strict ordinal UTF-8 path order at: $relativePath"
        }
        $previousUtf8Hex = $utf8Hex

        $byteLength = Get-JsonInt64 $fileProps['byte_length'] 'manifest.files[].byte_length'
        if ($observedTotal -gt ([long]::MaxValue - $byteLength)) {
            Fail 'manifest total byte sum overflow.'
        }
        $observedTotal += $byteLength

        $sha256 = Get-JsonString $fileProps['sha256'] 'manifest.files[].sha256'
        if ($sha256 -cnotmatch $Sha256Pattern) {
            Fail "manifest.files[].sha256 invalid: $sha256"
        }

        [void]$files.Add([ordered]@{
            relative_path = $relativePath
            byte_length = [long]$byteLength
            sha256 = $sha256
        })
    }

    if ([long]$files.Count -ne $fileCount) {
        Fail "manifest.file_count mismatch: declared=$fileCount observed=$($files.Count)"
    }
    if ($observedTotal -ne $totalBytes) {
        Fail "manifest.total_bytes mismatch: declared=$totalBytes observed=$observedTotal"
    }

    $logical = [ordered]@{
        contract_id = $contractId
        root_role = $rootRole
        file_count = [long]$fileCount
        total_bytes = [long]$totalBytes
        files = @($files)
    }

    Import-Module -Name $module -Force -ErrorAction Stop
    $command = Get-Command -Name 'ConvertTo-NxbCanonicalJson' -CommandType Function -ErrorAction Stop
    if (-not ([string]$command.Module.Path).Equals($module, [StringComparison]::OrdinalIgnoreCase)) {
        Fail "ConvertTo-NxbCanonicalJson resolved from unexpected module: $($command.Module.Path)"
    }

    $canonical = ConvertTo-NxbCanonicalJson -InputObject $logical
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($canonical)

    $outputStream = [IO.File]::Open(
        $output,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try {
        $outputStream.Write($bytes, 0, $bytes.Length)
        $outputStream.Flush($true)
    }
    finally {
        $outputStream.Dispose()
    }
}
finally {
    $inputDocument.Dispose()
    $schemaDocument.Dispose()
}
