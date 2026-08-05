BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsRoot = Join-Path $script:RepositoryRoot 'scripts'
    Import-Module (Join-Path $script:ScriptsRoot 'Nxb.Lab.Common.psm1') -Force
    Import-Module (Join-Path $script:ScriptsRoot 'Nxb.EvidenceStore.psm1') -Force

    function Initialize-NxbSigningExperiment {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$Name
        )

        $experimentPath = Join-Path $Root $Name
        $baselinePath = Join-Path $experimentPath 'baseline'
        $logsPath = Join-Path $experimentPath 'logs'
        New-Item -ItemType Directory -Path $baselinePath -Force | Out-Null
        New-Item -ItemType Directory -Path $logsPath -Force | Out-Null

        Write-NxbCanonicalJsonAtomic `
            -Path (Join-Path $experimentPath 'manifest.json') `
            -InputObject ([ordered]@{
                experiment_id = 'signing-experiment'
                status = 'prepared'
            }) `
            -Confirm:$false
        Write-NxbCanonicalJsonAtomic `
            -Path (Join-Path $baselinePath 'observation-identity.json') `
            -InputObject ([ordered]@{
                machine_id = 'signing-machine'
                boot_id = 'signing-boot'
            }) `
            -Confirm:$false
        [IO.File]::WriteAllText(
            (Join-Path $logsPath 'evidence.txt'),
            'signed synthetic evidence',
            [Text.UTF8Encoding]::new($false)
        )

        [void](& (Join-Path $script:ScriptsRoot 'New-EvidenceStoreRecord.ps1') `
            -ExperimentPath $experimentPath `
            -RecordType manifest_snapshot `
            -Payload ([ordered]@{ state = 'prepared' }) `
            -SessionId 'signing-session' `
            -CapturedUtc ([DateTime]'2026-08-04T21:00:00Z') `
            -MonotonicNs 100)

        [void](& (Join-Path $script:ScriptsRoot 'New-EvidenceStoreRecord.ps1') `
            -ExperimentPath $experimentPath `
            -RecordType evidence_index_snapshot `
            -Payload ([ordered]@{ count = [int64]1 }) `
            -SessionId 'signing-session' `
            -CapturedUtc ([DateTime]'2026-08-04T21:00:01Z') `
            -MonotonicNs 200)

        $bundle = & (Join-Path $script:ScriptsRoot 'New-EvidenceBundle.ps1') `
            -ExperimentPath $experimentPath `
            -IncludeRelativePath @(
                'manifest.json',
                'baseline/observation-identity.json',
                'evidence-store/chain-head.json',
                'logs/evidence.txt'
            ) `
            -Confirm:$false

        return [pscustomobject]@{
            ExperimentPath = $experimentPath
            BundlePath = $bundle.BundlePath
            BundleSha256 = $bundle.BundleSha256
        }
    }

    function Initialize-NxbTestCertificatePair {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$Name
        )

        $passwordText = "nxb-$Name-password"
        $password = [Security.SecureString]::new()
        foreach ($character in $passwordText.ToCharArray()) {
            $password.AppendChar($character)
        }
        $password.MakeReadOnly()

        $certificate = New-SelfSignedCertificate `
            -Subject ("CN=NXB Evidence Test {0}" -f [guid]::NewGuid()) `
            -KeyAlgorithm RSA `
            -KeyLength 2048 `
            -HashAlgorithm SHA256 `
            -KeyExportPolicy Exportable `
            -CertStoreLocation 'Cert:\CurrentUser\My' `
            -NotAfter (Get-Date).AddDays(1)

        [void]$script:CertificateThumbprints.Add($certificate.Thumbprint)
        $pfxPath = Join-Path $Root "$Name.pfx"
        $cerPath = Join-Path $Root "$Name.cer"
        Export-PfxCertificate `
            -Cert $certificate `
            -FilePath $pfxPath `
            -Password $password | Out-Null
        Export-Certificate `
            -Cert $certificate `
            -FilePath $cerPath `
            -Type CERT | Out-Null

        return [pscustomobject]@{
            PfxPath = $pfxPath
            CerPath = $cerPath
            Password = $password
            PasswordText = $passwordText
            Thumbprint = $certificate.Thumbprint
        }
    }

    function Add-NxbTestBundleSignature {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][object]$Experiment,
            [Parameter(Mandatory)][object]$Certificate
        )

        return & (Join-Path $script:ScriptsRoot 'Add-EvidenceBundleSignature.ps1') `
            -ExperimentPath $Experiment.ExperimentPath `
            -BundlePath $Experiment.BundlePath `
            -PfxPath $Certificate.PfxPath `
            -PfxPassword $Certificate.Password `
            -Confirm:$false
    }
}

Describe 'NXB detached evidence bundle signatures' {
    BeforeEach {
        $script:TemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
            'nxb-evidence-signing-{0}' -f [guid]::NewGuid()
        )
        New-Item -ItemType Directory -Path $script:TemporaryRoot -Force | Out-Null
        $script:CertificateThumbprints = [Collections.Generic.List[string]]::new()
    }

    AfterEach {
        foreach ($thumbprint in $script:CertificateThumbprints) {
            $certificatePath = "Cert:\CurrentUser\My\$thumbprint"
            if (Test-Path -LiteralPath $certificatePath) {
                Remove-Item -LiteralPath $certificatePath -Force
            }
        }
        if (Test-Path -LiteralPath $script:TemporaryRoot) {
            Remove-Item -LiteralPath $script:TemporaryRoot -Recurse -Force
        }
    }

    It 'preserves unsigned bundle identity and verifies with a public certificate' {
        $experiment = Initialize-NxbSigningExperiment `
            -Root $script:TemporaryRoot `
            -Name 'valid'
        $certificate = Initialize-NxbTestCertificatePair `
            -Root $script:TemporaryRoot `
            -Name 'valid'
        $unsignedCopy = Join-Path $script:TemporaryRoot 'unsigned-bundle.json'
        Copy-Item -LiteralPath $experiment.BundlePath -Destination $unsignedCopy

        $signed = Add-NxbTestBundleSignature `
            -Experiment $experiment `
            -Certificate $certificate
        $signed.BundleSha256 | Should -Be $experiment.BundleSha256
        $signed.SignatureState | Should -Be 'present_unverified'

        $rawManifest = Get-Content -LiteralPath $experiment.BundlePath -Raw
        $rawManifest | Should -Not -Match ([regex]::Escape($certificate.PfxPath))
        $rawManifest | Should -Not -Match ([regex]::Escape($certificate.PasswordText))

        $structural = & (Join-Path $script:ScriptsRoot 'Test-EvidenceBundle.ps1') `
            -ExperimentPath $experiment.ExperimentPath `
            -BundlePath $experiment.BundlePath `
            -PassThru
        $structural.SignatureState | Should -Be 'present_unverified'

        $verified = & (Join-Path $script:ScriptsRoot 'Test-EvidenceBundle.ps1') `
            -ExperimentPath $experiment.ExperimentPath `
            -BundlePath $experiment.BundlePath `
            -CertificatePath $certificate.CerPath `
            -PassThru
        $verified.IsValid | Should -BeTrue
        $verified.SignatureState | Should -Be 'valid'
        $verified.BundleSha256 | Should -Be $experiment.BundleSha256

        $comparison = & (Join-Path $script:ScriptsRoot 'Compare-EvidenceBundle.ps1') `
            -LeftBundlePath $unsignedCopy `
            -RightBundlePath $experiment.BundlePath
        $comparison.Relationship | Should -Be 'identical_bundle_identity'
        $comparison.SignatureStateChanged | Should -BeTrue
    }

    It 'rejects a one-byte detached signature modification' {
        $experiment = Initialize-NxbSigningExperiment `
            -Root $script:TemporaryRoot `
            -Name 'tamper'
        $certificate = Initialize-NxbTestCertificatePair `
            -Root $script:TemporaryRoot `
            -Name 'tamper'
        $signed = Add-NxbTestBundleSignature `
            -Experiment $experiment `
            -Certificate $certificate

        $bytes = [IO.File]::ReadAllBytes($signed.SignaturePath)
        $bytes[0] = $bytes[0] -bxor 0x01
        [IO.File]::WriteAllBytes($signed.SignaturePath, $bytes)

        {
            & (Join-Path $script:ScriptsRoot 'Test-EvidenceBundle.ps1') `
                -ExperimentPath $experiment.ExperimentPath `
                -CertificatePath $certificate.CerPath
        } | Should -Throw '*signature file SHA-256 uyuşmuyor*'
    }

    It 'rejects a different public certificate' {
        $experiment = Initialize-NxbSigningExperiment `
            -Root $script:TemporaryRoot `
            -Name 'wrong-cert'
        $signingCertificate = Initialize-NxbTestCertificatePair `
            -Root $script:TemporaryRoot `
            -Name 'signing-cert'
        $wrongCertificate = Initialize-NxbTestCertificatePair `
            -Root $script:TemporaryRoot `
            -Name 'wrong-cert'
        [void](Add-NxbTestBundleSignature `
            -Experiment $experiment `
            -Certificate $signingCertificate)

        {
            & (Join-Path $script:ScriptsRoot 'Test-EvidenceBundle.ps1') `
                -ExperimentPath $experiment.ExperimentPath `
                -CertificatePath $wrongCertificate.CerPath
        } | Should -Throw '*Certificate SHA-256*uyuşmuyor*'
    }

    It 'rejects a missing detached signature file' {
        $experiment = Initialize-NxbSigningExperiment `
            -Root $script:TemporaryRoot `
            -Name 'missing'
        $certificate = Initialize-NxbTestCertificatePair `
            -Root $script:TemporaryRoot `
            -Name 'missing'
        $signed = Add-NxbTestBundleSignature `
            -Experiment $experiment `
            -Certificate $certificate
        Remove-Item -LiteralPath $signed.SignaturePath -Force

        {
            & (Join-Path $script:ScriptsRoot 'Test-EvidenceBundle.ps1') `
                -ExperimentPath $experiment.ExperimentPath
        } | Should -Throw '*envanter dosyası bulunamadı*'
    }

    It 'requires a public certificate for a declared valid signature state' {
        $experiment = Initialize-NxbSigningExperiment `
            -Root $script:TemporaryRoot `
            -Name 'valid-state'
        $certificate = Initialize-NxbTestCertificatePair `
            -Root $script:TemporaryRoot `
            -Name 'valid-state'
        [void](Add-NxbTestBundleSignature `
            -Experiment $experiment `
            -Certificate $certificate)

        $bundle = Read-NxbJson -Path $experiment.BundlePath
        $bundle.signature_state = 'valid'
        Write-NxbCanonicalJsonAtomic `
            -Path $experiment.BundlePath `
            -InputObject $bundle `
            -Confirm:$false

        {
            & (Join-Path $script:ScriptsRoot 'Test-EvidenceBundle.ps1') `
                -ExperimentPath $experiment.ExperimentPath
        } | Should -Throw '*public certificate olmadan doğrulanamaz*'

        $verified = & (Join-Path $script:ScriptsRoot 'Test-EvidenceBundle.ps1') `
            -ExperimentPath $experiment.ExperimentPath `
            -CertificatePath $certificate.CerPath `
            -PassThru
        $verified.SignatureState | Should -Be 'valid'
    }
}
