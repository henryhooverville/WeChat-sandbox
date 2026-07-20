# Secure WeChat Sandbox (`wechat-sandbox`)

This project provides a cloud-native, automated framework for deploying a highly isolated, hardened Ubuntu VM on Windows 11 corporate desktops. The sole intent of this virtual machine is to host the native Linux WeChat client in a secure "sandbox" that cannot communicate with the local corporate network.

## Intent & Core Philosophy

Corporate environments often face a severe tension between **business enablement** (allowing employees to use WeChat for essential communications) and **network security** (mitigating the risk of an proprietary applications with data collection capabilities sitting laterally on a corporate network). 

This project resolves that tension by treating the local Windows 11 desktop as a hypervisor:
*   **Zero Trust Lateral Movement:** The VM is physically blocked at the hypervisor level from communicating with any internal private network (RFC1918).
*   **Appliance Design:** The VM is treated as a disposable appliance. It has no persistent administrative credentials, no local SSH server listening to the network, and is designed to be easily destroyed and redeployed by RMM if troubleshooting is required.
*   **User-Space Segregation:** The end-user operates inside a highly restricted, non-administrative guest profile, while the configuration of the VM is handled via declarative, immutable Infrastructure as Code (IaC).

---

## Architecture & System Interactions

The sandbox relies on a multi-layered boundary model where the host Windows OS, the hypervisor, the guest OS, and the local network interact under strict constraints:

### 1. The Network Gate (Hyper-V Port ACLs)
*   The VM is attached to a standard NAT switch on the Windows host to allow internet access.
*   Before the VM boots, the host applies stateless **Port Access Control Lists (ACLs)** to the VM’s virtual network card. 
*   These ACLs allow traffic destined for the public Internet (WAN) and explicitly whitelist public DNS servers (e.g., `8.8.8.8` and `208.67.222.222`).
*   The ACLs explicitly **Deny** all outbound traffic destined for private RFC1918 subnets (`10.0.0.0/8`, `172.16.0.0/12`, and `192.168.0.0/16`).

### 2. The Name Resolution Path (DNS Override)
*   Because the hypervisor blocks the VM from talking to any RFC1918 address, the VM cannot use the Windows Host's local gateway for DNS resolution.
*   During bootstrapping, Cloud-Init overrides the DHCP-provided DNS settings. It forces the guest OS to route its DNS queries directly to the public internet using the whitelisted public DNS servers.

### 3. The Presentation Layer (VSock Integration)
*   To keep the network completely closed while providing a seamless GUI, the VM uses **Hyper-V's Guest Integration Services via VSock**.
*   The guest OS runs a lightweight XFCE desktop wrapper and `xrdp` configured to listen on the hypervisor's internal virtual sockets instead of standard TCP network ports.
*   The end-user launches the Hyper-V Connection Manager (VMConnect). This establishes a GUI session directly over the hypervisor's physical bus, avoiding any local network routing.

---

## Deployment Lifecycle

1. **RMM Retrieval:** The RMM orchestrator pulls the standard Ubuntu Server ISO and your pre-compiled static `cidata.iso` to the target Windows 11 host.
2. **Host Configuration:** The RMM executes `deploy-vm.ps1` to create the VM shell, download and attach both ISOs, configure VSock, disable unneeded integration services, and apply the host-enforced Hyper-V Port ACLs.
3. **VM Boot & Bootstrap:** The VM is powered on. Cloud-Init mounts the `cidata.iso`, overrides DNS settings to use public servers, updates the package cache, and installs Ansible and Git.
4. **Declarative Hardening:** Cloud-Init clones your public `wechat-sandbox` repository and runs the local Ansible playbook to install the native WeChat client, set up XFCE/XRDP, and restrict user-space permissions.

## Configuration Options

To tailor this sandbox architecture for a specific corporate environment, a deployment engineer can modify specific environment variables across three interdependent infrastructure layers.

### 1. Infrastructure Sizing & Pathing Variables
These parameters control the resource footprint on the host machine and are located in the parameter block of **`deploy-vm.ps1`**:
*   **`$VMName`**: Dictates the display name assigned to the container inside Hyper-V Manager.
*   **`$VMMemory`**: Sets the system RAM limitation (e.g., `2GB`, `4GB`, `8GB`, `16GB`).
*   **`$VHDSizeGB`**: Configures the dynamic maximum storage boundary for the system.
*   **`$WorkingDir`**: Determines the file system directory on the Windows host where storage disks, installation ISOs, and orchestration logs are collected.

### 2. Network Topography & Isolation Settings
If your corporate network architecture already routes traffic across the default subnets, these parameters must be updated to prevent routing conflicts:
*   **`$SwitchName` & `$NatName` (`deploy-vm.ps1`)**: Naming tokens used by Windows to build the isolated virtual switch fabric.
*   **`$GatewayIP` & `$SubnetPrefix` (`deploy-vm.ps1`)**: Defines the internal translation boundary and binds the virtual router IP to the host interface.
*   **`network` block (`user-data`)**: Holds the matching static configurations (guest IP `addresses` and gateway `via` route) used by the Ubuntu installer to map WAN access.
*   **`nameservers` (`user-data`)**: Overrides network-provided name resolution to utilize secure public DNS servers directly over the WAN link.

### 3. Sourcing & Account Identifiers
*   **`git clone` URL (`user-data`)**: Located in the first-boot `runcmd` task block. Update this tracking path to reference your internal organization repository.
*   **`identity` schema (`user-data`)**: Declares the system credentials required to pass the primary automated setup stage (`sysadmin`). 
*   **`wechat-user` identity**: The non-administrative profile assigned to the end-user. For a functional out-of-band login chain, the user account's shadow password hash inside the guest profile configuration must correspond perfectly to the plain text authentication properties defined within the XRDP application configuration file.

---

### Cross-Layer Dependency Matrix
When modifying the core environmental variables, ensure changes are consistently applied across all corresponding files to maintain system integrity:

| Target Property | Source Implementation | Required Dependency | Operational Rationale |
| :--- | :--- | :--- | :--- |
| **Subnet Gateway IP** | `deploy-vm.ps1` | `user-data`, `playbook.yml` | The guest routing table and the internal network firewall parameters must match the host-side translation adapter. |
| **System Hostname** | `deploy-vm.ps1` | `meta-data`, `user-data` | Hyper-V provisioning modules and first-stage configuration records must reference matching metadata strings to align host logging. |
| **Target Guest User** | `user-data` | `playbook.yml` | Display manager automation files, application shortcuts, and unprivileged permission models are bound to specific home directories. |
