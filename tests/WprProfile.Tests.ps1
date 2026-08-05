BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsRoot = Join-Path $script:RepositoryRoot 'scripts'
    $script:ProfilesRoot = Join-Path $script:RepositoryRoot 'profiles'
    $script:CommittedProfile = Join-Path $script:ProfilesRoot 'Nxb.MinimalCpuScheduler.wprp'
}

Describe 'NXB minimal CPU scheduler WPR profile' {
    BeforeEach {
        $script:TestId = [guid]::NewGuid().ToString('N')
        $script:TemporaryProfile = Join-Path $script:ProfilesRoot ("test-$($script:TestId).wprp")
        $script:TemporaryLink = Join-Path $script:ProfilesRoot ("linked-$($script:TestId)")
        $script:OutsideRoot = Join-Path ([IO.Path]::GetTempPath()) ("nxb-wpr-profile-$($script:TestId)")
        New-Item -ItemType Directory -Path $script:OutsideRoot -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TemporaryProfile) {
            Remove-Item -LiteralPath $script:TemporaryProfile -Force
        }
        if (Test-Path -LiteralPath $script:TemporaryLink) {
            $cmdPath = Join-Path $env:SystemRoot 'System32\cmd.exe'
            & $cmdPath /d /c "rmdir `"$script:TemporaryLink`"" | Out-Null
            if ($LASTEXITCODE -ne 0 -and (Test-Path -LiteralPath $script:TemporaryLink)) {
                throw "Test junction temizlenemedi: $script:TemporaryLink"
            }
        }
        if (Test-Path -LiteralPath $script:OutsideRoot) {
            Remove-Item -LiteralPath $script:OutsideRoot -Recurse -Force
        }
    }

    It 'validates the committed bounded file and memory profile pair' {
        $result = & (Join-Path $script:ScriptsRoot 'Test-WprProfile.ps1') -PassThru

        $result.Name | Should -Be 'NxbMinimalCpuScheduler'
        $result.DetailLevel | Should -Be 'Verbose'
        $result.RelativePath | Should -Be 'profiles/Nxb.MinimalCpuScheduler.wprp'
        $result.FileProfileId | Should -Be 'NxbMinimalCpuScheduler.Verbose.File'
        $result.MemoryProfileId | Should -Be 'NxbMinimalCpuScheduler.Verbose.Memory'
        $result.FileProfileReference | Should -Match (
            'Nxb\.MinimalCpuScheduler\.wprp!NxbMinimalCpuScheduler\.Verbose$'
        )
        $result.Sha256 | Should -Match '^[0-9a-f]{64}$'
        $result.Length | Should -BeGreaterThan 0
        $result.BufferSizeKiB | Should -Be 1024
        $result.Buffers | Should -Be 64
        $result.MaximumFileSizeMiB | Should -Be 512
        $result.FileMode | Should -Be 'Circular'
        $result.Keywords.Count | Should -Be 10
        $result.Stacks.Count | Should -Be 9
    }

    It 'rejects a profile outside the repository profile root' {
        $outsideProfile = Join-Path $script:OutsideRoot 'external.wprp'
        Copy-Item -LiteralPath $script:CommittedProfile -Destination $outsideProfile

        {
            & (Join-Path $script:ScriptsRoot 'Test-WprProfile.ps1') `
                -Path $outsideProfile
        } | Should -Throw '*Yol deney kökünün dışında*'
    }

    It 'rejects a profile reached through a reparse point' {
        $outsideProfile = Join-Path $script:OutsideRoot 'linked.wprp'
        Copy-Item -LiteralPath $script:CommittedProfile -Destination $outsideProfile
        New-Item `
            -ItemType Junction `
            -Path $script:TemporaryLink `
            -Target $script:OutsideRoot | Out-Null

        {
            & (Join-Path $script:ScriptsRoot 'Test-WprProfile.ps1') `
                -Path (Join-Path $script:TemporaryLink 'linked.wprp')
        } | Should -Throw '*Reparse point*'
    }

    It 'rejects a DTD-bearing profile before contract evaluation' {
        @'
<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE WindowsPerformanceRecorder [<!ENTITY xxe SYSTEM "file:///C:/Windows/win.ini">]>
<WindowsPerformanceRecorder Version="1.0">
  <Profiles>&xxe;</Profiles>
</WindowsPerformanceRecorder>
'@ | Set-Content -LiteralPath $script:TemporaryProfile -Encoding UTF8

        {
            & (Join-Path $script:ScriptsRoot 'Test-WprProfile.ps1') `
                -Path $script:TemporaryProfile
        } | Should -Throw '*güvenli XML olarak ayrıştırılamadı*'
    }

    It 'rejects a changed kernel keyword set' {
        $content = Get-Content -LiteralPath $script:CommittedProfile -Raw
        $content = $content.Replace(
            '<Keyword Value="ReadyThread" />',
            '<Keyword Value="DiskIO" />'
        )
        Set-Content -LiteralPath $script:TemporaryProfile -Value $content -Encoding UTF8

        {
            & (Join-Path $script:ScriptsRoot 'Test-WprProfile.ps1') `
                -Path $script:TemporaryProfile
        } | Should -Throw '*keyword set zorunlu değeri içermiyor: ReadyThread*'
    }

    It 'rejects an unbounded or differently bounded file collector' {
        $content = Get-Content -LiteralPath $script:CommittedProfile -Raw
        $content = $content.Replace(
            '<MaximumFileSize Value="512" FileMode="Circular" />',
            '<MaximumFileSize Value="1024" FileMode="Sequential" />'
        )
        Set-Content -LiteralPath $script:TemporaryProfile -Value $content -Encoding UTF8

        {
            & (Join-Path $script:ScriptsRoot 'Test-WprProfile.ps1') `
                -Path $script:TemporaryProfile
        } | Should -Throw '*MaximumFileSize değeri 512 MiB olmalıdır*'
    }

    It 'rejects a profile without the matching memory variant' {
        $document = [System.Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.Load($script:CommittedProfile)
        $memoryProfile = $document.SelectSingleNode(
            "/WindowsPerformanceRecorder/Profiles/Profile[@Id='NxbMinimalCpuScheduler.Verbose.Memory']"
        )
        [void]$memoryProfile.ParentNode.RemoveChild($memoryProfile)
        $document.Save($script:TemporaryProfile)

        {
            & (Join-Path $script:ScriptsRoot 'Test-WprProfile.ps1') `
                -Path $script:TemporaryProfile
        } | Should -Throw '*tam olarak iki File/Memory varyantı*'
    }
}
