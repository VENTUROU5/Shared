#Requires -Modules VMware.PowerCLI
<#
.SYNOPSIS
    Monitors source content library and exports OVF templates on version change.
    
.DESCRIPTION
    This script runs on the management host with access to the source vCenter.
    It checks the content library every 15 minutes (configurable) and exports
    any templates that have a newer version than the last export.
    
.NOTES
    Schedule as a Windows Scheduled Task running every 15 minutes.
    Ensure the service account has:
    - Content Library read access
    - Export OVF privileges
    - Write access to SMB share
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\Config.ps1",
    [switch]$Force  # Force re-export of all templates regardless of version
)

# Load configuration
. $ConfigPath

# Initialize logging
$LogFile = Join-Path $LogPath "SourceExport_$(Get-Date -Format 'yyyyMMdd').log"
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

function Get-SourceState {
    $StateFile = Join-Path $StatePath "source-state.json"
    if (Test-Path $StateFile) {
        return Get-Content $StateFile -Raw | ConvertFrom-Json -AsHashtable
    }
    return @{}
}

function Save-SourceState {
    param([hashtable]$State)
    $StateFile = Join-Path $StatePath "source-state.json"
    if (-not (Test-Path $StatePath)) {
        New-Item -ItemType Directory -Path $StatePath -Force | Out-Null
    }
    $State | ConvertTo-Json -Depth 10 | Set-Content $StateFile
}

function Export-ContentLibraryItem {
    param(
        [VMware.VimAutomation.ViCore.Types.V1.ContentLibrary.ContentLibraryItem]$Item,
        [string]$Version,
        [string]$ExportBasePath
    )
    
    $ExportDir = Join-Path $ExportBasePath $Item.Name $Version
    
    if (Test-Path $ExportDir) {
        Write-Log "Export directory already exists: $ExportDir - skipping" "WARN"
        return $false
    }
    
    # Create export directory
    New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null
    
    Write-Log "Exporting $($Item.Name) version $Version to $ExportDir"
    
    try {
        # Export the OVF
        $ExportedFiles = Export-ContentLibraryItem -ContentLibraryItem $Item -Destination $ExportDir -ErrorAction Stop
        
        # Create manifest with metadata
        $Manifest = @{
            Name = $Item.Name
            Version = $Version
            ExportedAt = (Get-Date).ToString("o")
            SourceVCenter = $SourceVCenter
            SourceLibrary = $SourceContentLibrary
            ItemId = $Item.Id
            ItemType = $Item.ItemType
        }
        
        $ManifestFile = Join-Path $ExportDir "manifest.json"
        $Manifest | ConvertTo-Json -Depth 5 | Set-Content $ManifestFile
        
        Write-Log "Successfully exported $($Item.Name) ($($ExportedFiles.Count) files)"
        return $true
    }
    catch {
        Write-Log "Failed to export $($Item.Name): $_" "ERROR"
        # Clean up partial export
        if (Test-Path $ExportDir) {
            Remove-Item -Path $ExportDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
}

# Main execution
try {
    Write-Log "========== Starting Source Export Check =========="
    
    # Ensure SMB paths exist
    foreach ($Path in @($ExportsPath, $UuidsPath, $StatePath)) {
        if (-not (Test-Path $Path)) {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            Write-Log "Created directory: $Path"
        }
    }
    
    # Load credentials and connect
    if (-not (Test-Path $CredentialFile)) {
        Write-Log "Credential file not found: $CredentialFile" "ERROR"
        Write-Log "Create it with: Get-Credential | Export-Clixml -Path '$CredentialFile'" "ERROR"
        exit 1
    }
    
    $Credential = Import-Clixml $CredentialFile
    
    Write-Log "Connecting to source vCenter: $SourceVCenter"
    $VIServer = Connect-VIServer -Server $SourceVCenter -Credential $Credential -ErrorAction Stop
    
    # Get content library
    $Library = Get-ContentLibrary -Name $SourceContentLibrary -ErrorAction Stop
    if (-not $Library) {
        Write-Log "Content library not found: $SourceContentLibrary" "ERROR"
        exit 1
    }
    Write-Log "Found content library: $($Library.Name) (ID: $($Library.Id))"
    
    # Get all items
    $Items = Get-ContentLibraryItem -ContentLibrary $Library
    Write-Log "Found $($Items.Count) items in content library"
    
    # Load current state
    $State = Get-SourceState
    $UpdatedState = @{}
    $ExportCount = 0
    
    foreach ($Item in $Items) {
        # Only process OVF templates
        if ($Item.ItemType -ne "ovf") {
            Write-Log "Skipping non-OVF item: $($Item.Name) (Type: $($Item.ItemType))"
            continue
        }
        
        # Get version info - using ContentVersion property
        $CurrentVersion = $Item.ContentVersion
        $LastExportedVersion = $State[$Item.Name]
        
        $UpdatedState[$Item.Name] = $CurrentVersion
        
        if ($Force -or ($CurrentVersion -ne $LastExportedVersion)) {
            if ($LastExportedVersion) {
                Write-Log "Version change detected for $($Item.Name): $LastExportedVersion -> $CurrentVersion"
            } else {
                Write-Log "New item detected: $($Item.Name) (Version: $CurrentVersion)"
            }
            
            $Result = Export-ContentLibraryItem -Item $Item -Version $CurrentVersion -ExportBasePath $ExportsPath
            if ($Result) {
                $ExportCount++
            }
        } else {
            Write-Log "No change for $($Item.Name) (Version: $CurrentVersion)"
        }
    }
    
    # Save updated state
    Save-SourceState -State $UpdatedState
    
    Write-Log "========== Export Complete: $ExportCount items exported =========="
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
    Get-ChildItem -Path $LogPath -Filter "SourceExport_*.log" | 
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetentionDays) } |
        Remove-Item -Force
}
