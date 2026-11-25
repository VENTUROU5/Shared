# ============================================================================
# Export-Templates.ps1
# ============================================================================
# Monitors a vCenter Content Library for version changes and exports OVF
# packages to an SMB share for distribution to disconnected vCenters.
#
# USAGE:
#   .\Export-Templates.ps1                    # Check for changes, export new versions
#   .\Export-Templates.ps1 -Force             # Re-export all templates
#   .\Export-Templates.ps1 -ConfigPath C:\... # Use alternate config file
#
# SCHEDULE:
#   Run via Task Scheduler every 15-60 minutes to detect Content Library updates.
#
# WHAT IT DOES:
#   1. Connects to source vCenter
#   2. Enumerates OVF items in the Content Library
#   3. Compares ContentVersion against last known state
#   4. Exports changed/new items to SMB share
#   5. Creates manifest.json with metadata for Import-Templates.ps1
#
# REQUIRES:
#   - VMware.PowerCLI module (Install-Module VMware.PowerCLI -Scope CurrentUser)
#   - Network access to source vCenter
#   - Write access to SMB share ($ExportsPath)
#   - Valid credentials in $CredentialFile
# ============================================================================

<#
.SYNOPSIS
    Exports templates from Content Library when version changes.

.DESCRIPTION
    Monitors the source Content Library for version changes.
    Exports OVF packages to SMB share for distribution to disconnected vCenters.
    Run on a schedule (e.g., every 15 minutes) via Task Scheduler.

.PARAMETER ConfigPath
    Path to Config.ps1. Default: same directory as script.

.PARAMETER Force
    Force re-export all templates regardless of version.

.EXAMPLE
    .\Export-Templates.ps1
    Checks for Content Library changes and exports new versions.

.EXAMPLE
    .\Export-Templates.ps1 -Force
    Re-exports all templates regardless of current state.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\Config.ps1",
    [switch]$Force
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
# LOGGING SETUP
# ----------------------------------------------------------------------------
# Daily log file rotation - each day gets a new file
$LogFile = Join-Path $LogPath "Export_$(Get-Date -Format yyyyMMdd).log"
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
    $Entry = "$(Get-Date -Format yyyy-MM-dd HH:mm:ss) [$Level] $Message"
    Add-Content -Path $LogFile -Value $Entry
    if ($Level -eq "ERROR") { Write-Error $Message } else { Write-Host $Entry }
}

# ----------------------------------------------------------------------------
# STATE MANAGEMENT
# ----------------------------------------------------------------------------
# State file tracks which version of each template was last exported.
# Format: { "TemplateName": "ContentVersion", ... }

function Get-ExportState {
    <#
    .SYNOPSIS
        Loads the last known export state from JSON file.
    .OUTPUTS
        Hashtable of template name -> last exported version
    #>
    $StateFile = Join-Path $StatePath "export-state.json"
    if (Test-Path $StateFile) {
        return Get-Content $StateFile -Raw | ConvertFrom-Json -AsHashtable
    }
    return @{}
}

function Save-ExportState {
    <#
    .SYNOPSIS
        Persists the current export state to JSON file.
    .PARAMETER State
        Hashtable of template name -> current version
    #>
    param([hashtable]$State)
    New-Item -ItemType Directory -Path $StatePath -Force -ErrorAction SilentlyContinue | Out-Null
    $State | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $StatePath "export-state.json")
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================
try {
    Write-Log "===== Starting Export Check ====="
    
    # Ensure all required directories exist on SMB share
    foreach ($Path in @($ExportsPath, $StatePath, $UuidsPath)) {
        New-Item -ItemType Directory -Path $Path -Force -ErrorAction SilentlyContinue | Out-Null
    }
    
    # ------------------------------------------------------------------------
    # VCENTER CONNECTION
    # ------------------------------------------------------------------------
    if (-not (Test-Path $CredentialFile)) {
        Write-Log "Credential file not found: $CredentialFile" "ERROR"
        Write-Log "Create with: Get-Credential | Export-Clixml -Path " "ERROR"
        exit 1
    }
    
    # Load encrypted credentials (must be created by same user running this script)
    $Cred = Import-Clixml $CredentialFile
    Write-Log "Connecting to $SourceVCenter..."
    Connect-VIServer -Server $SourceVCenter -Credential $Cred -ErrorAction Stop | Out-Null
    
    # ------------------------------------------------------------------------
    # CONTENT LIBRARY ENUMERATION
    # ------------------------------------------------------------------------
    # Get the Content Library and filter to OVF items only
    $Library = Get-ContentLibrary -Name $SourceContentLibrary -ErrorAction Stop
    Write-Log "Found library: $($Library.Name)"
    
    # Only process OVF items (not ISO, VMTX, etc.)
    $Items = Get-ContentLibraryItem -ContentLibrary $Library | Where-Object { $_.ItemType -eq "ovf" }
    Write-Log "Found $($Items.Count) OVF items"
    
    # Load previous state and prepare new state
    $State = Get-ExportState
    $NewState = @{}
    $ExportCount = 0
    
    # ------------------------------------------------------------------------
    # PROCESS EACH TEMPLATE
    # ------------------------------------------------------------------------
    foreach ($Item in $Items) {
        # ContentVersion is incremented each time the item is updated in Content Library
        $Version = [string]$Item.ContentVersion
        $LastVersion = $State[$Item.Name]
        $NewState[$Item.Name] = $Version
        
        # Check if export is needed (version changed or -Force flag)
        if ($Force -or ($Version -ne $LastVersion)) {
            $Action = if ($LastVersion) { "Updated ($LastVersion -> $Version)" } else { "New" }
            Write-Log "$($Item.Name): $Action - exporting..."
            
            # Create version-specific export directory: exports\<TemplateName>\<Version>\
            $ExportDir = Join-Path $ExportsPath $Item.Name $Version
            
            # Skip if already exported (idempotent)
            if (Test-Path $ExportDir) {
                Write-Log "  Export already exists, skipping"
                continue
            }
            
            New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null
            
            try {
                # Export OVF from Content Library to SMB share
                # This creates .ovf descriptor and .vmdk disk files
                Export-ContentLibraryItem -ContentLibraryItem $Item -Destination $ExportDir -ErrorAction Stop | Out-Null
                
                # Create manifest.json with metadata for Import-Templates.ps1
                # This file is used to identify the export and track versions
                @{
                    Name = $Item.Name
                    Version = $Version
                    ExportedAt = (Get-Date).ToString("o")  # ISO 8601 format
                    SourceVCenter = $SourceVCenter
                    SourceLibrary = $SourceContentLibrary
                    ItemId = $Item.Id
                } | ConvertTo-Json | Set-Content (Join-Path $ExportDir "manifest.json")
                
                Write-Log "  Exported to $ExportDir"
                $ExportCount++
            }
            catch {
                Write-Log "  Export failed: $_" "ERROR"
                # Cleanup partial export on failure
                Remove-Item -Path $ExportDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            # No change detected - skip this template
            Write-Log "$($Item.Name): No change (v$Version)"
        }
    }
    
    # Save updated state for next run
    Save-ExportState -State $NewState
    Write-Log "===== Export Complete: $ExportCount exported ====="
}
catch {
    Write-Log "Script failed: $_" "ERROR"
    exit 1
}
finally {
    # Always disconnect from vCenter (suppress errors if not connected)
    Disconnect-VIServer * -Confirm:$false -ErrorAction SilentlyContinue
}
