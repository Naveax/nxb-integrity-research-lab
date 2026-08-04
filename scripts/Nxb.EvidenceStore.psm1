Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NxbIntegralNumber {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Value
    )

    return (
        $Value -is [sbyte] -or
        $Value -is [byte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64]
    )
}

function ConvertTo-NxbJsonStringLiteral {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')

    for ($index = 0; $index -lt $Value.Length; $index++) {
        $character = $Value[$index]
        $codeUnit = [int]$character
        $escaped = $null

        switch ($codeUnit) {
            0x08 { $escaped = '\b' }
            0x09 { $escaped = '\t' }
            0x0A { $escaped = '\n' }
            0x0C { $escaped = '\f' }
            0x0D { $escaped = '\r' }
            0x22 { $escaped = '\"' }
            0x5C { $escaped = '\\' }
        }

        if ($null -ne $escaped) {
            [void]$builder.Append($escaped)
            continue
        }

        if ($codeUnit -lt 0x20) {
            [void]$builder.AppendFormat(
                [Globalization.CultureInfo]::InvariantCulture,
                '\u{0:x4}',
                $codeUnit
            )
            continue
        }

        if ([char]::IsHighSurrogate($character)) {
            if ($index + 1 -ge $Value.Length -or
                -not [char]::IsLowSurrogate($Value[$index + 1])) {
                throw 'Canonical JSON string contains an unpaired high surrogate.'
            }

            [void]$builder.Append($character)
            $index++
            [void]$builder.Append($Value[$index])
            continue
        }

        if ([char]::IsLowSurrogate($character)) {
            throw 'Canonical JSON string contains an unpaired low surrogate.'
        }

        [void]$builder.Append($character)
    }

    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-NxbCanonicalJsonValue {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [Collections.Generic.HashSet[string]]$ExcludedRootProperties,

        [Parameter(Mandatory)]
        [bool]$IsRoot,

        [Parameter(Mandatory)]
        [ValidateRange(0, 100)]
        [int]$Depth
    )

    if ($Depth -ge 100) {
        throw 'Canonical JSON maximum nesting depth exceeded.'
    }

    if ($null -eq $Value) {
        return 'null'
    }

    if ($Value -is [bool]) {
        if ([bool]$Value) {
            return 'true'
        }
        return 'false'
    }

    if ($Value -is [string] -or $Value -is [char]) {
        return ConvertTo-NxbJsonStringLiteral -Value ([string]$Value)
    }

    if (Test-NxbIntegralNumber -Value $Value) {
        return ([IFormattable]$Value).ToString(
            $null,
            [Globalization.CultureInfo]::InvariantCulture
        )
    }

    if ($Value -is [decimal] -or
        $Value -is [single] -or
        $Value -is [double]) {
        throw "Floating-point value is not allowed in canonical JSON: $Value"
    }

    $propertyValues = [Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::Ordinal
    )
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if ($key -isnot [string]) {
                throw 'Canonical JSON object keys must be strings.'
            }
            $propertyValues[[string]$key] = $Value[$key]
        }
    }
    elseif ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.MemberType -notin @('NoteProperty', 'Property', 'AliasProperty')) {
                continue
            }
            $propertyValues[[string]$property.Name] = $property.Value
        }
    }
    elseif ($Value -is [Collections.IEnumerable]) {
        $elements = [Collections.Generic.List[string]]::new()
        foreach ($element in $Value) {
            [void]$elements.Add((ConvertTo-NxbCanonicalJsonValue `
                -Value $element `
                -ExcludedRootProperties $ExcludedRootProperties `
                -IsRoot $false `
                -Depth ($Depth + 1)))
        }
        return '[' + ($elements -join ',') + ']'
    }
    else {
        throw "Unsupported canonical JSON value type: $($Value.GetType().FullName)"
    }

    [string[]]$propertyNames = @($propertyValues.Keys)
    [Array]::Sort($propertyNames, [StringComparer]::Ordinal)

    $members = [Collections.Generic.List[string]]::new()
    foreach ($propertyName in $propertyNames) {
        if ($IsRoot -and $ExcludedRootProperties.Contains($propertyName)) {
            continue
        }

        $nameLiteral = ConvertTo-NxbJsonStringLiteral -Value $propertyName
        $valueLiteral = ConvertTo-NxbCanonicalJsonValue `
            -Value $propertyValues[$propertyName] `
            -ExcludedRootProperties $ExcludedRootProperties `
            -IsRoot $false `
            -Depth ($Depth + 1)
        [void]$members.Add("$nameLiteral`:$valueLiteral")
    }

    return '{' + ($members -join ',') + '}'
}

function ConvertTo-NxbCanonicalJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter()]
        [string[]]$ExcludeRootProperty = @()
    )

    process {
        $excluded = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::Ordinal
        )
        foreach ($propertyName in $ExcludeRootProperty) {
            if ([string]::IsNullOrWhiteSpace($propertyName)) {
                throw 'Excluded root property names cannot be empty.'
            }
            [void]$excluded.Add($propertyName)
        }

        return ConvertTo-NxbCanonicalJsonValue `
            -Value $InputObject `
            -ExcludedRootProperties $excluded `
            -IsRoot $true `
            -Depth 0
    }
}

function Get-NxbSha256Hex {
    [CmdletBinding(DefaultParameterSetName = 'Text')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Text')]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory, ParameterSetName = 'Bytes')]
        [AllowEmptyCollection()]
        [byte[]]$InputBytes
    )

    $bytes = if ($PSCmdlet.ParameterSetName -eq 'Text') {
        [Text.UTF8Encoding]::new($false, $true).GetBytes($Text)
    }
    else {
        $InputBytes
    }

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha256.ComputeHash($bytes)
        return -join ($digest | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-NxbCanonicalJsonHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter()]
        [string[]]$ExcludeRootProperty = @()
    )

    process {
        $canonicalJson = ConvertTo-NxbCanonicalJson `
            -InputObject $InputObject `
            -ExcludeRootProperty $ExcludeRootProperty
        return Get-NxbSha256Hex -Text $canonicalJson
    }
}

function Write-NxbCanonicalJsonAtomic {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter()]
        [string[]]$ExcludeRootProperty = @()
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $fullPath
    if (-not [string]::IsNullOrWhiteSpace($directory) -and
        -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $canonicalJson = ConvertTo-NxbCanonicalJson `
        -InputObject $InputObject `
        -ExcludeRootProperty $ExcludeRootProperty
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($canonicalJson)
    $temporaryPath = "$fullPath.tmp.$([guid]::NewGuid().ToString('N'))"

    if (-not $PSCmdlet.ShouldProcess($fullPath, 'Write canonical JSON atomically')) {
        return
    }

    try {
        [IO.File]::WriteAllBytes($temporaryPath, $bytes)
        Move-Item -LiteralPath $temporaryPath -Destination $fullPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-NxbCanonicalJson',
    'Get-NxbSha256Hex',
    'Get-NxbCanonicalJsonHash',
    'Write-NxbCanonicalJsonAtomic'
)
