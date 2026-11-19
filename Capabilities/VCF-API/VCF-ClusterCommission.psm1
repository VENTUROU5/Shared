#Requires -Modules VMware.PowerCLI
<#
.SYNOPSIS
    VCF API Helper Functions for Cluster Commission Operations
    
.DESCRIPTION
    Functions to interact with SDDC Manager API for retrieving:
    - Cluster Image IDs
    - Host IDs filtered by hostname
    
.NOTES
    Requires VCF 4.x or 5.x SDDC Manager
    Set $SDDCManager and $SDDCCredential before use, or pass as parameters
#>

# ============================================================================
# CONFIGURATION
# ============================================================================

$script:SDDCManager = $env:SDDC_MANAGER ?? "sddc-manager.domain.local"
$script:SDDCToken = $null
$script:SDDCTokenExpiry = $null

# ============================================================================
# AUTHENTICATION
# ============================================================================

function Get-VCFToken {
    <#
    .SYNOPSIS
        Authenticates to SDDC Manager and returns an access token.
    .PARAMETER SDDCManager
        FQDN of SDDC Manager
    .PARAMETER Credential
        PSCredential for authentication
    .EXAMPLE
        $token = Get-VCFToken -SDDCManager "sddc-mgr.lab.local" -Credential (Get-Credential)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$SDDCManager = $script:SDDCManager,
        
        [Parameter(Mandatory = $true)]
        [PSCredential]$Credential
    )
    
    $uri = "https://$SDDCManager/v1/tokens"
    
    $body = @{
        username = $Credential.UserName
        password = $Credential.GetNetworkCredential().Password
    } | ConvertTo-Json
    
    try {
        $response = Invoke-RestMethod -Uri $uri -Method POST -Body $body -ContentType "application/json" -SkipCertificateCheck
        
        $script:SDDCToken = $response.accessToken
        $script:SDDCTokenExpiry = (Get-Date).AddMinutes(60)  # Token typically valid for 60 mins
        $script:SDDCManager = $SDDCManager
        
        Write-Host "✓ Authenticated to $SDDCManager" -ForegroundColor Green
        return $response.accessToken
    }
    catch {
        Write-Error "Failed to authenticate to SDDC Manager: $_"
        throw
    }
}

function Get-VCFAuthHeader {
    <#
    .SYNOPSIS
        Returns authorization header for API calls. Re-authenticates if token expired.
    #>
    [CmdletBinding()]
    param(
        [PSCredential]$Credential
    )
    
    if (-not $script:SDDCToken -or (Get-Date) -gt $script:SDDCTokenExpiry) {
        if ($Credential) {
            Get-VCFToken -Credential $Credential | Out-Null
        }
        else {
            throw "Token expired and no credential provided. Call Get-VCFToken first."
        }
    }
    
    return @{
        Authorization = "Bearer $($script:SDDCToken)"
    }
}

# ============================================================================
# CLUSTER IMAGE FUNCTIONS
# ============================================================================

function Get-VCFClusterImage {
    <#
    .SYNOPSIS
        Retrieves cluster images (personalities) from SDDC Manager.
    .PARAMETER ImageId
        Optional. Specific image ID to retrieve.
    .PARAMETER Name
        Optional. Filter by image name (supports wildcards).
    .EXAMPLE
        Get-VCFClusterImage
        # Returns all cluster images
    .EXAMPLE
        Get-VCFClusterImage -Name "VCF*"
        # Returns images matching name pattern
    .EXAMPLE
        Get-VCFClusterImage -ImageId "abc123-def456"
        # Returns specific image
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ImageId,
        
        [Parameter(Mandatory = $false)]
        [string]$Name,
        
        [Parameter(Mandatory = $false)]
        [string]$SDDCManager = $script:SDDCManager
    )
    
    $headers = Get-VCFAuthHeader
    
    if ($ImageId) {
        $uri = "https://$SDDCManager/v1/personalities/$ImageId"
    }
    else {
        $uri = "https://$SDDCManager/v1/personalities"
    }
    
    try {
        $response = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -ContentType "application/json" -SkipCertificateCheck
        
        $images = if ($ImageId) { @($response) } else { $response.elements }
        
        # Filter by name if specified
        if ($Name) {
            $images = $images | Where-Object { $_.name -like $Name }
        }
        
        # Return filtered fields
        $images | Select-Object @(
            @{N = 'ImageId'; E = { $_.id } }
            @{N = 'Name'; E = { $_.name } }
            @{N = 'Version'; E = { $_.version } }
            @{N = 'Type'; E = { $_.personalityType } }
            @{N = 'VsanEnabled'; E = { $_.isVsanEnabled } }
            @{N = 'CreationDate'; E = { $_.creationTimestamp } }
        )
    }
    catch {
        Write-Error "Failed to retrieve cluster images: $_"
        throw
    }
}

function Get-VCFClusterImageId {
    <#
    .SYNOPSIS
        Quick function to get just the Image ID by name.
    .PARAMETER Name
        Exact name or pattern to match.
    .EXAMPLE
        $imageId = Get-VCFClusterImageId -Name "VCF-5.2-Cluster-Image"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    
    $image = Get-VCFClusterImage -Name $Name | Select-Object -First 1
    
    if ($image) {
        return $image.ImageId
    }
    else {
        Write-Warning "No cluster image found matching: $Name"
        return $null
    }
}

# ============================================================================
# HOST FUNCTIONS
# ============================================================================

function Get-VCFHost {
    <#
    .SYNOPSIS
        Retrieves hosts from SDDC Manager with optional filtering.
    .PARAMETER HostId
        Optional. Specific host ID to retrieve.
    .PARAMETER Hostname
        Optional. Filter by hostname (supports wildcards).
    .PARAMETER Hostnames
        Optional. Array of exact hostnames to retrieve.
    .PARAMETER Status
        Optional. Filter by status: ASSIGNED, UNASSIGNED_USEABLE, UNASSIGNED_UNUSEABLE
    .EXAMPLE
        Get-VCFHost
        # Returns all hosts
    .EXAMPLE
        Get-VCFHost -Hostname "esxi-01*"
        # Returns hosts matching pattern
    .EXAMPLE
        Get-VCFHost -Hostnames @("esxi-01.lab.local", "esxi-02.lab.local")
        # Returns specific hosts
    .EXAMPLE
        Get-VCFHost -Status UNASSIGNED_USEABLE
        # Returns only unassigned useable hosts
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$HostId,
        
        [Parameter(Mandatory = $false)]
        [string]$Hostname,
        
        [Parameter(Mandatory = $false)]
        [string[]]$Hostnames,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('ASSIGNED', 'UNASSIGNED_USEABLE', 'UNASSIGNED_UNUSEABLE')]
        [string]$Status,
        
        [Parameter(Mandatory = $false)]
        [string]$SDDCManager = $script:SDDCManager
    )
    
    $headers = Get-VCFAuthHeader
    
    if ($HostId) {
        $uri = "https://$SDDCManager/v1/hosts/$HostId"
    }
    else {
        $uri = "https://$SDDCManager/v1/hosts"
        
        # Add query parameters
        $queryParams = @()
        if ($Status) {
            $queryParams += "status=$Status"
        }
        if ($queryParams.Count -gt 0) {
            $uri += "?" + ($queryParams -join "&")
        }
    }
    
    try {
        $response = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -ContentType "application/json" -SkipCertificateCheck
        
        $hosts = if ($HostId) { @($response) } else { $response.elements }
        
        # Filter by hostname pattern
        if ($Hostname) {
            $hosts = $hosts | Where-Object { $_.fqdn -like $Hostname }
        }
        
        # Filter by exact hostname list
        if ($Hostnames) {
            $hosts = $hosts | Where-Object { $_.fqdn -in $Hostnames }
        }
        
        # Return filtered fields
        $hosts | Select-Object @(
            @{N = 'HostId'; E = { $_.id } }
            @{N = 'Hostname'; E = { $_.fqdn } }
            @{N = 'Status'; E = { $_.status } }
            @{N = 'ClusterId'; E = { $_.cluster.id } }
            @{N = 'ClusterName'; E = { $_.cluster.name } }
            @{N = 'DomainId'; E = { $_.domain.id } }
            @{N = 'DomainName'; E = { $_.domain.name } }
            @{N = 'HardwareModel'; E = { $_.hardwareModel } }
            @{N = 'HardwareVendor'; E = { $_.hardwareVendor } }
            @{N = 'CpuCores'; E = { $_.cpu.cores } }
            @{N = 'MemoryGB'; E = { [math]::Round($_.memory.totalCapacityMB / 1024, 0) } }
        )
    }
    catch {
        Write-Error "Failed to retrieve hosts: $_"
        throw
    }
}

function Get-VCFHostIds {
    <#
    .SYNOPSIS
        Quick function to get Host IDs from a list of hostnames.
    .PARAMETER Hostnames
        Array of FQDNs to look up.
    .PARAMETER AsHashtable
        Return as hashtable (hostname -> id) instead of array.
    .EXAMPLE
        $hostIds = Get-VCFHostIds -Hostnames @("esxi-01.lab.local", "esxi-02.lab.local")
    .EXAMPLE
        $hostMap = Get-VCFHostIds -Hostnames @("esxi-01.lab.local", "esxi-02.lab.local") -AsHashtable
        $hostMap["esxi-01.lab.local"]  # Returns the host ID
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Hostnames,
        
        [switch]$AsHashtable
    )
    
    $hosts = Get-VCFHost -Hostnames $Hostnames
    
    if ($AsHashtable) {
        $result = @{}
        foreach ($h in $hosts) {
            $result[$h.Hostname] = $h.HostId
        }
        return $result
    }
    else {
        return $hosts | Select-Object HostId, Hostname
    }
}

function Get-VCFUnassignedHosts {
    <#
    .SYNOPSIS
        Returns hosts available for cluster commission (UNASSIGNED_USEABLE).
    .EXAMPLE
        Get-VCFUnassignedHosts
    #>
    [CmdletBinding()]
    param()
    
    Get-VCFHost -Status UNASSIGNED_USEABLE
}

# ============================================================================
# CLUSTER COMMISSION HELPERS
# ============================================================================

function New-VCFClusterSpec {
    <#
    .SYNOPSIS
        Creates a cluster specification object for commissioning.
    .PARAMETER ClusterName
        Name for the new cluster.
    .PARAMETER ImageId
        Cluster image/personality ID.
    .PARAMETER HostIds
        Array of host IDs to include.
    .PARAMETER VsanDatastoreName
        Name for vSAN datastore (if vSAN enabled).
    .EXAMPLE
        $spec = New-VCFClusterSpec -ClusterName "CL01A" -ImageId "abc-123" -HostIds @("host-1", "host-2")
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterName,
        
        [Parameter(Mandatory = $true)]
        [string]$ImageId,
        
        [Parameter(Mandatory = $true)]
        [string[]]$HostIds,
        
        [Parameter(Mandatory = $false)]
        [string]$VsanDatastoreName = "$ClusterName-vSAN"
    )
    
    $hostSpecs = $HostIds | ForEach-Object {
        @{
            id = $_
        }
    }
    
    @{
        clusterName = $ClusterName
        clusterImageId = $ImageId
        hostSpecs = $hostSpecs
        datastoreSpec = @{
            vsanDatastoreSpec = @{
                datastoreName = $VsanDatastoreName
            }
        }
    }
}

function Get-VCFClusterCommissionPayload {
    <#
    .SYNOPSIS
        Builds the full JSON payload for cluster commission.
    .PARAMETER ClusterName
        Name for the new cluster.
    .PARAMETER ImageName
        Name pattern to match cluster image.
    .PARAMETER Hostnames
        Array of host FQDNs to include.
    .EXAMPLE
        $payload = Get-VCFClusterCommissionPayload -ClusterName "CL01A" -ImageName "VCF-5.2*" -Hostnames @("esxi-01.lab.local", "esxi-02.lab.local")
        $payload | ConvertTo-Json -Depth 10
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterName,
        
        [Parameter(Mandatory = $true)]
        [string]$ImageName,
        
        [Parameter(Mandatory = $true)]
        [string[]]$Hostnames
    )
    
    # Get Image ID
    $imageId = Get-VCFClusterImageId -Name $ImageName
    if (-not $imageId) {
        throw "Could not find cluster image matching: $ImageName"
    }
    Write-Host "✓ Found Image ID: $imageId" -ForegroundColor Green
    
    # Get Host IDs
    $hostMap = Get-VCFHostIds -Hostnames $Hostnames -AsHashtable
    
    $missingHosts = $Hostnames | Where-Object { -not $hostMap.ContainsKey($_) }
    if ($missingHosts) {
        Write-Warning "Hosts not found in SDDC Manager: $($missingHosts -join ', ')"
    }
    
    $hostIds = $Hostnames | Where-Object { $hostMap.ContainsKey($_) } | ForEach-Object { $hostMap[$_] }
    Write-Host "✓ Found $($hostIds.Count) hosts" -ForegroundColor Green
    
    # Build spec
    New-VCFClusterSpec -ClusterName $ClusterName -ImageId $imageId -HostIds $hostIds
}

# ============================================================================
# EXPORT MODULE MEMBERS
# ============================================================================

Export-ModuleMember -Function @(
    'Get-VCFToken'
    'Get-VCFClusterImage'
    'Get-VCFClusterImageId'
    'Get-VCFHost'
    'Get-VCFHostIds'
    'Get-VCFUnassignedHosts'
    'New-VCFClusterSpec'
    'Get-VCFClusterCommissionPayload'
)
