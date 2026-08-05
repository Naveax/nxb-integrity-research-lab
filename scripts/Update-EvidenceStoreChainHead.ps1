[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Nxb.EvidenceStore.psm1') -Force

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
$storePath = Join-Path $experimentFull 'evidence-store'
$chainHeadPath = Join-Path $storePath 'chain-head.json'

$verified = & (Join-Path $PSScriptRoot 'Test-EvidenceStoreChain.ps1') `
    -ExperimentPath $experimentFull `
    -IgnoreChainHead `
    -PassThru

$chainHead = [ordered]@{
    schema_version = 1
    experiment_id = $verified.ExperimentId
    machine_id = $verified.MachineId
    boot_id = $verified.BootId
    session_id = $verified.SessionId
    record_count = $verified.RecordCount
    genesis_record_sha256 = $verified.GenesisRecordSha256
    last_sequence = $verified.LastSequence
    last_record_sha256 = $verified.LastRecordSha256
    chain_sha256 = $verified.ChainSha256
}

if ($PSCmdlet.ShouldProcess($chainHeadPath, 'Write verified evidence chain head')) {
    Write-NxbCanonicalJsonAtomic `
        -Path $chainHeadPath `
        -InputObject $chainHead `
        -Confirm:$false

    & (Join-Path $PSScriptRoot 'Test-EvidenceStoreSchema.ps1') `
        -Path $chainHeadPath `
        -DocumentType chain-head

    & (Join-Path $PSScriptRoot 'Test-EvidenceStoreChain.ps1') `
        -ExperimentPath $experimentFull

    Write-Output $chainHeadPath
}
