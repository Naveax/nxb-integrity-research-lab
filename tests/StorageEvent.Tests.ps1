BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:Validator = Join-Path `
        $script:RepositoryRoot `
        'scripts\Test-StorageEvent.ps1'
    $script:Fixture = Join-Path `
        $script:RepositoryRoot `
        'tests\fixtures\storage-event.valid.json'
}

Describe 'NXB normalized storage event contract' {
    BeforeEach {
        $script:TemporaryEvent = Join-Path `
            ([IO.Path]::GetTempPath()) `
            ("nxb-storage-event-$([guid]::NewGuid().ToString('N')).json")
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:TemporaryEvent) {
            Remove-Item -LiteralPath $script:TemporaryEvent -Force
        }
    }

    It 'accepts the canonical valid fixture' {
        { & $script:Validator -Path $script:Fixture } | Should -Not -Throw
    }

    It 'rejects disk events mislabeled as filesystem events' {
        $document = Get-Content -LiteralPath $script:Fixture -Raw |
            ConvertFrom-Json
        $document.domain = 'filesystem'
        $document | ConvertTo-Json -Depth 32 |
            Set-Content -LiteralPath $script:TemporaryEvent -Encoding UTF8

        { & $script:Validator -Path $script:TemporaryEvent } |
            Should -Throw '*must use domain=storage*'
    }

    It 'rejects missing transfer bytes when transfer size is measured' {
        $document = Get-Content -LiteralPath $script:Fixture -Raw |
            ConvertFrom-Json
        $document.operation.transfer_bytes = $null
        $document | ConvertTo-Json -Depth 32 |
            Set-Content -LiteralPath $script:TemporaryEvent -Encoding UTF8

        { & $script:Validator -Path $script:TemporaryEvent } |
            Should -Throw '*operation.transfer_bytes must be present when measured*'
    }

    It 'rejects a duration value when duration semantics are not assessed' {
        $document = Get-Content -LiteralPath $script:Fixture -Raw |
            ConvertFrom-Json
        $document.operation.duration_us = 12.5
        $document | ConvertTo-Json -Depth 32 |
            Set-Content -LiteralPath $script:TemporaryEvent -Encoding UTF8

        { & $script:Validator -Path $script:TemporaryEvent } |
            Should -Throw '*operation.duration_us must be null when not measured*'
    }

    It 'rejects process identifiers when process attribution is unavailable' {
        $document = Get-Content -LiteralPath $script:Fixture -Raw |
            ConvertFrom-Json
        $document.semantics.process_attribution = 'unavailable'
        $document | ConvertTo-Json -Depth 32 |
            Set-Content -LiteralPath $script:TemporaryEvent -Encoding UTF8

        { & $script:Validator -Path $script:TemporaryEvent } |
            Should -Throw '*identity.process_id must be null when not measured*'
    }

    It 'rejects file events without measured file attribution' {
        $document = Get-Content -LiteralPath $script:Fixture -Raw |
            ConvertFrom-Json
        $document.event_type = 'file_read'
        $document.domain = 'filesystem'
        $document | ConvertTo-Json -Depth 32 |
            Set-Content -LiteralPath $script:TemporaryEvent -Encoding UTF8

        { & $script:Validator -Path $script:TemporaryEvent } |
            Should -Throw '*requires measured file attribution*'
    }

    It 'rejects file identity values when file attribution is not measured' {
        $document = Get-Content -LiteralPath $script:Fixture -Raw |
            ConvertFrom-Json
        $document.identity.path = 'C:\fixture\file.bin'
        $document | ConvertTo-Json -Depth 32 |
            Set-Content -LiteralPath $script:TemporaryEvent -Encoding UTF8

        { & $script:Validator -Path $script:TemporaryEvent } |
            Should -Throw '*file_key/path must be null*'
    }

    It 'rejects an unmeasured required timestamp semantic state' {
        $document = Get-Content -LiteralPath $script:Fixture -Raw |
            ConvertFrom-Json
        $document.semantics.timestamp = 'not_assessed'
        $document | ConvertTo-Json -Depth 32 |
            Set-Content -LiteralPath $script:TemporaryEvent -Encoding UTF8

        { & $script:Validator -Path $script:TemporaryEvent } |
            Should -Throw '*timestamp semantics must be measured*'
    }

    It 'rejects premature measured queue semantics' {
        $document = Get-Content -LiteralPath $script:Fixture -Raw |
            ConvertFrom-Json
        $document.semantics.queue_semantics = 'measured'
        $document | ConvertTo-Json -Depth 32 |
            Set-Content -LiteralPath $script:TemporaryEvent -Encoding UTF8

        { & $script:Validator -Path $script:TemporaryEvent } |
            Should -Throw '*queue semantics cannot be measured*'
    }
}
