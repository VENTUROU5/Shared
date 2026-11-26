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

# Script-level constants for logging
$ScriptName = "Import-Templates"

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

function Write-LogMessage {
    <#
    .SYNOPSIS
        Writes timestamped log entry to file and console.
    .PARAMETER LogLevel
        Log severity: DEBUG, INFO, WARN, ERROR. Default: INFO
    .PARAMETER LogFilePath
        Path to the log file.
    .PARAMETER LogMessage
        The message to log.
    #>
    param(
        [ValidateSet("DEBUG", "INFO", "WARN", "ERROR")]
        [string]$LogLevel = "INFO",
        [Parameter(Mandatory)]
        [string]$LogFilePath,
        [Parameter(Mandatory)]
        [string]$LogMessage
    )
    
    $Entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$LogLevel] $LogMessage"
    Add-Content -Path $LogFilePath -Value $Entry
    
    switch ($LogLevel) {
        "ERROR" { Write-Error $LogMessage }
        "WARN"  { Write-Warning $LogMessage }
        "DEBUG" { Write-Verbose $LogMessage }
        default { Write-Host $Entry }
    }
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
    
    $FunctionName = "Get-ImportState"
    
    $StateFile = Join-Path $StatePath "import-state-$VCenterName.json"
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: Looking for state file: $StateFile"
    
    if (Test-Path $StateFile) {
        Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: State file found, loading..."
        $state = Get-Content $StateFile -Raw | ConvertFrom-Json -AsHashtable
        Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: Loaded $($state.Count) template states for $VCenterName"
        return $state
    }
    
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: No state file found for $VCenterName, returning empty hashtable"
    return @{}
}

function Save-ImportState {
    <#
    .SYNOPSIS
        Persists import state for a specific vCenter.
    #>
    param([string]$VCenterName, [hashtable]$State)
    
    $FunctionName = "Save-ImportState"
    
    $StateFile = Join-Path $StatePath "import-state-$VCenterName.json"
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: Saving $($State.Count) template states to $StateFile"
    $State | ConvertTo-Json -Depth 10 | Set-Content $StateFile
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: State file saved successfully"
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
    
    $FunctionName = "Get-UuidMapping"
    
    $UuidFile = Join-Path $UuidsPath "uuids-$VCenterName.json"
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: Looking for UUID file: $UuidFile"
    
    if (Test-Path $UuidFile) {
        Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: UUID file found, loading..."
        $mapping = Get-Content $UuidFile -Raw | ConvertFrom-Json -AsHashtable
        Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: Loaded $($mapping.Count) UUID mappings for $VCenterName"
        return $mapping
    }
    
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: No UUID file found for $VCenterName, returning empty hashtable"
    return @{}
}

function Save-UuidMapping {
    <#
    .SYNOPSIS
        Persists UUID mapping for a specific vCenter.
    #>
    param([string]$VCenterName, [hashtable]$Mapping)
    
    $FunctionName = "Save-UuidMapping"
    
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: Ensuring UUID directory exists: $UuidsPath"
    New-Item -ItemType Directory -Path $UuidsPath -Force -ErrorAction SilentlyContinue | Out-Null
    
    $UuidFile = Join-Path $UuidsPath "uuids-$VCenterName.json"
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: Saving $($Mapping.Count) UUID mappings to $UuidFile"
    $Mapping | ConvertTo-Json -Depth 10 | Set-Content $UuidFile
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: UUID file saved successfully"
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
    
    $FunctionName = "Set-VMInstanceUuid"
    
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: Getting VM view for ID: $VMId"
    # Get the VM View object for direct API access
    $vm = Get-View -Id $VMId
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: VM view obtained: $($vm.Name)"
    
    # Create a config spec with only the InstanceUuid property
    $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $spec.InstanceUuid = $InstanceUuid
    
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: Calling ReconfigVM with new InstanceUuid..."
    # Apply the reconfiguration
    $vm.ReconfigVM($spec)
    Write-LogMessage -LogFilePath $LogFile -LogMessage "${FunctionName}: Set Instance UUID to $InstanceUuid"
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
    $FunctionName = "Get-AvailableExports"
    $Exports = @{}
    
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: Checking exports path: $ExportsPath"
    
    if (-not (Test-Path $ExportsPath)) {
        Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: Exports path does not exist, returning empty hashtable"
        return $Exports
    }
    
    # Enumerate template directories: exports\<TemplateName>\
    $templateDirs = Get-ChildItem -Path $ExportsPath -Directory
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: Found $($templateDirs.Count) template directories"
    
    $templateDirs | ForEach-Object {
        $TemplateName = $_.Name
        Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: Processing template directory: $TemplateName"
        
        # Find the highest version number (versions are numeric)
        $Versions = Get-ChildItem -Path $_.FullName -Directory | 
            Sort-Object { [int]$_.Name } -Descending |
            Select-Object -First 1
        
        if ($Versions) {
            Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: Latest version for $TemplateName is $($Versions.Name)"
            
            # Read the manifest to get metadata
            $ManifestPath = Join-Path $Versions.FullName "manifest.json"
            if (Test-Path $ManifestPath) {
                Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: Found manifest at $ManifestPath"
                $Manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
                $Exports[$TemplateName] = @{
                    Path = $Versions.FullName      # Full path to OVF files
                    Version = $Manifest.Version    # Content Library version
                    Manifest = $Manifest           # Full manifest object
                }
            } else {
                Write-LogMessage -LogLevel "WARN" -LogFilePath $LogFile -LogMessage "${FunctionName}: No manifest.json found in $($Versions.FullName)"
            }
        } else {
            Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: No version directories found for $TemplateName"
        }
    }
    
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: Discovered $($Exports.Count) available exports"
    return $Exports
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================
try {
    Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}: ===== Starting Import Sync ====="
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Force mode: $Force"
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Target vCenter filter: $(if ($TargetVCenter) { $TargetVCenter } else { 'None (all)' })"
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Config loaded from: $ConfigPath"
    
    # ------------------------------------------------------------------------
    # LOAD CREDENTIALS
    # ------------------------------------------------------------------------
    if (-not (Test-Path $CredentialFile)) {
        Write-LogMessage -LogLevel "ERROR" -LogFilePath $LogFile -LogMessage "${ScriptName}: Credential file not found: $CredentialFile"
        exit 1
    }
    
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Loading credentials from $CredentialFile"
    $Cred = Import-Clixml $CredentialFile
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Credentials loaded for user: $($Cred.UserName)"
    
    # ------------------------------------------------------------------------
    # DISCOVER AVAILABLE EXPORTS
    # ------------------------------------------------------------------------
    $AvailableExports = Get-AvailableExports
    
    if ($AvailableExports.Count -eq 0) {
        Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}: No exports found in $ExportsPath"
        exit 0
    }
    
    Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}: Found $($AvailableExports.Count) templates available for sync"
    
    # ------------------------------------------------------------------------
    # FILTER DESTINATIONS
    # ------------------------------------------------------------------------
    # Optionally filter to a single vCenter if -TargetVCenter specified
    $Destinations = $DestinationVCenters
    if ($TargetVCenter) {
        Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Filtering to target vCenter: $TargetVCenter"
        $Destinations = $Destinations | Where-Object { $_.Name -eq $TargetVCenter }
        if (-not $Destinations) {
            Write-LogMessage -LogLevel "ERROR" -LogFilePath $LogFile -LogMessage "${ScriptName}: Target vCenter '$TargetVCenter' not found in config"
            exit 1
        }
    }
    
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Processing $($Destinations.Count) destination vCenter(s)"
    
    # ------------------------------------------------------------------------
    # PROCESS EACH DESTINATION VCENTER
    # ------------------------------------------------------------------------
    foreach ($Dest in $Destinations) {
        Write-LogMessage -LogFilePath $LogFile -LogMessage ""
        Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}: --- Processing $($Dest.Name) ($($Dest.Server)) ---"
        
        try {
            # Connect to destination vCenter
            Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Connecting to $($Dest.Server)..."
            Connect-VIServer -Server $Dest.Server -Credential $Cred -ErrorAction Stop | Out-Null
            Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}: Connected"
            
            # ----------------------------------------------------------------
            # ENSURE DESTINATION FOLDER EXISTS
            # ----------------------------------------------------------------
            # Look for the target folder in VM and Templates view
            Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Looking for folder: $($Dest.Folder)"
            $Folder = Get-Folder -Name $Dest.Folder -Type VM -ErrorAction SilentlyContinue
            if (-not $Folder) {
                Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Folder not found, creating..."
                # Create folder under the datacenter root "vm" folder
                $VMFolder = Get-Folder -Type VM | Where-Object { $_.Name -eq "vm" } | Select-Object -First 1
                $Folder = New-Folder -Name $Dest.Folder -Location $VMFolder
                Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}: Created folder: $($Dest.Folder)"
            } else {
                Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Found existing folder: $($Folder.Name)"
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
                
                Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Processing template: $TemplateName"
                Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Available version: $($Export.Version), Last imported: $LastVersion"
                
                # Skip if version unchanged (unless -Force)
                if (-not $Force -and ($Export.Version -eq $LastVersion)) {
                    Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}:   $TemplateName : No change (v$($Export.Version))"
                    continue
                }
                
                Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}:   $TemplateName : Importing v$($Export.Version)..."
                
                # ------------------------------------------------------------
                # FIND EXISTING TEMPLATE AND PRESERVE UUID
                # ------------------------------------------------------------
                # Check for existing template - first in folder, then globally
                Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Searching for existing template in folder: $($Folder.Name)"
                $ExistingTemplate = Get-Template -Location $Folder -Name $TemplateName -ErrorAction SilentlyContinue
                if (-not $ExistingTemplate) {
                    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Not found in folder, searching globally..."
                    # Template might exist outside the target folder
                    $ExistingTemplate = Get-Template -Name $TemplateName -ErrorAction SilentlyContinue
                }
                $PreserveUuid = $null
                
                if ($ExistingTemplate) {
                    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Existing template found: $($ExistingTemplate.Name) in $($ExistingTemplate.Folder.Name)"
                    # Extract Instance UUID from existing template to preserve it
                    $View = Get-View -Id $ExistingTemplate.Id -Property Config
                    $PreserveUuid = $View.Config.InstanceUuid
                    $UuidMapping[$TemplateName] = $PreserveUuid
                    Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}:     Existing template found at $($ExistingTemplate.Folder.Name), will preserve UUID: $PreserveUuid"
                }
                elseif ($UuidMapping[$TemplateName]) {
                    # Template was deleted but we have stored UUID from previous run
                    # This handles disaster recovery scenarios
                    $PreserveUuid = $UuidMapping[$TemplateName]
                    Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}:     Using stored UUID: $PreserveUuid"
                    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Template not found but UUID mapping exists"
                } else {
                    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: No existing template or stored UUID - will create new"
                }
                
                # ------------------------------------------------------------
                # FIND OVF FILE
                # ------------------------------------------------------------
                # Export-ContentLibraryItem creates a subfolder, so search recursively
                Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Searching for OVF file in: $($Export.Path)"
                $OvfFile = Get-ChildItem -Path $Export.Path -Filter "*.ovf" -Recurse | Select-Object -First 1
                if (-not $OvfFile) {
                    Write-LogMessage -LogLevel "ERROR" -LogFilePath $LogFile -LogMessage "${ScriptName}:     No OVF file found in $($Export.Path)"
                    continue
                }
                Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Found OVF file: $($OvfFile.FullName)"
                
                # ------------------------------------------------------------
                # TAG-BASED RESOURCE SELECTION
                # ------------------------------------------------------------
                # Look for vSphere tag "AutomatedTemplate" on cluster, datastore, network
                # This allows flexible targeting without hardcoding resource names
                Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Looking for AutomatedTemplate tag..."
                $TargetTag = Get-Tag -Name "AutomatedTemplate" -ErrorAction SilentlyContinue
                if (-not $TargetTag) {
                    Write-LogMessage -LogLevel "WARN" -LogFilePath $LogFile -LogMessage "${ScriptName}:     Tag AutomatedTemplate not found - using defaults"
                    $Cluster = Get-Cluster | Select-Object -First 1
                    $Datastore = Get-Datastore | Sort-Object FreeSpaceGB -Descending | Select-Object -First 1
                    $Network = Get-VirtualPortGroup | Select-Object -First 1
                } else {
                    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: AutomatedTemplate tag found, searching for tagged resources..."
                    # Find resources with the AutomatedTemplate tag assigned
                    $Cluster = Get-Cluster | Where-Object { (Get-TagAssignment -Entity $_ -Tag $TargetTag -ErrorAction SilentlyContinue) } | Select-Object -First 1
                    $Datastore = Get-Datastore | Where-Object { (Get-TagAssignment -Entity $_ -Tag $TargetTag -ErrorAction SilentlyContinue) } | Select-Object -First 1
                    $Network = Get-VirtualPortGroup | Where-Object { (Get-TagAssignment -Entity $_ -Tag $TargetTag -ErrorAction SilentlyContinue) } | Select-Object -First 1
                    
                    # Fallback for each resource type if tag not found
                    if (-not $Cluster) {
                        Write-LogMessage -LogLevel "WARN" -LogFilePath $LogFile -LogMessage "${ScriptName}:     No cluster with AutomatedTemplate tag - using first available"
                        $Cluster = Get-Cluster | Select-Object -First 1
                    }
                    if (-not $Datastore) {
                        Write-LogMessage -LogLevel "WARN" -LogFilePath $LogFile -LogMessage "${ScriptName}:     No datastore with AutomatedTemplate tag - using largest"
                        $Datastore = Get-Datastore | Sort-Object FreeSpaceGB -Descending | Select-Object -First 1
                    }
                    if (-not $Network) {
                        Write-LogMessage -LogLevel "WARN" -LogFilePath $LogFile -LogMessage "${ScriptName}:     No network with AutomatedTemplate tag - using first available"
                        $Network = Get-VirtualPortGroup | Select-Object -First 1
                    }
                }
                
                Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Selected Cluster: $($Cluster.Name)"
                Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Selected Datastore: $($Datastore.Name) (Free: $([math]::Round($Datastore.FreeSpaceGB, 2)) GB)"
                Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Selected Network: $($Network.Name)"
                
                # Get a connected host from the cluster for OVF deployment
                # Import-VApp requires a specific host, not just a cluster
                Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Getting connected host from cluster $($Cluster.Name)..."
                $VMHost = Get-VMHost -Location $Cluster | Where-Object { $_.ConnectionState -eq "Connected" } | Select-Object -First 1
                if (-not $VMHost) {
                    Write-LogMessage -LogLevel "ERROR" -LogFilePath $LogFile -LogMessage "${ScriptName}:     No connected host in cluster $($Cluster.Name)"
                    continue
                }
                Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Selected host: $($VMHost.Name)"
                
                Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}:     Targets: Cluster=$($Cluster.Name), Host=$($VMHost.Name), Datastore=$($Datastore.Name), Network=$($Network.Name)"
                
                # ------------------------------------------------------------
                # DEPLOY OVF WITH TEMPORARY NAME
                # ------------------------------------------------------------
                # Use temporary name during deployment to avoid conflicts
                $TempName = "$TemplateName-new-$(Get-Date -Format 'yyyyMMddHHmmss')"
                Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Temporary VM name: $TempName"
                
                try {
                    Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}:     Deploying OVF..."
                    
                    # Get OVF configuration (network mappings, properties, etc.)
                    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Getting OVF configuration..."
                    $OvfConfig = Get-OvfConfiguration -Ovf $OvfFile.FullName
                    
                    # Map all OVF networks to the tagged network
                    if ($OvfConfig.NetworkMapping) {
                        Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Configuring network mappings..."
                        $OvfConfig.NetworkMapping.PSObject.Properties.Name | ForEach-Object {
                            Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Mapping OVF network '$_' to '$($Network.Name)'"
                            $OvfConfig.NetworkMapping.$_.Value = $Network
                        }
                    } else {
                        Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: No network mappings in OVF configuration"
                    }
                    
                    # Deploy OVF to the host (this takes several minutes for large templates)
                    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Starting Import-VApp..."
                    $deployStart = Get-Date
                    Import-VApp -Source $OvfFile.FullName -OvfConfiguration $OvfConfig `
                        -Name $TempName -VMHost $VMHost -Datastore $Datastore `
                        -DiskStorageFormat Thin -ErrorAction Stop | Out-Null
                    $deployDuration = (Get-Date) - $deployStart
                    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Import-VApp completed in $($deployDuration.TotalSeconds) seconds"
                    
                    # Get the newly deployed VM
                    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Getting newly deployed VM..."
                    $NewVM = Get-VM -Name $TempName
                    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: VM deployed: $($NewVM.Name), ID: $($NewVM.Id)"
                    
                    # --------------------------------------------------------
                    # SET OR RECORD INSTANCE UUID
                    # --------------------------------------------------------
                    if ($PreserveUuid) {
                        # Restore the original UUID for lineage preservation
                        Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Restoring preserved UUID..."
                        Set-VMInstanceUuid -VMId $NewVM.Id -InstanceUuid $PreserveUuid
                    }
                    else {
                        # First time for this template - record the new UUID
                        Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Recording new UUID for future use..."
                        $NewView = Get-View -Id $NewVM.Id -Property Config
                        $UuidMapping[$TemplateName] = $NewView.Config.InstanceUuid
                        Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}:     New UUID assigned: $($NewView.Config.InstanceUuid)"
                    }
                    
                    # --------------------------------------------------------
                    # CONVERT TO TEMPLATE
                    # --------------------------------------------------------
                    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Converting VM to template..."
                    Set-VM -VM $NewVM -ToTemplate -Confirm:$false | Out-Null
                    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: VM converted to template"
                    
                    # --------------------------------------------------------
                    # REMOVE OLD TEMPLATE
                    # --------------------------------------------------------
                    if ($ExistingTemplate) {
                        Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Removing old template: $($ExistingTemplate.Name)..."
                        Remove-Template -Template $ExistingTemplate -DeletePermanently -Confirm:$false
                        Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}:     Removed old template"
                    }
                    
                    # --------------------------------------------------------
                    # RENAME AND MOVE TO FINAL LOCATION
                    # --------------------------------------------------------
                    # Rename from temporary name to final name
                    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Renaming template from $TempName to $TemplateName..."
                    $NewTemplate = Get-Template -Name $TempName
                    Set-Template -Template $NewTemplate -Name $TemplateName -Confirm:$false | Out-Null
                    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Template renamed successfully"
                    
                    # Move to destination folder (if not already there)
                    $FinalTemplate = Get-Template -Name $TemplateName
                    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Template current folder: $($FinalTemplate.Folder.Name), Target folder: $($Folder.Name)"
                    if ($FinalTemplate.Folder.Name -ne $Folder.Name) {
                        Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Moving template to destination folder..."
                        # Silently ignore error if already in folder (can happen with naming conflicts)
                        try { Move-Template -Template $FinalTemplate -Destination $Folder -Confirm:$false -ErrorAction Stop | Out-Null } catch { }
                    } else {
                        Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Template already in correct folder, skipping move"
                    }
                    
                    Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}:     Successfully imported $TemplateName v$($Export.Version)"
                    $ImportCount++
                }
                catch {
                    Write-LogMessage -LogLevel "ERROR" -LogFilePath $LogFile -LogMessage "${ScriptName}:     Import failed: $_"
                    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Stack trace: $($_.ScriptStackTrace)"
                    # Cleanup failed deployment to avoid orphaned VMs
                    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Cleaning up failed deployment..."
                    Get-VM -Name $TempName -ErrorAction SilentlyContinue | Remove-VM -DeletePermanently -Confirm:$false -ErrorAction SilentlyContinue
                    Get-Template -Name $TempName -ErrorAction SilentlyContinue | Remove-Template -DeletePermanently -Confirm:$false -ErrorAction SilentlyContinue
                }
            }
            
            # Save state and UUID mappings for next run
            Save-ImportState -VCenterName $Dest.Name -State $NewState
            Save-UuidMapping -VCenterName $Dest.Name -Mapping $UuidMapping
            
            Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}: --- $($Dest.Name) complete: $ImportCount imported ---"
        }
        catch {
            Write-LogMessage -LogLevel "ERROR" -LogFilePath $LogFile -LogMessage "${ScriptName}: Failed to process $($Dest.Name): $_"
            Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Stack trace: $($_.ScriptStackTrace)"
        }
        finally {
            # Always disconnect from this vCenter
            Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Disconnecting from $($Dest.Server)..."
            Disconnect-VIServer -Server $Dest.Server -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    
    Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}: ===== Import Sync Complete ====="
}
catch {
    Write-LogMessage -LogLevel "ERROR" -LogFilePath $LogFile -LogMessage "${ScriptName}: Script failed: $_"
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Stack trace: $($_.ScriptStackTrace)"
    exit 1
}
