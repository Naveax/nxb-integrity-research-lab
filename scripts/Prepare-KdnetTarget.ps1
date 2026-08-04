[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^(?:\d{1,3}\.){3}\d{1,3}$')]
    [string]$HostIPv4,

    [Parameter()]
    [ValidateRange(50000, 50039)]
    [int]$Port = 50005,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$KdnetDirectory = 'C:\KDNET',

    [Parameter()]
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$kdnetExe = Join-Path $KdnetDirectory 'kdnet.exe'
$nicList = Join-Path $KdnetDirectory 'VerifiedNICList.xml'

foreach ($required in @($kdnetExe, $nicList)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Gerekli dosya bulunamadı: $required"
    }
}

Write-Host 'KDNET NIC desteği denetleniyor...'
$supportOutput = & $kdnetExe 2>&1
$supportOutput | ForEach-Object { Write-Host $_ }

if (-not $Apply) {
    Write-Warning 'Yalnız denetim yapıldı. Boot yapılandırması değiştirilmedi.'
    Write-Host 'Uygulamak için: -Apply'
    return
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'KDNET yapılandırması için PowerShell yönetici olarak çalıştırılmalı.'
}

Write-Warning 'Bu işlem hedef bilgisayarın boot/debug yapılandırmasını değiştirir.'
Write-Warning 'BitLocker kurtarma anahtarının yedekli olduğundan emin olun.'
Write-Warning 'Betik otomatik yeniden başlatma yapmayacaktır.'

$applyOutput = & $kdnetExe $HostIPv4 $Port 2>&1
$applyOutput | Tee-Object -FilePath (Join-Path $KdnetDirectory 'kdnet-configuration-output.txt')

if ($LASTEXITCODE -ne 0) {
    throw 'KDNET yapılandırması başarısız oldu.'
}

Write-Host 'KDNET yapılandırması uygulandı. Çıktıdaki key değerini güvenli saklayın.'
Write-Host 'WinDbg host bağlantısını hazırladıktan sonra hedefi elle yeniden başlatın.'
