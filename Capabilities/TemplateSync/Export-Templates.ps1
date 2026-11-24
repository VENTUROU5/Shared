#Requires -Modules VMware.PowerCLI
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
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\Config.ps1",
    [switch]$Force
)

. $ConfigPath

# Logging setup
$LogFile = Join-Path $LogPath "Export_$(Get-Date -Format 'yyyyMMdd').log"
New-Item -ItemType Directory -Path $LogPath -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Add-Content -Path $LogFile -Value $Entry
    if ($Level -eq "ERROR") { Write-Error $Message } else { Write-Host $Entry }
}

function Get-ExportState {
    $StateFile = Join-Path $StatePath "export-state.json"
    if (Test-Path $StateFile) {
        return Get-Content $StateFile -Raw | ConvertFrom-Json -AsHashtable
    }
    return @{}
}

function Save-ExportState {
    param([hashtable]$State)
    New-Item -ItemType Directory -Path $StatePath -Force -ErrorAction SilentlyContinue | Out-Null
    $State | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $StatePath "export-state.json")
}

# Main
try {
    Write-Log "===== Starting Export Check ====="
    
    # Ensure paths exist
    foreach ($Path in @($ExportsPath, $StatePath, $UuidsPath)) {
        New-Item -ItemType Directory -Path $Path -Force -ErrorAction SilentlyContinue | Out-Null
    }
    
    # Connect to source vCenter
    if (-not (Test-Path $CredentialFile)) {
        Write-Log "Credential file not found: $CredentialFile" "ERROR"
        Write-Log "Create with: Get-Credential | Export-Clixml -Path '$CredentialFile'" "ERROR"
        exit 1
    }
    
    $Cred = Import-Clixml $CredentialFile
    Write-Log "Connecting to $SourceVCenter..."
    Connect-VIServer -Server $SourceVCenter -Credential $Cred -ErrorAction Stop | Out-Null
    
    # Get content library
    $Library = Get-ContentLibrary -Name $SourceContentLibrary -ErrorAction Stop
    Write-Log "Found library: $($Library.Name)"
    
    $Items = Get-ContentLibraryItem -ContentLibrary $Library | Where-Object { $_.ItemType -eq "ovf" }
    Write-Log "Found $($Items.Count) OVF items"
    
    $State = Get-ExportState
    $NewState = @{}
    $ExportCount = 0
    
    foreach ($Item in $Items) {
        $Version = [string]$Item.ContentVersion
        $LastVersion = $State[$Item.Name]
        $NewState[$Item.Name] = $Version
        
        if ($Force -or ($Version -ne $LastVersion)) {
            $Action = if ($LastVersion) { "Updated ($LastVersion -> $Version)" } else { "New" }
            Write-Log "$($Item.Name): $Action - exporting..."
            
            $ExportDir = Join-Path $ExportsPath $Item.Name $Version
            
            if (Test-Path $ExportDir) {
                Write-Log "  Export already exists, skipping"
                continue
            }
            
            New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null
            
            try {
                Export-ContentLibraryItem -ContentLibraryItem $Item -Destination $ExportDir -ErrorAction Stop | Out-Null
                
                # Write manifest
                @{
                    Name = $Item.Name
                    Version = $Version
                    ExportedAt = (Get-Date).ToString("o")
                    SourceVCenter = $SourceVCenter
                    SourceLibrary = $SourceContentLibrary
                    ItemId = $Item.Id
                } | ConvertTo-Json | Set-Content (Join-Path $ExportDir "manifest.json")
                
                Write-Log "  Exported to $ExportDir"
                $ExportCount++
            }
            catch {
                Write-Log "  Export failed: $_" "ERROR"
                Remove-Item -Path $ExportDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            Write-Log "$($Item.Name): No change (v$Version)"
        }
    }
    
    Save-ExportState -State $NewState
    Write-Log "===== Export Complete: $ExportCount exported ====="
}
catch {
    Write-Log "Script failed: $_" "ERROR"
    exit 1
}
finally {
    Disconnect-VIServer * -Confirm:$false -ErrorAction SilentlyContinue
}
