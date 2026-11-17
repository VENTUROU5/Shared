# VMware Template Distribution Configuration

# Source vCenter (only used by source script)
$SourceVCenter = "vcenter-source.domain.local"
$SourceContentLibrary = "AutomatedTemplates"

# Destination vCenter (only used by destination script)
$DestinationVCenter = "vcenter-dest.domain.local"
$DestinationContentLibrary = "AutomatedTemplates"
$DestinationVCenterName = "vcenter-dest"  # Used for UUID storage path

# SMB Share paths
$SmbShareRoot = "\\fileserver\vmware-templates"
$ExportsPath = Join-Path $SmbShareRoot "exports"
$UuidsPath = Join-Path $SmbShareRoot "uuids"
$StatePath = Join-Path $SmbShareRoot "state"

# Credentials - path to encrypted credential file
# Create with: Get-Credential | Export-Clixml -Path "C:\Scripts\vcenter-creds.xml"
$CredentialFile = "C:\Scripts\vcenter-creds.xml"

# Logging
$LogPath = "C:\Scripts\Logs"
$LogRetentionDays = 30

# Timing (source script only)
$CheckIntervalMinutes = 15
