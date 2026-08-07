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
$outputParent = Split-Path -Parent $outputFull
if ([string]::IsNullOrWhiteSpace($outputParent)) {
    throw "Output parent could not be resolved: $outputFull"
}
[IO.Directory]::CreateDirectory($outputParent) | Out-Null

$headers = [Collections.Generic.List[object]]::new()
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($line in Get-Content -LiteralPath $inputFull) {
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

    $headers.Add([pscustomobject][ordered]@{
        event_name = $eventName
        columns = @($fields[1..($fields.Count - 1)])
        header_text = [string]$line
    })
}

$document = [pscustomobject][ordered]@{
    schema_version = 1
    source_sha256 = (
        Get-FileHash -LiteralPath $inputFull -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    header_count = $headers.Count
    headers = @($headers)
    claims = [ordered]@{
        event_rows_included = $false
        raw_etl_included = $false
        parser_completeness = 'not_claimed'
    }
}

[IO.File]::WriteAllText(
    $outputFull,
    ($document | ConvertTo-Json -Depth 16),
    [Text.UTF8Encoding]::new($false)
)

Write-Host "Xperf header inventory written: $outputFull"
if ($PassThru) {
    return $document
}
