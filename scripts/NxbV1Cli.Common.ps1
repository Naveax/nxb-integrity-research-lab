Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NxbV1CliPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $path = Join-Path -Path $RepositoryRoot -ChildPath 'config\nxb-v1-cli-policy.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'NXB v1 CLI policy is missing.' }
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
}

function Get-NxbV1CliExitCode {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Policy,[Parameter(Mandatory)][string]$Category)
    $property = $Policy.exit_codes.PSObject.Properties[$Category]
    if ($null -eq $property) { return 10 }
    return [int]$property.Value
}

function Get-NxbV1CliFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Policy,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Message
    )
    $exception = [InvalidOperationException]::new($Message)
    $exception.Data['nxb_cli_category'] = $Category
    $exception.Data['nxb_cli_exit_code'] = Get-NxbV1CliExitCode -Policy $Policy -Category $Category
    return $exception
}

function ConvertTo-NxbV1CliEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Policy,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][ValidateSet('passed','failed')][string]$Status,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][bool]$MutationPerformed,
        [Parameter()][AllowNull()][object]$Data,
        [Parameter()][object[]]$Errors = @()
    )
    $exitCode = Get-NxbV1CliExitCode -Policy $Policy -Category $Category
    return [pscustomobject][ordered]@{
        schema_version = 1
        contract_id = [string]$Policy.output.contract_id
        command = $Command
        status = $Status
        exit_code = $exitCode
        category = $Category
        message = $Message
        mutation_performed = $MutationPerformed
        data = $Data
        errors = @($Errors)
    }
}

function ConvertTo-NxbV1CliFailureEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Policy,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][Management.Automation.ErrorRecord]$ErrorRecord
    )
    $category = 'internal'
    $exitCode = Get-NxbV1CliExitCode -Policy $Policy -Category $category
    if ($null -ne $ErrorRecord.Exception.Data['nxb_cli_category']) {
        $category = [string]$ErrorRecord.Exception.Data['nxb_cli_category']
    }
    if ($null -ne $ErrorRecord.Exception.Data['nxb_cli_exit_code']) {
        $exitCode = [int]$ErrorRecord.Exception.Data['nxb_cli_exit_code']
    }
    $errorObject = [pscustomobject][ordered]@{
        category = $category
        message = [string]$ErrorRecord.Exception.Message
    }
    return [pscustomobject][ordered]@{
        schema_version = 1
        contract_id = [string]$Policy.output.contract_id
        command = $Command
        status = 'failed'
        exit_code = $exitCode
        category = $category
        message = [string]$ErrorRecord.Exception.Message
        mutation_performed = $false
        data = $null
        errors = @($errorObject)
    }
}

function Assert-NxbV1CliValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Policy,
        [Parameter()][AllowNull()][string]$Value,
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][string]$Category = 'usage'
    )
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw (Get-NxbV1CliFailure -Policy $Policy -Category $Category -Message ('{0} is required.' -f $Name))
    }
}

function Test-NxbV1CliConfigDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Document)
    $allowed = @('schema_version','contract_id','output_mode','non_interactive','update_channel','install_root','update_root','evidence_root')
    $required = @('schema_version','contract_id','output_mode','non_interactive','update_channel')
    foreach ($property in @($Document.PSObject.Properties)) {
        if ($allowed -notcontains [string]$property.Name) { return $false }
    }
    foreach ($name in $required) {
        if ($null -eq $Document.PSObject.Properties[$name]) { return $false }
    }
    if ([int]$Document.schema_version -ne 1) { return $false }
    if ([string]$Document.contract_id -cne 'nxb-v1-cli-config-v1') { return $false }
    if (@('human','json') -notcontains [string]$Document.output_mode) { return $false }
    if ($Document.non_interactive -isnot [bool]) { return $false }
    if (@('stable','beta') -notcontains [string]$Document.update_channel) { return $false }
    foreach ($rootName in @('install_root','update_root','evidence_root')) {
        $rootProperty = $Document.PSObject.Properties[$rootName]
        if ($null -ne $rootProperty -and $null -ne $rootProperty.Value -and $rootProperty.Value -isnot [string]) { return $false }
    }
    return $true
}

function Invoke-NxbV1CliDoctor {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Policy,[Parameter(Mandatory)][string]$RepositoryRoot)
    $path = Join-Path -Path $RepositoryRoot -ChildPath ([string]$Policy.delegation.doctor).Replace('/',[IO.Path]::DirectorySeparatorChar)
    try {
        $receipt = & $path -PassThru 6>$null
        return $receipt
    }
    catch {
        throw (Get-NxbV1CliFailure -Policy $Policy -Category 'dependency_doctor' -Message $_.Exception.Message)
    }
}

function Invoke-NxbV1CliEvidenceVerification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Policy,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$ExperimentPath,
        [Parameter()][string]$BundlePath,
        [Parameter()][string]$CertificatePath
    )
    $path = Join-Path -Path $RepositoryRoot -ChildPath ([string]$Policy.delegation.evidence_verify).Replace('/',[IO.Path]::DirectorySeparatorChar)
    $parameters = @{ ExperimentPath=$ExperimentPath; PassThru=$true }
    if (-not [string]::IsNullOrWhiteSpace($BundlePath)) { $parameters['BundlePath'] = $BundlePath }
    if (-not [string]::IsNullOrWhiteSpace($CertificatePath)) { $parameters['CertificatePath'] = $CertificatePath }
    try {
        $result = & $path @parameters 6>$null
        return $result
    }
    catch {
        throw (Get-NxbV1CliFailure -Policy $Policy -Category 'evidence_verification' -Message $_.Exception.Message)
    }
}

function Invoke-NxbV1CliSignedUpdate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Policy,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][ValidateSet('Check','Stage','Apply','Rollback')][string]$Mode,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$UpdateRoot,
        [Parameter(Mandatory)][string]$ReceiptPath,
        [Parameter()][string]$PackageRoot,
        [Parameter()][string]$ManifestPath,
        [Parameter()][string]$DescriptorPath,
        [Parameter()][string]$EnvelopePath,
        [Parameter()][string]$TrustPath,
        [Parameter()][switch]$DryRun
    )
    $path = Join-Path -Path $RepositoryRoot -ChildPath ([string]$Policy.delegation.signed_update).Replace('/',[IO.Path]::DirectorySeparatorChar)
    $action = $Mode
    if ($Mode -ceq 'Check') { $action = 'Stage' }
    $parameters = @{
        Action=$action
        InstallRoot=$InstallRoot
        UpdateRoot=$UpdateRoot
        ReceiptPath=$ReceiptPath
        Confirm=$false
    }
    if (-not [string]::IsNullOrWhiteSpace($PackageRoot)) { $parameters['PackageRoot'] = $PackageRoot }
    if (-not [string]::IsNullOrWhiteSpace($ManifestPath)) { $parameters['ManifestPath'] = $ManifestPath }
    if (-not [string]::IsNullOrWhiteSpace($DescriptorPath)) { $parameters['DescriptorPath'] = $DescriptorPath }
    if (-not [string]::IsNullOrWhiteSpace($EnvelopePath)) { $parameters['EnvelopePath'] = $EnvelopePath }
    if (-not [string]::IsNullOrWhiteSpace($TrustPath)) { $parameters['TrustPath'] = $TrustPath }
    if ($DryRun -or $Mode -ceq 'Check') { $parameters['WhatIf'] = $true }
    try {
        $null = @(& $path @parameters 6>&1)
    }
    catch {
        $message = [string]$_.Exception.Message
        $category = 'mutation_runtime'
        if ($message -match '(?i)(trust|signature|manifest|hash|tamper|revoked|channel|replay|downgrade)') { $category = 'trust_integrity' }
        elseif ($message -match '(?i)(already|missing|absent|separate|unsafe|requires|binding drift|precondition|sequence)') { $category = 'state_precondition' }
        throw (Get-NxbV1CliFailure -Policy $Policy -Category $category -Message $message)
    }
    if ($DryRun -or $Mode -ceq 'Check') {
        return [pscustomobject][ordered]@{
            verified = $true
            action = $Mode
            dry_run = $true
            mutation_performed = $false
        }
    }
    if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) {
        throw (Get-NxbV1CliFailure -Policy $Policy -Category 'mutation_runtime' -Message 'Signed update authority did not emit the required receipt.')
    }
    return (Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json)
}
