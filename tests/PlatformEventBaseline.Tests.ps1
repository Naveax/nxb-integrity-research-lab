$ErrorActionPreference = 'Stop'

Describe 'SUPERBLOCK 2 platform event baseline contract' {
    BeforeAll {
        function Get-NxbPlatformEventBaselineTestRoot {
            $root = [string]$env:NXB_PLATFORM_EVENT_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_PLATFORM_EVENT_REPOSITORY_ROOT is required.' }
            $fullRoot = [IO.Path]::GetFullPath($root)
            if (-not (Test-Path -LiteralPath $fullRoot -PathType Container)) { throw "Repository root missing: $fullRoot" }
            return $fullRoot
        }
    }

    It 'keeps collector validator certification and L0 binding components repo-owned' {
        $root = Get-NxbPlatformEventBaselineTestRoot
        foreach ($relative in @(
            'scripts\Get-NxbPlatformEventBaseline.ps1',
            'tools\validate_platform_event_baseline.py',
            'scripts\Invoke-NxbSuperblock2PlatformEventBaselineCertification.ps1',
            'scripts\Get-NxbPlatformBindingSnapshotV2.ps1'
        )) { Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf | Should -BeTrue }
    }

    It 'binds baseline metadata to the canonical L0 fingerprint' {
        $root = Get-NxbPlatformEventBaselineTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformEventBaseline.ps1') -Raw
        $source | Should -Match ([regex]::Escape('[ValidatePattern(''^[0-9a-f]{64}$'')][string]$BindingFingerprintSha256'))
        $source | Should -Match ([regex]::Escape('binding_fingerprint_sha256 = $BindingFingerprintSha256.ToLowerInvariant()'))
    }

    It 'discovers exactly the eight measured L0 provider names' {
        $root = Get-NxbPlatformEventBaselineTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformEventBaseline.ps1') -Raw
        foreach ($provider in @(
            'Microsoft-Windows-CodeIntegrity','Microsoft-Windows-DeviceGuard','Microsoft-Windows-Kernel-Boot',
            'Microsoft-Windows-Kernel-PnP','Microsoft-Windows-Kernel-Power','Microsoft-Windows-Kernel-Processor-Power',
            'Microsoft-Windows-UserPnp','Microsoft-Windows-WHEA-Logger'
        )) { $source | Should -Match ([regex]::Escape("'$provider'")) }
        ([regex]::Matches($source,[regex]::Escape("'Microsoft-Windows-"))).Count | Should -Be 8
    }

    It 'enumerates provider event definitions structurally' {
        $root = Get-NxbPlatformEventBaselineTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformEventBaseline.ps1') -Raw
        foreach ($needle in @('Events','event_definition_count','event_definitions','id =','version =','level =','task =','opcode =','keywords =')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'enumerates attached provider logs without guessing log names' {
        $root = Get-NxbPlatformEventBaselineTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformEventBaseline.ps1') -Raw
        foreach ($needle in @('LogLinks','LogName','attached_log_count','Get-WinEvent -ListLog $logName')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'bounds recent log sampling by lookback and max event count' {
        $root = Get-NxbPlatformEventBaselineTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformEventBaseline.ps1') -Raw
        $source | Should -Match ([regex]::Escape('[ValidateRange(1,30)][int]$LookbackDays = 7'))
        $source | Should -Match ([regex]::Escape('[ValidateRange(1,512)][int]$MaxEventsPerLog = 128'))
        $source | Should -Match ([regex]::Escape('-MaxEvents $MaxEventsPerLog'))
    }

    It 'aggregates recent events into structural shapes instead of retaining records' {
        $root = Get-NxbPlatformEventBaselineTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformEventBaseline.ps1') -Raw
        foreach ($needle in @('Group-Object { Get-NxbPlatformEventShapeKey','sampled_event_count','shapes = $shapeGroups','oldest_sample_utc','newest_sample_utc')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'never stores raw event message XML or payload fields' {
        $root = Get-NxbPlatformEventBaselineTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformEventBaseline.ps1') -Raw
        $source | Should -Not -Match ([regex]::Escape('FormatDescription'))
        $source | Should -Not -Match ([regex]::Escape('ToXml'))
        $source | Should -Not -Match ([regex]::Escape('event_payload ='))
        foreach ($claim in @('raw_event_message_exposed = $false','raw_event_xml_exposed = $false','raw_event_payload_exposed = $false')) {
            $source | Should -Match ([regex]::Escape($claim))
        }
    }

    It 'distinguishes disabled logs from unavailable queries' {
        $root = Get-NxbPlatformEventBaselineTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformEventBaseline.ps1') -Raw
        foreach ($needle in @("status = 'disabled'","reason = 'log_disabled'","status = 'unavailable'","reason = 'bounded_query_failed'","reason = 'list_log_failed'")) {
            $source | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'does not synthesize unavailable sampled counts as zero' {
        $root = Get-NxbPlatformEventBaselineTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformEventBaseline.ps1') -Raw
        $source | Should -Match ([regex]::Escape("status = 'unavailable'"))
        $source | Should -Match ([regex]::Escape('sampled_event_count = $null'))
    }

    It 'keeps zero as a valid measured count only for successful or disabled log queries' {
        $root = Get-NxbPlatformEventBaselineTestRoot
        $validator = Get-Content -LiteralPath (Join-Path $root 'tools\validate_platform_event_baseline.py') -Raw
        $validator | Should -Match ([regex]::Escape('0 <= count <= max_events'))
        $validator | Should -Match ([regex]::Escape('item["sampled_event_count"] == 0'))
        $validator | Should -Match ([regex]::Escape('item["sampled_event_count"] is None'))
    }

    It 'fingerprints provider metadata separately from recent activity' {
        $root = Get-NxbPlatformEventBaselineTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformEventBaseline.ps1') -Raw
        foreach ($needle in @('event_definitions = $_.event_definitions','attached_logs = @($_.logs | ForEach-Object { $_.log_name })','provider_metadata_fingerprint_sha256 = $metadataFingerprint')) {
            $source | Should -Match ([regex]::Escape($needle))
        }
        $source | Should -Not -Match ([regex]::Escape('metadataMaterial =') + '.{0,1000}' + [regex]::Escape('sampled_event_count'))
    }

    It 'preserves array cardinality in metadata canonicalization' {
        $root = Get-NxbPlatformEventBaselineTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformEventBaseline.ps1') -Raw
        $source | Should -Match ([regex]::Escape('-InputObject $items'))
        $source | Should -Match ([regex]::Escape('-NoEnumerate'))
        $source | Should -Not -Match ([regex]::Escape('return @($Value | ForEach-Object'))
    }

    It 'locks validator provider GUIDs to the measured L0 host inventory' {
        $root = Get-NxbPlatformEventBaselineTestRoot
        $validator = Get-Content -LiteralPath (Join-Path $root 'tools\validate_platform_event_baseline.py') -Raw
        foreach ($guid in @(
            '4ee76bd8-3cf4-44a0-a0ac-3937643e37a3','f717d024-f5b4-4f03-9ab9-331b2dc38ffb',
            '15ca44ff-4d7a-4baa-bba5-0998955e531e','9c205a39-1250-487d-abd7-e831c6290539',
            '331c3b3a-2005-44c2-ac5e-77220c37d6b4','0f67e49f-fe51-4e9f-b490-6f2948cc6027',
            '96f4a050-7e31-453c-88be-9634f4e02139','c26c4f3c-3f66-4e99-8f8a-39405cfed220'
        )) { $validator | Should -Match ([regex]::Escape($guid)) }
    }

    It 'independently recomputes provider metadata fingerprint in Python' {
        $root = Get-NxbPlatformEventBaselineTestRoot
        $validator = Get-Content -LiteralPath (Join-Path $root 'tools\validate_platform_event_baseline.py') -Raw
        foreach ($needle in @('metadata_material','canonical_json(metadata_material)','recomputed == metadata_fingerprint')) {
            $validator | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'requires shape counts to equal successful sampled event count' {
        $root = Get-NxbPlatformEventBaselineTestRoot
        $validator = Get-Content -LiteralPath (Join-Path $root 'tools\validate_platform_event_baseline.py') -Raw
        $validator | Should -Match ([regex]::Escape('sum(shape["count"] for shape in item["shapes"]) == count'))
    }

    It 'rejects raw event content fields independently' {
        $root = Get-NxbPlatformEventBaselineTestRoot
        $validator = Get-Content -LiteralPath (Join-Path $root 'tools\validate_platform_event_baseline.py') -Raw
        foreach ($needle in @('FORBIDDEN_KEYS','validate_no_raw_event_content','raw_message','raw_xml','payload')) {
            $validator | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'keeps event semantics and causality claims conservative' {
        $root = Get-NxbPlatformEventBaselineTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-NxbPlatformEventBaseline.ps1') -Raw
        foreach ($needle in @(
            'event_id_semantics = $false','event_task_opcode_semantics = $false','device_lifecycle_semantics = $false',
            'power_causality = $false','firmware_causality = $false','continuous_trace_completeness = ''not_claimed'''
        )) { $source | Should -Match ([regex]::Escape($needle)) }
    }

    It 'requires two baselines with stable metadata fingerprint but not identical recent activity' {
        $root = Get-NxbPlatformEventBaselineTestRoot
        $cert = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock2PlatformEventBaselineCertification.ps1') -Raw
        foreach ($needle in @('platform-event-baseline-a.json','platform-event-baseline-b.json','provider metadata fingerprint changed between baselines')) {
            $cert | Should -Match ([regex]::Escape($needle))
        }
        $cert | Should -Not -Match ([regex]::Escape('sampled_event_count changed between baselines'))
    }

    It 'keeps the L1 review ZIP bounded and free of raw trace/event artifacts' {
        $root = Get-NxbPlatformEventBaselineTestRoot
        $cert = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSuperblock2PlatformEventBaselineCertification.ps1') -Raw
        foreach ($needle in @('.etl','.evtx','.xml','.jsonl','Forbidden platform event review artifact')) {
            $cert | Should -Match ([regex]::Escape($needle))
        }
    }
}
