[CmdletBinding()]
param(
    [Parameter()][ValidateNotNullOrEmpty()][string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [Parameter()][ValidateNotNullOrEmpty()][string]$SignaturePath,
    [Parameter()][ValidateNotNullOrEmpty()][string]$OutputPath,
    [Parameter()][switch]$PassThru,
    [Parameter()][switch]$NoThrow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NxbKnownErrorRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $pathFull = [IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith($rootFull,[StringComparison]::OrdinalIgnoreCase)) {
        throw ('Path is outside repository root: {0}' -f $pathFull)
    }
    $relative = $pathFull.Substring($rootFull.Length).TrimStart([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    return ($relative -replace '\\','/')
}

function Test-NxbKnownErrorPathMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][object[]]$Glob
    )
    foreach ($item in @($Glob)) {
        $pattern = [System.Management.Automation.WildcardPattern]::new(
            [string]$item,
            [System.Management.Automation.WildcardOptions]::IgnoreCase
        )
        if ($pattern.IsMatch($RelativePath)) { return $true }
    }
    return $false
}

function Get-NxbKnownErrorLineNumber {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][int]$Index
    )
    if ($Index -le 0) { return 1 }
    $prefix = $Text.Substring(0,$Index)
    return ([regex]::Matches($prefix,"`n").Count + 1)
}

$rootFull = [IO.Path]::GetFullPath($RepositoryRoot)
if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
    throw ('Repository root missing: {0}' -f $rootFull)
}

if ([string]::IsNullOrWhiteSpace($SignaturePath)) {
    $SignaturePath = Join-Path $rootFull 'config\nxb-known-error-signatures.json'
}
$signatureFull = [IO.Path]::GetFullPath($SignaturePath)
if (-not (Test-Path -LiteralPath $signatureFull -PathType Leaf)) {
    throw ('Known-error signature file missing: {0}' -f $signatureFull)
}

$signatureDocument = Get-Content -LiteralPath $signatureFull -Raw | ConvertFrom-Json
if ([int]$signatureDocument.schema_version -ne 1) {
    throw 'Unsupported known-error signature schema.'
}
$ledgerPath = Join-Path $rootFull ([string]$signatureDocument.ledger_path)
if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) {
    throw ('Known-error ledger missing: {0}' -f $ledgerPath)
}

$allFiles = @(
    Get-ChildItem -LiteralPath $rootFull -File -Recurse -ErrorAction Stop |
        Where-Object { $_.Extension -ceq '.ps1' }
)

$findings = [Collections.Generic.List[object]]::new()
$ruleCount = 0
foreach ($rule in @($signatureDocument.rules)) {
    $ruleCount++
    $ruleId = [string]$rule.id
    $description = [string]$rule.description
    $regex = [regex]::new([string]$rule.regex)
    foreach ($file in $allFiles) {
        $relative = Get-NxbKnownErrorRelativePath -Root $rootFull -Path $file.FullName
        if (-not (Test-NxbKnownErrorPathMatch -RelativePath $relative -Glob @($rule.include_globs))) { continue }
        $text = Get-Content -LiteralPath $file.FullName -Raw
        foreach ($match in @($regex.Matches($text))) {
            $line = Get-NxbKnownErrorLineNumber -Text $text -Index $match.Index
            $preview = ([string]$match.Value -replace '[\r\n]+',' ').Trim()
            if ($preview.Length -gt 180) { $preview = $preview.Substring(0,180) }
            $findings.Add([pscustomobject][ordered]@{
                id = $ruleId
                description = $description
                path = $relative
                line = $line
                preview = $preview
            })
        }
    }
}

$orderedFinding = @(
    $findings.ToArray() |
        Sort-Object -Property @{Expression='id';Descending=$false}, @{Expression='path';Descending=$false}, @{Expression='line';Descending=$false}
)
$result = [pscustomobject][ordered]@{
    schema_version = 1
    scanned_utc = [DateTime]::UtcNow.ToString('o')
    repository_root = '.'
    ledger_path = (Get-NxbKnownErrorRelativePath -Root $rootFull -Path $ledgerPath)
    signature_path = (Get-NxbKnownErrorRelativePath -Root $rootFull -Path $signatureFull)
    rule_count = $ruleCount
    powershell_file_count = $allFiles.Count
    finding_count = $orderedFinding.Count
    status = if ($orderedFinding.Count -eq 0) { 'passed' } else { 'failed' }
    findings = $orderedFinding
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $outputFull = [IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path -Parent $outputFull
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $outputFull,
        (($result | ConvertTo-Json -Depth 20) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

if ($orderedFinding.Count -gt 0 -and -not $NoThrow) {
    $summary = @($orderedFinding | ForEach-Object { '{0} {1}:{2} {3}' -f $_.id,$_.path,$_.line,$_.preview }) -join [Environment]::NewLine
    throw ('NXB known-error pre-final scan failed with {0} finding(s).{1}{2}' -f $orderedFinding.Count,[Environment]::NewLine,$summary)
}

if ($PassThru) { return $result }
$result | ConvertTo-Json -Depth 20
