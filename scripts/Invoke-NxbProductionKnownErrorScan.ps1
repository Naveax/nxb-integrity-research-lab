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

$root = [IO.Path]::GetFullPath($RepositoryRoot)
if ([string]::IsNullOrWhiteSpace($ConfigurationPath)) {
    $ConfigurationPath = Join-Path $root 'config\nxb-production-known-error-extension.json'
}
$config = Get-Content -LiteralPath $ConfigurationPath -Raw | ConvertFrom-Json
$findings = [Collections.Generic.List[object]]::new()

foreach ($relativePath in @($config.authority_paths)) {
    $fullPath = Join-Path $root ([string]$relativePath).Replace('/',[IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        $findings.Add([pscustomobject][ordered]@{
            id = 'NXB-PRODUCTION-COVERAGE'
            path = [string]$relativePath
            line = 0
            preview = 'required authority path missing'
        })
        continue
    }
    $source = Get-Content -LiteralPath $fullPath -Raw
    foreach ($rule in @($config.rules)) {
        $regex = [regex]::new([string]$rule.regex)
        foreach ($match in @($regex.Matches($source))) {
            $prefix = $source.Substring(0,$match.Index)
            $line = ([regex]::Matches($prefix,"`n").Count + 1)
            $preview = $match.Value.Replace("`r",' ').Replace("`n",' ')
            if ($preview.Length -gt 160) { $preview = $preview.Substring(0,160) }
            $findings.Add([pscustomobject][ordered]@{
                id = [string]$rule.id
                path = [string]$relativePath
                line = $line
                preview = $preview
            })
        }
    }
}

foreach ($guard in @($config.guard_contracts)) {
    $fullPath = Join-Path $root ([string]$guard.path).Replace('/',[IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        $findings.Add([pscustomobject][ordered]@{ id=[string]$guard.id; path=[string]$guard.path; line=0; preview='guarded authority path missing' })
        continue
    }
    $source = Get-Content -LiteralPath $fullPath -Raw
    foreach ($token in @($guard.required_tokens)) {
        if ($source.IndexOf([string]$token,[StringComparison]::Ordinal) -lt 0) {
            $findings.Add([pscustomobject][ordered]@{
                id = [string]$guard.id
                path = [string]$guard.path
                line = 0
                preview = ('required guard token missing: {0}' -f [string]$token)
            })
        }
    }
}

$result = [pscustomobject][ordered]@{
    schema_version = 1
    status = if ($findings.Count -eq 0) { 'passed' } else { 'failed' }
    base_rule_floor = [int]$config.base_rule_floor
    extension_rule_count = @($config.rules).Count
    guard_contract_count = @($config.guard_contracts).Count
    authority_path_count = @($config.authority_paths).Count
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
