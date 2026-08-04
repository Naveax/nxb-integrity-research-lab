BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsRoot = Join-Path $script:RepositoryRoot 'scripts'
    Import-Module (Join-Path $script:ScriptsRoot 'Nxb.EvidenceStore.psm1') -Force
}

Describe 'NXB evidence-store schemas' {
    BeforeEach {
        $script:TemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
            'nxb-evidence-schema-{0}' -f [guid]::NewGuid()
        )
        New-Item -ItemType Directory -Path $script:TemporaryRoot -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TemporaryRoot) {
            Remove-Item -LiteralPath $script:TemporaryRoot -Recurse -Force
        }
    }

    It 'accepts valid record, chain-head and unsigned bundle documents' {
        $zeroHash = '0' * 64
        $oneHash = '1' * 64
        $twoHash = '2' * 64

        $record = [ordered]@{
            schema_version = 1
            sequence = 0
            previous_record_sha256 = $null
            record_type = 'manifest_snapshot'
            experiment_id = 'experiment-1'
            machine_id = 'machine-1'
            boot_id = 'boot-1'
            session_id = 'session-1'
            captured_utc = '2026-08-04T20:00:00Z'
            monotonic_ns = [int64]100
            payload = [ordered]@{ status = 'prepared' }
            payload_sha256 = $zeroHash
            record_sha256 = $oneHash
        }

        $chainHead = [ordered]@{
            schema_version = 1
            experiment_id = 'experiment-1'
            machine_id = 'machine-1'
            boot_id = 'boot-1'
            session_id = 'session-1'
            record_count = 1
            genesis_record_sha256 = $oneHash
            last_sequence = 0
            last_record_sha256 = $oneHash
            chain_sha256 = $twoHash
        }

        $bundle = [ordered]@{
            schema_version = 1
            experiment_id = 'experiment-1'
            machine_id = 'machine-1'
            boot_id = 'boot-1'
            session_id = 'session-1'
            chain_sha256 = $twoHash
            records = @(
                [ordered]@{
                    sequence = 0
                    relative_path = 'evidence-store/records/0000000000000000.json'
                    length = 128
                    sha256 = $oneHash
                }
            )
            files = @(
                [ordered]@{
                    relative_path = 'manifest.json'
                    length = 64
                    sha256 = $zeroHash
                }
            )
            signature_state = 'unsigned'
            bundle_sha256 = $twoHash
        }

        $recordPath = Join-Path $script:TemporaryRoot 'record.json'
        $chainPath = Join-Path $script:TemporaryRoot 'chain-head.json'
        $bundlePath = Join-Path $script:TemporaryRoot 'bundle-manifest.json'

        Write-NxbCanonicalJsonAtomic -Path $recordPath -InputObject $record -Confirm:$false
        Write-NxbCanonicalJsonAtomic -Path $chainPath -InputObject $chainHead -Confirm:$false
        Write-NxbCanonicalJsonAtomic -Path $bundlePath -InputObject $bundle -Confirm:$false

        {
            & (Join-Path $script:ScriptsRoot 'Test-EvidenceStoreSchema.ps1') `
                -Path $recordPath `
                -DocumentType record
        } | Should -Not -Throw

        {
            & (Join-Path $script:ScriptsRoot 'Test-EvidenceStoreSchema.ps1') `
                -Path $chainPath `
                -DocumentType chain-head
        } | Should -Not -Throw

        {
            & (Join-Path $script:ScriptsRoot 'Test-EvidenceStoreSchema.ps1') `
                -Path $bundlePath `
                -DocumentType bundle-manifest
        } | Should -Not -Throw
    }

    It 'rejects a non-genesis record with a null previous hash' {
        $invalidRecord = [ordered]@{
            schema_version = 1
            sequence = 1
            previous_record_sha256 = $null
            record_type = 'manifest_snapshot'
            experiment_id = 'experiment-1'
            machine_id = 'machine-1'
            boot_id = 'boot-1'
            session_id = 'session-1'
            captured_utc = '2026-08-04T20:00:00Z'
            monotonic_ns = [int64]100
            payload = [ordered]@{}
            payload_sha256 = '0' * 64
            record_sha256 = '1' * 64
        }

        $recordPath = Join-Path $script:TemporaryRoot 'invalid-record.json'
        Write-NxbCanonicalJsonAtomic `
            -Path $recordPath `
            -InputObject $invalidRecord `
            -Confirm:$false

        {
            & (Join-Path $script:ScriptsRoot 'Test-EvidenceStoreSchema.ps1') `
                -Path $recordPath `
                -DocumentType record
        } | Should -Throw '*Evidence-store schema doğrulaması başarısız*'
    }

    It 'rejects signature metadata when the bundle is explicitly unsigned' {
        $bundle = [ordered]@{
            schema_version = 1
            experiment_id = 'experiment-1'
            machine_id = 'machine-1'
            boot_id = 'boot-1'
            session_id = 'session-1'
            chain_sha256 = '0' * 64
            records = @(
                [ordered]@{
                    sequence = 0
                    relative_path = 'records/0000000000000000.json'
                    length = 1
                    sha256 = '1' * 64
                }
            )
            files = @()
            signature_state = 'unsigned'
            signature = [ordered]@{
                algorithm = 'test'
                key_id = 'test-key'
                relative_path = 'signatures/test.sig'
            }
            bundle_sha256 = '2' * 64
        }

        $bundlePath = Join-Path $script:TemporaryRoot 'invalid-bundle.json'
        Write-NxbCanonicalJsonAtomic `
            -Path $bundlePath `
            -InputObject $bundle `
            -Confirm:$false

        {
            & (Join-Path $script:ScriptsRoot 'Test-EvidenceStoreSchema.ps1') `
                -Path $bundlePath `
                -DocumentType bundle-manifest
        } | Should -Throw '*Evidence-store schema doğrulaması başarısız*'
    }
}
