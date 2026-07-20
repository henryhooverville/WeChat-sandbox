# ==============================================================================
# SECURE WECHAT SANDBOX DEPLOYMENT ENGINE
# Hardened for SYSTEM Context Execution with Local Logging
# ==============================================================================

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$VMName = "wechat-sandbox",

    [Parameter(Mandatory = $false)]
    [string]$VMMemory = "4GB",

    [Parameter(Mandatory = $false)]
    [int]$VHDSizeGB = 40,

    # Consolidated to standard Temp pathing
    [Parameter(Mandatory = $false)]
    [string]$WorkingDir = "C:\Temp\WeChat"
)

# Escalate all warnings/errors to terminating exceptions
$ErrorActionPreference = "Stop"
$PreviousProgressPreference = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'

# Define dynamic log path
$LogPath = "$WorkingDir\deploy.log"

# ==============================================================================
# 0. CENTRALIZED LOGGING FUNCTION
# ==============================================================================
function Write-Log {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    
    # Ensure working directory exists before writing logs
    if (-not (Test-Path -Path $WorkingDir)) {
        New-Item -ItemType Directory -Force -Path $WorkingDir | Out-Null
    }
    
    # Create unified timestamp
    $Timestamp = [DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss")
    $LogEntry = "[$Timestamp] [$Level] $Message"
    
    # Write to local file on disk
    $LogEntry | Out-File -FilePath $LogPath -Append -Encoding UTF8
    
    # Write to PowerShell output streams for RMM capturing
    switch ($Level) {
        "ERROR"   { Write-Error $LogEntry }
        "WARN"    { Write-Warning $LogEntry }
        "SUCCESS" { Write-Output $LogEntry }
        Default   { Write-Output $LogEntry }
    }
}

# ==============================================================================
# 1. SANITY CHECKS & PREREQUISITES
# ==============================================================================
function Test-SandboxPrerequisites {
    Write-Log "Running Host Integrity and Sanity Checks..."

    # Check 1: Admin / SYSTEM Privileges
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Elevation Fault: Script must run as Administrator or NT AUTHORITY\SYSTEM."
    }

    # Check 2: Windows Operating System Edition (No Home Editions)
    $OS = Get-CimInstance Win32_OperatingSystem
    if ($OS.Caption -match "Home") {
        throw "OS Incompatibility: Current Windows Edition is '$($OS.Caption)'. Hyper-V requires Pro, Enterprise, or Education SKUs."
    }

    # Check 3: Hyper-V Management Powershell Module Availability
    if (-not (Get-Command -Module Hyper-V -Name New-VM -ErrorAction SilentlyContinue)) {
        throw "Module Fault: Hyper-V PowerShell administration tools are not installed or enabled."
    }

    # Check 4: Hyper-V Host Compute Service (vmcompute) Status
    $Service = Get-Service -Name "vmcompute" -ErrorAction SilentlyContinue
    if ($null -eq $Service -or $Service.Status -ne "Running") {
        throw "Service Fault: Hyper-V Host Compute Service (vmcompute) is inactive. Ensure hypervisor launch is not blocked."
    }
    
    # Check 5: Hyper-V Management Powershell Module Availability
    if (-not (Get-Command -Module Hyper-V -Name New-VM -ErrorAction SilentlyContinue)) {
        throw "Module Fault: Hyper-V PowerShell administration tools are not installed or enabled."
    }

    # Check 6: Hyper-V Host Compute Service (vmcompute) Status
    $Service = Get-Service -Name "vmcompute" -ErrorAction SilentlyContinue
    if ($null -eq $Service -or $Service.Status -ne "Running") {
        throw "Service Fault: Hyper-V Host Compute Service (vmcompute) is inactive. Ensure hypervisor launch is not blocked."
    }

    Write-Log "All host requirements met. Hyper-V engine verified running." -Level "SUCCESS"
}

# ==============================================================================
# 2. NETWORKING & FIREWALL IMPLEMENTATION
# ==============================================================================
function Initialize-SandboxNetwork {
    param (
        [string]$SwitchName,
        [string]$NatName,
        [string]$GatewayIP,
        [string]$SubnetPrefix,
        [string]$VirtualAdapterName
    )
    Write-Log "Initializing isolated virtual network interfaces..."

    try {
        # Create Internal Switch
        if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
            New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
            Write-Log "Created Internal Switch: $SwitchName" -Level "SUCCESS"
            Start-Sleep -Seconds 15
        }

        # Identify generated Virtual Network Adapter interface
        $NetAdapter = Get-NetAdapter | Where-Object { $_.Name -eq $VirtualAdapterName }
        if ($null -eq $NetAdapter) {
            throw "Failed to map vSwitch adapter: '$VirtualAdapterName'."
        }

        # Bind gateway IP to host side of switch
        if (-not (Get-NetIPAddress -InterfaceIndex $NetAdapter.InterfaceIndex -IPAddress $GatewayIP -ErrorAction SilentlyContinue)) {
            New-NetIPAddress -IPAddress $GatewayIP -PrefixLength 24 -InterfaceIndex $NetAdapter.InterfaceIndex | Out-Null
            Write-Log "Assigned host-side gateway gateway IP: $GatewayIP" -Level "SUCCESS"
        }

        # Create localized translation engine (NAT)
        if (-not (Get-NetNat -Name $NatName -ErrorAction SilentlyContinue)) {
            New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $SubnetPrefix | Out-Null
            Write-Log "Created static NAT network mapping: $SubnetPrefix" -Level "SUCCESS"
        }
    }
    catch {
        throw "Network Setup Failed: $_"
    }
}

# ==============================================================================
# 3. SECURE ASSET RETRIEVAL
# ==============================================================================
function Get-SandboxAssets {
    param (
        [string]$WorkingDir,
        [string]$UbuntuIso,
        [string]$CloudInitIso
    )
    Write-Log "Verifying static media assets in $WorkingDir..."

    try {
        if (-not (Test-Path -Path $UbuntuIso)) {
            Write-Log "Downloading Ubuntu 24.04 Server ISO..."
            Invoke-WebRequest -Uri "https://releases.ubuntu.com/resolute/ubuntu-24.04-live-server-amd64.iso" -OutFile $UbuntuIso -UseBasicParsing
            Write-Log "Ubuntu ISO download completed successfully." -Level "SUCCESS"
        }

        if (-not (Test-Path -Path $CloudInitIso)) {
            Write-Log "Downloading bootstrapping configuration (cidata.iso)..."
            # Replace placeholder with target static URL
            Invoke-WebRequest -Uri "https://github.com/henryhooverville/WeChat-sandbox/releases/download/latest/cidata.iso" -OutFile $CloudInitIso -UseBasicParsing
            Write-Log "cidata.iso download completed successfully." -Level "SUCCESS"
        }
    }
    catch {
        # Avoid caching broken/partially downloaded packages
        if (Test-Path -Path $UbuntuIso) { Remove-Item -Path $UbuntuIso -Force -ErrorAction SilentlyContinue }
        if (Test-Path -Path $CloudInitIso) { Remove-Item -Path $CloudInitIso -Force -ErrorAction SilentlyContinue }
        throw "Download Fault: Network asset collection timed out or was blocked. Details: $_"
    }
}

# ==============================================================================
# 4. HYPER-V VM PROVISIONING
# ==============================================================================
function New-SandboxVM {
    param (
        [string]$VMName,
        [long]$MemoryBytes,
        [int]$VHDSizeGB,
        [string]$VHDPath,
        [string]$SwitchName,
        [string]$UbuntuIso,
        [string]$CloudInitIso,
        [string]$GatewayIP
    )
    Write-Log "Building isolated virtual system structure..."

    try {
        if (-not (Get-VM -Name $VMName -ErrorAction SilentlyContinue)) {
            # Provision base VM config
            New-VM -Name $VMName -MemoryStartupBytes $MemoryBytes -Generation 2 -NewVHDPath $VHDPath -VHDSizeBytes ($VHDSizeGB * 1GB) -SwitchName $SwitchName | Out-Null
            Set-VM -Name $VMName -ProcessorCount 2
            Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplate "MicrosoftUEFICertificateAuthority"
            
            # Attach both ISO storage drives
            Add-VMDvdDrive -VMName $VMName -Path $UbuntuIso
            Add-VMDvdDrive -VMName $VMName -Path $CloudInitIso
            
            # Secure integration channels (Only change hardware variables at birth)
            Set-VM -VMName $VMName -EnhancedSessionTransportType HvSocket
            Disable-VMIntegrationService -VMName $VMName -Name "Guest Service Interface"
            
            Write-Log "Built VM container and attached system media disks." -Level "SUCCESS"
        } else {
            Write-Log "Target VM '$VMName' already exists. Skipping core hardware modification loops." -Level "INFO"
        }

        # Apply Zero-Trust Hypervisor Port ACL Boundaries (Safely runs hot on existing VMs)
        Write-Log "Verifying hypervisor layer egress ACL rules..."
        Remove-VMNetworkAdapterAcl -VMName $VMName -ErrorAction SilentlyContinue

        # Rule 1: Allow Layer-2 link mapping to the localized gateway
        Add-VMNetworkAdapterAcl -VMName $VMName -RemoteIPAddress $GatewayIP -Direction Outbound -Action Allow

        # Rule 2: Explicit stateless drops targeting any RFC1918 internal subnets
        Add-VMNetworkAdapterAcl -VMName $VMName -RemoteIPAddress "10.0.0.0/8" -Direction Outbound -Action Deny
        Add-VMNetworkAdapterAcl -VMName $VMName -RemoteIPAddress "172.16.0.0/12" -Direction Outbound -Action Deny
        Add-VMNetworkAdapterAcl -VMName $VMName -RemoteIPAddress "192.168.0.0/16" -Direction Outbound -Action Deny
        Write-Log "Hypervisor network ACL boundaries successfully applied." -Level "SUCCESS"
    }
    catch {
        throw "VM Setup Fault: $_"
    }
}

# ==============================================================================
# 5. ORCHESTRATION LAYER & FAULT RUNBOOK
# ==============================================================================
try {
    # Initialize the local directory to set up our logging path immediately
    if (-not (Test-Path -Path $WorkingDir)) {
        New-Item -ItemType Directory -Force -Path $WorkingDir | Out-Null
    }
    
    Write-Log "--------------------------------------------------"
    Write-Log "Starting WeChat Sandbox deployment run..."
    
    # Step A: Validate Prerequisites
    Test-SandboxPrerequisites

    # Setup Constants
    $SwitchName         = "wechat-switch"
    $NatName            = "wechat-nat-net"
    $GatewayIP          = "192.168.250.1"
    $SubnetPrefix       = "192.168.250.0/24"
    $VirtualAdapterName = "vEthernet ($SwitchName)"
    $VHDPath            = "$WorkingDir\$VMName.vhdx"
    $UbuntuIso          = "$WorkingDir\ubuntu-24.04-live-server-amd64.iso"
    $CloudInitIso       = "$WorkingDir\cidata.iso"

    $MemoryBytes = switch ($VMMemory) {
        "2GB"  { 2GB }
        "4GB"  { 4GB }
        "8GB"  { 8GB }
        "16GB" { 16GB }
        Default { 4GB }
    }

    # Step B: Secure storage pathing and fetch assets
    Get-SandboxAssets -WorkingDir $WorkingDir -UbuntuIso $UbuntuIso -CloudInitIso $CloudInitIso

    # Step C: Setup Hyper-V local NAT and virtual switches
    Initialize-SandboxNetwork -SwitchName $SwitchName -NatName $NatName -GatewayIP $GatewayIP -SubnetPrefix $SubnetPrefix -VirtualAdapterName $VirtualAdapterName

    # Step D: Construct the secure VM
    New-SandboxVM -VMName $VMName -MemoryBytes $MemoryBytes -VHDSizeGB $VHDSizeGB -VHDPath $VHDPath -SwitchName $SwitchName -UbuntuIso $UbuntuIso -CloudInitIso $CloudInitIso -GatewayIP $GatewayIP

    # Step E: Boot Sandbox VM
    Write-Log "Directing VM boot command..."
    Start-VM -VMName $VMName
    Write-Log "Secure isolated WeChat VM successfully deployed." -Level "SUCCESS"

    $ProgressPreference = $PreviousProgressPreference
    exit 0
}
catch {
    # Capture failure specifics cleanly
    $ErrorDetails = $_.Exception.Message
    $ErrorLine    = $_.InvocationInfo.ScriptLineNumber
    Write-Log "CRITICAL SANDBOX FAILURE: $ErrorDetails (Occurred on Line $ErrorLine)" -Level "ERROR"

    # RUNBOOK CLEANUP: Avoid leaving incomplete/unsecured systems running
    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
        Write-Log "Running Failure Cleanup: Destroying dirty sandbox VM configuration..." -Level "WARN"
        Stop-VM -Name $VMName -Force -ErrorAction SilentlyContinue
        Remove-VM -Name $VMName -Force -ErrorAction SilentlyContinue
        if (Test-Path -Path $VHDPath) { Remove-Item -Path $VHDPath -Force -ErrorAction SilentlyContinue }
    }

    $ProgressPreference = $PreviousProgressPreference
    exit 1
}
