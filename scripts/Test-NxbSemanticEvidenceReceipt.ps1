[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ReceiptPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedPolicySha256,
    [Parameter()][ValidateNotNullOrEmpty()][string]$ExpectedRepository = 'Naveax/nxb-integrity-research-lab',
    [Parameter()][string]$ExpectedMachineIdSha256,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ClaimName = @(
    'pnp_lifecycle_semantics',
    'pcie_bdf_semantics',
    'event_id_semantics',
    'event_task_opcode_semantics',
    'power_causality',
    'firmware_causality',
    'root_cause_validated',
    'continuous_trace_completeness'
)

function Test-NxbSemanticExactPropertySet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string[]]$RequiredName
    )

    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($itemName in $RequiredName) { [void]$expected.Add($itemName) }

    $actual = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($propertyItem in $Object.PSObject.Properties) { [void]$actual.Add([string]$propertyItem.Name) }

    if ($actual.Count -ne $expected.Count) { return $false }
    foreach ($itemName in $RequiredName) {
        if (-not $actual.Contains($itemName)) { return $false }
    }
    return $true
}

function Test-NxbSemanticHexText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][int]$Length
    )
    return ($Text.Length -eq $Length -and $Text -cmatch ('^[0-9a-f]{{{0}}}$' -f $Length))
}

function Test-NxbSemanticIntegerValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)

    return (
        $Value -is [byte] -or
        $Value -is [sbyte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64]
    )
}

function Get-NxbSemanticSha256Text {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $sha.Dispose()
    }
}

function Get-NxbSemanticSha256File {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try {
            return (($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) -join '')
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $sha.Dispose()
    }
}

function Get-NxbSemanticUtcDate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)

    if ($Value -is [DateTimeOffset]) {
        return ([DateTimeOffset]$Value).ToUniversalTime()
    }
    if ($Value -is [DateTime]) {
        return [DateTimeOffset]::new(([DateTime]$Value).ToUniversalTime())
    }

    $textValue = [string]$Value
    $parsedValue = [DateTimeOffset]::MinValue
    $dateStyle = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [DateTimeOffset]::TryParse(
        $textValue,
        [Globalization.CultureInfo]::InvariantCulture,
        $dateStyle,
        [ref]$parsedValue
    )) {
        throw ('Semantic receipt contains an invalid timestamp: {0}' -f $textValue)
    }
    return $parsedValue.ToUniversalTime()
}

function Get-NxbSemanticCanonicalMaterial {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Receipt)

    $scopeHash = Get-NxbSemanticSha256Text -Text ([string]$Receipt.capture.scope)
    $limitationArray = @($Receipt.validation.limitations | ForEach-Object { [string]$_ })
    $limitationHash = Get-NxbSemanticSha256Text -Text ($limitationArray -join "`n")
    $negativeText = ([bool]$Receipt.validation.negative_controls_passed).ToString().ToLowerInvariant()
    $cleanupText = ([bool]$Receipt.validation.cleanup_verified).ToString().ToLowerInvariant()
    $independentText = ([bool]$Receipt.validation.independent_validation_passed).ToString().ToLowerInvariant()

    return (@(
        'schema=1',
        ('receipt_id={0}' -f [string]$Receipt.receipt_id),
        ('claim_name={0}' -f [string]$Receipt.claim_name),
        ('status={0}' -f [string]$Receipt.status),
        ('repository={0}' -f [string]$Receipt.authority.repository),
        ('exact_head={0}' -f [string]$Receipt.authority.exact_head),
        ('policy_sha256={0}' -f [string]$Receipt.authority.policy_sha256),
        ('machine_id_sha256={0}' -f [string]$Receipt.machine.machine_id_sha256),
        ('scope_sha256={0}' -f $scopeHash),
        ('source_kind={0}' -f [string]$Receipt.capture.source_kind),
        ('bounded_session_seconds={0}' -f [int64]$Receipt.capture.bounded_session_seconds),
        ('artifact_count={0}' -f [int64]$Receipt.evidence.artifact_count),
        ('artifact_index_sha256={0}' -f [string]$Receipt.evidence.artifact_index_sha256),
        ('negative_controls_passed={0}' -f $negativeText),
        ('cleanup_verified={0}' -f $cleanupText),
        ('independent_validation_passed={0}' -f $independentText),
        ('validator_name={0}' -f [string]$Receipt.validation.validator_name),
        ('validator_version={0}' -f [string]$Receipt.validation.validator_version),
        ('validator_implementation_sha256={0}' -f [string]$Receipt.validation.validator_implementation_sha256),
        ('limitations_sha256={0}' -f $limitationHash)
    ) -join "`n")
}

$receiptFull = [IO.Path]::GetFullPath($ReceiptPath)
if (-not (Test-Path -LiteralPath $receiptFull -PathType Leaf)) {
    throw ('Semantic receipt is missing: {0}' -f $receiptFull)
}

$receiptRaw = Get-Content -LiteralPath $receiptFull -Raw
$receipt = $receiptRaw | ConvertFrom-Json

if (-not (Test-NxbSemanticExactPropertySet -Object $receipt -RequiredName @(
    'schema_version','receipt_id','claim_name','status','authority','machine','capture','evidence','validation','receipt_fingerprint_sha256'
))) { throw 'Semantic receipt top-level property set is not exact.' }
if (-not (Test-NxbSemanticExactPropertySet -Object $receipt.authority -RequiredName @('repository','exact_head','policy_sha256'))) {
    throw 'Semantic receipt authority property set is not exact.'
}
if (-not (Test-NxbSemanticExactPropertySet -Object $receipt.machine -RequiredName @('machine_id_sha256'))) {
    throw 'Semantic receipt machine property set is not exact.'
}
if (-not (Test-NxbSemanticExactPropertySet -Object $receipt.capture -RequiredName @('scope','source_kind','started_utc','ended_utc','bounded_session_seconds'))) {
    throw 'Semantic receipt capture property set is not exact.'
}
if (-not (Test-NxbSemanticExactPropertySet -Object $receipt.evidence -RequiredName @('artifact_count','artifact_index_sha256'))) {
    throw 'Semantic receipt evidence property set is not exact.'
}
if (-not (Test-NxbSemanticExactPropertySet -Object $receipt.validation -RequiredName @(
    'negative_controls_passed','cleanup_verified','independent_validation_passed','validator_name','validator_version','validator_implementation_sha256','limitations'
))) { throw 'Semantic receipt validation property set is not exact.' }

if (-not (Test-NxbSemanticIntegerValue -Value $receipt.schema_version) -or [int64]$receipt.schema_version -ne 1) {
    throw 'Semantic receipt schema_version must be integer 1.'
}

$receiptId = [string]$receipt.receipt_id
if ($receiptId -cnotmatch '^[a-z0-9][a-z0-9._-]{2,127}$') { throw 'Semantic receipt_id is invalid.' }

$claim = [string]$receipt.claim_name
if ([Array]::IndexOf($ClaimName,$claim) -lt 0) { throw ('Unknown semantic claim: {0}' -f $claim) }

$status = [string]$receipt.status
if ($status -notin @('validated','failed','unavailable')) { throw ('Unknown semantic receipt status: {0}' -f $status) }

$repository = [string]$receipt.authority.repository
if ([string]::IsNullOrWhiteSpace($repository) -or $repository.Length -gt 256 -or $repository -match '[\r\n]') {
    throw 'Semantic receipt repository binding is invalid.'
}
if ($repository -cne $ExpectedRepository) {
    throw ('Semantic receipt repository mismatch: expected={0} actual={1}' -f $ExpectedRepository,$repository)
}

$exactHead = [string]$receipt.authority.exact_head
if (-not (Test-NxbSemanticHexText -Text $exactHead -Length 40)) { throw 'Semantic receipt exact_head is not lowercase 40-hex.' }
if ($exactHead -cne $ExpectedHead) {
    throw ('Semantic receipt exact-head mismatch: expected={0} actual={1}' -f $ExpectedHead,$exactHead)
}

$policyHash = [string]$receipt.authority.policy_sha256
if (-not (Test-NxbSemanticHexText -Text $policyHash -Length 64)) { throw 'Semantic receipt policy_sha256 is not lowercase 64-hex.' }
if ($policyHash -cne $ExpectedPolicySha256) {
    throw ('Semantic receipt policy mismatch: expected={0} actual={1}' -f $ExpectedPolicySha256,$policyHash)
}

$machineHash = [string]$receipt.machine.machine_id_sha256
if (-not (Test-NxbSemanticHexText -Text $machineHash -Length 64)) { throw 'Semantic receipt machine_id_sha256 is not lowercase 64-hex.' }
if (-not [string]::IsNullOrWhiteSpace($ExpectedMachineIdSha256)) {
    if (-not (Test-NxbSemanticHexText -Text $ExpectedMachineIdSha256 -Length 64)) {
        throw 'ExpectedMachineIdSha256 must be lowercase 64-hex when supplied.'
    }
    if ($machineHash -cne $ExpectedMachineIdSha256) {
        throw ('Semantic receipt machine mismatch: expected={0} actual={1}' -f $ExpectedMachineIdSha256,$machineHash)
    }
}

$scope = [string]$receipt.capture.scope
if ([string]::IsNullOrWhiteSpace($scope) -or $scope.Length -gt 2048) { throw 'Semantic receipt scope is invalid.' }
$sourceKind = [string]$receipt.capture.source_kind
if ([string]::IsNullOrWhiteSpace($sourceKind) -or $sourceKind.Length -gt 128 -or $sourceKind -match '[\r\n]') {
    throw 'Semantic receipt source_kind is invalid.'
}

if (-not (Test-NxbSemanticIntegerValue -Value $receipt.capture.bounded_session_seconds)) {
    throw 'Semantic receipt bounded_session_seconds must be an integer.'
}
$boundedSeconds = [int64]$receipt.capture.bounded_session_seconds
if ($boundedSeconds -lt 1 -or $boundedSeconds -gt 86400) { throw 'Semantic receipt bounded_session_seconds is outside the allowed range.' }

$startedUtc = Get-NxbSemanticUtcDate -Value $receipt.capture.started_utc
$endedUtc = Get-NxbSemanticUtcDate -Value $receipt.capture.ended_utc
if ($endedUtc -le $startedUtc) { throw 'Semantic receipt capture end must be after capture start.' }
$observedSeconds = ($endedUtc - $startedUtc).TotalSeconds
if ($observedSeconds -gt ([double]$boundedSeconds + 0.001)) {
    throw ('Semantic receipt observed duration exceeds bounded_session_seconds: observed={0} bounded={1}' -f $observedSeconds,$boundedSeconds)
}

if (-not (Test-NxbSemanticIntegerValue -Value $receipt.evidence.artifact_count)) {
    throw 'Semantic receipt artifact_count must be an integer.'
}
$artifactCount = [int64]$receipt.evidence.artifact_count
if ($artifactCount -lt 0 -or $artifactCount -gt 1000000) { throw 'Semantic receipt artifact_count is outside the allowed range.' }
$artifactIndexHash = [string]$receipt.evidence.artifact_index_sha256
if (-not (Test-NxbSemanticHexText -Text $artifactIndexHash -Length 64)) {
    throw 'Semantic receipt artifact_index_sha256 is not lowercase 64-hex.'
}

foreach ($booleanName in @('negative_controls_passed','cleanup_verified','independent_validation_passed')) {
    $booleanProperty = $receipt.validation.PSObject.Properties[$booleanName]
    if ($null -eq $booleanProperty -or $booleanProperty.Value -isnot [bool]) {
        throw ('Semantic receipt validation.{0} must be boolean.' -f $booleanName)
    }
}

$validatorName = [string]$receipt.validation.validator_name
$validatorVersion = [string]$receipt.validation.validator_version
if ([string]::IsNullOrWhiteSpace($validatorName) -or $validatorName.Length -gt 128 -or $validatorName -match '[\r\n]') {
    throw 'Semantic receipt validator_name is invalid.'
}
if ([string]::IsNullOrWhiteSpace($validatorVersion) -or $validatorVersion.Length -gt 64 -or $validatorVersion -match '[\r\n]') {
    throw 'Semantic receipt validator_version is invalid.'
}
$validatorHash = [string]$receipt.validation.validator_implementation_sha256
if (-not (Test-NxbSemanticHexText -Text $validatorHash -Length 64)) {
    throw 'Semantic receipt validator_implementation_sha256 is not lowercase 64-hex.'
}

if ($receipt.validation.limitations -isnot [System.Array]) { throw 'Semantic receipt limitations must be an array.' }
$limitationArray = @($receipt.validation.limitations)
if ($limitationArray.Count -gt 64) { throw 'Semantic receipt limitations exceeds 64 entries.' }
foreach ($limitationItem in $limitationArray) {
    if ($limitationItem -isnot [string]) { throw 'Semantic receipt limitation entries must be strings.' }
    $limitationText = [string]$limitationItem
    if ([string]::IsNullOrWhiteSpace($limitationText) -or $limitationText.Length -gt 256 -or $limitationText -match '[\r\n]') {
        throw 'Semantic receipt contains an invalid limitation entry.'
    }
}

$promotable = ($status -ceq 'validated')
if ($promotable) {
    if ($artifactCount -lt 1) { throw 'Validated semantic receipt requires at least one evidence artifact.' }
    if (-not [bool]$receipt.validation.negative_controls_passed) { throw 'Validated semantic receipt requires negative controls to pass.' }
    if (-not [bool]$receipt.validation.cleanup_verified) { throw 'Validated semantic receipt requires cleanup verification.' }
    if (-not [bool]$receipt.validation.independent_validation_passed) { throw 'Validated semantic receipt requires independent validation.' }
}

$fingerprint = [string]$receipt.receipt_fingerprint_sha256
if (-not (Test-NxbSemanticHexText -Text $fingerprint -Length 64)) { throw 'Semantic receipt fingerprint is not lowercase 64-hex.' }
$canonicalMaterial = Get-NxbSemanticCanonicalMaterial -Receipt $receipt
$computedFingerprint = Get-NxbSemanticSha256Text -Text $canonicalMaterial
if ($computedFingerprint -cne $fingerprint) {
    throw ('Semantic receipt fingerprint mismatch: expected={0} computed={1}' -f $fingerprint,$computedFingerprint)
}

$receiptFileHash = Get-NxbSemanticSha256File -Path $receiptFull
$result = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    promotable = $promotable
    claim_name = $claim
    receipt_id = $receiptId
    repository = $repository
    exact_head = $exactHead
    policy_sha256 = $policyHash
    machine_id_sha256 = $machineHash
    artifact_count = $artifactCount
    receipt_fingerprint_sha256 = $computedFingerprint
    receipt_file_sha256 = $receiptFileHash
}

if ($PassThru) { return $result }
$result | ConvertTo-Json -Depth 10
