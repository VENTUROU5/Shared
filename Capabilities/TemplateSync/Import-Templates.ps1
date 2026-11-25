# ============================================================================
# Import-Templates.ps1
# ============================================================================
# Imports OVF templates from SMB share to destination vCenters while
# preserving Instance UUIDs for VM lineage tracking.
#
# USAGE:
#   .\Import-Templates.ps1                           # Sync all destinations
#   .\Import-Templates.ps1 -Force                    # Re-import all templates
#   .\Import-Templates.ps1 -TargetVCenter vcenter-dr # Sync specific vCenter
#
# SCHEDULE:
#   Run via Task Scheduler after Export-Templates.ps1 (e.g., 15-60 min offset)
#
# WHAT IT DOES:
#   1. Scans SMB share for available exports
#   2. For each destination vCenter:
#      a. Connects and finds/creates destination folder
#      b. For each template needing update:
#         - Records existing template Instance UUID (if any)
#         - Deploys new OVF with temporary name
#         - Restores original Instance UUID via ReconfigVM API
#         - Converts to template
#         - Removes old template
#         - Renames new template to final name
#         - Moves to destination folder
#
# UUID PRESERVATION:
#   Instance UUIDs are preserved across template updates so VMs deployed from
#   the template maintain their lineage tracking. The UUID is stored in:
#   - $UuidsPath\uuids-<vcenter>.json (persisted for disaster recovery)
#
# TAG-BASED RESOURCE SELECTION:
#   The script looks for a vSphere tag named "AutomatedTemplate" to select:
#   - Cluster: Where to find a connected host for deployment
#   - Datastore: Where to store template disks
#   - Network: Which port group to map OVF networks to
#   Falls back to first available / largest datastore if tags not configured.
#
# REQUIRES:
#   - VMware.PowerCLI module
#   - Network access to destination vCenters
#   - Read access to SMB share ($ExportsPath)
#   - vCenter permissions: VM deploy, template create/delete, folder create
# ============================================================================

<#
.SYNOPSIS
    Imports templates to destination vCenters, preserving Instance UUIDs.

.DESCRIPTION
    For each destination vCenter:
    1. Check SMB share for new template versions
    2. Record existing template's Instance UUID
    3. Deploy new OVF as template
    4. Restore the original Instance UUID
    5. Remove old template

.PARAMETER ConfigPath
    Path to Config.ps1.

.PARAMETER Force
    Force re-import all templates regardless of version.

.PARAMETER TargetVCenter
    Only sync to this specific vCenter (by Name from config).

.EXAMPLE
    .\Import-Templates.ps1
    Syncs all templates to all configured destination vCenters.

.EXAMPLE
    .\Import-Templates.ps1 -Force -TargetVCenter vcenter-prod
    Force re-imports all templates to vcenter-prod only.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\Config.ps1",
    [switch]$Force,
    [string]$TargetVCenter
)

# Load configuration (vCenter settings, paths, credentials)
. $ConfigPath

# ----------------------------------------------------------------------------
# MODULE IMPORT
# ----------------------------------------------------------------------------
# Import PowerCLI module explicitly (not using #Requires for WinRM/Task compatibility)
try {
    Import-Module VMware.VimAutomation.Core -ErrorAction Stop
    # Suppress certificate warnings and CEIP prompts
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -ParticipateInCeip:$false -ErrorAction SilentlyContinue | Out-Null
} catch {
    Write-Error "Failed to import VMware.PowerCLI: $_"
    Write-Error "Install with: Install-Module VMware.PowerCLI -Scope CurrentUser"
    exit 1
}

# ----------------------------------------------------------------------------
# LOGGING
# ----------------------------------------------------------------------------
$LogFile = Join-Path $LogPath "Import_$(Get-Date -Format 'yyyyMMdd').log"
New-Item -ItemType Directory -Path $LogPath -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log {
    <#
    .SYNOPSIS
        Writes timestamped log entry to file and console.
    #>
    param(
        [string]$Message,
        [string]$Level = "INFO"  # INFO, WARN, ERROR
    )
    $Entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Add-Content -Path $LogFile -Value $Entry
    if ($Level -eq "ERROR") { Write-Error $Message } else { Write-Host $Entry }
}

# ----------------------------------------------------------------------------
# STATE MANAGEMENT
# ----------------------------------------------------------------------------
# Each vCenter has its own state file tracking which versions are imported.
# Format: { "TemplateName": "Version", ... }

function Get-ImportState {
    <#
    .SYNOPSIS
        Loads import state for a specific vCenter.
    .PARAMETER VCenterName
        Short name of the vCenter (from config)
    #>
    param([string]$VCenterName)
    $StateFile = Join-Path $StatePath "import-state-$VCenterName.json"
    if (Test-Path $StateFile) {
        return Get-Content $StateFile -Raw | ConvertFrom-Json -AsHashtable
    }
    return @{}
}

function Save-ImportState {
    <#
    .SYNOPSIS
        Persists import state for a specific vCenter.
    #>
    param([string]$VCenterName, [hashtable]$State)
    $State | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $StatePath "import-state-$VCenterName.json")
}

# ----------------------------------------------------------------------------
# UUID MAPPING
# ----------------------------------------------------------------------------
# UUID mappings persist the Instance UUID for each template per vCenter.
# This allows UUID preservation even if the template is accidentally deleted.
# Format: { "TemplateName": "uuid-string", ... }

function Get-UuidMapping {
    <#
    .SYNOPSIS
        Loads UUID mapping for a specific vCenter.
    .DESCRIPTION
        UUID mappings track the Instance UUID assigned to each template.
        Used to preserve UUIDs across template updates for VM lineage tracking.
    #>
    param([string]$VCenterName)
    $UuidFile = Join-Path $UuidsPath "uuids-$VCenterName.json"
    if (Test-Path $UuidFile) {
        return Get-Content $UuidFile -Raw | ConvertFrom-Json -AsHashtable
    }
    return @{}
}

function Save-UuidMapping {
    <#
    .SYNOPSIS
        Persists UUID mapping for a specific vCenter.
    #>
    param([string]$VCenterName, [hashtable]$Mapping)
    New-Item -ItemType Directory -Path $UuidsPath -Force -ErrorAction SilentlyContinue | Out-Null
    $Mapping | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $UuidsPath "uuids-$VCenterName.json")
}

# ----------------------------------------------------------------------------
# UUID MODIFICATION
# ----------------------------------------------------------------------------
function Set-VMInstanceUuid {
    <#
    .SYNOPSIS
        Sets the Instance UUID of a VM using the vSphere API.
    .DESCRIPTION
        Uses ReconfigVM API to modify the InstanceUuid property.
        This is the key function that preserves template lineage.
        Instance UUID is different from BIOS UUID and is used by vCenter
        for tracking VM relationships and clones.
    .PARAMETER VMId
        Managed Object Reference ID of the VM (e.g., "VirtualMachine-vm-123")
    .PARAMETER InstanceUuid
        UUID string to assign (format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
    #>
    param(
        [string]$VMId,
        [string]$InstanceUuid
    )
    
    # Get the VM View object for direct API access
    $vm = Get-View -Id $VMId
    
    # Create a config spec with only the InstanceUuid property
    $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $spec.InstanceUuid = $InstanceUuid
    
    # Apply the reconfiguration
    $vm.ReconfigVM($spec)
    Write-Log "    Set Instance UUID to $InstanceUuid"
}

# ----------------------------------------------------------------------------
# EXPORT DISCOVERY
# ----------------------------------------------------------------------------
function Get-AvailableExports {
    <#
    .SYNOPSIS
        Discovers available template exports on the SMB share.
    .DESCRIPTION
        Scans $ExportsPath for template directories containing version
        subdirectories with manifest.json files. Returns the latest
        version of each template.
    .OUTPUTS
        Hashtable: { "TemplateName": { Path, Version, Manifest }, ... }
    #>
    $Exports = @{}
    
    if (-not (Test-Path $ExportsPath)) { return $Exports }
    
    # Enumerate template directories: exports\<TemplateName>\
    Get-ChildItem -Path $ExportsPath -Directory | ForEach-Object {
        $TemplateName = $_.Name
        
        # Find the highest version number (versions are numeric)
        $Versions = Get-ChildItem -Path $_.FullName -Directory | 
            Sort-Object { [int]$_.Name } -Descending |
            Select-Object -First 1
        
        if ($Versions) {
            # Read the manifest to get metadata
            $ManifestPath = Join-Path $Versions.FullName "manifest.json"
            if (Test-Path $ManifestPath) {
                $Manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
                $Exports[$TemplateName] = @{
                    Path = $Versions.FullName      # Full path to OVF files
                    Version = $Manifest.Version    # Content Library version
                    Manifest = $Manifest           # Full manifest object
                }
            }
        }
    }
    
    return $Exports
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================
try {
    Write-Log "===== Starting Import Sync ====="
    
    # ------------------------------------------------------------------------
    # LOAD CREDENTIALS
    # ------------------------------------------------------------------------
    if (-not (Test-Path $CredentialFile)) {
        Write-Log "Credential file not found: $CredentialFile" "ERROR"
        exit 1
    }
    
    $Cred = Import-Clixml $CredentialFile
    
    # ------------------------------------------------------------------------
    # DISCOVER AVAILABLE EXPORTS
    # ------------------------------------------------------------------------
    $AvailableExports = Get-AvailableExports
    
    if ($AvailableExports.Count -eq 0) {
        Write-Log "No exports found in $ExportsPath"
        exit 0
    }
    
    Write-Log "Found $($AvailableExports.Count) templates available for sync"
    
    # ------------------------------------------------------------------------
    # FILTER DESTINATIONS
    # ------------------------------------------------------------------------
    # Optionally filter to a single vCenter if -TargetVCenter specified
    $Destinations = $DestinationVCenters
    if ($TargetVCenter) {
        $Destinations = $Destinations | Where-Object { $_.Name -eq $TargetVCenter }
        if (-not $Destinations) {
            Write-Log "Target vCenter '$TargetVCenter' not found in config" "ERROR"
            exit 1
        }
    }
    
    # ------------------------------------------------------------------------
    # PROCESS EACH DESTINATION VCENTER
    # ------------------------------------------------------------------------
    foreach ($Dest in $Destinations) {
        Write-Log ""
        Write-Log "--- Processing $($Dest.Name) ($($Dest.Server)) ---"
        
        try {
            # Connect to destination vCenter
            Connect-VIServer -Server $Dest.Server -Credential $Cred -ErrorAction Stop | Out-Null
            Write-Log "Connected"
            
            # ----------------------------------------------------------------
            # ENSURE DESTINATION FOLDER EXISTS
            # ----------------------------------------------------------------
            # Look for the target folder in VM and Templates view
            $Folder = Get-Folder -Name $Dest.Folder -Type VM -ErrorAction SilentlyContinue
            if (-not $Folder) {
                # Create folder under the datacenter root "vm" folder
                $VMFolder = Get-Folder -Type VM | Where-Object { $_.Name -eq "vm" } | Select-Object -First 1
                $Folder = New-Folder -Name $Dest.Folder -Location $VMFolder
                Write-Log "Created folder: $($Dest.Folder)"
            }
            
            # Load state and UUID mappings for this vCenter
            $State = Get-ImportState -VCenterName $Dest.Name
            $UuidMapping = Get-UuidMapping -VCenterName $Dest.Name
            $NewState = @{}
            $ImportCount = 0
            
            # ----------------------------------------------------------------
            # PROCESS EACH TEMPLATE
            # ----------------------------------------------------------------
            foreach ($TemplateName in $AvailableExports.Keys) {
                $Export = $AvailableExports[$TemplateName]
                $LastVersion = $State[$TemplateName]
                $NewState[$TemplateName] = $Export.Version
                
                # Skip if version unchanged (unless -Force)
                if (-not $Force -and ($Export.Version -eq $LastVersion)) {
                    Write-Log "  $TemplateName : No change (v$($Export.Version))"
                    continue
                }
                
                Write-Log "  $TemplateName : Importing v$($Export.Version)..."
                
                # ------------------------------------------------------------
                # FIND EXISTING TEMPLATE AND PRESERVE UUID
                # ------------------------------------------------------------
                # Check for existing template - first in folder, then globally
                $ExistingTemplate = Get-Template -Location $Folder -Name $TemplateName -ErrorAction SilentlyContinue
                if (-not $ExistingTemplate) {
                    # Template might exist outside the target folder
                    $ExistingTemplate = Get-Template -Name $TemplateName -ErrorAction SilentlyContinue
                }
                $PreserveUuid = $null
                
                if ($ExistingTemplate) {
                    # Extract Instance UUID from existing template to preserve it
                    $View = Get-View -Id $ExistingTemplate.Id -Property Config
                    $PreserveUuid = $View.Config.InstanceUuid
                    $UuidMapping[$TemplateName] = $PreserveUuid
                    Write-Log "    Existing template found at $($ExistingTemplate.Folder.Name), will preserve UUID: $PreserveUuid"
                }
                elseif ($UuidMapping[$TemplateName]) {
                    # Template was deleted but we have stored UUID from previous run
                    # This handles disaster recovery scenarios
                    $PreserveUuid = $UuidMapping[$TemplateName]
                    Write-Log "    Using stored UUID: $PreserveUuid"
                }
                
                # ------------------------------------------------------------
                # FIND OVF FILE
                # ------------------------------------------------------------
                # Export-ContentLibraryItem creates a subfolder, so search recursively
                $OvfFile = Get-ChildItem -Path $Export.Path -Filter "*.ovf" -Recurse | Select-Object -First 1
                if (-not $OvfFile) {
                    Write-Log "    No OVF file found in $($Export.Path)" "ERROR"
                    continue
                }
                
                # ------------------------------------------------------------
                # TAG-BASED RESOURCE SELECTION
                # ------------------------------------------------------------
                # Look for vSphere tag "AutomatedTemplate" on cluster, datastore, network
                # This allows flexible targeting without hardcoding resource names
                $TargetTag = Get-Tag -Name "AutomatedTemplate" -ErrorAction SilentlyContinue
                if (-not $TargetTag) {
                    Write-Log "    Tag AutomatedTemplate not found - using defaults" "WARN"
                    $Cluster = Get-Cluster | Select-Object -First 1
                    $Datastore = Get-Datastore | Sort-Object FreeSpaceGB -Descending | Select-Object -First 1
                    $Network = Get-VirtualPortGroup | Select-Object -First 1
                } else {
                    # Find resources with the AutomatedTemplate tag assigned
                    $Cluster = Get-Cluster | Where-Object { (Get-TagAssignment -Entity $_ -Tag $TargetTag -ErrorAction SilentlyContinue) } | Select-Object -First 1
                    $Datastore = Get-Datastore | Where-Object { (Get-TagAssignment -Entity $_ -Tag $TargetTag -ErrorAction SilentlyContinue) } | Select-Object -First 1
                    $Network = Get-VirtualPortGroup | Where-Object { (Get-TagAssignment -Entity $_ -Tag $TargetTag -ErrorAction SilentlyContinue) } | Select-Object -First 1
                    
                    # Fallback for each resource type if tag not found
                    if (-not $Cluster) {
                        Write-Log "    No cluster with AutomatedTemplate tag - using first available" "WARN"
                        $Cluster = Get-Cluster | Select-Object -First 1
                    }
                    if (-not $Datastore) {
                        Write-Log "    No datastore with AutomatedTemplate tag - using largest" "WARN"
                        $Datastore = Get-Datastore | Sort-Object FreeSpaceGB -Descending | Select-Object -First 1
                    }
                    if (-not $Network) {
                        Write-Log "    No network with AutomatedTemplate tag - using first available" "WARN"
                        $Network = Get-VirtualPortGroup | Select-Object -First 1
                    }
                }
                
                # Get a connected host from the cluster for OVF deployment
                # Import-VApp requires a specific host, not just a cluster
                $VMHost = Get-VMHost -Location $Cluster | Where-Object { $_.ConnectionState -eq "Connected" } | Select-Object -First 1
                if (-not $VMHost) {
                    Write-Log "    No connected host in cluster $($Cluster.Name)" "ERROR"
                    continue
                }
                
                Write-Log "    Targets: Cluster=$($Cluster.Name), Host=$($VMHost.Name), Datastore=$($Datastore.Name), Network=$($Network.Name)"
                
                # ------------------------------------------------------------
                # DEPLOY OVF WITH TEMPORARY NAME
                # ------------------------------------------------------------
                # Use temporary name during deployment to avoid conflicts
                $TempName = "$TemplateName-new-$(Get-Date -Format 'yyyyMMddHHmmss')"
                
                try {
                    Write-Log "    Deploying OVF..."
                    
                    # Get OVF configuration (network mappings, properties, etc.)
                    $OvfConfig = Get-OvfConfiguration -Ovf $OvfFile.FullName
                    
                    # Map all OVF networks to the tagged network
                    if ($OvfConfig.NetworkMapping) {
                        $OvfConfig.NetworkMapping.PSObject.Properties.Name | ForEach-Object {
                            $OvfConfig.NetworkMapping.$_.Value = $Network
                        }
                    }
                    
                    # Deploy OVF to the host (this takes several minutes for large templates)
                    Import-VApp -Source $OvfFile.FullName -OvfConfiguration $OvfConfig `
                        -Name $TempName -VMHost $VMHost -Datastore $Datastore `
                        -DiskStorageFormat Thin -ErrorAction Stop | Out-Null
                    
                    # Get the newly deployed VM
                    $NewVM = Get-VM -Name $TempName
                    
                    # --------------------------------------------------------
                    # SET OR RECORD INSTANCE UUID
                    # --------------------------------------------------------
                    if ($PreserveUuid) {
                        # Restore the original UUID for lineage preservation
                        Set-VMInstanceUuid -VMId $NewVM.Id -InstanceUuid $PreserveUuid
                    }
                    else {
                        # First time for this template - record the new UUID
                        $NewView = Get-View -Id $NewVM.Id -Property Config
                        $UuidMapping[$TemplateName] = $NewView.Config.InstanceUuid
                        Write-Log "    New UUID assigned: $($NewView.Config.InstanceUuid)"
                    }
                    
                    # --------------------------------------------------------
                    # CONVERT TO TEMPLATE
                    # --------------------------------------------------------
                    Set-VM -VM $NewVM -ToTemplate -Confirm:$false | Out-Null
                    
                    # --------------------------------------------------------
                    # REMOVE OLD TEMPLATE
                    # --------------------------------------------------------
                    if ($ExistingTemplate) {
                        Remove-Template -Template $ExistingTemplate -DeletePermanently -Confirm:$false
                        Write-Log "    Removed old template"
                    }
                    
                    # --------------------------------------------------------
                    # RENAME AND MOVE TO FINAL LOCATION
                    # --------------------------------------------------------
                    # Rename from temporary name to final name
                    $NewTemplate = Get-Template -Name $TempName
                    Set-Template -Template $NewTemplate -Name $TemplateName -Confirm:$false | Out-Null
                    
                    # Move to destination folder (if not already there)
                    $FinalTemplate = Get-Template -Name $TemplateName
                    if ($FinalTemplate.Folder.Name -ne $Folder.Name) {
                        # Silently ignore error if already in folder (can happen with naming conflicts)
                        try { Move-Template -Template $FinalTemplate -Destination $Folder -Confirm:$false -ErrorAction Stop | Out-Null } catch { }
                    }
                    
                    Write-Log "    Successfully imported $TemplateName v$($Export.Version)"
                    $ImportCount++
                }
                catch {
                    Write-Log "    Import failed: $_" "ERROR"
                    # Cleanup failed deployment to avoid orphaned VMs
                    Get-VM -Name $TempName -ErrorAction SilentlyContinue | Remove-VM -DeletePermanently -Confirm:$false -ErrorAction SilentlyContinue
                    Get-Template -Name $TempName -ErrorAction SilentlyContinue | Remove-Template -DeletePermanently -Confirm:$false -ErrorAction SilentlyContinue
                }
            }
            
            # Save state and UUID mappings for next run
            Save-ImportState -VCenterName $Dest.Name -State $NewState
            Save-UuidMapping -VCenterName $Dest.Name -Mapping $UuidMapping
            
            Write-Log "--- $($Dest.Name) complete: $ImportCount imported ---"
        }
        catch {
            Write-Log "Failed to process $($Dest.Name): $_" "ERROR"
        }
        finally {
            # Always disconnect from this vCenter
            Disconnect-VIServer -Server $Dest.Server -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    
    Write-Log "===== Import Sync Complete ====="
}
catch {
    Write-Log "Script failed: $_" "ERROR"
    exit 1
}
