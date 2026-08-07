BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:BridgePath = Join-Path `
        $script:RepositoryRoot `
        'scripts\ConvertFrom-NxbXperfMemoryDumper.ps1'

    function Invoke-NxbRealHeaderBridge {
        param(
            [Parameter(Mandatory)]
            [string]$InputPath,

            [Parameter(Mandatory)]
            [string]$OutputDirectory
        )

        & $script:BridgePath `
            -InputPath $InputPath `
            -OutputDirectory $OutputDirectory `
            -PassThru
    }
}

Describe 'NXB real Xperf memory dumper header compatibility' {
    It 'normalizes the observed Windows 10 VirtualAlloc and HardFault shapes' {
        $inputPath = Join-Path $TestDrive 'observed-real-headers.txt'
        @(
            'VirtualAlloc, TimeStamp, Process Name ( PID), BaseAddr, EndAddr, Flags',
            'VirtualAlloc, 1000, target.exe (4242), 0x1000, 0x3000, 0x3000',
            'VirtualFree, TimeStamp, Process Name ( PID), BaseAddr, EndAddr, Flags',
            'VirtualFree, 2000, target.exe (4242), 0x1000, 0x3000, 0x8000',
            'HardFault, TimeStamp, Process Name ( PID), ThreadID, VirtualAddr, ByteOffset, IOSize, ElapsedTime, FileObject, FileName, Hardfaulted Address Information',
            'HardFault, 3000, target.exe (4242), 101, 0x5000, 0, 4096, 1, 0x1, pagefile.sys, info',
            'PageFault, TimeStamp, Process Name ( PID), ThreadID, VirtualAddr, PrgrmCtr, Type, Image!Function',
            'PageFault, 4000, target.exe (4242), 101, 0x6000, 0x7000, DemandZeroFault, module!fn'
        ) | Set-Content -LiteralPath $inputPath -Encoding Ascii

        $output = Join-Path $TestDrive 'observed-real-output'
        $result = Invoke-NxbRealHeaderBridge `
            -InputPath $inputPath `
            -OutputDirectory $output

        $rows = @(Import-Csv -LiteralPath $result.event_export_path)
        $alloc = @(
            $rows | Where-Object event_type -CEQ 'virtual_allocation'
        )[0]
        $free = @(
            $rows | Where-Object event_type -CEQ 'virtual_free'
        )[0]
        $hard = @(
            $rows | Where-Object event_type -CEQ 'hard_fault'
        )[0]

        [int]$alloc.size_bytes | Should -Be 8192
        [int]$free.size_bytes | Should -Be 8192
        [int]$hard.size_bytes | Should -Be 4096
        [int]$hard.process_id | Should -Be 4242
        [int]$hard.thread_id | Should -Be 101

        @($result.manifest.virtual_region_size_sources) |
            Should -Contain 'derived_end_minus_base'
        @($result.manifest.hard_fault_size_sources) |
            Should -Contain 'header_size_field'
        @($result.manifest.known_unmapped_memory_event_names) |
            Should -Contain 'PageFault'
        [bool]$result.manifest.claims.hard_fault_bytes_exact |
            Should -BeFalse
    }

    It 'preserves structural fields when ANSI display-name bytes need fallback' {
        $inputPath = Join-Path $TestDrive 'ansi-display-name.txt'
        $prefix = [Text.Encoding]::ASCII.GetBytes(
            "VirtualAlloc, TimeStamp, Process Name ( PID), BaseAddr, EndAddr, Flags`r`n" +
            'VirtualAlloc, 1000, proc'
        )
        $suffix = [Text.Encoding]::ASCII.GetBytes(
            "name.exe (4242), 0x1000, 0x2000, 0x3000`r`n"
        )
        $bytes = [byte[]]::new($prefix.Length + 1 + $suffix.Length)
        [Array]::Copy($prefix, 0, $bytes, 0, $prefix.Length)
        $bytes[$prefix.Length] = 0x81
        [Array]::Copy(
            $suffix,
            0,
            $bytes,
            $prefix.Length + 1,
            $suffix.Length
        )
        [IO.File]::WriteAllBytes($inputPath, $bytes)

        $output = Join-Path $TestDrive 'ansi-output'
        $result = Invoke-NxbRealHeaderBridge `
            -InputPath $inputPath `
            -OutputDirectory $output
        $rows = @(Import-Csv -LiteralPath $result.event_export_path)

        $rows.Count | Should -Be 1
        [string]$rows[0].event_type | Should -Be 'virtual_allocation'
        [int]$rows[0].process_id | Should -Be 4242
        [int]$rows[0].size_bytes | Should -Be 4096
        [string]$result.manifest.decode_error_policy |
            Should -BeIn @('replace', 'strict')
    }
}
