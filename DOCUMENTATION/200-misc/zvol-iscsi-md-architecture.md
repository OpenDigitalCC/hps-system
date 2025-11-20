# ZFS/iSCSI/MD RAID Architecture Guide

## Overview

This architecture provides resilient storage for KVM virtualization environments using ZFS on the storage server, iSCSI for network block storage transport, and MD RAID for host-level redundancy.

## Architecture Components

### 1. Storage Server Layer

Hardware:

- 2× 12TB IronWolf drives (mirror-0)
- 1× NVMe drive partitioned for:
  - SLOG (ZIL): 18.5GB partition (nvme0n1p4)
  - L2ARC: 93GB partition (nvme0n1p5)
- 2.5GbE network interface

ZFS Configuration:
```bash
Pool: storage
├── mirror-0 (data vdevs)
│   ├── ata-ST12000VN0008-2YS101_ZRT2KAHX
│   └── ata-ST12000VN0008-2YS101_ZRT2K4VV
├── logs (SLOG)
│   └── nvme0n1p4
└── cache (L2ARC)
    └── nvme0n1p5
```

iSCSI Target Configuration:

- Service: targetcli (LIO)
- Protocol: iSCSI over TCP port 3260
- Authentication: Disabled for lab (enable ACLs in production)
- Backing stores: ZFS zvols

Creating iSCSI LUNs:
```bash
# Using management script
sudo /usr/local/bin/iscsi-lun.sh create <name> <size>

# Example
sudo iscsi-lun.sh create vm-disk01 100G
```

### 2. KVM Host Layer

Network:

- 2.5GbE connection to storage server
- IP: 192.168.125.x

iSCSI Initiator:
```bash
# Discovery
sudo iscsiadm -m discovery -t st -p <storage-server-ip>

# Login to specific target
sudo iscsiadm -m node -T iqn.2024-11.local.storage-01:<name> -l

# Check sessions
sudo iscsiadm -m session
```

MD RAID Configuration:
```bash
# Create mirror across two iSCSI LUNs
sudo mdadm --create /dev/md1 \
  --level=1 \
  --raid-devices=2 \
  --bitmap=internal \
  /dev/sdX /dev/sdY

# Format and mount
sudo mkfs.ext4 /dev/md1
sudo mount /dev/md1 /mnt/storage
```

Key Points:

- RAID members should be from DIFFERENT iSCSI targets
- Verify device sizes match before creating RAID
- Use write-intent bitmap for faster recovery

### 3. Virtual Machine Layer

Disk Attachment:
```bash
# Attach RAID device to VM
sudo virsh attach-disk <vm-name> /dev/md1 vdb \
  --driver qemu --subdriver raw --type block --live
```

Inside VM:
```bash
# Format and mount
sudo mkfs.ext4 /dev/vdb
sudo mkdir /mnt/data
sudo mount /dev/vdb /mnt/data
```

## Managing Storage Outages

### Scenario 1: Single iSCSI Target Failure

Detection:

- MD RAID transitions to degraded mode `[U_]`
- dmesg shows I/O errors
- One RAID member marked as faulty

KVM Host Response:
```bash
# Monitor RAID status
watch cat /proc/mdstat

# Check for failed devices
sudo mdadm --detail /dev/md1
```

Recovery Steps:

1. Fix storage server issue
2. Re-enable iSCSI target
3. Device reconnects (may have new name)
4. Add device back to RAID:
```bash
sudo mdadm --manage /dev/md1 --add /dev/sdX
```
5. Monitor rebuild: `watch cat /proc/mdstat`

VM Impact:

- ✅ Continues operation normally
- ⚠️ Write performance may degrade slightly
- ⚠️ No redundancy until rebuild completes

### Scenario 2: Storage Server Network Failure

Symptoms:

- All iSCSI sessions timeout
- Multiple devices fail
- RAID may fail completely if both members affected

Prevention:

- Use multipath in production
- Separate network paths for each RAID member
- Configure appropriate iSCSI timeout values

### Scenario 3: ZFS Volume Issues

If zvol becomes unavailable:
```bash
# On storage server - check volmode
zfs get volmode storage/iscsi-<name>

# Should be "dev" - if not:
sudo zfs set volmode=dev storage/iscsi-<name>

# Trigger udev
sudo udevadm trigger --subsystem-match=block

# Recreate backstore if needed
sudo targetcli backstores/block create name=<name> \
  dev=/dev/zvol/storage/iscsi-<name>
```

## Critical Safety Rules

### Device Management

DO:

- ✅ Logout specific targets: `sudo iscsiadm -m node -T <target> -u`
- ✅ Verify device sizes before RAID creation
- ✅ Use `lsblk -o NAME,SIZE,TYPE` to identify devices
- ✅ Keep VM root disks on separate LUNs from RAID members

DON'T:

- ❌ Use `iscsiadm -m session -u` (logs out ALL sessions)
- ❌ Include VM boot disks in test RAID arrays
- ❌ Stop RAID arrays while VMs are writing
- ❌ Restart storage server target service during production

### Monitoring

Essential checks:
```bash
# On storage server
zpool status storage
zpool iostat -v storage 2

# On KVM host
cat /proc/mdstat
sudo mdadm --detail /dev/md1
sudo iscsiadm -m session

# Track performance
arcstat 2  # ZFS ARC statistics
dstat -cdngy --disk-util --io 2
```

## Production Recommendations

1. Dual Storage Servers:

   - Mirror RAID across separate physical servers
   - Each member on different server = survive server failure
   - Requires 2× 10GbE per host for bandwidth

2. Network Redundancy:

   - Bonded interfaces (LACP)
   - Multipath iSCSI configuration
   - Separate VLANs for storage traffic

3. Monitoring:

   - Monit/Nagios for disk health
   - MD RAID status alerts
   - ZFS pool health checks
   - iSCSI session monitoring

4. SLOG Redundancy:

   - Mirror SLOG devices (2× NVMe)
   - Critical for data integrity
   - Loss of SLOG = potential data loss on power failure

5. Capacity Planning:

   - L2ARC sizing: 5-10× working set size
   - SLOG sizing: ~5 seconds of write traffic
   - Network bandwidth: 2× expected peak load

## Management Scripts

iSCSI LUN Management:
Located at `/usr/local/bin/iscsi-lun.sh`

```bash
# Create LUN
sudo iscsi-lun.sh create <identifier> <size>

# Remove LUN
sudo iscsi-lun.sh remove <identifier>

# List all LUNs
sudo iscsi-lun.sh list
```

## Troubleshooting

iSCSI connection issues:
```bash
# Check network connectivity
ping <storage-server>

# Verify target service running
sudo systemctl status target

# Check firewall (port 3260)
sudo ss -tlnp | grep 3260
```

RAID won't accept device:
```bash
# Clear stale superblock
sudo mdadm --zero-superblock /dev/sdX

# Or wipe completely
sudo wipefs -a /dev/sdX
```

Device name confusion:
```bash
# Use persistent device paths
ls -l /dev/disk/by-path/

# Or by-id for more stable names
ls -l /dev/disk/by-id/
```
