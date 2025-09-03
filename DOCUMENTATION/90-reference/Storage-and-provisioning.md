## Storage configuration

This section describes how storage is provisioned and managed within HPS.  
It covers the role of ZFS, iSCSI exports, and the functions used to configure storage cluster hosts (SCHs) and thin compute nodes (TCNs).

---

### Overview

HPS provides storage to diskless compute nodes via **ZFS-backed iSCSI exports**.  
Rather than replicating data at the storage back-end, redundancy is achieved through **client-side RAID** on the TCNs. This design keeps the storage back-end simple (“just a bunch of block devices”) and allows flexible RAID layouts on the client.

---

### Functions and building blocks

Several library functions are provided to initialise and manage storage nodes:

- **remote_log**  
  Sends log output from a remote node back to the provisioning system.

- **remote_cluster_variable** and **remote_host_variable**  
  Used to read and update cluster-level and host-level configuration variables across the environment.

- **initialise_opensvc_cluster**  
  Prepares an OpenSVC cluster context for managing storage resources.

- **load_opensvc_conf**  
  Loads the OpenSVC configuration to ensure cluster services are consistent across nodes.

- **ZFS install and configure functions**  
  Automate installation of ZFS, creation of zpools, and export of zvols for use as iSCSI devices.

Additional functions can be added over time. These are distributed to remote nodes (e.g. TCNs and SCNs) and sourced locally so they can operate with the same provisioning logic as the HPS controller.

---

### Host configuration variables

The iSCSI devices used by each thin compute node are defined in the host configuration.  
Two key variables are:

- **ISCSI_ROOT_0**  
- **ISCSI_ROOT_1**

These identify the iSCSI targets that provide the root disks for the TCN.  
When a TCN is first configured, these variables are created and stored in its host config.

Future expansions will allow additional variables such as **ISCSI_DATA_N** to define data disks for workloads running on the TCN.

---

### Provisioning workflow

1. **SCN setup**  
   Storage cluster hosts are provisioned with ZFS and OpenSVC. ZFS zpools and zvols are created as needed for iSCSI targets.

2. **TCN request**  
   When a thin compute node is being installed, the provisioning system determines its storage requirements and allocates ISCSI_ROOT variables.

3. **OpenSVC orchestration**  
   OpenSVC is instructed to create the relevant iSCSI targets on one or more SCNs. These zvol-backed targets are exported over the storage network.

4. **Client RAID**  
   The TCN combines the iSCSI devices into a RAID set (e.g. RAID1 using `mdadm`) to provide redundancy. This allows failover if one SCN becomes unavailable.

5. **Installation**  
   The TCN OS is installed directly onto the iSCSI-backed RAID devices, making it fully diskless and resilient to back-end failures.

6. **Expansion**  
   Additional iSCSI targets can later be provisioned for data disks and attached to the TCN as needed.

---

### Future extensions

- Automated provisioning of **ISCSI_DATA** targets for application and workload storage.  
- Enhanced ZFS tuning (e.g. `volblocksize`, `compression`, `logbias`) to optimise for specific workloads.  
- Integration of monitoring hooks so that OpenSVC and HPS can track zpool health and iSCSI target performance.  
- Support for flexible RAID scenarios where high-value services use multiple SCNs while low-cost services may only rely on a single disk.

---

### Acronyms

- **SCN** – Storage cluster node (storage host).  
- **TCN** – Thin compute node (diskless compute host).  
- **ZFS** – Advanced file system and volume manager used for iSCSI backing.  
- **iSCSI** – Protocol that exports block storage devices over a TCP/IP network.  
- **OpenSVC** – Cluster manager and orchestrator used to control zvol exports and failover behaviour.

