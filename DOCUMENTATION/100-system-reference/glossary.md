## Glossary

## Glossary

Btrfs  
: A modern Linux file system with support for snapshots, pooling, and checksumming. Considered for HPS storage but not selected due to lack of native block device export.

CCH (Compute Cluster Host)  
: A host profile type in HPS representing a node dedicated to compute workloads.

CIDR (Classless Inter-Domain Routing)  
: A method for allocating IP addresses and routing, using a prefix length (e.g. `/24`) to indicate the network mask.

DHCP (Dynamic Host Configuration Protocol)  
: Network protocol that automatically assigns IP addresses and other network settings to devices on a network.

DHCP interface  
: The network interface on which HPS's DHCP service (dnsmasq) listens to respond to PXE boot and other client requests.

DHCP range  
: The range of IP addresses available for assignment via DHCP in a given network segment.

DHCP reservation  
: A mapping of a specific MAC address to a fixed IP address in the DHCP server configuration.

DHCP server  
: A service that hands out IP addresses and network configuration to clients; in HPS, typically provided by dnsmasq.

DHCP subnet  
: The network segment configuration for DHCP, usually defined by IP address and netmask/CIDR.

DHCP static lease  
: A lease configuration mapping a specific client to a specific IP, without dynamic changes.

DHCP options  
: Additional configuration data sent by DHCP server to clients (e.g., boot file name, domain name, DNS servers).

DHCP vendor class identifier  
: A DHCP field that can identify the client’s hardware or software type.

DHCP relay  
: A service that forwards DHCP requests from clients in one network to a DHCP server in another network.

DHCP snooping  
: A network switch feature that limits DHCP responses to trusted ports.

DHCP starvation  
: An attack in which an attacker sends repeated DHCP requests to exhaust the available address pool.

DHCPDISCOVER  
: DHCP message type sent by clients to find available DHCP servers.

DHCPOFFER  
: DHCP message type sent by servers in response to a DHCPDISCOVER, offering an IP configuration.

DHCPREQUEST  
: DHCP message type sent by clients to request offered configuration.

DHCPACK  
: DHCP message type sent by the server to confirm an IP lease to the client.

dnsmasq  
: Lightweight DNS forwarder and DHCP server used by HPS to provide PXE boot and local DNS services.

DR node (Disaster Recovery node)  
: A dedicated node used to provide failover capability and data recovery in the event of a primary node failure.

DRH (Disaster Recovery Host)  
: Host profile type in HPS representing a disaster recovery node.

HPS (Host Provisioning Service)  
: The provisioning framework implemented in this project for automated PXE-based OS deployment and configuration.

HPS container  
: The Docker container providing the HPS services.

HPS config  
: The configuration directory structure for HPS, stored separately from the core scripts to allow upgrades without overwriting site-specific settings.

HPS system  
: The set of Bash scripts, functions, and service configurations that implement the HPS provisioning environment.

iPXE  
: Open-source network boot firmware supporting protocols such as HTTP, iSCSI, and PXE. Used by HPS for dynamic boot menus and provisioning.

ISO (International Organization for Standardization image file)  
: A disk image format commonly used to distribute operating system installation media.

Kickstart  
: Automated installation method used by Red Hat-based distributions, configured via a `.ks` file.

MAC address  
: Media Access Control address, a unique identifier assigned to a network interface.

NFS (Network File System)  
: Protocol for sharing files over a network, not used for boot in HPS but sometimes relevant for Linux provisioning.

PXE (Preboot eXecution Environment)  
: Network boot framework that allows a system to boot from a network interface before an OS is installed.

PXE boot menu  
: The interactive menu shown to PXE/iPXE clients to select a boot option.

SCH (Storage Cluster Host)  
: Host profile type in HPS representing a node dedicated to storage services.

syslog  
: Standardised system logging protocol used to collect logs from services.

TCH (Thin Compute Host)  
: Host profile type in HPS representing a lightweight compute node.

TFTP (Trivial File Transfer Protocol)  
: Simple file transfer protocol used in PXE boot to transfer bootloaders and configuration.

ZFS  
: Advanced file system with volume management, snapshots, and data integrity features. Selected in HPS for iSCSI exports due to native zvol support.

