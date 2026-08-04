[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ToolPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$InvocationName,

    [Parameter()]
    [AllowEmptyCollection()]
    [string[]]$ArgumentList = @(),

    [Parameter()]
    [AllowEmptyCollection()]
    [int[]]$SensitiveArgumentIndex = @(),

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$CollectorId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SessionId,

    [Parameter()]
    [ValidateSet('not_run', 'succeeded', 'failed')]
    [string]$Status = 'not_run',

    [Parameter()]
    [Nullable[int]]$ExitCode,

    [Parameter()]
    [DateTime]$CapturedUtc = [DateTime]::UtcNow,

    [Parameter()]
    [ValidateRange(-1, 9223372036854775807)]
    [int64]$MonotonicNs = -1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Nxb.EvidenceStore.psm1') -Force

$toolFull = Get-NxbFullPath -Path $ToolPath
$toolItem = Get-Item -LiteralPath $toolFull -Force
if ($toolItem.PSIsContainer) {
    throw "Tool path bir dosya olmalıdır: $toolFull"
}

$redactedIndexes = [Collections.Generic.HashSet[int]]::new()
foreach ($index in $SensitiveArgumentIndex) {
    if ($index -lt 0 -or $index -ge $ArgumentList.Count) {
        throw "Sensitive argument index aralık dışında: $index"
    }
    [void]$redactedIndexes.Add($index)
}

$normalizedArguments = [Collections.Generic.List[string]]::new()
for ($index = 0; $index -lt $ArgumentList.Count; $index++) {
    if ($redactedIndexes.Contains($index)) {
        [void]$normalizedArguments.Add('<redacted>')
    }
    else {
        [void]$normalizedArguments.Add([string]$ArgumentList[$index])
    }
}

$argumentEnvelope = [ordered]@{
    arguments = [object[]]$normalizedArguments.ToArray()
}
$argumentDigest = Get-NxbCanonicalJsonHash -InputObject $argumentEnvelope
$fileHash = (Get-FileHash -LiteralPath $toolFull -Algorithm SHA256).Hash.ToLowerInvariant()
$versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($toolFull)

$payload = [ordered]@{
    provenance_version = 1
    tool_kind = 'local_file'
    tool_path = $toolFull
    tool_sha256 = $fileHash
    tool_length = [int64]$toolItem.Length
    last_write_utc = $toolItem.LastWriteTimeUtc.ToString(
        'yyyy-MM-ddTHH:mm:ss.fffffffZ',
        [Globalization.CultureInfo]::InvariantCulture
    )
    file_version = if ([string]::IsNullOrWhiteSpace($versionInfo.FileVersion)) {
        $null
    }
    else {
        [string]$versionInfo.FileVersion
    }
    product_version = if ([string]::IsNullOrWhiteSpace($versionInfo.ProductVersion)) {
        $null
    }
    else {
        [string]$versionInfo.ProductVersion
    }
    invocation_name = $InvocationName
    argument_digest_sha256 = $argumentDigest
    argument_count = [int64]$ArgumentList.Count
    redacted_argument_count = [int64]$redactedIndexes.Count
    collector_id = $CollectorId
    status = $Status
    exit_code = if ($ExitCode.HasValue) { [int64]$ExitCode.Value } else { $null }
}

& (Join-Path $PSScriptRoot 'New-EvidenceStoreRecord.ps1') `
    -ExperimentPath $ExperimentPath `
    -RecordType tool_provenance `
    -Payload $payload `
    -SessionId $SessionId `
    -CapturedUtc $CapturedUtc `
    -MonotonicNs $MonotonicNs
