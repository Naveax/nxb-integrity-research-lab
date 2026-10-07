[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CycleObservationJsonPath,
    [Parameter(Mandatory = $true)][string]$ExpectedCandidateSha,
    [Parameter(Mandatory = $true)][string]$ExpectedCandidateTree,
    [Parameter(Mandatory = $true)][string]$ExpectedCellId,
    [Parameter(Mandatory = $true)][string]$ExpectedFingerprintSha256,
    [Parameter(Mandatory = $true)][string]$ExpectedPolicySha256,
    [Parameter(Mandatory = $true)][string]$ExpectedIntentSha256,
    [Parameter(Mandatory = $true)][string]$EvidenceStoreModulePath,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'PowerShell 7 required.'
}

$ExpectedEvidenceStoreSha256 = '207a3e379e411fa6761f21cf01810135572d87033779ec8f791fa0befcd17cd7'
$Git40Pattern = '^[0-9a-f]{40}$'
$Sha256Pattern = '^[0-9a-f]{64}$'
$CellIdPattern = '^[a-z0-9]+(?:-[a-z0-9]+)*$'
$UtcPattern = '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
$Utf8 = [Text.UTF8Encoding]::new($false, $true)

function Fail {
    param([Parameter(Mandatory = $true)][string]$Message)
    throw $Message
}

function Assert-LowerHex {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($Value -cnotmatch $Pattern) {
        Fail "$Label has invalid lowercase hexadecimal form."
    }
}

function Assert-OrdinaryFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathFullyQualified($Path)) {
        Fail "$Label must be an absolute path."
    }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.Equals($Path, [StringComparison]::OrdinalIgnoreCase)) {
        Fail "$Label must be normalized: $Path"
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Fail "$Label does not exist: $full"
    }
    $item = Get-Item -LiteralPath $full -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "$Label is reparse-backed: $full"
    }
    return $full
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Assert-NfcString {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($Value.Normalize([Text.NormalizationForm]::FormC) -cne $Value) {
        Fail "$Label is not NFC-normalized."
    }
    foreach ($character in $Value.ToCharArray()) {
        $code = [int][char]$character
        if ($code -ge 0xD800 -and $code -le 0xDFFF) {
            Fail "$Label contains a surrogate code unit."
        }
    }
}

function Assert-JsonElementProfile {
    param(
        [Parameter(Mandatory = $true)][Text.Json.JsonElement]$Element,
        [Parameter(Mandatory = $true)][string]$Label
    )

    switch ($Element.ValueKind) {
        ([Text.Json.JsonValueKind]::Object) {
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($property in $Element.EnumerateObject()) {
                Assert-NfcString -Value $property.Name -Label "$Label key"
                if (-not $seen.Add($property.Name)) {
                    Fail "duplicate JSON key: $($property.Name)"
                }
                Assert-JsonElementProfile -Element $property.Value -Label "$Label.$($property.Name)"
            }
            break
        }
        ([Text.Json.JsonValueKind]::Array) {
            $index = 0
            foreach ($child in $Element.EnumerateArray()) {
                Assert-JsonElementProfile -Element $child -Label "$Label[$index]"
                $index++
            }
            break
        }
        ([Text.Json.JsonValueKind]::String) {
            Assert-NfcString -Value $Element.GetString() -Label $Label
            break
        }
        ([Text.Json.JsonValueKind]::Number) {
            [long]$integer = 0
            if (-not $Element.TryGetInt64([ref]$integer)) {
                Fail "$Label contains a non-Int64 JSON number."
            }
            break
        }
        ([Text.Json.JsonValueKind]::Undefined) {
            Fail "$Label contains an undefined JSON value."
        }
    }
}

function Read-StrictJsonObject {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = Assert-OrdinaryFile -Path $Path -Label 'CycleObservationJsonPath'
    $bytes = [IO.File]::ReadAllBytes($full)
    if ($bytes.Length -eq 0) {
        Fail 'cycle observation is empty.'
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Fail 'cycle observation contains a UTF-8 BOM.'
    }
    $text = $Utf8.GetString($bytes)
    $options = [Text.Json.JsonDocumentOptions]::new()
    $options.AllowTrailingCommas = $false
    $options.CommentHandling = [Text.Json.JsonCommentHandling]::Disallow
    $options.MaxDepth = 50
    $jsonDocument = [Text.Json.JsonDocument]::Parse($text, $options)
    try {
        if ($jsonDocument.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
            Fail 'cycle observation root must be an object.'
        }
        Assert-JsonElementProfile -Element $jsonDocument.RootElement -Label 'cycle observation'
    }
    finally {
        $jsonDocument.Dispose()
    }

    $document = $text | ConvertFrom-Json -Depth 50 -DateKind String
    if ($document -isnot [pscustomobject]) {
        Fail 'cycle observation root must deserialize to an object.'
    }
    return $document
}

function Assert-ExactPropertySet {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $actual = [string[]]@($Object.PSObject.Properties.Name)
    [Array]::Sort($actual, [StringComparer]::Ordinal)
    $expectedSorted = [string[]]@($Expected)
    [Array]::Sort($expectedSorted, [StringComparer]::Ordinal)
    if ($actual.Count -ne $expectedSorted.Count) {
        Fail "$Label property cardinality mismatch."
    }
    for ($index = 0; $index -lt $actual.Count; $index++) {
        if ($actual[$index] -cne $expectedSorted[$index]) {
            Fail "$Label property mismatch: expected=$($expectedSorted[$index]) actual=$($actual[$index])"
        }
    }
}

function Assert-IntegerRange {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][long]$Minimum,
        [Parameter(Mandatory = $true)][long]$Maximum,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($Value -isnot [sbyte] -and
        $Value -isnot [byte] -and
        $Value -isnot [int16] -and
        $Value -isnot [uint16] -and
        $Value -isnot [int32] -and
        $Value -isnot [uint32] -and
        $Value -isnot [int64]) {
        Fail "$Label must be an integer."
    }
    $number = [long]$Value
    if ($number -lt $Minimum -or $number -gt $Maximum) {
        Fail "$Label is outside [$Minimum,$Maximum]: $number"
    }
}

function Assert-BooleanValue {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][bool]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($Value -isnot [bool] -or [bool]$Value -ne $Expected) {
        Fail "$Label must be $Expected."
    }
}

function Assert-ExactString {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($Value -isnot [string] -or [string]$Value -cne $Expected) {
        Fail "$Label mismatch."
    }
}

function Assert-UtcRange {
    param(
        [Parameter(Mandatory = $true)][string]$Started,
        [Parameter(Mandatory = $true)][string]$Finished
    )
    if ($Started -cnotmatch $UtcPattern -or $Finished -cnotmatch $UtcPattern) {
        Fail 'cycle timestamps must be exact UTC second-resolution Z strings.'
    }
    $start = [DateTimeOffset]::ParseExact(
        $Started,
        'yyyy-MM-ddTHH:mm:ssZ',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal
    )
    $finish = [DateTimeOffset]::ParseExact(
        $Finished,
        'yyyy-MM-ddTHH:mm:ssZ',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal
    )
    if ($finish -le $start) {
        Fail 'cycle finished_utc must be later than started_utc.'
    }
}

Assert-LowerHex -Value $ExpectedCandidateSha -Pattern $Git40Pattern -Label 'ExpectedCandidateSha'
Assert-LowerHex -Value $ExpectedCandidateTree -Pattern $Git40Pattern -Label 'ExpectedCandidateTree'
Assert-LowerHex -Value $ExpectedFingerprintSha256 -Pattern $Sha256Pattern -Label 'ExpectedFingerprintSha256'
Assert-LowerHex -Value $ExpectedPolicySha256 -Pattern $Sha256Pattern -Label 'ExpectedPolicySha256'
Assert-LowerHex -Value $ExpectedIntentSha256 -Pattern $Sha256Pattern -Label 'ExpectedIntentSha256'
if ($ExpectedCellId -cnotmatch $CellIdPattern) {
    Fail 'ExpectedCellId has invalid form.'
}

$modulePath = Assert-OrdinaryFile -Path $EvidenceStoreModulePath -Label 'EvidenceStoreModulePath'
$moduleSha = (Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($moduleSha -cne $ExpectedEvidenceStoreSha256) {
    Fail "EvidenceStore module SHA-256 drift: expected=$ExpectedEvidenceStoreSha256 actual=$moduleSha"
}
Import-Module -Name $modulePath -Force -ErrorAction Stop
$canonicalCommand = Get-Command -Name 'ConvertTo-NxbCanonicalJson' -CommandType Function -ErrorAction Stop
if (-not ([string]$canonicalCommand.Module.Path).Equals($modulePath, [StringComparison]::OrdinalIgnoreCase)) {
    Fail "ConvertTo-NxbCanonicalJson resolved from unexpected module: $($canonicalCommand.Module.Path)"
}

$cycle = Read-StrictJsonObject -Path $CycleObservationJsonPath

Assert-ExactPropertySet -Object $cycle -Expected @(
    'candidate_sha',
    'candidate_tree_sha',
    'cell_id',
    'elapsed_seconds',
    'fingerprint_after_sha256',
    'fingerprint_before_sha256',
    'finished_utc',
    'index',
    'observability',
    'part3',
    'part4',
    'raw_evidence_sha256',
    'started_utc'
) -Label 'cycle'

Assert-ExactString -Value $cycle.candidate_sha -Expected $ExpectedCandidateSha -Label 'cycle candidate_sha'
Assert-ExactString -Value $cycle.candidate_tree_sha -Expected $ExpectedCandidateTree -Label 'cycle candidate_tree_sha'
Assert-ExactString -Value $cycle.cell_id -Expected $ExpectedCellId -Label 'cycle cell_id'
Assert-ExactString -Value $cycle.fingerprint_before_sha256 -Expected $ExpectedFingerprintSha256 -Label 'cycle fingerprint_before_sha256'
Assert-ExactString -Value $cycle.fingerprint_after_sha256 -Expected $ExpectedFingerprintSha256 -Label 'cycle fingerprint_after_sha256'
Assert-IntegerRange -Value $cycle.index -Minimum 1 -Maximum 24 -Label 'cycle index'
Assert-IntegerRange -Value $cycle.elapsed_seconds -Minimum 1 -Maximum 3600 -Label 'cycle elapsed_seconds'
Assert-UtcRange -Started ([string]$cycle.started_utc) -Finished ([string]$cycle.finished_utc)

Assert-ExactPropertySet -Object $cycle.part4 -Expected @(
    'crash_detected',
    'emergency_recovery_closed',
    'final_resume_closed',
    'graceful_recovery_closed',
    'max_attempts_observed',
    'max_ticks_observed',
    'ready_queue_peak',
    'task_count',
    'tasks_completed'
) -Label 'cycle part4'
Assert-IntegerRange -Value $cycle.part4.task_count -Minimum 24 -Maximum 24 -Label 'part4 task_count'
Assert-IntegerRange -Value $cycle.part4.tasks_completed -Minimum 24 -Maximum 24 -Label 'part4 tasks_completed'
Assert-IntegerRange -Value $cycle.part4.max_ticks_observed -Minimum 1 -Maximum 256 -Label 'part4 max_ticks_observed'
Assert-IntegerRange -Value $cycle.part4.max_attempts_observed -Minimum 1 -Maximum 3 -Label 'part4 max_attempts_observed'
Assert-IntegerRange -Value $cycle.part4.ready_queue_peak -Minimum 0 -Maximum 24 -Label 'part4 ready_queue_peak'
Assert-BooleanValue -Value $cycle.part4.crash_detected -Expected $true -Label 'part4 crash_detected'
Assert-BooleanValue -Value $cycle.part4.graceful_recovery_closed -Expected $true -Label 'part4 graceful_recovery_closed'
Assert-BooleanValue -Value $cycle.part4.emergency_recovery_closed -Expected $true -Label 'part4 emergency_recovery_closed'
Assert-BooleanValue -Value $cycle.part4.final_resume_closed -Expected $true -Label 'part4 final_resume_closed'

Assert-ExactPropertySet -Object $cycle.part3 -Expected @(
    'accounting_closed',
    'high_watermark',
    'low_watermark',
    'max_frame_bytes_observed',
    'max_queue_depth_observed',
    'max_session_seconds_observed',
    'queue_overflow',
    'reconnect_attempts',
    'spool_byte_peak',
    'spool_record_peak',
    'synthetic_event_count'
) -Label 'cycle part3'
Assert-IntegerRange -Value $cycle.part3.synthetic_event_count -Minimum 24 -Maximum 24 -Label 'part3 synthetic_event_count'
Assert-IntegerRange -Value $cycle.part3.max_frame_bytes_observed -Minimum 1 -Maximum 16384 -Label 'part3 max_frame_bytes_observed'
Assert-IntegerRange -Value $cycle.part3.max_session_seconds_observed -Minimum 1 -Maximum 300 -Label 'part3 max_session_seconds_observed'
Assert-IntegerRange -Value $cycle.part3.max_queue_depth_observed -Minimum 0 -Maximum 8 -Label 'part3 max_queue_depth_observed'
Assert-IntegerRange -Value $cycle.part3.high_watermark -Minimum 6 -Maximum 6 -Label 'part3 high_watermark'
Assert-IntegerRange -Value $cycle.part3.low_watermark -Minimum 2 -Maximum 2 -Label 'part3 low_watermark'
Assert-IntegerRange -Value $cycle.part3.spool_record_peak -Minimum 0 -Maximum 64 -Label 'part3 spool_record_peak'
Assert-IntegerRange -Value $cycle.part3.spool_byte_peak -Minimum 0 -Maximum 262144 -Label 'part3 spool_byte_peak'
Assert-IntegerRange -Value $cycle.part3.reconnect_attempts -Minimum 0 -Maximum 3 -Label 'part3 reconnect_attempts'
Assert-IntegerRange -Value $cycle.part3.queue_overflow -Minimum 0 -Maximum 0 -Label 'part3 queue_overflow'
Assert-BooleanValue -Value $cycle.part3.accounting_closed -Expected $true -Label 'part3 accounting_closed'

Assert-ExactPropertySet -Object $cycle.observability -Expected @(
    'disk_bytes',
    'memory_wpr_trigger_count',
    'trace_accounting_closed',
    'trace_lost_events',
    'trace_post_seconds',
    'trace_pre_seconds',
    'trace_ring_bytes',
    'trace_session_seconds'
) -Label 'cycle observability'
Assert-IntegerRange -Value $cycle.observability.memory_wpr_trigger_count -Minimum 0 -Maximum 1 -Label 'observability memory_wpr_trigger_count'
Assert-IntegerRange -Value $cycle.observability.trace_ring_bytes -Minimum 1 -Maximum 67108864 -Label 'observability trace_ring_bytes'
Assert-IntegerRange -Value $cycle.observability.trace_pre_seconds -Minimum 0 -Maximum 30 -Label 'observability trace_pre_seconds'
Assert-IntegerRange -Value $cycle.observability.trace_post_seconds -Minimum 0 -Maximum 30 -Label 'observability trace_post_seconds'
Assert-IntegerRange -Value $cycle.observability.trace_session_seconds -Minimum 0 -Maximum 300 -Label 'observability trace_session_seconds'
Assert-IntegerRange -Value $cycle.observability.disk_bytes -Minimum 0 -Maximum 536870912 -Label 'observability disk_bytes'
Assert-IntegerRange -Value $cycle.observability.trace_lost_events -Minimum 0 -Maximum 0 -Label 'observability trace_lost_events'
Assert-BooleanValue -Value $cycle.observability.trace_accounting_closed -Expected $true -Label 'observability trace_accounting_closed'

Assert-ExactPropertySet -Object $cycle.raw_evidence_sha256 -Expected @(
    'observability',
    'part3',
    'part4',
    'recovery'
) -Label 'cycle raw_evidence_sha256'
foreach ($name in @('observability', 'part3', 'part4', 'recovery')) {
    Assert-LowerHex -Value ([string]$cycle.raw_evidence_sha256.$name) -Pattern $Sha256Pattern -Label "raw_evidence_sha256.$name"
}

$canonicalCycle = ConvertTo-NxbCanonicalJson -InputObject $cycle
$cycleObservationSha256 = Get-Sha256Hex -Bytes ($Utf8.GetBytes($canonicalCycle))

$result = [pscustomobject][ordered]@{
    status = 'ENDURANCE_CYCLE_PREFLIGHT_ONLY'
    admitted = $false
    physical_compatibility_claimed = $false
    workload_executed = $false
    wpt_capture_executed = $false
    repository_mutated = $false
    cycle_index = [int]$cycle.index
    elapsed_seconds = [int]$cycle.elapsed_seconds
    candidate_sha = $ExpectedCandidateSha
    candidate_tree_sha = $ExpectedCandidateTree
    cell_id = $ExpectedCellId
    fingerprint_sha256 = $ExpectedFingerprintSha256
    policy_sha256 = $ExpectedPolicySha256
    intent_sha256 = $ExpectedIntentSha256
    cycle_observation_sha256 = $cycleObservationSha256
}

if ($PassThru) {
    $result
}
