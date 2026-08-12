[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter()][string]$ConfigurationPath,
    [Parameter()][string]$OutputPath,
    [Parameter()][switch]$NoThrow,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NxbProductionConfigProperty {
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][AllowNull()][object]$DefaultValue = $null
    )

    if ($null -eq $InputObject) { return $DefaultValue }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if (-not $InputObject.Contains($Name)) { return $DefaultValue }
        return $InputObject[$Name]
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $DefaultValue }
    return $property.Value
}

function Test-NxbProductionConfigField {
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) { return $false }
    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject.Contains($Name)
    }
    return ($null -ne $InputObject.PSObject.Properties[$Name])
}

function Test-NxbProductionRelativePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ([IO.Path]::IsPathRooted($Path)) { return $false }
    $normalized = $Path.Replace('\\','/')
    if ($normalized.StartsWith('../',[StringComparison]::Ordinal) -or
        $normalized.EndsWith('/..',[StringComparison]::Ordinal) -or
        $normalized.Contains('/../')) {
        return $false
    }
    return $true
}

$root = [IO.Path]::GetFullPath($RepositoryRoot)
if ([string]::IsNullOrWhiteSpace($ConfigurationPath)) {
    $ConfigurationPath = Join-Path $root 'config\nxb-production-known-error-extension.json'
}
$configFull = [IO.Path]::GetFullPath($ConfigurationPath)
$configFindingPath = 'config/nxb-production-known-error-extension.json'
$config = Get-Content -LiteralPath $configFull -Raw | ConvertFrom-Json
$findings = [Collections.Generic.List[object]]::new()

$schemaContracts = @(Get-NxbProductionConfigProperty -InputObject $config -Name 'schema_contracts' -DefaultValue @())
if ($schemaContracts.Count -eq 0) {
    $findings.Add([pscustomobject][ordered]@{
        id = 'NXB-ERR-035'
        path = $configFindingPath
        line = 0
        preview = 'production scanner schema_contracts is missing or empty'
    })
}
else {
    foreach ($schemaContract in $schemaContracts) {
        $schemaId = [string](Get-NxbProductionConfigProperty -InputObject $schemaContract -Name 'id' -DefaultValue 'NXB-ERR-035')
        $collectionName = [string](Get-NxbProductionConfigProperty -InputObject $schemaContract -Name 'collection' -DefaultValue '')
        $requiredFields = @(Get-NxbProductionConfigProperty -InputObject $schemaContract -Name 'required_fields' -DefaultValue @())
        if ([string]::IsNullOrWhiteSpace($collectionName) -or $requiredFields.Count -eq 0) {
            $findings.Add([pscustomobject][ordered]@{
                id = $schemaId
                path = $configFindingPath
                line = 0
                preview = 'schema contract must define collection and required_fields'
            })
            continue
        }

        $collection = @(Get-NxbProductionConfigProperty -InputObject $config -Name $collectionName -DefaultValue @())
        if ($collection.Count -eq 0) {
            $findings.Add([pscustomobject][ordered]@{
                id = $schemaId
                path = $configFindingPath
                line = 0
                preview = ('schema collection missing or empty: {0}' -f $collectionName)
            })
            continue
        }

        foreach ($item in $collection) {
            foreach ($fieldNameValue in $requiredFields) {
                $fieldName = [string]$fieldNameValue
                if (-not (Test-NxbProductionConfigField -InputObject $item -Name $fieldName)) {
                    $findings.Add([pscustomobject][ordered]@{
                        id = $schemaId
                        path = $configFindingPath
                        line = 0
                        preview = ('required config field missing: {0}.{1}' -f $collectionName,$fieldName)
                    })
                }
            }
        }
    }
}

$authorityPaths = @(Get-NxbProductionConfigProperty -InputObject $config -Name 'authority_paths' -DefaultValue @())
$rules = @(Get-NxbProductionConfigProperty -InputObject $config -Name 'rules' -DefaultValue @())
$guardContracts = @(Get-NxbProductionConfigProperty -InputObject $config -Name 'guard_contracts' -DefaultValue @())

foreach ($relativePathValue in $authorityPaths) {
    $relativePath = [string]$relativePathValue
    if (-not (Test-NxbProductionRelativePath -Path $relativePath)) {
        $findings.Add([pscustomobject][ordered]@{
            id = 'NXB-PRODUCTION-COVERAGE'
            path = $configFindingPath
            line = 0
            preview = ('unsafe authority path: {0}' -f $relativePath)
        })
        continue
    }

    $fullPath = Join-Path $root $relativePath.Replace('/',[IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        $findings.Add([pscustomobject][ordered]@{
            id = 'NXB-PRODUCTION-COVERAGE'
            path = $relativePath
            line = 0
            preview = 'required authority path missing'
        })
        continue
    }

    $source = Get-Content -LiteralPath $fullPath -Raw
    foreach ($rule in $rules) {
        $ruleId = [string](Get-NxbProductionConfigProperty -InputObject $rule -Name 'id' -DefaultValue 'NXB-PRODUCTION-CONFIG')
        $regexText = [string](Get-NxbProductionConfigProperty -InputObject $rule -Name 'regex' -DefaultValue '')
        if ([string]::IsNullOrWhiteSpace($regexText)) {
            $findings.Add([pscustomobject][ordered]@{
                id = 'NXB-PRODUCTION-CONFIG'
                path = $configFindingPath
                line = 0
                preview = ('rule regex missing: {0}' -f $ruleId)
            })
            continue
        }

        try {
            $regex = [regex]::new($regexText)
        }
        catch {
            $findings.Add([pscustomobject][ordered]@{
                id = 'NXB-PRODUCTION-CONFIG'
                path = $configFindingPath
                line = 0
                preview = ('rule regex invalid: {0}' -f $ruleId)
            })
            continue
        }

        foreach ($match in @($regex.Matches($source))) {
            $prefix = $source.Substring(0,$match.Index)
            $line = ([regex]::Matches($prefix,"`n").Count + 1)
            $preview = $match.Value.Replace("`r",' ').Replace("`n",' ')
            if ($preview.Length -gt 160) { $preview = $preview.Substring(0,160) }
            $findings.Add([pscustomobject][ordered]@{
                id = $ruleId
                path = $relativePath
                line = $line
                preview = $preview
            })
        }
    }
}

foreach ($guard in $guardContracts) {
    $guardId = [string](Get-NxbProductionConfigProperty -InputObject $guard -Name 'id' -DefaultValue 'NXB-PRODUCTION-CONFIG')
    $guardPath = [string](Get-NxbProductionConfigProperty -InputObject $guard -Name 'path' -DefaultValue '')
    $requiredTokens = @(Get-NxbProductionConfigProperty -InputObject $guard -Name 'required_tokens' -DefaultValue @())

    if ([string]::IsNullOrWhiteSpace($guardPath)) {
        $findings.Add([pscustomobject][ordered]@{
            id = 'NXB-ERR-035'
            path = $configFindingPath
            line = 0
            preview = ('guard path missing: {0}' -f $guardId)
        })
        continue
    }
    if (-not (Test-NxbProductionRelativePath -Path $guardPath)) {
        $findings.Add([pscustomobject][ordered]@{
            id = 'NXB-ERR-035'
            path = $configFindingPath
            line = 0
            preview = ('guard path unsafe: {0}' -f $guardPath)
        })
        continue
    }
    if ($requiredTokens.Count -eq 0) {
        $findings.Add([pscustomobject][ordered]@{
            id = 'NXB-ERR-035'
            path = $configFindingPath
            line = 0
            preview = ('guard required_tokens missing: {0}' -f $guardId)
        })
        continue
    }

    $fullPath = Join-Path $root $guardPath.Replace('/',[IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        $findings.Add([pscustomobject][ordered]@{
            id = $guardId
            path = $guardPath
            line = 0
            preview = 'guarded authority path missing'
        })
        continue
    }

    $source = Get-Content -LiteralPath $fullPath -Raw
    foreach ($tokenValue in $requiredTokens) {
        $token = [string]$tokenValue
        if ($source.IndexOf($token,[StringComparison]::Ordinal) -lt 0) {
            $findings.Add([pscustomobject][ordered]@{
                id = $guardId
                path = $guardPath
                line = 0
                preview = ('required guard token missing: {0}' -f $token)
            })
        }
    }
}

$result = [pscustomobject][ordered]@{
    schema_version = 1
    status = if ($findings.Count -eq 0) { 'passed' } else { 'failed' }
    base_rule_floor = [int](Get-NxbProductionConfigProperty -InputObject $config -Name 'base_rule_floor' -DefaultValue 0)
    extension_rule_count = $rules.Count
    schema_contract_count = $schemaContracts.Count
    guard_contract_count = $guardContracts.Count
    authority_path_count = $authorityPaths.Count
    finding_count = $findings.Count
    findings = @($findings)
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),(($result | ConvertTo-Json -Depth 16) + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
}
if ($findings.Count -gt 0 -and -not $NoThrow) {
    $detail = @($findings | ForEach-Object { '{0} {1}:{2} {3}' -f $_.id,$_.path,$_.line,$_.preview }) -join [Environment]::NewLine
    throw ('Production known-error extension scan failed: findings={0}{1}{2}' -f $findings.Count,[Environment]::NewLine,$detail)
}
if ($PassThru) { return $result }
