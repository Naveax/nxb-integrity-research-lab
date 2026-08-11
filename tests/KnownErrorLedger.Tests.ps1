$ErrorActionPreference = 'Stop'

Describe 'NXB known-error ledger pre-final contract' {
    BeforeAll {
        function Get-NxbKnownErrorTestRoot {
            $root = [string]$env:NXB_ADAPTIVE_REPOSITORY_ROOT
            if ([string]::IsNullOrWhiteSpace($root)) { throw 'NXB_ADAPTIVE_REPOSITORY_ROOT is required.' }
            return [IO.Path]::GetFullPath($root)
        }

        function Get-NxbKnownErrorSignatureDocument {
            $root = Get-NxbKnownErrorTestRoot
            return (Get-Content -LiteralPath (Join-Path $root 'config\nxb-known-error-signatures.json') -Raw | ConvertFrom-Json)
        }

        function Get-NxbKnownErrorRule {
            param([Parameter(Mandatory)][string]$Id)
            $document = Get-NxbKnownErrorSignatureDocument
            $item = @($document.rules | Where-Object { [string]$_.id -ceq $Id })
            if ($item.Count -ne 1) { throw ('Known-error rule not uniquely present: {0}' -f $Id) }
            return $item[0]
        }
    }

    It 'keeps ledger scanner and inherited V5 authority repo-owned' {
        $root = Get-NxbKnownErrorTestRoot
        foreach ($relative in @(
            'docs\NXB-KNOWN-ERROR-LEDGER.md',
            'config\nxb-known-error-signatures.json',
            'scripts\Invoke-NxbKnownErrorScan.ps1',
            'scripts\Invoke-NxbAdaptiveObservabilityCertificationV5.ps1'
        )) {
            Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf | Should -BeTrue
        }
    }

    It 'uses signature schema version one and canonical ledger path' {
        $document = Get-NxbKnownErrorSignatureDocument
        [int]$document.schema_version | Should -Be 1
        [string]$document.ledger_path | Should -BeExactly 'docs/NXB-KNOWN-ERROR-LEDGER.md'
    }

    It 'keeps machine rule ids unique and extends active semantic transport coverage' {
        $document = Get-NxbKnownErrorSignatureDocument
        $ids = @($document.rules | ForEach-Object { [string]$_.id })
        @($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
        $ids.Count | Should -BeGreaterOrEqual 16

        foreach ($ruleId in @('NXB-ERR-001','NXB-ERR-005','NXB-ERR-006','NXB-ERR-008','NXB-ERR-021','NXB-ERR-026')) {
            $rule = Get-NxbKnownErrorRule -Id $ruleId
            @($rule.include_globs) | Should -Contain 'scripts/*NxbSemantic*.ps1'
            @($rule.include_globs) | Should -Contain 'tests/Semantic*.Tests.ps1'
        }
        $eventRule = Get-NxbKnownErrorRule -Id 'NXB-ERR-027'
        @($eventRule.include_globs) | Should -Contain 'scripts/Invoke-NxbSemanticPnpEventExperiment.ps1'
    }

    It 'lists every machine rule in the human ledger' {
        $root = Get-NxbKnownErrorTestRoot
        $ledger = Get-Content -LiteralPath (Join-Path $root 'docs\NXB-KNOWN-ERROR-LEDGER.md') -Raw
        $document = Get-NxbKnownErrorSignatureDocument
        foreach ($rule in @($document.rules)) {
            $ledger | Should -Match ([regex]::Escape([string]$rule.id))
        }
    }

    It 'retains the complete observed workflow ledger through NXB-ERR-027' {
        $root = Get-NxbKnownErrorTestRoot
        $ledger = Get-Content -LiteralPath (Join-Path $root 'docs\NXB-KNOWN-ERROR-LEDGER.md') -Raw
        foreach ($number in 1..27) {
            $id = 'NXB-ERR-{0:D3}' -f $number
            $ledger | Should -Match ([regex]::Escape($id))
        }
        $ledger | Should -Match ([regex]::Escape('Do not generate a regex quantifier through nested Python/PowerShell brace formatting.'))
        $ledger | Should -Match ([regex]::Escape('Never use `.PSObject.Properties` to enumerate a JSON array.'))
        $ledger | Should -Match ([regex]::Escape('Keep active IRL-006 PowerShell authority/test `.ps1` files ASCII-only'))
        $ledger | Should -Match ([regex]::Escape('Do not use optional Windows diagnostic EventLog channels as claim authority'))
    }

    It 'locks recent analyzer runtime array encoding and EventLog regression classes' {
        $root = Get-NxbKnownErrorTestRoot

        $wildcardRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-019').regex)
        $wildcardRegex.IsMatch('[WildcardOptions]::IgnoreCase') | Should -BeTrue
        $wildcardRegex.IsMatch('[System.Management.Automation.WildcardOptions]::IgnoreCase') | Should -BeFalse

        $profileRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-021').regex)
        $profileRegex.IsMatch('$profile = $policy.mode_profiles.foo') | Should -BeTrue
        $profileRegex.IsMatch('$modeProfile = $policy.mode_profiles.foo') | Should -BeFalse

        $assignedRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-014').regex)
        $assignedRegex.IsMatch('$pythonValidatorPath = Join-Path $root ''tools\validate_semantic_evidence_receipt.py''') | Should -BeTrue
        $assignedRegex.IsMatch('$context = Get-NxbSemanticTestContext') | Should -BeFalse

        $arrayRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-024').regex)
        $badArrayProjection = '$policy.claim_targets' + '.PSObject.Properties'
        $arrayRegex.IsMatch($badArrayProjection) | Should -BeTrue
        $arrayRegex.IsMatch('@($policy.claim_targets)') | Should -BeFalse

        $capabilityRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-025').regex)
        $badCimPresence = 'Get-' + 'CimInstance Win32_PnPEntity -ErrorAction Stop'
        $capabilityRegex.IsMatch($badCimPresence) | Should -BeTrue

        $encodingRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-026').regex)
        $nonAsciiFixture = 'non-ascii-' + [char]0x2192
        $encodingRegex.IsMatch($nonAsciiFixture) | Should -BeTrue
        $encodingRegex.IsMatch('ascii-only-authority') | Should -BeFalse

        $eventRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-027').regex)
        $badEventRead = 'Get-' + 'WinEvent -FilterHashtable $filter'
        $eventRegex.IsMatch($badEventRead) | Should -BeTrue
        $eventRegex.IsMatch('[Nxb.Semantic.PnpLifecycleCollector]::new()') | Should -BeFalse

        $pnpSource = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSemanticPnpEventExperiment.ps1') -Raw
        $eventRegex.IsMatch($pnpSource) | Should -BeFalse
        $pnpSource | Should -Match ([regex]::Escape('repo_owned_eventsource_lifecycle_bridge_v1'))
        $pnpSource | Should -Match ([regex]::Escape('optional_windows_eventlog_used_as_authority = $false'))

        $ledgerTestSource = Get-Content -LiteralPath (Join-Path $root 'tests\KnownErrorLedger.Tests.ps1') -Raw
        $encodingRegex.IsMatch($ledgerTestSource) | Should -BeFalse
    }

    It 'detects ambiguous variable-colon interpolation but permits explicit scope variables' {
        $regex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-001').regex)
        $quote = [char]34
        $bad = 'throw ' + $quote + 'repeat $Repeat' + ': exit=$exitCode' + $quote
        $goodDelimited = 'throw ' + $quote + 'repeat ${Repeat}' + ': exit=$exitCode' + $quote
        $goodScope = 'Write-Output ' + $quote + '$env' + ':OS' + $quote
        $regex.IsMatch($bad) | Should -BeTrue
        $regex.IsMatch($goodDelimited) | Should -BeFalse
        $regex.IsMatch($goodScope) | Should -BeFalse
    }

    It 'detects assignment to the automatic Matches variable case-insensitively' {
        $regex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-006').regex)
        $regex.IsMatch('$matches = @()') | Should -BeTrue
        $regex.IsMatch('$Matches = $null') | Should -BeTrue
        $regex.IsMatch('$domainMappings = @()') | Should -BeFalse
    }

    It 'detects the known plural helper declarations without matching replacements' {
        $regex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-008').regex)
        $regex.IsMatch('function Write-NxbHysteresisSignals {') | Should -BeTrue
        $regex.IsMatch('function Get-NxbStableUniqueDomains {') | Should -BeTrue
        $regex.IsMatch('function Write-NxbHysteresisSignalDocument {') | Should -BeFalse
        $regex.IsMatch('function Get-NxbStableUniqueDomain {') | Should -BeFalse
    }

    It 'detects double-quoted expected-source regex interpolation' {
        $regex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-015').regex)
        $quote = [char]34
        $bad = '[regex]::Escape(' + $quote + 'throw -f $stateFull' + $quote + ')'
        $good = "[regex]::Escape('-f `$stateFull')"
        $regex.IsMatch($bad) | Should -BeTrue
        $regex.IsMatch($good) | Should -BeFalse
    }

    It 'requires unreadable authoritative trigger state to stay fail-closed' {
        $root = Get-NxbKnownErrorTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Update-NxbAdaptiveObservabilityState.ps1') -Raw
        $source | Should -Match ([regex]::Escape('Adaptive trigger state is unreadable: {0}'))
        $source | Should -Match ([regex]::Escape('-f $stateFull'))
        $source | Should -Not -Match ([regex]::Escape('starting from empty state'))
    }

    It 'runs exact-tree scanner at zero and keeps scanner fail-closed' {
        $root = Get-NxbKnownErrorTestRoot
        $scanner = Join-Path $root 'scripts\Invoke-NxbKnownErrorScan.ps1'
        $result = & $scanner -RepositoryRoot $root -NoThrow -PassThru
        if ([string]$result.status -cne 'passed' -or [int]$result.finding_count -ne 0) {
            $detail = @($result.findings | ForEach-Object { '{0} {1}:{2} {3}' -f $_.id,$_.path,$_.line,$_.preview }) -join [Environment]::NewLine
            throw ('Exact-tree known-error scan failed: findings={0}{1}{2}' -f [int]$result.finding_count,[Environment]::NewLine,$detail)
        }
        [string]$result.status | Should -BeExactly 'passed'
        [int]$result.finding_count | Should -Be 0
        [int]$result.rule_count | Should -BeGreaterOrEqual 16

        $source = Get-Content -LiteralPath $scanner -Raw
        $source | Should -Match ([regex]::Escape('if ($orderedFinding.Count -gt 0 -and -not $NoThrow)'))
        $source | Should -Match ([regex]::Escape('NXB known-error pre-final scan failed with {0} finding(s).'))
    }
}
