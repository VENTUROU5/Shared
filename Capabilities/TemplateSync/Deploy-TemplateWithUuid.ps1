#Requires -Modules VMware.PowerCLI
<#
.SYNOPSIS
    Deploys a VM from content library using the preserved instance-uuid.
    
.DESCRIPTION
    Helper script to deploy VMs from the distributed templates while
    preserving the consistent instance-uuid stored in the SMB share.
    Use this when deploying from the destination content libraries.
    
.PARAMETER TemplateName
    Name of the template in the content library.
    
.PARAMETER VMName
    Name for the new VM.
    
.PARAMETER VMHost
    ESXi host to deploy to.
    
.PARAMETER Datastore
    Datastore for the VM.
    
.PARAMETER Folder
    Optional VM folder.
    
.PARAMETER ApplyUuid
    Apply the stored instance-uuid after deployment. Default: $true
    
.EXAMPLE
    .\Deploy-TemplateWithUuid.ps1 -TemplateName "Windows2022-Base" -VMName "NewVM01" -VMHost "esxi01.domain.local" -Datastore "DS01"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TemplateName,
    
    [Parameter(Mandatory)]
    [string]$VMName,
    
    [Parameter(Mandatory)]
    [string]$VMHost,
    
    [Parameter(Mandatory)]
    [string]$Datastore,
    
    [string]$Folder,
    
    [string]$ConfigPath = "$PSScriptRoot\Config.ps1",
    
    [bool]$ApplyUuid = $true
)

# Load configuration
. $ConfigPath

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    switch ($Level) {
        "ERROR" { Write-Error "$Timestamp $Message" }
        "WARN"  { Write-Warning "$Timestamp $Message" }
        default { Write-Host "$Timestamp [$Level] $Message" }
    }
}

function Get-UuidMapping {
    param([string]$TemplateName)
    $UuidFile = Join-Path $UuidsPath $DestinationVCenterName "$TemplateName.json"
    if (Test-Path $UuidFile) {
        return Get-Content $UuidFile -Raw | ConvertFrom-Json
    }
    return $null
}

try {
    # Check connection
    if (-not $global:DefaultVIServers -or $global:DefaultVIServers.Count -eq 0) {
        Write-Log "Not connected to vCenter. Connect first with Connect-VIServer" "ERROR"
        exit 1
    }
    
    # Get content library and item
    $Library = Get-ContentLibrary -Name $DestinationContentLibrary -ErrorAction Stop
    $LibraryItem = Get-ContentLibraryItem -ContentLibrary $Library -Name $TemplateName -ErrorAction Stop
    
    if (-not $LibraryItem) {
        Write-Log "Template '$TemplateName' not found in content library '$DestinationContentLibrary'" "ERROR"
        exit 1
    }
    
    Write-Log "Found template: $TemplateName"
    
    # Get target resources
    $TargetHost = Get-VMHost -Name $VMHost -ErrorAction Stop
    $TargetDatastore = Get-Datastore -Name $Datastore -ErrorAction Stop
    
    # Build deployment parameters
    $DeployParams = @{
        ContentLibraryItem = $LibraryItem
        Name = $VMName
        VMHost = $TargetHost
        Datastore = $TargetDatastore
    }
    
    if ($Folder) {
        $TargetFolder = Get-Folder -Name $Folder -ErrorAction Stop
        $DeployParams.Location = $TargetFolder
    }
    
    Write-Log "Deploying VM '$VMName' from template '$TemplateName'..."
    $NewVM = New-VM @DeployParams -ErrorAction Stop
    Write-Log "VM deployed successfully: $($NewVM.Name)"
    
    # Apply stored UUID if requested
    if ($ApplyUuid) {
        $UuidMapping = Get-UuidMapping -TemplateName $TemplateName
        
        if ($UuidMapping -and $UuidMapping.InstanceUuid) {
            Write-Log "Applying stored instance-uuid: $($UuidMapping.InstanceUuid)"
            
            # VM must be powered off to change UUID
            if ($NewVM.PowerState -ne "PoweredOff") {
                Write-Log "Powering off VM to apply UUID..."
                Stop-VM -VM $NewVM -Confirm:$false | Out-Null
            }
            
            # Apply the UUID using extraConfig
            $Spec = New-Object VMware.Vim.VirtualMachineConfigSpec
            $Spec.uuid = $UuidMapping.InstanceUuid
            
            $NewVM.ExtensionData.ReconfigVM($Spec)
            
            Write-Log "Instance-uuid applied successfully"
            
            # Refresh VM object
            $NewVM = Get-VM -Name $VMName
        } else {
            Write-Log "No UUID mapping found for template '$TemplateName' - using auto-generated UUID" "WARN"
        }
    }
    
    Write-Log "Deployment complete!"
    Write-Log "  VM Name: $($NewVM.Name)"
    Write-Log "  Instance UUID: $($NewVM.ExtensionData.Config.InstanceUuid)"
    Write-Log "  Power State: $($NewVM.PowerState)"
    
    return $NewVM
}
catch {
    Write-Log "Deployment failed: $_" "ERROR"
    throw
}
