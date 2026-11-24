# TemplateSync Configuration
# Copy this file and update values for your environment

# Source vCenter (where Content Library lives)
$SourceVCenter = "vcenter.plenty.wtf"
$SourceContentLibrary = "AutomatedTemplates"

# Destination vCenters (array - sync to all of these)
$DestinationVCenters = @(
    @{
        Server = "vcenter.plenty.wtf"      # Can be same as source for testing
        Name   = "vcenter-prod"             # Short name for UUID storage
        Folder = "AutomatedTemplates"       # VM folder to store templates
    }
    # Add more destinations:
    # @{
    #     Server = "vcenter2.domain.local"
    #     Name   = "vcenter-dr"
    #     Folder = "AutomatedTemplates"
    # }
)

# SMB Share for staging exports (accessible from all management hosts)
$SmbShareRoot = "\\fileserver\vmware-templates"
$ExportsPath = Join-Path $SmbShareRoot "exports"
$StatePath = Join-Path $SmbShareRoot "state"
$UuidsPath = Join-Path $SmbShareRoot "uuids"    # Stores instance UUIDs per vCenter

# Credentials - path to encrypted credential file
# Create with: Get-Credential | Export-Clixml -Path "C:\Scripts\TemplateSync\vcenter-creds.xml"
$CredentialFile = "C:\Scripts\TemplateSync\vcenter-creds.xml"

# Deployment settings
$DefaultResourcePool = $null    # Use default if not specified
$DefaultDatastore = $null       # Use default if not specified

# Logging
$LogPath = "C:\Scripts\TemplateSync\Logs"
$LogRetentionDays = 30
