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

function Invoke-NxbV1CiConfiguredKnownErrorScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedContractId,
        [Parameter(Mandatory)][int]$ExpectedRuleCount
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ('CI known-error configuration missing: {0}' -f $Path)
    }
    $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([int]$document.schema_version -ne 1 -or [string]$document.contract_id -cne $ExpectedContractId) {
        throw ('CI inherited known-error contract drift: {0}' -f $ExpectedContractId)
    }
    $rules = @($document.rules)
    if ($rules.Count -ne $ExpectedRuleCount) {
        throw ('CI inherited known-error rule cardinality drift: contract={0} expected={1} actual={2}' -f $ExpectedContractId,$ExpectedRuleCount,$rules.Count)
    }

    $findings = [Collections.Generic.List[object]]::new()
    foreach ($rule in $rules) {
        $regex = [regex]::new(
            [string]$rule.regex,
            [Text.RegularExpressions.RegexOptions]::Multiline -bor [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        foreach ($relativeObject in @($rule.include)) {
            $relative = [string]$relativeObject
            $full = Join-Path -Path $Root -ChildPath $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
                $findings.Add([pscustomobject][ordered]@{
                    id = [string]$rule.id
                    path = $relative
                    index = -1
                    value = 'required authority path missing'
                })
                continue
            }
            $source = Get-Content -LiteralPath $full -Raw
            foreach ($regexMatch in @($regex.Matches($source))) {
                $findings.Add([pscustomobject][ordered]@{
                    id = [string]$rule.id
                    path = $relative
                    index = [int]$regexMatch.Index
                    value = [string]$regexMatch.Value
                })
            }
        }
    }

    return [pscustomobject][ordered]@{
        contract_id = $ExpectedContractId
        rule_count = $rules.Count
        finding_count = $findings.Count
        status = if ($findings.Count -eq 0) { 'passed' } else { 'failed' }
        findings = @($findings)
    }
}

$root = [IO.Path]::GetFullPath($RepositoryRoot)
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw ('CI known-error repository root missing: {0}' -f $root) }
if ([string]::IsNullOrWhiteSpace($ConfigurationPath)) {
    $ConfigurationPath = Join-Path $root 'config\nxb-v1-ci-known-error-signatures.json'
}
$configurationFull = [IO.Path]::GetFullPath($ConfigurationPath)

$base = & (Join-Path $PSScriptRoot 'Invoke-NxbKnownErrorScan.ps1') -RepositoryRoot $root -NoThrow -PassThru
$production = & (Join-Path $PSScriptRoot 'Invoke-NxbProductionKnownErrorScan.ps1') -RepositoryRoot $root -NoThrow -PassThru
$release = Invoke-NxbV1CiConfiguredKnownErrorScan -Root $root -Path (Join-Path $root 'config\nxb-v1-release-known-error-signatures.json') -ExpectedContractId 'nxb-v1-release-known-error-signatures-v1' -ExpectedRuleCount 1
$signing = Invoke-NxbV1CiConfiguredKnownErrorScan -Root $root -Path (Join-Path $root 'config\nxb-v1-signing-known-error-signatures.json') -ExpectedContractId 'nxb-v1-signing-known-error-signatures-v1' -ExpectedRuleCount 2
$installer = Invoke-NxbV1CiConfiguredKnownErrorScan -Root $root -Path (Join-Path $root 'config\nxb-v1-installer-known-error-signatures.json') -ExpectedContractId 'nxb-v1-installer-known-error-signatures-v1' -ExpectedRuleCount 4
$update = Invoke-NxbV1CiConfiguredKnownErrorScan -Root $root -Path (Join-Path $root 'config\nxb-v1-update-known-error-signatures.json') -ExpectedContractId 'nxb-v1-update-known-error-signatures-v1' -ExpectedRuleCount 7
$cli = Invoke-NxbV1CiConfiguredKnownErrorScan -Root $root -Path (Join-Path $root 'config\nxb-v1-cli-known-error-signatures.json') -ExpectedContractId 'nxb-v1-cli-known-error-signatures-v1' -ExpectedRuleCount 5
$ci = Invoke-NxbV1CiConfiguredKnownErrorScan -Root $root -Path $configurationFull -ExpectedContractId 'nxb-v1-ci-known-error-signatures-v1' -ExpectedRuleCount 6

$contractFailures = [Collections.Generic.List[string]]::new()
if ([string]$base.status -cne 'passed' -or [int]$base.rule_count -lt 23 -or [int]$base.finding_count -ne 0) {
    $contractFailures.Add('base')
}
if ([string]$production.status -cne 'passed' -or [int]$production.extension_rule_count -ne 9 -or [int]$production.schema_contract_count -ne 1 -or [int]$production.guard_contract_count -ne 1 -or [int]$production.finding_count -ne 0) {
    $contractFailures.Add('production')
}
foreach ($pair in @(
    @('release',$release),
    @('signing',$signing),
    @('installer',$installer),
    @('update',$update),
    @('cli',$cli),
    @('ci',$ci)
)) {
    if ([string]$pair[1].status -cne 'passed' -or [int]$pair[1].finding_count -ne 0) {
        $contractFailures.Add([string]$pair[0])
    }
}

$totalFindings = [int]$base.finding_count + [int]$production.finding_count + [int]$release.finding_count + [int]$signing.finding_count + [int]$installer.finding_count + [int]$update.finding_count + [int]$cli.finding_count + [int]$ci.finding_count
$status = if ($contractFailures.Count -eq 0 -and $totalFindings -eq 0) { 'passed' } else { 'failed' }
$result = [pscustomobject][ordered]@{
    schema_version = 1
    status = $status
    authority = 'nxb-v1-ci-known-error-scan-v1'
    base_rule_count = [int]$base.rule_count
    production_extension_rule_count = [int]$production.extension_rule_count
    production_schema_contract_count = [int]$production.schema_contract_count
    production_guard_contract_count = [int]$production.guard_contract_count
    release_rule_count = [int]$release.rule_count
    signing_rule_count = [int]$signing.rule_count
    installer_rule_count = [int]$installer.rule_count
    update_rule_count = [int]$update.rule_count
    cli_rule_count = [int]$cli.rule_count
    ci_rule_count = [int]$ci.rule_count
    finding_count = $totalFindings
    failed_contracts = @($contractFailures)
    findings = [pscustomobject][ordered]@{
        base = @($base.findings)
        production = @($production.findings)
        release = @($release.findings)
        signing = @($signing.findings)
        installer = @($installer.findings)
        update = @($update.findings)
        cli = @($cli.findings)
        ci = @($ci.findings)
    }
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $outputFull = [IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path -Parent $outputFull
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $outputFull,
        (($result | ConvertTo-Json -Depth 32) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

if ($status -cne 'passed' -and -not $NoThrow) {
    throw ('NXB v1 CI known-error scan failed: findings={0} contracts={1}' -f $totalFindings,(@($contractFailures) -join ','))
}
if ($PassThru) { return $result }
Write-Information ('NXB v1 CI known-error scan: base={0} production={1}+1+1 release={2} signing={3} installer={4} update={5} cli={6} ci={7} findings={8}' -f [int]$base.rule_count,[int]$production.extension_rule_count,[int]$release.rule_count,[int]$signing.rule_count,[int]$installer.rule_count,[int]$update.rule_count,[int]$cli.rule_count,[int]$ci.rule_count,$totalFindings)
