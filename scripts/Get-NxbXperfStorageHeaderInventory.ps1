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
if ([string]::IsNullOrWhiteSpace($outputParent)) {
    throw "Output parent could not be resolved: $outputFull"
}
[IO.Directory]::CreateDirectory($outputParent) | Out-Null

$headers = [Collections.Generic.List[object]]::new()
$candidates = [Collections.Generic.List[object]]::new()
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$reader = [IO.StreamReader]::new($inputFull, $true)
try {
    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        if ($null -eq $line) {
            break
        }

        $fields = @([string]$line -split ',' | ForEach-Object { $_.Trim() })
        if ($fields.Count -lt 2) {
            continue
        }
        if ([string]$fields[1] -cne 'TimeStamp') {
            continue
        }

        $eventName = [string]$fields[0]
        if ([string]::IsNullOrWhiteSpace($eventName)) {
            continue
        }
        if (-not $seen.Add([string]$line)) {
            continue
        }

        $entry = [pscustomobject][ordered]@{
            event_name = $eventName
            columns = @($fields[1..($fields.Count - 1)])
            header_text = [string]$line
        }
        $headers.Add($entry)

        if ($eventName -match '(?i)(disk|file|split)') {
            $candidates.Add($entry)
        }
    }
}
finally {
    $reader.Dispose()
}

$document = [pscustomobject][ordered]@{
    schema_version = 1
    source_sha256 = (
        Get-FileHash -LiteralPath $inputFull -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    header_count = $headers.Count
    candidate_storage_header_count = $candidates.Count
    headers = @($headers)
    candidate_storage_headers = @($candidates)
    claims = [ordered]@{
        event_rows_included = $false
        raw_etl_included = $false
        candidate_name_match_implies_semantics = $false
        queue_semantics = 'not_claimed'
        latency_semantics = 'not_claimed'
        throughput_semantics = 'not_claimed'
        iops_semantics = 'not_claimed'
        parser_completeness = 'not_claimed'
    }
}

[IO.File]::WriteAllText(
    $outputFull,
    ($document | ConvertTo-Json -Depth 16),
    [Text.UTF8Encoding]::new($false)
)

Write-Information `
    -MessageData "Xperf storage header inventory written: $outputFull" `
    -InformationAction Continue

if ($PassThru) {
    return $document
}
