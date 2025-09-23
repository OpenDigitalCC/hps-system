# Design Decisions

## Choice of boot firmware: UEFI vs legacy BIOS for diskless servers

Decision  
: **Legacy BIOS** selected as the boot firmware mode for diskless servers.

### Rationale:

- Using UEFI with iSCSI-backed ZFS volumes in a RAID1 configuration was found to add **significant complexity** to the boot process, especially around firmware-level RAID support and driver requirements.
- Legacy BIOS booting is **simpler and more predictable** in a diskless environment, particularly when boot devices are provided as iSCSI LUNs managed at the client level with MD RAID.
- Secure Boot provides little additional value in this scenario since the root disk is remote (iSCSI) and already subject to provisioning controls in HPS, making the complexity of UEFI+Secure Boot unjustified.
- By avoiding UEFI, the system benefits from a **cleaner, more robust boot path** with fewer moving parts, reducing risk during provisioning and recovery.

### Trade-offs and compromises:

- Some modern hardware platforms are increasingly UEFI-centric, and relying on BIOS boot mode may limit compatibility with certain devices in the future.
- Secure Boot cannot be leveraged for kernel validation in this model, which may be a requirement in highly regulated environments.
- Legacy BIOS lacks some advanced features of UEFI such as larger boot volume support and graphical configuration menus, though these are not critical for diskless servers.

### Alternatives considered:

- **UEFI with Secure Boot** – Provides firmware-level kernel verification but introduces bootloader and driver complexity with limited real-world benefit for iSCSI-booted, diskless nodes.
- **UEFI without Secure Boot** – Simplifies compared to full Secure Boot but still adds no significant functional gain for this scenario, while retaining complexity.
- **Mixed mode** – Maintaining both BIOS and UEFI boot paths was considered but rejected as it increases maintenance burden without improving robustness.

### Summary:

For diskless servers provisioned by HPS, **Legacy BIOS booting was chosen** as it avoids unnecessary UEFI complexity and delivers a simpler, more reliable boot process. Secure Boot does not meaningfully strengthen security in this architecture, where the root filesystem is centrally provisioned over iSCSI.  



## Choice of File System for iSCSI Export: ZFS vs. Btrfs

Decision
: **ZFS** selected as the primary file system for our iSCSI export volumes.

### Rationale:

- **ZFS supports native block devices (zvols),** allowing direct and efficient exports of block storage over iSCSI. This feature aligns well with our requirement for reliable, performant SAN/NAS workflows.
- ZFS provides **native, atomic snapshots and cloning** of zvols, enhancing backup and provisioning capabilities crucial for production environments.
- Its robust data integrity features (checksumming, self-healing), advanced caching, and mature RAID implementations contribute to enterprise-grade reliability and performance.

### Trade-offs and Compromises:

- There is a **license incompatibility** between ZFS and the Red Hat ecosystem, meaning ZFS packages are not officially supported or included in RHEL distributions.
- As a result, ZFS must currently be **built from source or installed from third-party repositories**, adding complexity to deployment and ongoing maintenance.
- This introduces a support risk and necessitates additional operational effort compared to fully integrated Linux-native options.

### Alternatives Considered:

- **Btrfs** was a close second due to its strong native support for snapshots, flexibility in resizing and tuning volumes on the fly, and better Linux kernel integration.
- However, **Btrfs lacks native block device export (no zvol equivalent),** forcing us to use file-backed iSCSI LUNs that generally perform less optimally and do not offer atomic snapshot capabilities at the block layer.
- Other Linux file systems (XFS, Ext4, Stratis) were evaluated but do not meet the combination of flexibility, native snapshot, and block device export requirements.

### Summary:

While recognizing the complexity introduced by licensing and packaging constraints, **ZFS was chosen because it directly meets the core technical needs of efficient iSCSI block exports, robust snapshotting, and enterprise reliability.** Btrfs remains a strong alternative for scenarios prioritizing Linux-native integration and flexibility but is currently less ideal for our iSCSI workload due to the lack of native block device support.

*This decision may be revisited as OpenZFS support for RHEL 10 matures or new technologies emerge.*

## Choice of Base OS Deployment Method: Pre-Built Image vs. Fresh Install

Decision  
: **Fresh install** selected as the primary method for deploying the base operating system.

### Rationale:

- **Fresh installs ensure hardware compatibility** by using the installer’s latest kernel and driver set, reducing the risk of missing support for new or varied hardware configurations.  
- Installing at provisioning time allows **security updates and package fixes** from the local mirror or upstream sources to be applied immediately, avoiding staleness issues inherent in pre-built images.  
- The process starts from a **clean, reproducible configuration** defined by Kickstart or Preseed, eliminating unintended artifacts, logs, or credentials that may remain in captured images.  

### Trade-offs and Compromises:

- Fresh installs are **slower** than restoring a pre-built image, especially on large systems or when provisioning many hosts concurrently.  
- The process **relies on functioning installer infrastructure** (DHCP/TFTP/HTTP and repository availability) at the time of deployment.  
- There is **less bit-for-bit uniformity** compared to image-based deployment, as package versions may vary if mirrors are updated between installs.  

### Alternatives Considered:

- **Pre-built images** offer faster deployment and consistent results but can quickly become outdated, require additional effort to rebuild for each hardware or OS variant, and carry a higher risk of incompatibility if built on different hardware.  
- Pre-built images may also include **unwanted residual configuration or data** unless carefully cleaned before capture, increasing operational risk.  
- A **hybrid approach**—maintaining a fresh-install workflow while offering image duplication for identical hardware—was identified as a potential enhancement for high-speed redeployment in specific scenarios.  

### Summary:

While acknowledging the speed advantages of image-based deployment, **fresh installs were chosen for their hardware adaptability, up-to-date software, and clean configuration state**. The reduced risk of compatibility issues and the ability to apply updates during provisioning outweigh the longer install time in our current environment. 
 
We will explore the feasibility of adding a controlled image duplication process to complement the standard fresh-install workflow for cases where rapid redeployment on identical hardware is beneficial.  

