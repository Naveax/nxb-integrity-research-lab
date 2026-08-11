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

    It 'keeps machine-detectable rule ids unique' {
        $document = Get-NxbKnownErrorSignatureDocument
        $ids = @($document.rules | ForEach-Object { [string]$_.id })
        @($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
        $ids.Count | Should -BeGreaterThan 0
    }

    It 'lists every machine rule in the human ledger' {
        $root = Get-NxbKnownErrorTestRoot
        $ledger = Get-Content -LiteralPath (Join-Path $root 'docs\NXB-KNOWN-ERROR-LEDGER.md') -Raw
        $document = Get-NxbKnownErrorSignatureDocument
        foreach ($rule in @($document.rules)) {
            $ledger | Should -Match ([regex]::Escape([string]$rule.id))
        }
    }

    It 'retains the full observed and preflight ledger through NXB-ERR-018' {
        $root = Get-NxbKnownErrorTestRoot
        $ledger = Get-Content -LiteralPath (Join-Path $root 'docs\NXB-KNOWN-ERROR-LEDGER.md') -Raw
        foreach ($number in 1..18) {
            $id = 'NXB-ERR-{0:D3}' -f $number
            $ledger | Should -Match ([regex]::Escape($id))
        }
    }

    It 'detects ambiguous variable-colon interpolation but permits explicit scope variables' {
        $rule = Get-NxbKnownErrorRule -Id 'NXB-ERR-001'
        $regex = [regex]::new([string]$rule.regex)
        $regex.IsMatch('throw "repeat $Repeat: exit=$exitCode"') | Should -BeTrue
        $regex.IsMatch('throw "repeat ${Repeat}: exit=$exitCode"') | Should -BeFalse
        $regex.IsMatch('Write-Output "$env:OS"') | Should -BeFalse
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
        $bad = '[regex]::Escape("throw -f $stateFull")'
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
        [string]$result.status | Should -BeExactly 'passed'
        [int]$result.finding_count | Should -Be 0
        [int]$result.rule_count | Should -BeGreaterThan 0
    }

    It 'keeps the scanner fail-closed by default when findings exist' {
        $root = Get-NxbKnownErrorTestRoot
        $source = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-NxbKnownErrorScan.ps1') -Raw
        $source | Should -Match ([regex]::Escape("if ($orderedFinding.Count -gt 0 -and -not $NoThrow)"))
        $source | Should -Match ([regex]::Escape('NXB known-error pre-final scan failed with {0} finding(s).'))
    }
}
