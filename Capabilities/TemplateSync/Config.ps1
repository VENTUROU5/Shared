# ============================================================================
# TemplateSync Configuration
# ============================================================================
# This file defines the source and destination vCenters, paths for staging
# exports, and credentials for authentication.
#
# SETUP:
#   1. Copy this file to your scripts directory
#   2. Update all values for your environment
#   3. Create credentials file (see $CredentialFile section below)
#   4. Ensure SMB share is accessible from management hosts
#
# ARCHITECTURE:
#   Source vCenter (Content Library) --> SMB Share --> Destination vCenters
#   - Export-Templates.ps1 pulls from source, writes to SMB
#   - Import-Templates.ps1 reads from SMB, pushes to destinations
# ============================================================================

# ----------------------------------------------------------------------------
# SOURCE VCENTER
# ----------------------------------------------------------------------------
# The vCenter that hosts the master Content Library containing OVF templates.
# This is where Export-Templates.ps1 connects to monitor for changes.

$SourceVCenter = "vcenter.plenty.wtf"

# Name of the Content Library to monitor. Must contain OVF-type items.
# Templates are exported when their ContentVersion changes.
$SourceContentLibrary = "AutomatedTemplates"

# ----------------------------------------------------------------------------
# DESTINATION VCENTERS
# ----------------------------------------------------------------------------
# Array of vCenters to sync templates TO. Each destination is independent
# and maintains its own state (versions imported) and UUID mappings.
#
# Properties:
#   Server - FQDN or IP of the vCenter Server
#   Name   - Short identifier used for state/UUID file names (no spaces)
#   Folder - VM folder where templates will be stored (created if missing)

$DestinationVCenters = @(
    @{
        Server = "vcenter.plenty.wtf"      # Can be same as source for testing
        Name   = "vcenter-prod"             # Used in state file names
        Folder = "AutomatedTemplates"       # VM & Templates folder name
    }
    # Add more destinations for multi-site sync:
    # @{
    #     Server = "vcenter-dr.domain.local"
    #     Name   = "vcenter-dr"
    #     Folder = "AutomatedTemplates"
    # }
    # @{
    #     Server = "vcenter-dev.domain.local"
    #     Name   = "vcenter-dev"
    #     Folder = "AutomatedTemplates"
    # }
)

# ----------------------------------------------------------------------------
# STAGING PATHS (SMB SHARE)
# ----------------------------------------------------------------------------
# Central SMB share for staging exports. Must be accessible from:
#   - The host running Export-Templates.ps1 (write access)
#   - All hosts running Import-Templates.ps1 (read access)
#
# Structure created automatically:
#   $SmbShareRoot\
#     exports\           - OVF files exported from Content Library
#       <TemplateName>\
#         <Version>\     - e.g., exports\Rocky\2\
#           *.ovf, *.vmdk, manifest.json
#     state\             - Version tracking files
#       export-state.json
#       import-state-<vcenter>.json
#     uuids\             - Instance UUID preservation files
#       uuids-<vcenter>.json

$SmbShareRoot = "\\fileserver\vmware-templates"
$ExportsPath = Join-Path $SmbShareRoot "exports"
$StatePath = Join-Path $SmbShareRoot "state"
$UuidsPath = Join-Path $SmbShareRoot "uuids"

# ----------------------------------------------------------------------------
# CREDENTIALS
# ----------------------------------------------------------------------------
# Path to encrypted credential file for vCenter authentication.
# The same credentials are used for source and all destination vCenters.
#
# CREATE THE CREDENTIAL FILE (run interactively as the service account):
#   Get-Credential | Export-Clixml -Path "C:\Scripts\TemplateSync\vcenter-creds.xml"
#
# SECURITY NOTES:
#   - File is encrypted using Windows DPAPI (tied to user account)
#   - Must be created by the same user that runs the scheduled task
#   - If using gMSA or different accounts, create file for each

$CredentialFile = "C:\Scripts\TemplateSync\vcenter-creds.xml"

# ----------------------------------------------------------------------------
# DEPLOYMENT SETTINGS (OPTIONAL)
# ----------------------------------------------------------------------------
# Default resource pool and datastore if tag-based selection fails.
# Set to $null to use automatic selection (first available).
# Import-Templates.ps1 prefers resources tagged with "AutomatedTemplate".

$DefaultResourcePool = $null    # e.g., "Production-RP"
$DefaultDatastore = $null       # e.g., "vsanDatastore"

# ----------------------------------------------------------------------------
# LOGGING
# ----------------------------------------------------------------------------
# Log files are created daily with format: Export_yyyyMMdd.log, Import_yyyyMMdd.log
# Recommend setting up log rotation or cleanup via scheduled task.

$LogPath = "C:\Scripts\TemplateSync\Logs"
$LogRetentionDays = 30          # For manual cleanup reference (not auto-cleaned)
