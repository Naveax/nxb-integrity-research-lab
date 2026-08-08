BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsRoot = Join-Path $script:RepositoryRoot 'scripts'
    $script:ProfilesRoot = Join-Path $script:RepositoryRoot 'profiles'
    $script:CommittedProfile = Join-Path $script:ProfilesRoot 'Nxb.MemoryWorkingSet.wprp'
}

Describe 'NXB bounded memory and working-set WPR profile' {
    BeforeEach {
        $script:TestId = [guid]::NewGuid().ToString('N')
        $script:TemporaryProfile = Join-Path $script:ProfilesRoot ("memory-test-$($script:TestId).wprp")
        $script:TemporaryLink = Join-Path $script:ProfilesRoot ("memory-linked-$($script:TestId)")
        $script:OutsideRoot = Join-Path ([IO.Path]::GetTempPath()) ("nxb-memory-wpr-$($script:TestId)")
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

    It 'validates the committed bounded memory file and memory profile pair' {
        $result = & (Join-Path $script:ScriptsRoot 'Test-NxbMemoryWprProfile.ps1') -PassThru

        $result.Name | Should -Be 'NxbMemoryWorkingSet'
        $result.DetailLevel | Should -Be 'Verbose'
        $result.RelativePath | Should -Be 'profiles/Nxb.MemoryWorkingSet.wprp'
        $result.FileProfileId | Should -Be 'NxbMemoryWorkingSet.Verbose.File'
        $result.MemoryProfileId | Should -Be 'NxbMemoryWorkingSet.Verbose.Memory'
        $result.FileProfileReference | Should -Match (
            'Nxb\.MemoryWorkingSet\.wprp!NxbMemoryWorkingSet\.Verbose$'
        )
        $result.Sha256 | Should -Match '^[0-9a-f]{64}$'
        $result.Length | Should -BeGreaterThan 0
        $result.BufferSizeKiB | Should -Be 1024
        $result.Buffers | Should -Be 64
        $result.MaximumFileSizeMiB | Should -Be 512
        $result.FileMode | Should -Be 'Circular'
        $result.Keywords.Count | Should -Be 11
        $result.Stacks.Count | Should -Be 9
        $result.ReferenceSetEnabled | Should -BeFalse
        $result.Keywords | Should -Contain 'AllFaults'
        $result.Keywords | Should -Contain 'MemoryInfoWS'
        $result.Keywords | Should -Contain 'VirtualAllocation'
    }

    It 'rejects a memory profile outside the repository profile root' {
        $outsideProfile = Join-Path $script:OutsideRoot 'external.wprp'
        Copy-Item -LiteralPath $script:CommittedProfile -Destination $outsideProfile

        {
            & (Join-Path $script:ScriptsRoot 'Test-NxbMemoryWprProfile.ps1') `
                -Path $outsideProfile
        } | Should -Throw '*Yol deney kökünün dışında*'
    }

    It 'rejects a memory profile reached through a reparse point' {
        $outsideProfile = Join-Path $script:OutsideRoot 'linked.wprp'
        Copy-Item -LiteralPath $script:CommittedProfile -Destination $outsideProfile
        New-Item `
            -ItemType Junction `
            -Path $script:TemporaryLink `
            -Target $script:OutsideRoot | Out-Null

        {
            & (Join-Path $script:ScriptsRoot 'Test-NxbMemoryWprProfile.ps1') `
                -Path (Join-Path $script:TemporaryLink 'linked.wprp')
        } | Should -Throw '*Reparse point*'
    }

    It 'rejects a DTD-bearing memory profile before contract evaluation' {
        @'
<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE WindowsPerformanceRecorder [<!ENTITY xxe SYSTEM "file:///C:/Windows/win.ini">]>
<WindowsPerformanceRecorder Version="1.0">
  <Profiles>&xxe;</Profiles>
</WindowsPerformanceRecorder>
'@ | Set-Content -LiteralPath $script:TemporaryProfile -Encoding UTF8

        {
            & (Join-Path $script:ScriptsRoot 'Test-NxbMemoryWprProfile.ps1') `
                -Path $script:TemporaryProfile
        } | Should -Throw '*güvenli XML olarak ayrıştırılamadı*'
    }

    It 'rejects removal of the all-fault event contract' {
        $content = Get-Content -LiteralPath $script:CommittedProfile -Raw
        $content = $content.Replace(
            '<Keyword Value="AllFaults" />',
            '<Keyword Value="DiskIO" />'
        )
        Set-Content -LiteralPath $script:TemporaryProfile -Value $content -Encoding UTF8

        {
            & (Join-Path $script:ScriptsRoot 'Test-NxbMemoryWprProfile.ps1') `
                -Path $script:TemporaryProfile
        } | Should -Throw '*zorunlu değeri içermiyor: AllFaults*'
    }

    It 'rejects ReferenceSet in the minimal memory profile' {
        $content = Get-Content -LiteralPath $script:CommittedProfile -Raw
        $content = $content.Replace(
            '<Keyword Value="AllFaults" />',
            "<Keyword Value=`"AllFaults`" />`r`n        <Keyword Value=`"ReferenceSet`" />"
        )
        Set-Content -LiteralPath $script:TemporaryProfile -Value $content -Encoding UTF8

        {
            & (Join-Path $script:ScriptsRoot 'Test-NxbMemoryWprProfile.ps1') `
                -Path $script:TemporaryProfile
        } | Should -Throw '*keyword set öğe sayısı uyuşmuyor*'
    }

    It 'rejects an unbounded or differently bounded memory file collector' {
        $content = Get-Content -LiteralPath $script:CommittedProfile -Raw
        $content = $content.Replace(
            '<MaximumFileSize Value="512" FileMode="Circular" />',
            '<MaximumFileSize Value="1024" FileMode="Sequential" />'
        )
        Set-Content -LiteralPath $script:TemporaryProfile -Value $content -Encoding UTF8

        {
            & (Join-Path $script:ScriptsRoot 'Test-NxbMemoryWprProfile.ps1') `
                -Path $script:TemporaryProfile
        } | Should -Throw '*MaximumFileSize değeri 512 MiB olmalıdır*'
    }

    It 'rejects a profile without the matching memory-mode variant' {
        $document = [System.Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.Load($script:CommittedProfile)
        $memoryProfile = $document.SelectSingleNode(
            "/WindowsPerformanceRecorder/Profiles/Profile[@Id='NxbMemoryWorkingSet.Verbose.Memory']"
        )
        [void]$memoryProfile.ParentNode.RemoveChild($memoryProfile)
        $document.Save($script:TemporaryProfile)

        {
            & (Join-Path $script:ScriptsRoot 'Test-NxbMemoryWprProfile.ps1') `
                -Path $script:TemporaryProfile
        } | Should -Throw '*tam olarak iki File/Memory varyantı*'
    }

    It 'rejects extra event collectors from the minimal memory profile' {
        $content = Get-Content -LiteralPath $script:CommittedProfile -Raw
        $content = $content.Replace(
            '<SystemProvider Id="NxbMemoryWorkingSetSystemProvider">',
            "<EventCollector Id=`"UnexpectedMemoryCollector`" Name=`"Unexpected`">`r`n" +
            "      <BufferSize Value=`"128`" />`r`n" +
            "      <Buffers Value=`"4`" />`r`n" +
            "    </EventCollector>`r`n`r`n" +
            '    <SystemProvider Id="NxbMemoryWorkingSetSystemProvider">'
        )
        Set-Content -LiteralPath $script:TemporaryProfile -Value $content -Encoding UTF8

        {
            & (Join-Path $script:ScriptsRoot 'Test-NxbMemoryWprProfile.ps1') `
                -Path $script:TemporaryProfile
        } | Should -Throw '*ek Event veya Heap collector/provider içeremez*'
    }
}
