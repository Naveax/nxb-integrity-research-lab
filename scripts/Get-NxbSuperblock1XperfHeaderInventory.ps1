[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$InputPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$inputFull = [IO.Path]::GetFullPath($InputPath)
$outputFull = [IO.Path]::GetFullPath($OutputPath)
if ($inputFull -ceq $outputFull) {
    throw 'InputPath and OutputPath must be different files.'
}
if (Test-Path -LiteralPath $outputFull) {
    throw "OutputPath already exists: $outputFull"
}
$inputItem = Get-Item -LiteralPath $inputFull -Force
if (($inputItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "InputPath cannot be a reparse point: $inputFull"
}
$outputParent = Split-Path -Parent $outputFull
[IO.Directory]::CreateDirectory($outputParent) | Out-Null

$headers = [Collections.Generic.List[object]]::new()
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$reader = [IO.StreamReader]::new($inputFull,$true)
try {
    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        if ($null -eq $line) { break }
        $fields = @([string]$line -split ',' | ForEach-Object { $_.Trim() })
        if ($fields.Count -lt 2 -or [string]$fields[1] -cne 'TimeStamp') { continue }
        $eventName = [string]$fields[0]
        if ([string]::IsNullOrWhiteSpace($eventName)) { continue }
        if (-not $seen.Add([string]$line)) { continue }
        $domainHint = if ($eventName -match '(?i)(dxg|dxgi|present|gpu|vidmm|vidsch)') {
            'gpu_candidate'
        }
        elseif ($eventName -match '(?i)(tcp|udp|network|winsock|afd|dns|ndis)') {
            'network_candidate'
        }
        elseif ($eventName -match '(?i)(process|thread|image|registry|pnp|driver|module)') {
            'kernel_lifecycle_candidate'
        }
        else {
            'unclassified'
        }
        $headers.Add([pscustomobject][ordered]@{
            event_name = $eventName
            domain_hint = $domainHint
            columns = @($fields[1..($fields.Count - 1)])
        })
    }
}
finally {
    $reader.Dispose()
}

$counts = [ordered]@{
    gpu_candidate = @($headers | Where-Object { $_.domain_hint -ceq 'gpu_candidate' }).Count
    network_candidate = @($headers | Where-Object { $_.domain_hint -ceq 'network_candidate' }).Count
    kernel_lifecycle_candidate = @($headers | Where-Object { $_.domain_hint -ceq 'kernel_lifecycle_candidate' }).Count
    unclassified = @($headers | Where-Object { $_.domain_hint -ceq 'unclassified' }).Count
}
$document = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    source_sha256 = (Get-FileHash -LiteralPath $inputFull -Algorithm SHA256).Hash.ToLowerInvariant()
    header_count = $headers.Count
    candidate_counts = $counts
    headers = @($headers)
    claims = [ordered]@{
        event_rows_included = $false
        event_name_implies_semantics = $false
        domain_hint_implies_semantics = $false
        keyword_semantics_validated = $false
        event_ids_validated = $false
        parser_completeness = 'not_claimed'
        trace_completeness = 'not_claimed'
    }
}
[IO.File]::WriteAllText(
    $outputFull,
    (($document | ConvertTo-Json -Depth 16) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)
Write-Information -MessageData "SUPERBLOCK xperf header inventory written: $outputFull" -InformationAction Continue
if ($PassThru) { return $document }
