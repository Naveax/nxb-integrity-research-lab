Set-StrictMode -Version Latest

function ConvertFrom-NxbTransportHex {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]+$')][string]$Hex)

    if (($Hex.Length % 2) -ne 0) { throw 'Hex input must contain an even number of characters.' }
    $bytes = [byte[]]::new($Hex.Length / 2)
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        $bytes[$index] = [Convert]::ToByte($Hex.Substring($index * 2,2),16)
    }
    return $bytes
}

function Get-NxbTransportSha256Text {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Get-NxbTransportPayloadText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object]$Payload)

    if ($null -eq $Payload) { return 'null' }
    return ($Payload | ConvertTo-Json -Depth 16 -Compress)
}

function Get-NxbTransportCanonicalMaterial {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Frame)

    return (@(
        'schema=1',
        ('session_id={0}' -f [string]$Frame.session_id),
        ('sender_role={0}' -f [string]$Frame.sender_role),
        ('sequence={0}' -f [int64]$Frame.sequence),
        ('kind={0}' -f [string]$Frame.kind),
        ('payload_sha256={0}' -f [string]$Frame.payload_sha256),
        ('payload_b64={0}' -f [string]$Frame.payload_b64)
    ) -join "`n")
}

function Get-NxbTransportAuthTag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Frame,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$KeyHex
    )

    $key = ConvertFrom-NxbTransportHex -Hex $KeyHex
    $hmac = [Security.Cryptography.HMACSHA256]::new($key)
    try {
        $material = Get-NxbTransportCanonicalMaterial -Frame $Frame
        $bytes = [Text.Encoding]::UTF8.GetBytes($material)
        return (($hmac.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $hmac.Dispose() }
}

function ConvertTo-NxbTransportFrame {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SessionId,
        [Parameter(Mandatory)][ValidateSet('controller','target')][string]$SenderRole,
        [Parameter(Mandatory)][ValidateRange(0,[long]::MaxValue)][long]$Sequence,
        [Parameter(Mandatory)][ValidateSet('event','drain','resume','emergency_stop','shutdown','ack','reject','status')][string]$Kind,
        [Parameter(Mandatory)][AllowNull()][object]$Payload,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$KeyHex
    )

    $payloadText = Get-NxbTransportPayloadText -Payload $Payload
    $payloadBytes = [Text.Encoding]::UTF8.GetBytes($payloadText)
    $payloadB64 = [Convert]::ToBase64String($payloadBytes)
    $frame = [pscustomobject][ordered]@{
        schema_version = 1
        session_id = $SessionId
        sender_role = $SenderRole
        sequence = [int64]$Sequence
        kind = $Kind
        payload_sha256 = Get-NxbTransportSha256Text -Text $payloadText
        payload_b64 = $payloadB64
        auth_tag = ''
    }
    $frame.auth_tag = Get-NxbTransportAuthTag -Frame $frame -KeyHex $KeyHex
    return $frame
}

function Test-NxbTransportFrame {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Frame,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$KeyHex,
        [Parameter()][AllowNull()][string]$ExpectedSessionId,
        [Parameter()][AllowNull()][string]$ExpectedSenderRole
    )

    if ([int]$Frame.schema_version -ne 1) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSessionId) -and [string]$Frame.session_id -cne $ExpectedSessionId) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSenderRole) -and [string]$Frame.sender_role -cne $ExpectedSenderRole) { return $false }
    if ([string]$Frame.payload_sha256 -notmatch '^[0-9a-f]{64}$') { return $false }
    if ([string]$Frame.auth_tag -notmatch '^[0-9a-f]{64}$') { return $false }

    try {
        $payloadBytes = [Convert]::FromBase64String([string]$Frame.payload_b64)
        $payloadText = [Text.Encoding]::UTF8.GetString($payloadBytes)
    }
    catch { return $false }

    if ((Get-NxbTransportSha256Text -Text $payloadText) -cne [string]$Frame.payload_sha256) { return $false }
    $expectedTag = Get-NxbTransportAuthTag -Frame $Frame -KeyHex $KeyHex
    return ([string]$Frame.auth_tag -ceq $expectedTag)
}

function Get-NxbTransportPayloadObject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Frame)

    $payloadBytes = [Convert]::FromBase64String([string]$Frame.payload_b64)
    $payloadText = [Text.Encoding]::UTF8.GetString($payloadBytes)
    return ($payloadText | ConvertFrom-Json)
}

function ConvertTo-NxbTransportJsonLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Frame)
    return ($Frame | ConvertTo-Json -Depth 16 -Compress)
}

function ConvertFrom-NxbTransportJsonLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Line)
    return ($Line | ConvertFrom-Json)
}
