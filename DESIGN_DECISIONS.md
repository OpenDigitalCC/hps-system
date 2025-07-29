# Design Decisions

## Choice of File System for iSCSI Export: ZFS vs. Btrfs

**Decision:**  
We selected **ZFS** as the primary file system for our iSCSI export volumes.

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

---

*This decision may be revisited as OpenZFS support for RHEL 10 matures or new technologies emerge.*


