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

    It 'keeps the ledger signature document scanner and V5 authority repo-owned' {
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

    It 'uses signature schema version one and points to the canonical ledger' {
        $document = Get-NxbKnownErrorSignatureDocument
        [int]$document.schema_version | Should -Be 1
        [string]$document.ledger_path | Should -BeExactly 'docs/NXB-KNOWN-ERROR-LEDGER.md'
    }

    It 'keeps machine-detectable rule ids unique and extends generic coverage to semantic authority' {
        $document = Get-NxbKnownErrorSignatureDocument
        $ids = @($document.rules | ForEach-Object { [string]$_.id })
        @($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
        $ids.Count | Should -BeGreaterThan 0

        foreach ($ruleId in @('NXB-ERR-001','NXB-ERR-005','NXB-ERR-006','NXB-ERR-008','NXB-ERR-021')) {
            $rule = Get-NxbKnownErrorRule -Id $ruleId
            @($rule.include_globs) | Should -Contain 'scripts/*NxbSemantic*.ps1'
            @($rule.include_globs) | Should -Contain 'tests/Semantic*.Tests.ps1'
        }
        foreach ($ruleId in @('NXB-ERR-007','NXB-ERR-015')) {
            $rule = Get-NxbKnownErrorRule -Id $ruleId
            @($rule.include_globs) | Should -Contain 'tests/Semantic*.Tests.ps1'
        }
    }

    It 'lists every machine rule in the human ledger' {
        $root = Get-NxbKnownErrorTestRoot
        $ledger = Get-Content -LiteralPath (Join-Path $root 'docs\NXB-KNOWN-ERROR-LEDGER.md') -Raw
        $document = Get-NxbKnownErrorSignatureDocument
        foreach ($rule in @($document.rules)) {
            $ledger | Should -Match ([regex]::Escape([string]$rule.id))
        }
    }

    It 'retains the full observed preflight and workflow ledger through NXB-ERR-021 and locks automatic-variable regressions' {
        $root = Get-NxbKnownErrorTestRoot
        $ledger = Get-Content -LiteralPath (Join-Path $root 'docs\NXB-KNOWN-ERROR-LEDGER.md') -Raw
        foreach ($number in 1..21) {
            $id = 'NXB-ERR-{0:D3}' -f $number
            $ledger | Should -Match ([regex]::Escape($id))
        }

        $wildcardRule = Get-NxbKnownErrorRule -Id 'NXB-ERR-019'
        $wildcardRegex = [regex]::new([string]$wildcardRule.regex)
        $wildcardRegex.IsMatch('[WildcardOptions]::IgnoreCase') | Should -BeTrue
        $wildcardRegex.IsMatch('[System.Management.Automation.WildcardOptions]::IgnoreCase') | Should -BeFalse

        $scanner = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbKnownErrorScan.ps1') -Raw
        $scanner | Should -Match ([regex]::Escape('[System.Management.Automation.WildcardOptions]::IgnoreCase'))
        $scanner | Should -Not -Match ([regex]::Escape('[WildcardOptions]::IgnoreCase'))

        $profileRule = Get-NxbKnownErrorRule -Id 'NXB-ERR-021'
        $profileRegex = [regex]::new([string]$profileRule.regex)
        $profileRegex.IsMatch('$profile = $policy.mode_profiles.foo') | Should -BeTrue
        $profileRegex.IsMatch('$modeProfile = $policy.mode_profiles.foo') | Should -BeFalse

        $resolver = Get-Content -LiteralPath (Join-Path $root 'scripts\Resolve-NxbAdaptiveObservabilityPlan.ps1') -Raw
        $resolver | Should -Not -Match '(?im)^\s*\$profile\s*='
        $resolver | Should -Match ([regex]::Escape('$modeProfile = $policy.mode_profiles.PSObject.Properties[$effectiveMode].Value'))
    }

    It 'detects ambiguous variable-colon interpolation but permits explicit scope variables' {
        $rule = Get-NxbKnownErrorRule -Id 'NXB-ERR-001'
        $regex = [regex]::new([string]$rule.regex)
        $quote = [char]34
        $bad = 'throw ' + $quote + 'repeat $Repeat' + ': exit=$exitCode' + $quote
        $goodDelimited = 'throw ' + $quote + 'repeat ${Repeat}' + ': exit=$exitCode' + $quote
        $goodScope = 'Write-Output ' + $quote + '$env' + ':OS' + $quote
        $regex.IsMatch($bad) | Should -BeTrue
        $regex.IsMatch($goodDelimited) | Should -BeFalse
        $regex.IsMatch($goodScope) | Should -BeFalse
    }

    It 'detects assignment to the automatic Matches variable case-insensitively' {
        $rule = Get-NxbKnownErrorRule -Id 'NXB-ERR-006'
        $regex = [regex]::new([string]$rule.regex)
        $regex.IsMatch('$matches = @()') | Should -BeTrue
        $regex.IsMatch('$Matches = $null') | Should -BeTrue
        $regex.IsMatch('$domainMappings = @()') | Should -BeFalse
    }

    It 'detects the known plural helper declarations without matching replacements' {
        $rule = Get-NxbKnownErrorRule -Id 'NXB-ERR-008'
        $regex = [regex]::new([string]$rule.regex)
        $regex.IsMatch('function Write-NxbHysteresisSignals {') | Should -BeTrue
        $regex.IsMatch('function Get-NxbStableUniqueDomains {') | Should -BeTrue
        $regex.IsMatch('function Write-NxbHysteresisSignalDocument {') | Should -BeFalse
        $regex.IsMatch('function Get-NxbStableUniqueDomain {') | Should -BeFalse
    }

    It 'detects double-quoted expected-source regex interpolation' {
        $rule = Get-NxbKnownErrorRule -Id 'NXB-ERR-015'
        $regex = [regex]::new([string]$rule.regex)
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

    It 'runs the scanner against the exact repository tree with zero known-error findings' {
        $root = Get-NxbKnownErrorTestRoot
        $scanner = Join-Path $root 'scripts\Invoke-NxbKnownErrorScan.ps1'
        $result = & $scanner -RepositoryRoot $root -NoThrow -PassThru
        if ([string]$result.status -cne 'passed' -or [int]$result.finding_count -ne 0) {
            $detail = @(
                $result.findings | ForEach-Object {
                    '{0} {1}:{2} {3}' -f $_.id,$_.path,$_.line,$_.preview
                }
            ) -join [Environment]::NewLine
            throw ('Exact-tree known-error scan failed: findings={0}{1}{2}' -f [int]$result.finding_count,[Environment]::NewLine,$detail)
        }
        [string]$result.status | Should -BeExactly 'passed'
        [int]$result.finding_count | Should -Be 0
        [int]$result.rule_count | Should -BeGreaterThan 0
    }

    It 'keeps the scanner fail-closed by default when findings exist' {
        $root = Get-NxbKnownErrorTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbKnownErrorScan.ps1') -Raw
        $source | Should -Match ([regex]::Escape('if ($orderedFinding.Count -gt 0 -and -not $NoThrow)'))
        $source | Should -Match ([regex]::Escape('NXB known-error pre-final scan failed with {0} finding(s).'))
    }
}
