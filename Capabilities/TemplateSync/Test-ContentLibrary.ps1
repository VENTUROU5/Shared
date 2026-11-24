#Requires -Modules VMware.PowerCLI
<#
.SYNOPSIS
    Test script to validate Content Library access and TemplateSync configuration.

.PARAMETER VCenterServer
    vCenter server hostname or IP.

.PARAMETER ContentLibraryName
    Name of the content library to check. Default: AutomatedTemplates

.EXAMPLE
    .\Test-ContentLibrary.ps1 -VCenterServer vcenter.plenty.wtf -ContentLibraryName AutomatedTemplates
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$VCenterServer,
    
    [string]$ContentLibraryName = "AutomatedTemplates"
)

# Suppress CEIP warning
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -ParticipateInCeip:$false | Out-Null

Write-Host "=== Content Library Test ===" -ForegroundColor Cyan
Write-Host ""

# Connect to vCenter
Write-Host "Connecting to $VCenterServer..." -ForegroundColor Yellow
try {
    $connection = Connect-VIServer -Server $VCenterServer -ErrorAction Stop
    Write-Host "Connected to: $($connection.Name) (Version: $($connection.Version))" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Failed to connect - $_" -ForegroundColor Red
    exit 1
}

Write-Host ""

# List all content libraries
Write-Host "=== All Content Libraries ===" -ForegroundColor Cyan
$libraries = Get-ContentLibrary
if ($libraries) {
    $libraries | Format-Table Name, Id, Type -AutoSize
} else {
    Write-Host "No content libraries found!" -ForegroundColor Red
}

Write-Host ""

# Check for specific library
Write-Host "=== Checking for  ===" -ForegroundColor Cyan
$targetLib = Get-ContentLibrary -Name $ContentLibraryName -ErrorAction SilentlyContinue
if ($targetLib) {
    Write-Host "FOUND: $($targetLib.Name)" -ForegroundColor Green
    Write-Host "  ID: $($targetLib.Id)"
    Write-Host "  Type: $($targetLib.Type)"
    
    Write-Host ""
    Write-Host "=== Library Items ===" -ForegroundColor Cyan
    $items = Get-ContentLibraryItem -ContentLibrary $targetLib
    if ($items) {
        $items | Format-Table Name, ItemType, ContentVersion, SizeGB -AutoSize
        Write-Host "Total items: $($items.Count)" -ForegroundColor Green
    } else {
        Write-Host "Library is empty" -ForegroundColor Yellow
    }
} else {
    Write-Host "NOT FOUND: " -ForegroundColor Red
    Write-Host "Available libraries: $($libraries.Name -join , )" -ForegroundColor Yellow
}

Write-Host ""

# Disconnect
Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
Write-Host "Disconnected from vCenter" -ForegroundColor Gray
Write-Host ""
Write-Host "=== Test Complete ===" -ForegroundColor Cyan
