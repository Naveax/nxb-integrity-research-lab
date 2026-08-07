BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:BridgePath = Join-Path `
        $script:RepositoryRoot `
        'scripts\ConvertFrom-NxbXperfMemoryDumper.ps1'
}

Describe 'NXB generic Xperf PageFault mapping' {
    It 'maps only observed soft PageFault types and leaves generic hard fault unmapped' {
        $inputPath = Join-Path $TestDrive 'generic-pagefault.txt'
        @(
            'PageFault, TimeStamp, Process Name ( PID), ThreadID, VirtualAddr, PrgrmCtr, Type, Image!Function',
            'PageFault, 1000, target.exe (4242), 101, 0x1000, 0x2000, Transition, module!fn',
            'PageFault, 2000, target.exe (4242), 101, 0x3000, 0x4000, DemandZero, module!fn',
            'PageFault, 3000, target.exe (4242), 101, 0x5000, 0x6000, CopyOnWrite, module!fn',
            'PageFault, 4000, target.exe (4242), 101, 0x7000, 0x8000, GuardPage, module!fn',
            'PageFault, 5000, target.exe (4242), 101, 0x9000, 0xA000, HardFault, module!fn',
            'HardFault, TimeStamp, Process Name ( PID), ThreadID, VirtualAddr, ByteOffset, IOSize, ElapsedTime, FileObject, FileName, Hardfaulted Address Information',
            'HardFault, 6000, target.exe (4242), 101, 0xB000, 0, 4096, 1, 0x1, pagefile.sys, info'
        ) | Set-Content -LiteralPath $inputPath -Encoding Ascii

        $output = Join-Path $TestDrive 'generic-pagefault-output'
        $result = & $script:BridgePath `
            -InputPath $inputPath `
            -OutputDirectory $output `
            -PassThru

        $rows = @(Import-Csv -LiteralPath $result.event_export_path)
        @($rows | Where-Object event_type -CEQ 'transition_fault').Count |
            Should -Be 1
        @($rows | Where-Object event_type -CEQ 'demand_zero_fault').Count |
            Should -Be 1
        @($rows | Where-Object event_type -CEQ 'copy_on_write_fault').Count |
            Should -Be 1
        @($rows | Where-Object event_type -CEQ 'guard_page_fault').Count |
            Should -Be 1
        @($rows | Where-Object event_type -CEQ 'hard_fault').Count |
            Should -Be 1

        [int]$result.manifest.observed_page_fault_type_counts.Transition |
            Should -Be 1
        [int]$result.manifest.observed_page_fault_type_counts.DemandZero |
            Should -Be 1
        [int]$result.manifest.observed_page_fault_type_counts.CopyOnWrite |
            Should -Be 1
        [int]$result.manifest.observed_page_fault_type_counts.GuardPage |
            Should -Be 1
        [int]$result.manifest.observed_page_fault_type_counts.HardFault |
            Should -Be 1

        [int]$result.manifest.mapped_page_fault_type_counts.Transition |
            Should -Be 1
        [int]$result.manifest.mapped_page_fault_type_counts.DemandZero |
            Should -Be 1
        [int]$result.manifest.mapped_page_fault_type_counts.CopyOnWrite |
            Should -Be 1
        [int]$result.manifest.mapped_page_fault_type_counts.GuardPage |
            Should -Be 1
        [int]$result.manifest.unmapped_page_fault_type_counts.HardFault |
            Should -Be 1

        [bool]$result.manifest.claims.generic_pagefault_hardfault_normalized |
            Should -BeFalse
    }

    It 'keeps unknown generic PageFault types explicit and unmapped' {
        $inputPath = Join-Path $TestDrive 'generic-pagefault-unknown.txt'
        @(
            'PageFault, TimeStamp, Process Name ( PID), ThreadID, VirtualAddr, PrgrmCtr, Type, Image!Function',
            'PageFault, 1000, target.exe (4242), 101, 0x1000, 0x2000, AccessViolation, module!fn'
        ) | Set-Content -LiteralPath $inputPath -Encoding Ascii

        $output = Join-Path $TestDrive 'generic-pagefault-unknown-output'
        {
            & $script:BridgePath `
                -InputPath $inputPath `
                -OutputDirectory $output `
                -PassThru |
                Out-Null
        } | Should -Throw '*No supported Xperf memory events were normalized*'
    }
}
