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
#   5. Creates manifest via New-Manifest function
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

# Script-level constants for logging
$ScriptName = "Export-Templates"

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
    
    $Entry = "$(Get-Date -Format yyyy-MM-dd HH:mm:ss) [$LogLevel] $LogMessage"
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
# State file tracks which version of each template was last exported.
# Format: { "TemplateName": "ContentVersion", ... }

function Get-ExportState {
    <#
    .SYNOPSIS
        Loads the last known export state from JSON file.
    .OUTPUTS
        Hashtable of template name -> last exported version
    #>
    $FunctionName = "Get-ExportState"
    
    $StateFile = Join-Path $StatePath "export-state.json"
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: Looking for state file at $StateFile"
    
    if (Test-Path $StateFile) {
        Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: State file found, loading..."
        $state = Get-Content $StateFile -Raw | ConvertFrom-Json -AsHashtable
        Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: Loaded $($state.Count) template states"
        return $state
    }
    
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: No state file found, returning empty hashtable"
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
    
    $FunctionName = "Save-ExportState"
    
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: Ensuring state directory exists at $StatePath"
    New-Item -ItemType Directory -Path $StatePath -Force -ErrorAction SilentlyContinue | Out-Null
    
    $StateFile = Join-Path $StatePath "export-state.json"
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: Saving $($State.Count) template states to $StateFile"
    $State | ConvertTo-Json -Depth 10 | Set-Content $StateFile
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${FunctionName}: State file saved successfully"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================
try {
    Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}: ===== Starting Export Check ====="
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Force mode: $Force"
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Config loaded from: $ConfigPath"
    
    # Ensure all required directories exist on SMB share
    foreach ($Path in @($ExportsPath, $StatePath, $UuidsPath)) {
        Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Ensuring directory exists: $Path"
        New-Item -ItemType Directory -Path $Path -Force -ErrorAction SilentlyContinue | Out-Null
    }
    
    # ------------------------------------------------------------------------
    # VCENTER CONNECTION
    # ------------------------------------------------------------------------
    if (-not (Test-Path $CredentialFile)) {
        Write-LogMessage -LogLevel "ERROR" -LogFilePath $LogFile -LogMessage "${ScriptName}: Credential file not found: $CredentialFile"
        Write-LogMessage -LogLevel "ERROR" -LogFilePath $LogFile -LogMessage "${ScriptName}: Create with: Get-Credential | Export-Clixml -Path "
        exit 1
    }
    
    # Load encrypted credentials (must be created by same user running this script)
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Loading credentials from $CredentialFile"
    $Cred = Import-Clixml $CredentialFile
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Credentials loaded for user: $($Cred.UserName)"
    
    Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}: Connecting to $SourceVCenter..."
    Connect-VIServer -Server $SourceVCenter -Credential $Cred -ErrorAction Stop | Out-Null
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Successfully connected to $SourceVCenter"
    
    # ------------------------------------------------------------------------
    # CONTENT LIBRARY ENUMERATION
    # ------------------------------------------------------------------------
    # Get the Content Library and filter to OVF items only
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Looking for Content Library: $SourceContentLibrary"
    $Library = Get-ContentLibrary -Name $SourceContentLibrary -ErrorAction Stop
    Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}: Found library: $($Library.Name)"
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Library ID: $($Library.Id)"
    
    # Only process OVF items (not ISO, VMTX, etc.)
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Enumerating library items..."
    $AllItems = Get-ContentLibraryItem -ContentLibrary $Library
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Total items in library: $($AllItems.Count)"
    
    $Items = $AllItems | Where-Object { $_.ItemType -eq "ovf" }
    Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}: Found $($Items.Count) OVF items"
    
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
        
        Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Processing item: $($Item.Name)"
        Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Current version: $Version, Last exported version: $LastVersion"
        
        # Check if export is needed (version changed or -Force flag)
        if ($Force -or ($Version -ne $LastVersion)) {
            $Action = if ($LastVersion) { "Updated ($LastVersion -> $Version)" } else { "New" }
            Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}: $($Item.Name): $Action - exporting..."
            
            # Create version-specific export directory: exports\<TemplateName>\<Version>\
            $TemplateDir = Join-Path $ExportsPath $Item.Name
            $ExportDir = Join-Path $TemplateDir $Version
            
            Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Template directory: $TemplateDir"
            Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Export directory: $ExportDir"
            
            # Skip if already exported (idempotent)
            if (Test-Path $ExportDir) {
                Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}: Export already exists, skipping"
                continue
            }
            
            New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null
            Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Created export directory"
            
            try {
                # Export OVF from Content Library to SMB share
                # This creates .ovf descriptor and .vmdk disk files
                Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Starting Export-ContentLibraryItem..."
                $exportStart = Get-Date
                Export-ContentLibraryItem -ContentLibraryItem $Item -Destination $ExportDir -ErrorAction Stop | Out-Null
                $exportDuration = (Get-Date) - $exportStart
                Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Export completed in $($exportDuration.TotalSeconds) seconds"
                
                Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}: Exported to $ExportDir"
                
                # Call New-Manifest to create manifest and zip
                Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Calling New-Manifest for $($Item.Name)..."
                New-Manifest -FilePath $TemplateDir -LogPath $LogFile
                Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: New-Manifest completed"
                
                $ExportCount++
            }
            catch {
                Write-LogMessage -LogLevel "ERROR" -LogFilePath $LogFile -LogMessage "${ScriptName}: Export failed for $($Item.Name): $_"
                Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Cleaning up failed export directory: $ExportDir"
                # Cleanup partial export on failure
                Remove-Item -Path $ExportDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            # No change detected - skip this template
            Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}: $($Item.Name): No change (v$Version)"
        }
    }
    
    # Save updated state for next run
    Save-ExportState -State $NewState
    Write-LogMessage -LogFilePath $LogFile -LogMessage "${ScriptName}: ===== Export Complete: $ExportCount exported ====="
}
catch {
    Write-LogMessage -LogLevel "ERROR" -LogFilePath $LogFile -LogMessage "${ScriptName}: Script failed: $_"
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Stack trace: $($_.ScriptStackTrace)"
    exit 1
}
finally {
    # Always disconnect from vCenter (suppress errors if not connected)
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Disconnecting from vCenter..."
    Disconnect-VIServer * -Confirm:$false -ErrorAction SilentlyContinue
    Write-LogMessage -LogLevel "DEBUG" -LogFilePath $LogFile -LogMessage "${ScriptName}: Cleanup complete"
}
