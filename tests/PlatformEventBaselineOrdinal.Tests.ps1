$ErrorActionPreference = 'Stop'

Describe 'SUPERBLOCK 2 L1 ordinal metadata repair contract' {
    BeforeAll {
        function Get-NxbPlatformEventOrdinalTestRoot {
            $root = [string]$env:NXB_PLATFORM_EVENT_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_PLATFORM_EVENT_REPOSITORY_ROOT is required.' }
            return [IO.Path]::GetFullPath($root)
        }
    }

    It 'keeps V1 discovery V3 normalizer and Python validator repo-owned' {
        $root = Get-NxbPlatformEventOrdinalTestRoot
        foreach ($relative in @(
            'scripts\Get-NxbPlatformEventBaseline.ps1',
            'scripts\Get-NxbPlatformEventBaselineV3.ps1',
            'tools\validate_platform_event_baseline.py'
        )) { Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf | Should -BeTrue }
    }

    It 'uses an ordinal sorted set for keyword uniqueness' {
        $root = Get-NxbPlatformEventOrdinalTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformEventBaselineV3.ps1') -Raw
        $source | Should -Match ([regex]::Escape('[Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)'))
        $source | Should -Match ([regex]::Escape('$definition.keywords = Get-NxbPlatformEventV3OrdinalStringSet'))
    }

    It 'uses UTF8 ordinal hex keys for textual ordering' {
        $root = Get-NxbPlatformEventOrdinalTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformEventBaselineV3.ps1') -Raw
        $source | Should -Match ([regex]::Escape('[Text.Encoding]::UTF8.GetBytes([string]$Value)'))
        foreach ($field in @('$_.level','$_.task','$_.opcode','$_.log_name','$_.provider_name')) {
            $source | Should -Match ([regex]::Escape("Get-NxbPlatformEventV3OrdinalHexKey -Value $field"))
        }
    }

    It 'normalizes definitions shapes logs and providers before hashing with approved verbs' {
        $root = Get-NxbPlatformEventOrdinalTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformEventBaselineV3.ps1') -Raw
        foreach ($name in @(
            'Get-NxbPlatformEventV3OrderedDefinitionInventory',
            'Get-NxbPlatformEventV3OrderedShapeInventory',
            'Get-NxbPlatformEventV3OrderedLogInventory',
            'Get-NxbPlatformEventV3OrderedProviderInventory'
        )) { $source | Should -Match ([regex]::Escape($name)) }
        $source | Should -Not -Match ([regex]::Escape('Sort-NxbPlatformEventV3'))
    }

    It 'preserves array cardinality while rebuilding canonical metadata' {
        $root = Get-NxbPlatformEventOrdinalTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformEventBaselineV3.ps1') -Raw
        $source | Should -Match ([regex]::Escape('Write-Output -InputObject $items -NoEnumerate'))
        $source | Should -Not -Match ([regex]::Escape('return @($Value | ForEach-Object'))
    }

    It 'recomputes metadata fingerprint after ordinal normalization' {
        $root = Get-NxbPlatformEventOrdinalTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformEventBaselineV3.ps1') -Raw
        $source | Should -Match ([regex]::Escape('$snapshot.provider_metadata_fingerprint_sha256 = Get-NxbPlatformEventV3Sha256Text'))
        $source | Should -Match ([regex]::Escape('$canonicalMetadata | ConvertTo-Json -Depth 40 -Compress'))
    }

    It 'removes transient V1 baseline in finally' {
        $root = Get-NxbPlatformEventOrdinalTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformEventBaselineV3.ps1') -Raw
        $source | Should -Match ([regex]::Escape("'.v1.tmp'"))
        $source | Should -Match ([regex]::Escape('Remove-Item -LiteralPath $tempPath -Force'))
    }

    It 'keeps Python enforcing ordinal sorted unique keywords and structural array order' {
        $root = Get-NxbPlatformEventOrdinalTestRoot
        $validator = Get-Content -LiteralPath (Join-Path $root 'tools\validate_platform_event_baseline.py') -Raw
        $validator | Should -Match ([regex]::Escape('item["keywords"] == sorted(set(item["keywords"]))'))
        $validator | Should -Match ([regex]::Escape('definitions == sorted(definitions, key=definition_sort_key)'))
        $validator | Should -Match ([regex]::Escape('logs == sorted(logs, key=lambda item: item["log_name"])'))
        $validator | Should -Match ([regex]::Escape('item["shapes"] == sorted(item["shapes"], key=shape_sort_key)'))
    }
}
