[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter()]
    [ValidateRange(4096,1048576)]
    [int]$LoopbackBytes = 65536,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -cne 'Windows_NT') {
    throw 'SUPERBLOCK bounded workload requires Windows.'
}

$outputFull = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $outputFull) {
    throw "OutputPath already exists: $outputFull"
}
$outputDirectory = Split-Path -Parent $outputFull
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
}

$startedUtc = [DateTime]::UtcNow
$listener = $null
$client = $null
$server = $null
$tempFile = Join-Path ([IO.Path]::GetTempPath()) ("nxb-superblock-workload-$([guid]::NewGuid().ToString('N')).bin")
$childExitCode = $null
$dnsAddresses = @()
$registryRead = $false
$fileHash = $null
$loopbackHash = $null
$receivedBytes = 0

try {
    $dnsAddresses = @(
        [Net.Dns]::GetHostAddresses('localhost') |
            ForEach-Object { $_.AddressFamily.ToString() } |
            Sort-Object -Unique
    )

    $versionKey = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    $registryRead = -not [string]::IsNullOrWhiteSpace([string]$versionKey.ProductName)

    $payload = New-Object byte[] $LoopbackBytes
    for ($index = 0; $index -lt $payload.Length; $index++) {
        $payload[$index] = [byte]($index % 251)
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $loopbackHash = ([BitConverter]::ToString($sha.ComputeHash($payload))).Replace('-','').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start()
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $acceptTask = $listener.AcceptTcpClientAsync()
    $client = [Net.Sockets.TcpClient]::new()
    $client.Connect([Net.IPAddress]::Loopback,$port)
    $server = $acceptTask.GetAwaiter().GetResult()

    $clientStream = $client.GetStream()
    $serverStream = $server.GetStream()
    $clientStream.Write($payload,0,$payload.Length)
    $clientStream.Flush()
    $client.Client.Shutdown([Net.Sockets.SocketShutdown]::Send)

    $buffer = New-Object byte[] 16384
    $received = New-Object IO.MemoryStream
    try {
        while (($read = $serverStream.Read($buffer,0,$buffer.Length)) -gt 0) {
            $received.Write($buffer,0,$read)
            $receivedBytes += $read
        }
        $receivedPayload = $received.ToArray()
    }
    finally {
        $received.Dispose()
    }
    if ($receivedBytes -ne $LoopbackBytes) {
        throw "Loopback byte count mismatch: expected=$LoopbackBytes actual=$receivedBytes"
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $receivedHash = ([BitConverter]::ToString($sha.ComputeHash($receivedPayload))).Replace('-','').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
    if ($receivedHash -cne $loopbackHash) {
        throw 'Loopback payload SHA-256 mismatch.'
    }

    [IO.File]::WriteAllBytes($tempFile,$payload)
    $fileHash = (Get-FileHash -LiteralPath $tempFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($fileHash -cne $loopbackHash) {
        throw 'Temporary file SHA-256 mismatch.'
    }
    [void][IO.File]::ReadAllBytes($tempFile)

    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    $childExecutable = if ($null -ne $pwsh) {
        $pwsh.Source
    }
    else {
        Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    $child = Start-Process -FilePath $childExecutable -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-Command','exit 0') -Wait -PassThru -WindowStyle Hidden
    $childExitCode = [int]$child.ExitCode
    if ($childExitCode -ne 0) {
        throw "Bounded child process failed: exit=$childExitCode"
    }
}
finally {
    if ($null -ne $server) { $server.Dispose() }
    if ($null -ne $client) { $client.Dispose() }
    if ($null -ne $listener) { $listener.Stop() }
    if (Test-Path -LiteralPath $tempFile -PathType Leaf) {
        Remove-Item -LiteralPath $tempFile -Force
    }
}

$completedUtc = [DateTime]::UtcNow
$result = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    started_utc = $startedUtc.ToString('o')
    completed_utc = $completedUtc.ToString('o')
    duration_ms = [math]::Round(($completedUtc - $startedUtc).TotalMilliseconds,3)
    loopback = [ordered]@{
        address = '127.0.0.1'
        byte_count = $LoopbackBytes
        received_byte_count = $receivedBytes
        payload_sha256 = $loopbackHash
        external_network_used = $false
    }
    dns = [ordered]@{
        query = 'localhost'
        address_family_count = @($dnsAddresses).Count
        external_name_used = $false
    }
    registry = [ordered]@{
        bounded_read_completed = $registryRead
        write_executed = $false
    }
    file_io = [ordered]@{
        byte_count = $LoopbackBytes
        payload_sha256 = $fileHash
        temporary_file_removed = -not (Test-Path -LiteralPath $tempFile)
    }
    process_lifecycle = [ordered]@{
        child_exit_code = $childExitCode
    }
    gpu = [ordered]@{
        controlled_gpu_workload_executed = $false
        reason = 'GPU provider capture is enabled, but this foundation workload does not claim a controlled GPU stimulus.'
    }
    claims = [ordered]@{
        network_connection_semantics = $false
        network_latency_semantics = $false
        kernel_lifecycle_semantics = $false
        device_lifecycle_semantics = $false
        gpu_present_semantics = $false
        trace_completeness = 'not_claimed'
    }
}
[IO.File]::WriteAllText(
    $outputFull,
    (($result | ConvertTo-Json -Depth 12) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)
Write-Information -MessageData "SUPERBLOCK bounded workload completed: $outputFull" -InformationAction Continue
if ($PassThru) { return $result }
