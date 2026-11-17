# VMware Template Distribution System

Distributes VM templates from a central content library to multiple vCenters without direct connectivity between them.

## Architecture

```
┌─────────────────┐     SMB Share      ┌─────────────────┐
│ Source vCenter  │ ←── exports/ ───→  │ Dest vCenter A  │
│ (Central)       │                    │ (Script Box A)  │
│                 │     ┌─────────┐    └─────────────────┘
│ AutomatedTempl. │ ──→ │ uuids/  │
│ Content Library │     │ state/  │    ┌─────────────────┐
└─────────────────┘     └─────────┘ ←─ │ Dest vCenter B  │
                                       │ (Script Box B)  │
                                       └─────────────────┘
```

## How It Works

1. **Source script** monitors the central content library every 15 minutes
2. When a template version changes, it exports the OVF to the SMB share
3. **Destination scripts** (one per vCenter) detect new exports and import them
4. Each destination maintains its own UUID mapping for consistent deployments

## SMB Share Structure

```
\\fileserver\vmware-templates\
├── exports/
│   └── <template-name>/
│       └── <version>/
│           ├── *.ovf
│           ├── *.vmdk
│           └── manifest.json
├── uuids/
│   └── <vcenter-name>/
│       └── <template-name>.json
└── state/
    ├── source-state.json
    └── <vcenter-name>-state.json
```

## Setup

### Prerequisites

- PowerCLI installed: `Install-Module VMware.PowerCLI -Scope CurrentUser`
- SMB share accessible from all script boxes
- Service account with appropriate vCenter permissions

### Step 1: Configure the Scripts

Each script box needs its own `Config.ps1`:

**Source script box:**
```powershell
$SourceVCenter = "vcenter-central.domain.local"
$SourceContentLibrary = "AutomatedTemplates"
$SmbShareRoot = "\\fileserver\vmware-templates"
$CredentialFile = "C:\Scripts\vcenter-creds.xml"
$LogPath = "C:\Scripts\Logs"
```

**Destination script box:**
```powershell
$DestinationVCenter = "vcenter-site1.domain.local"
$DestinationContentLibrary = "AutomatedTemplates"
$DestinationVCenterName = "site1"  # Unique identifier for UUID storage
$SmbShareRoot = "\\fileserver\vmware-templates"
$CredentialFile = "C:\Scripts\vcenter-creds.xml"
$LogPath = "C:\Scripts\Logs"
```

### Step 2: Create Encrypted Credentials

On each script box, run as the service account:

```powershell
# This encrypts the credential using the service account's key
Get-Credential | Export-Clixml -Path "C:\Scripts\vcenter-creds.xml"
```

### Step 3: Set Up Scheduled Tasks

**Source script box:**
```powershell
$Action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Export-SourceTemplates.ps1"
$Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days 365)
$Principal = New-ScheduledTaskPrincipal -UserId "DOMAIN\svc-vmware-sync" -LogonType Password

Register-ScheduledTask -TaskName "VMware Template Export" `
    -Action $Action -Trigger $Trigger -Principal $Principal
```

**Destination script boxes:**
```powershell
$Action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Import-DestinationTemplates.ps1"
$Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days 365)
$Principal = New-ScheduledTaskPrincipal -UserId "DOMAIN\svc-vmware-sync" -LogonType Password

Register-ScheduledTask -TaskName "VMware Template Import" `
    -Action $Action -Trigger $Trigger -Principal $Principal
```

## Required vCenter Permissions

### Source vCenter (export)
- Content Library → Read
- Content Library → Download files

### Destination vCenter (import)
- Content Library → Create local library
- Content Library → Add library item
- Content Library → Update library item
- Content Library → Delete library item
- Content Library → Upload files

## Usage

### Manual Export (all templates)
```powershell
.\Export-SourceTemplates.ps1 -Force
```

### Manual Import (all templates)
```powershell
.\Import-DestinationTemplates.ps1 -Force
```

### Deploy a VM with Preserved UUID
```powershell
# Connect to destination vCenter first
Connect-VIServer -Server vcenter-site1.domain.local

# Deploy using the helper script
.\Deploy-TemplateWithUuid.ps1 `
    -TemplateName "Windows2022-Base" `
    -VMName "NewServer01" `
    -VMHost "esxi01.site1.local" `
    -Datastore "DS-Production-01"
```

## UUID Mapping

The system stores a unique instance-uuid for each template at each destination vCenter. This allows:

- Consistent UUID across all VMs deployed from the same template at a site
- Different UUIDs per site (if required by external systems)
- UUID retrieval via SMB share for automation tools

UUID files are stored at:
```
\\fileserver\vmware-templates\uuids\<vcenter-name>\<template-name>.json
```

Example content:
```json
{
  "InstanceUuid": "421a3f78-9b2c-4d5e-8f1a-0c3b5d7e9f1a",
  "LastUpdated": "2026-11-05T10:30:00.000Z",
  "Version": "3",
  "VCenter": "vcenter-site1.domain.local"
}
```

## Troubleshooting

### Check Logs
```powershell
# Source logs
Get-Content "C:\Scripts\Logs\SourceExport_*.log" -Tail 50

# Destination logs
Get-Content "C:\Scripts\Logs\DestImport_*.log" -Tail 50
```

### Force Re-sync
```powershell
# Delete state files to force full re-export/import
Remove-Item "\\fileserver\vmware-templates\state\source-state.json"
Remove-Item "\\fileserver\vmware-templates\state\site1-state.json"
```

### Test Connectivity
```powershell
# Test SMB access
Test-Path "\\fileserver\vmware-templates"

# Test vCenter connection
Connect-VIServer -Server vcenter.domain.local -Credential (Get-Credential)
```

## Files

| File | Purpose |
|------|---------|
| `Config.ps1` | Configuration variables (edit per script box) |
| `Export-SourceTemplates.ps1` | Runs on source, exports changed templates |
| `Import-DestinationTemplates.ps1` | Runs on destinations, imports new versions |
| `Deploy-TemplateWithUuid.ps1` | Helper to deploy VMs with preserved UUID |
