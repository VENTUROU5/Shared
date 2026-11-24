#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sets up the TemplateSync scheduled tasks and prerequisites.

.DESCRIPTION
    Creates credential files, directories, and scheduled tasks for 
    Export-SourceTemplates.ps1 and Import-DestinationTemplates.ps1.

.PARAMETER ScriptPath
    Path where TemplateSync scripts are located. Default: C:\Scripts\TemplateSync

.PARAMETER SmbShare
    UNC path to the SMB share for template staging. Required.

.PARAMETER SourceVCenter
    Source vCenter server (for export task). Required for -SetupExport.

.PARAMETER DestinationVCenter  
    Destination vCenter server (for import task). Required for -SetupImport.

.PARAMETER ContentLibrary
    Content library name. Default: AutomatedTemplates

.PARAMETER SetupExport
    Configure the export scheduled task.

.PARAMETER SetupImport
    Configure the import scheduled task.

.PARAMETER IntervalMinutes
    How often to run the sync. Default: 15

.EXAMPLE
    # Setup export task on source management host
    .\Setup-ScheduledTask.ps1 -SetupExport -SourceVCenter vcenter.domain.local -SmbShare "\\fileserver\templates"

.EXAMPLE
    # Setup import task on destination management host  
    .\Setup-ScheduledTask.ps1 -SetupImport -DestinationVCenter vcenter2.domain.local -SmbShare "\\fileserver\templates"

.EXAMPLE
    # One-liner for export task (run as admin, will prompt for credentials)
    irm https://git.getfree.au/jimmy/Shared/raw/branch/main/Capabilities/TemplateSync/Setup-ScheduledTask.ps1 | iex; Setup-TemplateSync -SetupExport -SourceVCenter "vcenter.local" -SmbShare "\\server\share"
#>

[CmdletBinding()]
param(
    [string]$ScriptPath = "C:\Scripts\TemplateSync",
    
    [Parameter(Mandatory)]
    [string]$SmbShare,
    
    [string]$SourceVCenter,
    [string]$DestinationVCenter,
    [string]$ContentLibrary = "AutomatedTemplates",
    
    [switch]$SetupExport,
    [switch]$SetupImport,
    
    [int]$IntervalMinutes = 15
)

function Setup-TemplateSync {
    param(
        [string]$ScriptPath = "C:\Scripts\TemplateSync",
        [Parameter(Mandatory)][string]$SmbShare,
        [string]$SourceVCenter,
        [string]$DestinationVCenter,
        [string]$ContentLibrary = "AutomatedTemplates",
        [switch]$SetupExport,
        [switch]$SetupImport,
        [int]$IntervalMinutes = 15
    )
    
    # Validate parameters
    if ($SetupExport -and -not $SourceVCenter) {
        throw "SourceVCenter is required when using -SetupExport"
    }
    if ($SetupImport -and -not $DestinationVCenter) {
        throw "DestinationVCenter is required when using -SetupImport"
    }
    if (-not $SetupExport -and -not $SetupImport) {
        throw "Specify -SetupExport and/or -SetupImport"
    }

    Write-Host "=== TemplateSync Setup ===" -ForegroundColor Cyan
    
    # Create directories
    Write-Host "`n[1/5] Creating directories..." -ForegroundColor Yellow
    $Dirs = @($ScriptPath, "$ScriptPath\Logs", "$SmbShare\exports", "$SmbShare\uuids", "$SmbShare\state")
    foreach ($Dir in $Dirs) {
        if (-not (Test-Path $Dir)) {
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            Write-Host "  Created: $Dir" -ForegroundColor Green
        } else {
            Write-Host "  Exists: $Dir" -ForegroundColor Gray
        }
    }

    # Download scripts
    Write-Host "`n[2/5] Downloading scripts..." -ForegroundColor Yellow
    $BaseUrl = "https://git.getfree.au/jimmy/Shared/raw/branch/main/Capabilities/TemplateSync"
    $Scripts = @("Config.ps1", "Export-SourceTemplates.ps1", "Import-DestinationTemplates.ps1", "Deploy-TemplateWithUuid.ps1")
    foreach ($Script in $Scripts) {
        $Dest = Join-Path $ScriptPath $Script
        Invoke-WebRequest -Uri "$BaseUrl/$Script" -OutFile $Dest -UseBasicParsing
        Write-Host "  Downloaded: $Script" -ForegroundColor Green
    }

    # Create/update config
    Write-Host "`n[3/5] Generating Config.ps1..." -ForegroundColor Yellow
    $ConfigContent = @"
# VMware Template Distribution Configuration
# Generated: $(Get-Date -Format yyyy-MM-dd HH:mm:ss)

# Source vCenter
`$SourceVCenter = "$SourceVCenter"
`$SourceContentLibrary = "$ContentLibrary"

# Destination vCenter
`$DestinationVCenter = "$DestinationVCenter"
`$DestinationContentLibrary = "$ContentLibrary"
`$DestinationVCenterName = "$($DestinationVCenter -replace ..*,)"

# SMB Share paths
`$SmbShareRoot = "$SmbShare"
`$ExportsPath = Join-Path `$SmbShareRoot "exports"
`$UuidsPath = Join-Path `$SmbShareRoot "uuids"
`$StatePath = Join-Path `$SmbShareRoot "state"

# Credentials
`$CredentialFile = "$ScriptPath\vcenter-creds.xml"

# Logging
`$LogPath = "$ScriptPath\Logs"
`$LogRetentionDays = 30

# Timing
`$CheckIntervalMinutes = $IntervalMinutes
"@
    $ConfigContent | Set-Content (Join-Path $ScriptPath "Config.ps1")
    Write-Host "  Config written" -ForegroundColor Green

    # Prompt for credentials
    Write-Host "`n[4/5] Setting up credentials..." -ForegroundColor Yellow
    $CredFile = Join-Path $ScriptPath "vcenter-creds.xml"
    if (-not (Test-Path $CredFile)) {
        Write-Host "  Enter vCenter credentials (administrator@vsphere.local or similar):" -ForegroundColor Cyan
        $Cred = Get-Credential -Message "vCenter administrator credentials"
        $Cred | Export-Clixml -Path $CredFile
        Write-Host "  Credentials saved to: $CredFile" -ForegroundColor Green
    } else {
        Write-Host "  Credential file exists: $CredFile" -ForegroundColor Gray
    }

    # Create scheduled tasks
    Write-Host "`n[5/5] Creating scheduled tasks..." -ForegroundColor Yellow
    
    if ($SetupExport) {
        $TaskName = "TemplateSync-Export"
        $Action = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument "-ExecutionPolicy Bypass -File `"$ScriptPath\Export-SourceTemplates.ps1`""
        $Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
        $Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries
        
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -RunLevel Highest -User "SYSTEM" | Out-Null
        Write-Host "  Created task: $TaskName (every $IntervalMinutes min)" -ForegroundColor Green
    }
    
    if ($SetupImport) {
        $TaskName = "TemplateSync-Import"
        $Action = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument "-ExecutionPolicy Bypass -File `"$ScriptPath\Import-DestinationTemplates.ps1`""
        $Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
        $Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries
        
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -RunLevel Highest -User "SYSTEM" | Out-Null
        Write-Host "  Created task: $TaskName (every $IntervalMinutes min, offset +5)" -ForegroundColor Green
    }

    Write-Host "`n=== Setup Complete ===" -ForegroundColor Cyan
    Write-Host @"

Next steps:
1. Test manually: pwsh -File "$ScriptPath\Export-SourceTemplates.ps1"
2. Check logs: Get-Content "$ScriptPath\Logs\*.log" -Tail 50
3. View tasks: Get-ScheduledTask -TaskName "TemplateSync*"
"@
}

# If running directly (not dot-sourced), execute with provided params
if ($SetupExport -or $SetupImport) {
    Setup-TemplateSync -ScriptPath $ScriptPath -SmbShare $SmbShare -SourceVCenter $SourceVCenter -DestinationVCenter $DestinationVCenter -ContentLibrary $ContentLibrary -SetupExport:$SetupExport -SetupImport:$SetupImport -IntervalMinutes $IntervalMinutes
}
