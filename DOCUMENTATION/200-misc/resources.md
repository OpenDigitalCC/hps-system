## External resources

Below are external projects, code repositories, and documentation sources that are relevant to HPS.  
These provide additional background, tooling, or dependencies that are either directly used or referenced in the design.


### Btrfs

**Link:** https://btrfs.readthedocs.io

**Summary:** Linux file system with features such as snapshots, compression, and subvolumes. Considered for HPS storage but not selected as the primary iSCSI export filesystem.

### dnsmasq

**Link:** http://www.thekelleys.org.uk/dnsmasq/doc.html

**Summary:** Lightweight DNS forwarder and DHCP server used in HPS to provide PXE boot services, static leases, and local DNS.

### Docker

**Link:** https://docs.docker.com

**Summary:** Containerisation platform used to run the HPS environment (`hps-container`) in a controlled, reproducible manner.

### iPXE

**Link:** https://ipxe.org

**Summary:** Open-source network boot firmware supporting PXE, HTTP, iSCSI, and scripting. HPS uses iPXE binaries (`ipxe.efi`, `undionly.kpxe`, `snponly.efi`) for boot menus and network installs.

### ISO images for Rocky Linux

**Link:** https://download.rockylinux.org/pub/rocky/

**Summary:** Official Rocky Linux distribution media. HPS uses these ISOs to populate PXE boot trees and perform installations.

### Kickstart documentation

**Link:** https://pykickstart.readthedocs.io

**Summary:** Red Hat-based distributions’ automated installation system. Kickstart files are used in HPS to perform unattended OS deployments.

### OpenSVC

**Link:** https://www.opensvc.com

**Summary:** Cluster resource manager and service orchestrator considered for integration with HPS for managing ZFS-backed iSCSI storage and service failover.

### Pandoc

**Link:** https://pandoc.org

**Summary:** Document converter used to compile HPS Markdown documentation into PDF, HTML, and other formats.

### PXE specification

**Link:** https://en.wikipedia.org/wiki/Preboot_Execution_Environment

**Summary:** Standard network boot process for x86 systems. HPS extends PXE with iPXE for additional protocol support and boot menu scripting.

### Rocky Linux

**Link:** https://rockylinux.org

**Summary:** Enterprise-grade Linux distribution used as a primary OS target in HPS deployments.

### syslog protocol (RFC 5424)

**Link:** https://datatracker.ietf.org/doc/html/rfc5424

**Summary:** Standard for message logging in IP networks. HPS services can log via syslog for centralised collection.

### TFTP

**Link:** https://datatracker.ietf.org/doc/html/rfc1350

**Summary:** Simple file transfer protocol used to serve PXE/iPXE bootloaders and configuration files to network boot clients.

### ZFS on Linux (OpenZFS)

**Link:** https://openzfs.org

**Summary:** Advanced file system and volume manager selected for HPS storage exports due to native block device (zvol) support, snapshots, and data integrity features.

