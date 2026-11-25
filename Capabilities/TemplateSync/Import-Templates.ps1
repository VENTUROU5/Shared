# Requires VMware.PowerCLI (Import-Module below handles the check)
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
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\Config.ps1",
    [switch]$Force,
    [string]$TargetVCenter
)

. $ConfigPath

# Import VMware.PowerCLI
try {
    Import-Module VMware.VimAutomation.Core -ErrorAction Stop
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -ParticipateInCeip:$false -ErrorAction SilentlyContinue | Out-Null
} catch {
    Write-Error "Failed to import VMware.PowerCLI: $_"
    Write-Error "Install with: Install-Module VMware.PowerCLI -Scope CurrentUser"
    exit 1
}

$LogFile = Join-Path $LogPath "Import_$(Get-Date -Format 'yyyyMMdd').log"
New-Item -ItemType Directory -Path $LogPath -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Add-Content -Path $LogFile -Value $Entry
    if ($Level -eq "ERROR") { Write-Error $Message } else { Write-Host $Entry }
}

function Get-ImportState {
    param([string]$VCenterName)
    $StateFile = Join-Path $StatePath "import-state-$VCenterName.json"
    if (Test-Path $StateFile) {
        return Get-Content $StateFile -Raw | ConvertFrom-Json -AsHashtable
    }
    return @{}
}

function Save-ImportState {
    param([string]$VCenterName, [hashtable]$State)
    $State | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $StatePath "import-state-$VCenterName.json")
}

function Get-UuidMapping {
    param([string]$VCenterName)
    $UuidFile = Join-Path $UuidsPath "uuids-$VCenterName.json"
    if (Test-Path $UuidFile) {
        return Get-Content $UuidFile -Raw | ConvertFrom-Json -AsHashtable
    }
    return @{}
}

function Save-UuidMapping {
    param([string]$VCenterName, [hashtable]$Mapping)
    New-Item -ItemType Directory -Path $UuidsPath -Force -ErrorAction SilentlyContinue | Out-Null
    $Mapping | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $UuidsPath "uuids-$VCenterName.json")
}

function Set-VMInstanceUuid {
    param(
        [string]$VMId,
        [string]$InstanceUuid
    )
    
    $vm = Get-View -Id $VMId
    $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $spec.InstanceUuid = $InstanceUuid
    
    $vm.ReconfigVM($spec)
    Write-Log "    Set Instance UUID to $InstanceUuid"
}

function Get-AvailableExports {
    # Returns hashtable of template name -> latest version path
    $Exports = @{}
    
    if (-not (Test-Path $ExportsPath)) { return $Exports }
    
    Get-ChildItem -Path $ExportsPath -Directory | ForEach-Object {
        $TemplateName = $_.Name
        $Versions = Get-ChildItem -Path $_.FullName -Directory | 
            Sort-Object { [int]$_.Name } -Descending |
            Select-Object -First 1
        
        if ($Versions) {
            $ManifestPath = Join-Path $Versions.FullName "manifest.json"
            if (Test-Path $ManifestPath) {
                $Manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
                $Exports[$TemplateName] = @{
                    Path = $Versions.FullName
                    Version = $Manifest.Version
                    Manifest = $Manifest
                }
            }
        }
    }
    
    return $Exports
}

# Main
try {
    Write-Log "===== Starting Import Sync ====="
    
    if (-not (Test-Path $CredentialFile)) {
        Write-Log "Credential file not found: $CredentialFile" "ERROR"
        exit 1
    }
    
    $Cred = Import-Clixml $CredentialFile
    $AvailableExports = Get-AvailableExports
    
    if ($AvailableExports.Count -eq 0) {
        Write-Log "No exports found in $ExportsPath"
        exit 0
    }
    
    Write-Log "Found $($AvailableExports.Count) templates available for sync"
    
    # Process each destination vCenter
    $Destinations = $DestinationVCenters
    if ($TargetVCenter) {
        $Destinations = $Destinations | Where-Object { $_.Name -eq $TargetVCenter }
        if (-not $Destinations) {
            Write-Log "Target vCenter '$TargetVCenter' not found in config" "ERROR"
            exit 1
        }
    }
    
    foreach ($Dest in $Destinations) {
        Write-Log ""
        Write-Log "--- Processing $($Dest.Name) ($($Dest.Server)) ---"
        
        try {
            Connect-VIServer -Server $Dest.Server -Credential $Cred -ErrorAction Stop | Out-Null
            Write-Log "Connected"
            
            # Get or create destination folder
            $Folder = Get-Folder -Name $Dest.Folder -Type VM -ErrorAction SilentlyContinue
            if (-not $Folder) {
                $VMFolder = Get-Folder -Type VM | Where-Object { $_.Name -eq "vm" } | Select-Object -First 1
                $Folder = New-Folder -Name $Dest.Folder -Location $VMFolder
                Write-Log "Created folder: $($Dest.Folder)"
            }
            
            $State = Get-ImportState -VCenterName $Dest.Name
            $UuidMapping = Get-UuidMapping -VCenterName $Dest.Name
            $NewState = @{}
            $ImportCount = 0
            
            foreach ($TemplateName in $AvailableExports.Keys) {
                $Export = $AvailableExports[$TemplateName]
                $LastVersion = $State[$TemplateName]
                $NewState[$TemplateName] = $Export.Version
                
                if (-not $Force -and ($Export.Version -eq $LastVersion)) {
                    Write-Log "  $TemplateName : No change (v$($Export.Version))"
                    continue
                }
                
                Write-Log "  $TemplateName : Importing v$($Export.Version)..."
                
                # Check for existing template
                $ExistingTemplate = Get-Template -Location $Folder -Name $TemplateName -ErrorAction SilentlyContinue
                $PreserveUuid = $null
                
                if ($ExistingTemplate) {
                    # Get existing Instance UUID to preserve
                    $View = Get-View -Id $ExistingTemplate.Id -Property Config
                    $PreserveUuid = $View.Config.InstanceUuid
                    $UuidMapping[$TemplateName] = $PreserveUuid
                    Write-Log "    Existing template found, will preserve UUID: $PreserveUuid"
                }
                elseif ($UuidMapping[$TemplateName]) {
                    # Template was deleted but we have stored UUID
                    $PreserveUuid = $UuidMapping[$TemplateName]
                    Write-Log "    Using stored UUID: $PreserveUuid"
                }
                
                # Find OVF file
                $OvfFile = Get-ChildItem -Path $Export.Path -Filter "*.ovf" -Recurse | Select-Object -First 1
                if (-not $OvfFile) {
                    Write-Log "    No OVF file found in $($Export.Path)" "ERROR"
                    continue
                }
                
                # Get deployment targets by tag "AutomatedTemplate"
                $TargetTag = Get-Tag -Name "AutomatedTemplate" -ErrorAction SilentlyContinue
                if (-not $TargetTag) {
                    Write-Log "    Tag AutomatedTemplate not found - using defaults" "WARN"
                    $Cluster = Get-Cluster | Select-Object -First 1
                    $Datastore = Get-Datastore | Sort-Object FreeSpaceGB -Descending | Select-Object -First 1
                    $Network = Get-VirtualPortGroup | Select-Object -First 1
                } else {
                    # Find tagged resources
                    $Cluster = Get-Cluster | Where-Object { (Get-TagAssignment -Entity $_ -Tag $TargetTag -ErrorAction SilentlyContinue) } | Select-Object -First 1
                    $Datastore = Get-Datastore | Where-Object { (Get-TagAssignment -Entity $_ -Tag $TargetTag -ErrorAction SilentlyContinue) } | Select-Object -First 1
                    $Network = Get-VirtualPortGroup | Where-Object { (Get-TagAssignment -Entity $_ -Tag $TargetTag -ErrorAction SilentlyContinue) } | Select-Object -First 1
                    
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
                
                # Get a connected host from the cluster
                $VMHost = Get-VMHost -Location $Cluster | Where-Object { $_.ConnectionState -eq "Connected" } | Select-Object -First 1
                if (-not $VMHost) {
                    Write-Log "    No connected host in cluster $($Cluster.Name)" "ERROR"
                    continue
                }
                
                Write-Log "    Targets: Cluster=$($Cluster.Name), Host=$($VMHost.Name), Datastore=$($Datastore.Name), Network=$($Network.Name)"
                
                # Deploy new template with temporary name
                $TempName = "$TemplateName-new-$(Get-Date -Format 'yyyyMMddHHmmss')"
                
                try {
                    Write-Log "    Deploying OVF..."
                    
                    $OvfConfig = Get-OvfConfiguration -Ovf $OvfFile.FullName
                    
                    # Set network mapping
                    if ($OvfConfig.NetworkMapping) {
                        $OvfConfig.NetworkMapping.PSObject.Properties.Name | ForEach-Object {
                            $OvfConfig.NetworkMapping.$_.Value = $Network
                        }
                    }
                    
                    
                    Import-VApp -Source $OvfFile.FullName -OvfConfiguration $OvfConfig `
                        -Name $TempName -VMHost $VMHost -Datastore $Datastore `
                        -DiskStorageFormat Thin -ErrorAction Stop | Out-Null
                    
                    # Convert to template
                    $NewVM = Get-VM -Name $TempName
                    
                    # Set Instance UUID if we have one to preserve
                    if ($PreserveUuid) {
                        Set-VMInstanceUuid -VMId $NewVM.Id -InstanceUuid $PreserveUuid
                    }
                    else {
                        # Store the new UUID for future updates
                        $NewView = Get-View -Id $NewVM.Id -Property Config
                        $UuidMapping[$TemplateName] = $NewView.Config.InstanceUuid
                        Write-Log "    New UUID assigned: $($NewView.Config.InstanceUuid)"
                    }
                    
                    # Convert to template
                    Set-VM -VM $NewVM -ToTemplate -Confirm:$false | Out-Null
                    
                    # Remove old template if exists
                    if ($ExistingTemplate) {
                        Remove-Template -Template $ExistingTemplate -DeletePermanently -Confirm:$false
                        Write-Log "    Removed old template"
                    }
                    
                    # Rename new template
                    $NewTemplate = Get-Template -Name $TempName
                    Set-Template -Template $NewTemplate -Name $TemplateName -Confirm:$false | Out-Null
                    
                    # Move to destination folder
                    Move-Template -Template (Get-Template -Name $TemplateName) -Destination $Folder -Confirm:$false | Out-Null
                    
                    Write-Log "    Successfully imported $TemplateName v$($Export.Version)"
                    $ImportCount++
                }
                catch {
                    Write-Log "    Import failed: $_" "ERROR"
                    # Cleanup failed deployment
                    Get-VM -Name $TempName -ErrorAction SilentlyContinue | Remove-VM -DeletePermanently -Confirm:$false -ErrorAction SilentlyContinue
                    Get-Template -Name $TempName -ErrorAction SilentlyContinue | Remove-Template -DeletePermanently -Confirm:$false -ErrorAction SilentlyContinue
                }
            }
            
            Save-ImportState -VCenterName $Dest.Name -State $NewState
            Save-UuidMapping -VCenterName $Dest.Name -Mapping $UuidMapping
            
            Write-Log "--- $($Dest.Name) complete: $ImportCount imported ---"
        }
        catch {
            Write-Log "Failed to process $($Dest.Name): $_" "ERROR"
        }
        finally {
            Disconnect-VIServer -Server $Dest.Server -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    
    Write-Log "===== Import Sync Complete ====="
}
catch {
    Write-Log "Script failed: $_" "ERROR"
    exit 1
}
