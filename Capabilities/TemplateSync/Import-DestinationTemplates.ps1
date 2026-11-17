#Requires -Modules VMware.PowerCLI
<#
.SYNOPSIS
    Imports OVF templates from SMB share to destination content library.
    Preserves instance-uuid across deployments.
    
.DESCRIPTION
    This script runs on management hosts with access to destination vCenters.
    It monitors the SMB share for new template versions and imports them to
    the local content library, updating the UUID mapping for future deployments.
    
.NOTES
    Schedule as a Windows Scheduled Task running every 15 minutes.
    Ensure the service account has:
    - Content Library admin access (create library if missing)
    - Import OVF privileges
    - Read access to SMB share
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\Config.ps1",
    [switch]$Force  # Force re-import of all templates regardless of version
)

# Load configuration
. $ConfigPath

# Initialize logging
$LogFile = Join-Path $LogPath "DestImport_$($DestinationVCenterName)_$(Get-Date -Format 'yyyyMMdd').log"
if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "$Timestamp [$Level] $Message"
    Add-Content -Path $LogFile -Value $LogEntry
    switch ($Level) {
        "ERROR" { Write-Error $Message }
        "WARN"  { Write-Warning $Message }
        default { Write-Host $LogEntry }
    }
}

function Get-DestinationState {
    $StateFile = Join-Path $StatePath "$DestinationVCenterName-state.json"
    if (Test-Path $StateFile) {
        return Get-Content $StateFile -Raw | ConvertFrom-Json -AsHashtable
    }
    return @{}
}

function Save-DestinationState {
    param([hashtable]$State)
    $StateFile = Join-Path $StatePath "$DestinationVCenterName-state.json"
    if (-not (Test-Path $StatePath)) {
        New-Item -ItemType Directory -Path $StatePath -Force | Out-Null
    }
    $State | ConvertTo-Json -Depth 10 | Set-Content $StateFile
}

function Get-UuidMapping {
    param([string]$TemplateName)
    $UuidFile = Join-Path $UuidsPath $DestinationVCenterName "$TemplateName.json"
    if (Test-Path $UuidFile) {
        return Get-Content $UuidFile -Raw | ConvertFrom-Json -AsHashtable
    }
    return $null
}

function Save-UuidMapping {
    param(
        [string]$TemplateName,
        [string]$InstanceUuid,
        [string]$Version
    )
    $UuidDir = Join-Path $UuidsPath $DestinationVCenterName
    if (-not (Test-Path $UuidDir)) {
        New-Item -ItemType Directory -Path $UuidDir -Force | Out-Null
    }
    
    $UuidFile = Join-Path $UuidDir "$TemplateName.json"
    $Mapping = @{
        InstanceUuid = $InstanceUuid
        LastUpdated = (Get-Date).ToString("o")
        Version = $Version
        VCenter = $DestinationVCenter
    }
    $Mapping | ConvertTo-Json -Depth 5 | Set-Content $UuidFile
    Write-Log "Saved UUID mapping for $TemplateName : $InstanceUuid"
}

function Get-LatestExportVersion {
    param([string]$TemplateName)
    
    $TemplatePath = Join-Path $ExportsPath $TemplateName
    if (-not (Test-Path $TemplatePath)) {
        return $null
    }
    
    # Get the highest version directory
    $Versions = Get-ChildItem -Path $TemplatePath -Directory | 
        Sort-Object { [int]$_.Name } -Descending
    
    if ($Versions) {
        return $Versions[0].Name
    }
    return $null
}

function Import-TemplateToLibrary {
    param(
        [string]$TemplateName,
        [string]$Version,
        [VMware.VimAutomation.ViCore.Types.V1.ContentLibrary.ContentLibrary]$Library
    )
    
    $SourcePath = Join-Path $ExportsPath $TemplateName $Version
    $ManifestFile = Join-Path $SourcePath "manifest.json"
    
    if (-not (Test-Path $ManifestFile)) {
        Write-Log "Manifest not found at $ManifestFile - skipping" "WARN"
        return $false
    }
    
    # Find the OVF file
    $OvfFile = Get-ChildItem -Path $SourcePath -Filter "*.ovf" | Select-Object -First 1
    if (-not $OvfFile) {
        Write-Log "No OVF file found in $SourcePath - skipping" "WARN"
        return $false
    }
    
    Write-Log "Importing $TemplateName version $Version from $($OvfFile.FullName)"
    
    try {
        # Check if item already exists
        $ExistingItem = Get-ContentLibraryItem -ContentLibrary $Library -Name $TemplateName -ErrorAction SilentlyContinue
        
        if ($ExistingItem) {
            Write-Log "Removing existing item: $TemplateName"
            Remove-ContentLibraryItem -ContentLibraryItem $ExistingItem -Confirm:$false
        }
        
        # Import the OVF to content library
        $NewItem = New-ContentLibraryItem -ContentLibrary $Library -Name $TemplateName -Files $OvfFile.FullName -ErrorAction Stop
        
        Write-Log "Successfully imported $TemplateName (ID: $($NewItem.Id))"
        
        # Generate and save UUID for this vCenter's deployment
        # The UUID will be applied when the template is deployed as a VM
        $InstanceUuid = [guid]::NewGuid().ToString()
        Save-UuidMapping -TemplateName $TemplateName -InstanceUuid $InstanceUuid -Version $Version
        
        return $true
    }
    catch {
        Write-Log "Failed to import $TemplateName : $_" "ERROR"
        return $false
    }
}

function Ensure-ContentLibrary {
    param([string]$LibraryName)
    
    $Library = Get-ContentLibrary -Name $LibraryName -ErrorAction SilentlyContinue
    
    if (-not $Library) {
        Write-Log "Content library '$LibraryName' not found - creating..."
        
        # Get a datastore for the library
        $Datastore = Get-Datastore | Where-Object { $_.FreeSpaceGB -gt 100 } | 
            Sort-Object FreeSpaceGB -Descending | Select-Object -First 1
        
        if (-not $Datastore) {
            Write-Log "No suitable datastore found with >100GB free space" "ERROR"
            throw "No suitable datastore for content library"
        }
        
        $Library = New-ContentLibrary -Name $LibraryName -Datastore $Datastore -ErrorAction Stop
        Write-Log "Created content library '$LibraryName' on datastore '$($Datastore.Name)'"
    }
    
    return $Library
}

# Main execution
try {
    Write-Log "========== Starting Destination Import Check =========="
    Write-Log "Destination vCenter: $DestinationVCenter ($DestinationVCenterName)"
    
    # Check SMB connectivity
    if (-not (Test-Path $ExportsPath)) {
        Write-Log "Cannot access exports path: $ExportsPath" "ERROR"
        exit 1
    }
    
    # Load credentials and connect
    if (-not (Test-Path $CredentialFile)) {
        Write-Log "Credential file not found: $CredentialFile" "ERROR"
        Write-Log "Create it with: Get-Credential | Export-Clixml -Path '$CredentialFile'" "ERROR"
        exit 1
    }
    
    $Credential = Import-Clixml $CredentialFile
    
    Write-Log "Connecting to destination vCenter: $DestinationVCenter"
    $VIServer = Connect-VIServer -Server $DestinationVCenter -Credential $Credential -ErrorAction Stop
    
    # Ensure content library exists
    $Library = Ensure-ContentLibrary -LibraryName $DestinationContentLibrary
    Write-Log "Using content library: $($Library.Name) (ID: $($Library.Id))"
    
    # Get list of available templates from SMB share
    $AvailableTemplates = Get-ChildItem -Path $ExportsPath -Directory -ErrorAction SilentlyContinue
    Write-Log "Found $($AvailableTemplates.Count) templates in export share"
    
    # Load current state
    $State = Get-DestinationState
    $UpdatedState = @{}
    $ImportCount = 0
    
    foreach ($TemplateDir in $AvailableTemplates) {
        $TemplateName = $TemplateDir.Name
        $LatestVersion = Get-LatestExportVersion -TemplateName $TemplateName
        
        if (-not $LatestVersion) {
            Write-Log "No valid version found for $TemplateName - skipping"
            continue
        }
        
        $LastImportedVersion = $State[$TemplateName]
        $UpdatedState[$TemplateName] = $LatestVersion
        
        if ($Force -or ($LatestVersion -ne $LastImportedVersion)) {
            if ($LastImportedVersion) {
                Write-Log "New version available for $TemplateName : $LastImportedVersion -> $LatestVersion"
            } else {
                Write-Log "New template available: $TemplateName (Version: $LatestVersion)"
            }
            
            $Result = Import-TemplateToLibrary -TemplateName $TemplateName -Version $LatestVersion -Library $Library
            if ($Result) {
                $ImportCount++
            }
        } else {
            Write-Log "No change for $TemplateName (Version: $LatestVersion)"
        }
    }
    
    # Save updated state
    Save-DestinationState -State $UpdatedState
    
    Write-Log "========== Import Complete: $ImportCount items imported =========="
}
catch {
    Write-Log "Script failed: $_" "ERROR"
    Write-Log $_.ScriptStackTrace "ERROR"
    exit 1
}
finally {
    if ($VIServer) {
        Disconnect-VIServer -Server $VIServer -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log "Disconnected from vCenter"
    }
    
    # Clean up old logs
    Get-ChildItem -Path $LogPath -Filter "DestImport_*.log" | 
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetentionDays) } |
        Remove-Item -Force
}
