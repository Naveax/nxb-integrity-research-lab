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

    It 'keeps machine rule ids unique and extends coverage through ERR-033' {
        $document = Get-NxbKnownErrorSignatureDocument
        $ids = @($document.rules | ForEach-Object { [string]$_.id })
        @($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
        $ids.Count | Should -BeGreaterOrEqual 22
        foreach ($ruleId in @('NXB-ERR-024','NXB-ERR-025','NXB-ERR-026','NXB-ERR-027','NXB-ERR-028','NXB-ERR-029','NXB-ERR-030','NXB-ERR-031','NXB-ERR-032','NXB-ERR-033')) {
            $ids | Should -Contain $ruleId
        }
        @((Get-NxbKnownErrorRule -Id 'NXB-ERR-029').include_globs) | Should -Contain 'tests/KnownErrorLedger.Tests.ps1'
        @((Get-NxbKnownErrorRule -Id 'NXB-ERR-030').include_globs) | Should -Contain 'scripts/Invoke-NxbSemanticPnpEventExperiment.ps1'
        @((Get-NxbKnownErrorRule -Id 'NXB-ERR-031').include_globs) | Should -Contain 'scripts/Invoke-NxbSemanticPowerFirmwareExperiment.ps1'
        @((Get-NxbKnownErrorRule -Id 'NXB-ERR-032').include_globs) | Should -Contain 'scripts/Invoke-NxbSemanticRootTraceExperiment.ps1'
        @((Get-NxbKnownErrorRule -Id 'NXB-ERR-033').include_globs) | Should -Contain 'scripts/Invoke-NxbControllerTargetTransportExperiment.ps1'
    }

    It 'lists every machine rule and every historical id through ERR-033 in the human ledger' {
        $root = Get-NxbKnownErrorTestRoot
        $ledger = Get-Content -LiteralPath (Join-Path $root 'docs\NXB-KNOWN-ERROR-LEDGER.md') -Raw
        $document = Get-NxbKnownErrorSignatureDocument
        foreach ($rule in @($document.rules)) {
            $ledger | Should -Match ([regex]::Escape([string]$rule.id))
        }
        foreach ($number in 1..33) {
            $id = 'NXB-ERR-{0:D3}' -f $number
            $ledger | Should -Match ([regex]::Escape($id))
        }
    }

    It 'locks recent array capability encoding EventLog ASCII prose empty-collection firmware-readback dictionary-traversal and transport-transcript regression behavior' {
        $arrayRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-024').regex)
        $badArrayProjection = '$policy.claim_targets' + '.PSObject.Properties'
        $arrayRegex.IsMatch($badArrayProjection) | Should -BeTrue
        $arrayRegex.IsMatch('@($policy.claim_targets)') | Should -BeFalse

        $capabilityRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-025').regex)
        $badCimPresence = 'Get-' + 'CimInstance Win32_PnPEntity -ErrorAction Stop'
        $capabilityRegex.IsMatch($badCimPresence) | Should -BeTrue

        $encodingRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-026').regex)
        $encodingRegex.IsMatch('non-ascii-' + [char]0x2192) | Should -BeTrue
        $encodingRegex.IsMatch('ascii-only-authority') | Should -BeFalse

        $eventRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-027').regex)
        $eventRegex.IsMatch('Get-' + 'WinEvent -FilterHashtable $filter') | Should -BeTrue
        $eventRegex.IsMatch('[Nxb.Semantic.PnpLifecycleCollector]::new()') | Should -BeFalse

        $asciiRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-028').regex)
        $singleQuote = [char]39
        $backslash = [char]92
        $badAsciiAssertion = 'Should -Not -Match ' + $singleQuote + '[^' + $backslash + 'u0000-' + $backslash + 'u007F]' + $singleQuote
        $asciiRegex.IsMatch($badAsciiAssertion) | Should -BeTrue
        $asciiRegex.IsMatch('[IO.File]::ReadAllBytes($Path)') | Should -BeFalse

        $proseRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-029').regex)
        $quote = [char]39
        $badProseAssertion = '$ledger | Should -Match ([regex]::Escape(' + $quote + 'This explanatory sentence is intentionally long and brittle.' + $quote + '))'
        $proseRegex.IsMatch($badProseAssertion) | Should -BeTrue
        $proseRegex.IsMatch('$ledger | Should -Match ([regex]::Escape(' + $quote + 'NXB-ERR-029' + $quote + '))') | Should -BeFalse

        $emptyCollectionRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-030').regex)
        $emptyCollectionRegex.IsMatch('[Parameter(Mandatory)][object[]]$Record') | Should -BeTrue
        $emptyCollectionRegex.IsMatch('[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Record') | Should -BeFalse

        $firmwareRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-031').regex)
        $badFirmwareReadback = '(Get-VMFirmware -VMName $vmName -ErrorAction Stop).EnableSecureBoot'
        $goodFirmwareReadback = 'Get-NxbSemanticFirmwareSecureBootState -Firmware (Get-VMFirmware -VMName $vmName -ErrorAction Stop)'
        $firmwareRegex.IsMatch($badFirmwareReadback) | Should -BeTrue
        $firmwareRegex.IsMatch($goodFirmwareReadback) | Should -BeFalse

        $dictionaryRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-032').regex)
        $badDictionaryWalker = @'
foreach ($segment in $Path.Split('.')) {
    if ($null -eq $current) { return $DefaultValue }
    $property = $current.PSObject.Properties[$segment]
'@
        $goodDictionaryWalker = @'
foreach ($segment in $Path.Split('.')) {
    if ($null -eq $current) { return $DefaultValue }
    if ($current -is [System.Collections.IDictionary]) {
        if (-not $current.Contains($segment)) { return $DefaultValue }
        $current = $current[$segment]
        continue
    }
    $property = $current.PSObject.Properties[$segment]
'@
        $dictionaryRegex.IsMatch($badDictionaryWalker) | Should -BeTrue
        $dictionaryRegex.IsMatch($goodDictionaryWalker) | Should -BeFalse

        $transcriptRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-033').regex)
        $transcriptRegex.IsMatch('[Parameter(Mandatory)][Collections.Generic.List[object]]$Transcript') | Should -BeTrue
        $transcriptRegex.IsMatch('[Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Transcript') | Should -BeFalse
    }

    It 'keeps current Part 4 ledger PnP firmware root-trace and transport sources free of ERR-028 through ERR-033 patterns' {
        $root = Get-NxbKnownErrorTestRoot
        $asciiRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-028').regex)
        $proseRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-029').regex)
        $emptyCollectionRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-030').regex)
        $firmwareRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-031').regex)
        $dictionaryRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-032').regex)
        $transcriptRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-033').regex)
        $part4Source = Get-Content -LiteralPath (Join-Path $root 'tests\Part4ResumableRunner.Tests.ps1') -Raw
        $ledgerSource = Get-Content -LiteralPath (Join-Path $root 'tests\KnownErrorLedger.Tests.ps1') -Raw
        $pnpSource = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSemanticPnpEventExperiment.ps1') -Raw
        $firmwareSource = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSemanticPowerFirmwareExperiment.ps1') -Raw
        $rootTraceSource = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbSemanticRootTraceExperiment.ps1') -Raw
        $transportSource = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbControllerTargetTransportExperiment.ps1') -Raw
        $asciiRegex.IsMatch($part4Source) | Should -BeFalse
        $asciiRegex.IsMatch($ledgerSource) | Should -BeFalse
        $proseRegex.IsMatch($ledgerSource) | Should -BeFalse
        $emptyCollectionRegex.IsMatch($pnpSource) | Should -BeFalse
        $firmwareRegex.IsMatch($firmwareSource) | Should -BeFalse
        $dictionaryRegex.IsMatch($rootTraceSource) | Should -BeFalse
        $transcriptRegex.IsMatch($transportSource) | Should -BeFalse
        $part4Source | Should -Match ([regex]::Escape('[IO.File]::ReadAllBytes($Path)'))
        $pnpSource | Should -Match ([regex]::Escape('[AllowEmptyCollection()][object[]]$Record'))
        $pnpSource | Should -Match ([regex]::Escape('if ($Record.Count -eq 0) { return @() }'))
        $firmwareSource | Should -Match ([regex]::Escape('function Get-NxbSemanticFirmwareSecureBootState'))
        $firmwareSource | Should -Match ([regex]::Escape('foreach ($propertyName in @(''SecureBoot'',''EnableSecureBoot''))'))
        $firmwareSource | Should -Match ([regex]::Escape('secure_boot_readback = ''vmfirmware_property_adapter_v1'''))
        $rootTraceSource | Should -Match ([regex]::Escape('if ($current -is [System.Collections.IDictionary])'))
        $rootTraceSource | Should -Match ([regex]::Escape('$current = $current[$segment]'))
        $rootTraceSource | Should -Match ([regex]::Escape('$eventsLostStatus -cne ''measured'''))
        $rootTraceSource | Should -Match ([regex]::Escape('$buffersWrittenStatus -cne ''measured'''))
        $transportSource | Should -Match ([regex]::Escape('[Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Transcript'))
        $transportSource | Should -Match ([regex]::Escape('[Parameter(Mandatory)][object[]]$Records'))
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

    It 'detects assignment to automatic Matches and PROFILE variables' {
        $matchesRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-006').regex)
        $matchesRegex.IsMatch('$matches = @()') | Should -BeTrue
        $matchesRegex.IsMatch('$domainMappings = @()') | Should -BeFalse
        $profileRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-021').regex)
        $profileRegex.IsMatch('$profile = $policy.mode_profiles.foo') | Should -BeTrue
        $profileRegex.IsMatch('$modeProfile = $policy.mode_profiles.foo') | Should -BeFalse
    }

    It 'detects plural helpers and double-quoted expected-source interpolation' {
        $pluralRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-008').regex)
        $pluralRegex.IsMatch('function Write-NxbHysteresisSignals {') | Should -BeTrue
        $pluralRegex.IsMatch('function Write-NxbHysteresisSignalDocument {') | Should -BeFalse
        $sourceRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-015').regex)
        $quote = [char]34
        $bad = '[regex]::Escape(' + $quote + 'throw -f $stateFull' + $quote + ')'
        $sourceRegex.IsMatch($bad) | Should -BeTrue
        $sourceRegex.IsMatch("[regex]::Escape('-f `$stateFull')") | Should -BeFalse
    }

    It 'requires unreadable authoritative trigger state to stay fail-closed' {
        $root = Get-NxbKnownErrorTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Update-NxbAdaptiveObservabilityState.ps1') -Raw
        $source | Should -Match ([regex]::Escape('Adaptive trigger state is unreadable: {0}'))
        $source | Should -Match ([regex]::Escape('-f $stateFull'))
        $source | Should -Not -Match ([regex]::Escape('starting from empty state'))
    }

    It 'keeps guarded native stderr and fully qualified wildcard enum regressions locked' {
        $root = Get-NxbKnownErrorTestRoot
        $wildcardRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-019').regex)
        $wildcardRegex.IsMatch('[WildcardOptions]::IgnoreCase') | Should -BeTrue
        $wildcardRegex.IsMatch('[System.Management.Automation.WildcardOptions]::IgnoreCase') | Should -BeFalse
        $nativeRegex = [regex]::new([string](Get-NxbKnownErrorRule -Id 'NXB-ERR-022').regex)
        $semanticSource = Get-Content -LiteralPath (Join-Path $root 'tests\SemanticEvidenceAuthority.Tests.ps1') -Raw
        $nativeRegex.IsMatch($semanticSource) | Should -BeFalse
        $semanticSource | Should -Match ([regex]::Escape('$previousErrorActionPreference = $ErrorActionPreference'))
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
        [int]$result.rule_count | Should -BeGreaterOrEqual 22
        $source = Get-Content -LiteralPath $scanner -Raw
        $source | Should -Match ([regex]::Escape('if ($orderedFinding.Count -gt 0 -and -not $NoThrow)'))
        $source | Should -Match ([regex]::Escape('NXB known-error pre-final scan failed with {0} finding(s).'))
    }
}
