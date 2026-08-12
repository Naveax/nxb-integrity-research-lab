[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter()][string]$ConfigurationPath,
    [Parameter()][switch]$NoThrow,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($RepositoryRoot)
if ([string]::IsNullOrWhiteSpace($ConfigurationPath)) {
    $ConfigurationPath = Join-Path -Path $root -ChildPath 'config\nxb-v1-cli-known-error-signatures.json'
}
$config = Get-Content -LiteralPath $ConfigurationPath -Raw | ConvertFrom-Json
if ([string]$config.contract_id -cne 'nxb-v1-cli-known-error-signatures-v1') { throw 'CLI known-error contract drift.' }
$findings = [Collections.Generic.List[object]]::new()
foreach ($rule in @($config.rules)) {
    $regex = [regex]::new([string]$rule.regex,[Text.RegularExpressions.RegexOptions]::Multiline -bor [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($relativeObject in @($rule.include)) {
        $relative = [string]$relativeObject
        $full = Join-Path -Path $root -ChildPath $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw ('CLI known-error scanner path missing: {0}' -f $relative) }
        $source = Get-Content -LiteralPath $full -Raw
        foreach ($match in @($regex.Matches($source))) {
            $findings.Add([pscustomobject][ordered]@{
                id = [string]$rule.id
                path = $relative
                index = [int]$match.Index
                value = [string]$match.Value
            })
        }
    }
}
$status = 'passed'
if ($findings.Count -gt 0) { $status = 'failed' }
$result = [pscustomobject][ordered]@{
    schema_version = 1
    status = $status
    authority = 'nxb-v1-cli-known-error-scan-v1'
    rule_count = @($config.rules).Count
    finding_count = $findings.Count
    findings = @($findings)
}
if ($findings.Count -gt 0 -and -not $NoThrow) { throw ('CLI known-error findings: {0}' -f $findings.Count) }
if ($PassThru) { return $result }
if (-not $PassThru) { Write-Information ('NXB v1 CLI known-error scan: rules={0} findings={1}' -f @($config.rules).Count,$findings.Count) }
