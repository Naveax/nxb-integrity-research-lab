Set-StrictMode -Version Latest

function Get-NxbFinalSha256Text {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Get-NxbFinalFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-NxbFinalAtomicJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$InputObject
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    $tempPath = $fullPath + '.tmp-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $tempPath,
            (($InputObject | ConvertTo-Json -Depth 64) + [Environment]::NewLine),
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $tempPath -Destination $fullPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

function ConvertTo-NxbFinalCanonicalNode {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [char] -or $Value -is [bool] -or
        $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or $Value -is [single] -or
        $Value -is [double] -or $Value -is [decimal]) {
        return $Value
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)) {
            $result[$key] = ConvertTo-NxbFinalCanonicalNode -Value $Value[$key]
        }
        return $result
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        return @($Value | ForEach-Object { ConvertTo-NxbFinalCanonicalNode -Value $_ })
    }

    $objectResult = [ordered]@{}
    foreach ($name in @($Value.PSObject.Properties.Name | Sort-Object -CaseSensitive)) {
        $objectResult[$name] = ConvertTo-NxbFinalCanonicalNode -Value $Value.PSObject.Properties[$name].Value
    }
    return $objectResult
}

function Get-NxbFinalCanonicalJsonSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$InputObject)
    $canonical = ConvertTo-NxbFinalCanonicalNode -Value $InputObject
    $json = $canonical | ConvertTo-Json -Depth 64 -Compress
    return Get-NxbFinalSha256Text -Text $json
}

function Get-NxbFinalFindingId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$RootCauseKey,
        [Parameter(Mandatory)][string]$Class,
        [Parameter(Mandatory)][string]$EvidenceSha256
    )
    if ($EvidenceSha256.Length -ne 64 -or $EvidenceSha256 -cnotmatch '^[0-9a-f]+$') {
        throw 'Evidence SHA-256 must be 64 lowercase hex characters.'
    }
    $material = @($TargetId,$RootCauseKey,$Class,$EvidenceSha256) -join "`n"
    return 'finding-' + (Get-NxbFinalSha256Text -Text $material).Substring(0,32)
}

function Invoke-NxbFinalFindingCorrelation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Observation,
        [Parameter(Mandatory)][ValidateRange(1,4096)][int]$MaximumFindings
    )

    $seenEvidence = @{}
    $grouped = [ordered]@{}
    foreach ($item in @($Observation)) {
        $targetId = [string]$item.target_id
        $sessionId = [string]$item.session_id
        $className = [string]$item.class
        $rootCauseKey = [string]$item.root_cause_key
        $evidenceSha = [string]$item.evidence_sha256
        if ([string]::IsNullOrWhiteSpace($targetId) -or [string]::IsNullOrWhiteSpace($sessionId) -or
            [string]::IsNullOrWhiteSpace($className) -or [string]::IsNullOrWhiteSpace($rootCauseKey)) {
            throw 'Finding observation identity fields are required.'
        }
        if ($evidenceSha.Length -ne 64 -or $evidenceSha -cnotmatch '^[0-9a-f]+$') {
            throw 'Finding observation evidence hash is invalid.'
        }
        if ($seenEvidence.ContainsKey($evidenceSha)) { continue }
        $seenEvidence[$evidenceSha] = $true
        $groupKey = @($targetId,$sessionId,$className,$rootCauseKey) -join '|'
        if (-not $grouped.Contains($groupKey)) {
            $grouped[$groupKey] = [Collections.Generic.List[object]]::new()
        }
        $grouped[$groupKey].Add($item)
    }

    $findings = [Collections.Generic.List[object]]::new()
    foreach ($groupKey in @($grouped.Keys | Sort-Object -CaseSensitive)) {
        $rows = @($grouped[$groupKey])
        if ($rows.Count -eq 0) { continue }
        $first = $rows[0]
        $evidenceHashes = @($rows | ForEach-Object { [string]$_.evidence_sha256 } | Sort-Object -Unique)
        $aggregateEvidenceSha = Get-NxbFinalSha256Text -Text ($evidenceHashes -join "`n")
        $findingId = Get-NxbFinalFindingId -TargetId ([string]$first.target_id) -RootCauseKey ([string]$first.root_cause_key) -Class ([string]$first.class) -EvidenceSha256 $aggregateEvidenceSha
        $severityHints = @($rows | ForEach-Object { [string]$_.severity_hint } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        $findings.Add([pscustomobject][ordered]@{
            finding_id = $findingId
            target_id = [string]$first.target_id
            session_id = [string]$first.session_id
            class = [string]$first.class
            root_cause_key = [string]$first.root_cause_key
            evidence_sha256 = $aggregateEvidenceSha
            evidence_count = $evidenceHashes.Count
            evidence_hashes = $evidenceHashes
            severity_hints = $severityHints
            severity_promoted = $false
        })
        if ($findings.Count -gt $MaximumFindings) {
            throw 'Finding count exceeded the configured bound.'
        }
    }
    return @($findings | Sort-Object finding_id)
}

function Test-NxbFinalAuthorizedRequestPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Policy,
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][bool]$CertificationMode
    )

    $hostName = [string]$Plan.host
    $method = ([string]$Plan.method).ToUpperInvariant()
    $requestCount = [int]$Plan.request_count
    $responseBudget = [int64]$Plan.maximum_response_bytes
    if ($requestCount -lt 1 -or $requestCount -gt [int]$Policy.certification.maximum_requests) { return $false }
    if ($responseBudget -lt 1 -or $responseBudget -gt [int64]$Policy.certification.maximum_response_bytes) { return $false }

    if ($CertificationMode) {
        if (@($Policy.certification.allowed_hosts) -cnotcontains $hostName) { return $false }
        if (@($Policy.certification.allowed_methods) -cnotcontains $method) { return $false }
        if ([bool]$Plan.production_secret_attached) { return $false }
        return $true
    }

    $permitScopeId = [string]$Plan.permit_scope_id
    $permitHost = [string]$Plan.permit_host
    $permitMethod = ([string]$Plan.permit_method).ToUpperInvariant()
    $permitSha = [string]$Plan.permit_sha256
    if ([string]::IsNullOrWhiteSpace($permitScopeId) -or [string]::IsNullOrWhiteSpace($permitHost) -or [string]::IsNullOrWhiteSpace($permitMethod)) { return $false }
    if ($hostName -cne $permitHost -or $method -cne $permitMethod) { return $false }
    $permitMaterial = @('nxb-part7-permit-v1',$permitScopeId,$permitHost,$permitMethod) -join "`n"
    $expectedPermitSha = Get-NxbFinalSha256Text -Text $permitMaterial
    if ($permitSha -cne $expectedPermitSha) { return $false }
    if (-not [bool]$Plan.scope_authorized) { return $false }
    if (-not [bool]$Plan.kill_switch_armed) { return $false }
    if ([bool]$Plan.production_secret_attached) { return $false }
    return $true
}

function Protect-NxbFinalSecretText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Secret
    )
    $result = $Text
    foreach ($secretValue in @($Secret)) {
        if ([string]::IsNullOrEmpty($secretValue)) { continue }
        $result = $result.Replace($secretValue,'[REDACTED]')
    }
    return $result
}

function Get-NxbFinalArtifactManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Path)
    $rows = foreach ($itemPath in @($Path | Sort-Object -Unique)) {
        $fullPath = [IO.Path]::GetFullPath($itemPath)
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw ('Artifact missing: {0}' -f $fullPath)
        }
        $file = Get-Item -LiteralPath $fullPath
        [pscustomobject][ordered]@{
            name = $file.Name
            bytes = [int64]$file.Length
            sha256 = Get-NxbFinalFileSha256 -Path $fullPath
        }
    }
    return @($rows | Sort-Object name)
}

function Test-NxbFinalPackageManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][string]$ExpectedVersion
    )
    if ([string]$Manifest.version -cne $ExpectedVersion) { return $false }
    $fingerprint = [string]$Manifest.signer_fingerprint_sha256
    if ($fingerprint.Length -ne 64 -or $fingerprint -cnotmatch '^[0-9a-f]+$') { return $false }
    if (-not [bool]$Manifest.staged_only) { return $false }
    if ([bool]$Manifest.auto_apply) { return $false }
    foreach ($file in @($Manifest.files)) {
        $hash = [string]$file.sha256
        if ($hash.Length -ne 64 -or $hash -cnotmatch '^[0-9a-f]+$') { return $false }
        if ([int64]$file.bytes -lt 0) { return $false }
    }
    return $true
}

function Get-NxbFinalReportObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExactHead,
        [Parameter(Mandatory)][string]$ReleaseVersion,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Finding,
        [Parameter(Mandatory)][object]$PartStatus
    )
    $findingRows = @($Finding | Sort-Object finding_id)
    return [pscustomobject][ordered]@{
        schema_version = 1
        release_version = $ReleaseVersion
        exact_head = $ExactHead
        status = 'candidate'
        finding_count = $findingRows.Count
        findings = $findingRows
        parts = $PartStatus
        production_merge_performed = $false
    }
}
