# VCF Cluster Commission API Helpers

PowerShell module for interacting with VMware Cloud Foundation SDDC Manager API to assist with cluster commissioning.

## Features

- **Authentication**: Token-based auth with auto-refresh
- **Cluster Images**: Retrieve and filter cluster personalities
- **Hosts**: Query hosts by hostname, status, or ID
- **Commission Helpers**: Build cluster spec payloads

## Quick Start

```powershell
# Import the module
Import-Module .\VCF-ClusterCommission.psm1

# Authenticate to SDDC Manager
Get-VCFToken -SDDCManager "sddc-mgr.lab.local" -Credential (Get-Credential)

# Get all cluster images
Get-VCFClusterImage

# Get specific image ID by name
$imageId = Get-VCFClusterImageId -Name "VCF-5.2*"

# Get hosts by hostname list
$hosts = Get-VCFHostIds -Hostnames @(
    "esxi-01.lab.local",
    "esxi-02.lab.local",
    "esxi-03.lab.local",
    "esxi-04.lab.local"
)

# Get unassigned hosts available for commissioning
Get-VCFUnassignedHosts
```

## Functions Reference

### Authentication

| Function | Description |
|----------|-------------|
| `Get-VCFToken` | Authenticate and store token for subsequent calls |

### Cluster Images

| Function | Description |
|----------|-------------|
| `Get-VCFClusterImage` | List all images with filtering options |
| `Get-VCFClusterImageId` | Quick lookup - returns just the ID |

**Output fields:**
- `ImageId` - UUID for API calls
- `Name` - Display name
- `Version` - VCF version
- `Type` - Personality type
- `VsanEnabled` - Boolean
- `CreationDate` - Timestamp

### Hosts

| Function | Description |
|----------|-------------|
| `Get-VCFHost` | List hosts with filtering |
| `Get-VCFHostIds` | Get IDs for a list of hostnames |
| `Get-VCFUnassignedHosts` | Shortcut for available hosts |

**Output fields:**
- `HostId` - UUID for API calls
- `Hostname` - FQDN
- `Status` - ASSIGNED, UNASSIGNED_USEABLE, UNASSIGNED_UNUSEABLE
- `ClusterId`, `ClusterName` - Current assignment (if any)
- `DomainId`, `DomainName` - Current domain (if any)
- `HardwareModel`, `HardwareVendor` - Server info
- `CpuCores`, `MemoryGB` - Resources

### Commission Helpers

| Function | Description |
|----------|-------------|
| `New-VCFClusterSpec` | Build cluster spec from IDs |
| `Get-VCFClusterCommissionPayload` | Full payload from names (looks up IDs) |

## Examples

### Example 1: Get Cluster Image ID

```powershell
# List all images
Get-VCFClusterImage | Format-Table

# Output:
# ImageId                              Name                    Version Type    VsanEnabled
# -------                              ----                    ------- ----    -----------
# a1b2c3d4-e5f6-7890-abcd-ef1234567890 VCF-5.2-Cluster-Image   5.2.0   VCENTER True

# Get just the ID
$imageId = Get-VCFClusterImageId -Name "VCF-5.2*"
# Returns: a1b2c3d4-e5f6-7890-abcd-ef1234567890
```

### Example 2: Get Host IDs from Hostnames

```powershell
# Define your hosts
$hostnames = @(
    "esxi-cl01-01.lab.local",
    "esxi-cl01-02.lab.local",
    "esxi-cl01-03.lab.local",
    "esxi-cl01-04.lab.local"
)

# Get as array
Get-VCFHostIds -Hostnames $hostnames

# Output:
# HostId                               Hostname
# ------                               --------
# 11111111-2222-3333-4444-555555555555 esxi-cl01-01.lab.local
# 22222222-3333-4444-5555-666666666666 esxi-cl01-02.lab.local
# ...

# Get as hashtable for easy lookup
$hostMap = Get-VCFHostIds -Hostnames $hostnames -AsHashtable
$hostMap["esxi-cl01-01.lab.local"]  # Returns the host ID
```

### Example 3: Build Commission Payload

```powershell
# Full payload - looks up image and host IDs automatically
$payload = Get-VCFClusterCommissionPayload `
    -ClusterName "CL01A" `
    -ImageName "VCF-5.2*" `
    -Hostnames @(
        "esxi-cl01-01.lab.local",
        "esxi-cl01-02.lab.local",
        "esxi-cl01-03.lab.local",
        "esxi-cl01-04.lab.local"
    )

# View the JSON
$payload | ConvertTo-Json -Depth 10

# Output:
# {
#   "clusterName": "CL01A",
#   "clusterImageId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
#   "hostSpecs": [
#     { "id": "11111111-2222-3333-4444-555555555555" },
#     { "id": "22222222-3333-4444-5555-666666666666" },
#     ...
#   ],
#   "datastoreSpec": {
#     "vsanDatastoreSpec": {
#       "datastoreName": "CL01A-vSAN"
#     }
#   }
# }
```

### Example 4: Filter Hosts by Status

```powershell
# Get only unassigned hosts ready for use
Get-VCFUnassignedHosts | Format-Table Hostname, CpuCores, MemoryGB

# Or filter manually
Get-VCFHost -Status UNASSIGNED_USEABLE | Where-Object { $_.MemoryGB -ge 512 }
```

### Example 5: Wildcard Hostname Matching

```powershell
# Get all hosts matching a pattern
Get-VCFHost -Hostname "esxi-cl01-*" | Select-Object HostId, Hostname
```

## Environment Variables

You can set defaults via environment variables:

```powershell
$env:SDDC_MANAGER = "sddc-mgr.lab.local"
```

## Error Handling

All functions throw on failure. Wrap in try/catch:

```powershell
try {
    $imageId = Get-VCFClusterImageId -Name "NonExistent"
}
catch {
    Write-Error "Failed: $_"
}
```

## API Endpoints Used

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/v1/tokens` | POST | Authentication |
| `/v1/personalities` | GET | Cluster images |
| `/v1/personalities/{id}` | GET | Specific image |
| `/v1/hosts` | GET | Host inventory |
| `/v1/hosts/{id}` | GET | Specific host |
