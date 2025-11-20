# Storage Disaster Recovery Runbook

## Purpose

This runbook provides example step-by-step procedures for recovering from storage failures in a ZFS/iSCSI/MD RAID environment. Follow procedures carefully and in order.

---

## Pre-Incident Preparation

### Required Information

Document and keep updated:

```bash
# Storage server details
STORAGE_IP=192.168.125.116
STORAGE_POOL=storage

# KVM host details
KVM_HOST_IP=192.168.125.x
KVM_HOST_NAME=s01

# VM details
VM_NAME=sjm-explore
VM_BOOT_DISK=/dev/sda (iSCSI: lun01)
VM_DATA_DISK=/dev/vdb (MD RAID: md1)

# RAID configuration
RAID_DEVICE=/dev/md1
RAID_MEMBER_1=/dev/sdb (iqn:test01)
RAID_MEMBER_2=/dev/sdc (iqn:test02)
```

### Monitoring Commands

Keep these commands ready:

```bash
# On storage server
zpool status storage
zpool iostat -v storage 2
sudo targetcli ls

# On KVM host
cat /proc/mdstat
sudo mdadm --detail /dev/md1
sudo iscsiadm -m session
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT

# System-wide
dmesg -T | tail -50
sudo systemctl status target
```

---

## Scenario 1: Single iSCSI Target Failure

### Symptoms

- MD RAID shows degraded state `[U_]`
- One device in RAID marked as faulty or removed
- dmesg shows I/O errors on specific device
- VM continues operation (may be slightly slower)

### Diagnosis

**On KVM host:**
```bash
# Check RAID status
cat /proc/mdstat
sudo mdadm --detail /dev/md1

# Identify failed device
dmesg | grep -i "error" | tail -20

# Check iSCSI sessions
sudo iscsiadm -m session -P 3 | grep -E "Target:|State:|Attached"
```

**On storage server:**
```bash
# Check ZFS pool health
zpool status storage

# Check target status
sudo targetcli ls /iscsi

# Verify zvol accessibility
ls -lh /dev/zvol/storage/iscsi-*
```

### Recovery Procedure

#### Step 1: Identify Root Cause

**If ZFS error:**
```bash
# Check pool errors
zpool status -v storage

# Clear transient errors (if applicable)
sudo zpool clear storage

# Scrub if needed
sudo zpool scrub storage
```

**If zvol missing:**
```bash
# Check volmode
zfs get volmode storage/iscsi-<identifier>

# Fix if needed
sudo zfs set volmode=dev storage/iscsi-<identifier>

# Trigger device creation
sudo udevadm trigger --subsystem-match=block

# Verify
ls -lh /dev/zvol/storage/iscsi-<identifier>
```

**If target configuration issue:**
```bash
# Recreate backstore
sudo targetcli

/> backstores/block create name=<identifier> \
   dev=/dev/zvol/storage/iscsi-<identifier> readonly=False

/> iscsi/<target-iqn>/tpg1/luns create /backstores/block/<identifier>

/> exit
```

#### Step 2: Reconnect on KVM Host

```bash
# Logout from specific target
sudo iscsiadm -m node -T <target-iqn> -u

# Wait 5 seconds
sleep 5

# Login again
sudo iscsiadm -m node -T <target-iqn> -l

# Verify device appeared
lsblk | grep 10G
dmesg | tail -10
```

#### Step 3: Re-add to RAID

```bash
# Identify which device came back (sdb, sdc, sdd, etc.)
NEW_DEVICE=/dev/sdX  # Replace X

# Test device is accessible
sudo dd if=$NEW_DEVICE of=/dev/null bs=1M count=10 iflag=direct

# If OLD superblock exists, clean it
sudo mdadm --zero-superblock $NEW_DEVICE

# Add back to array
sudo mdadm --manage /dev/md1 --add $NEW_DEVICE

# Monitor rebuild
watch cat /proc/mdstat
```

#### Step 4: Verify Recovery

```bash
# Wait for rebuild to complete
# Status should show [UU]

# Check final state
sudo mdadm --detail /dev/md1

# Verify no errors
dmesg | grep -i error | tail -20

# Test write performance
sudo dd if=/dev/zero of=/dev/md1 bs=1M count=100 oflag=direct
```

### Expected Timeline

- Detection: Immediate to 2 minutes
- Diagnosis: 2-5 minutes
- Repair: 5-10 minutes
- Rebuild (10GB): 5-10 minutes
- **Total: 15-30 minutes**

---

## Scenario 2: Complete Storage Server Network Failure

### Symptoms

- All iSCSI sessions disconnect
- Multiple/all RAID arrays fail
- VMs freeze or crash if boot disks affected
- Network unreachable errors

### Diagnosis

**On KVM host:**
```bash
# Check iSCSI sessions
sudo iscsiadm -m session
# May show no sessions

# Test network connectivity
ping $STORAGE_IP

# Check RAID status
cat /proc/mdstat
# May show [__] or stopped

# Check VM status
sudo virsh list --all
```

### Recovery Procedure

#### Step 1: Restore Network

**Verify physical connectivity:**

- Check cables
- Check switch ports
- Verify network interface up on storage server

**On storage server:**
```bash
# Check network interface
ip addr show
sudo systemctl status networking

# Test from storage server to KVM host
ping $KVM_HOST_IP

# Verify iSCSI service listening
sudo ss -tlnp | grep 3260
```

#### Step 2: Reconnect iSCSI Sessions

**On KVM host:**
```bash
# Attempt to reconnect all targets
sudo iscsiadm -m node -l

# If that fails, try manual reconnection
sudo iscsiadm -m discovery -t st -p $STORAGE_IP
sudo iscsiadm -m node -l

# Verify sessions restored
sudo iscsiadm -m session
```

#### Step 3: Assess RAID Damage

```bash
# Check all RAID arrays
cat /proc/mdstat

# For each degraded array:
sudo mdadm --detail /dev/mdX

# Identify missing devices
lsblk -o NAME,SIZE,TYPE
```

#### Step 4: Rebuild RAIDs

**For each RAID array:**

```bash
# If RAID is stopped, try to assemble
sudo mdadm --assemble /dev/md1 /dev/sdX /dev/sdY

# If only one device missing, add it back
sudo mdadm --manage /dev/md1 --add /dev/sdX

# Monitor rebuild
watch cat /proc/mdstat
```

#### Step 5: Recover VMs

**If VMs are down:**

```bash
# Check VM state
sudo virsh list --all

# Attempt to start
sudo virsh start $VM_NAME

# Monitor logs
sudo virsh console $VM_NAME
# Or
tail -f /var/log/libvirt/qemu/$VM_NAME.log
```

### Expected Timeline

- Network restoration: 5-30 minutes (depends on root cause)
- iSCSI reconnection: 2-5 minutes
- RAID assessment: 5-10 minutes
- RAID rebuild: 30-120 minutes (depends on size)
- VM recovery: 5-15 minutes
- **Total: 1-3 hours**

---

## Scenario 3: ZFS Pool Degraded or Failed

### Symptoms

- `zpool status` shows DEGRADED or FAULTED
- Disk errors in dmesg
- I/O performance severely degraded
- iSCSI targets may become read-only or unavailable

### Diagnosis

```bash
# On storage server
zpool status -v storage

# Check for disk errors
dmesg | grep -i "ata\|scsi\|error"

# Check SMART status
sudo smartctl -a /dev/disk/by-id/<disk-id>

# Verify both mirror members
ls -lh /dev/disk/by-id/ | grep ST12000
```

### Recovery Procedure - Mirror Member Failure

#### Step 1: Identify Failed Disk

```bash
# Check pool status
zpool status storage

# Note which disk shows FAULTED or UNAVAIL
# Example: ata-ST12000VN0008-2YS101_ZRT2KAHX
```

#### Step 2: Replace Disk (Hot Swap if Supported)

**Physical replacement:**

1. Identify physical disk bay
2. Power down if hot-swap not supported
3. Replace failed disk
4. Power on / wait for disk detection

#### Step 3: Resilver New Disk

```bash
# Replace in pool
sudo zpool replace storage \
  ata-ST12000VN0008-2YS101_OLDSERIAL \
  ata-ST12000VN0008-2YS101_NEWSERIAL

# Monitor resilver
watch zpool status storage

# Check progress
zpool status -v storage | grep -i resilver
```

#### Step 4: Verify Pool Health

```bash
# After resilver completes
zpool status storage
# Should show ONLINE

# Scrub to verify
sudo zpool scrub storage

# Monitor scrub
watch zpool status storage
```

### Expected Timeline

- Diagnosis: 5-10 minutes
- Physical replacement: 15-60 minutes
- Resilver (12TB): 6-12 hours
- Scrub: 4-8 hours
- **Total: 12-24 hours**

---

## Scenario 4: Corrupted MD RAID Metadata

### Symptoms

- `mdadm --detail` fails with "cannot load array metadata"
- RAID shows as "broken" or "inactive"
- Devices exist but RAID won't recognize them
- State shows FAILED despite devices being present

### Diagnosis

```bash
# Check RAID status
cat /proc/mdstat
sudo mdadm --detail /dev/md1

# Examine individual devices
sudo mdadm --examine /dev/sdb
sudo mdadm --examine /dev/sdc

# Check for UUID mismatches
```

### Recovery Procedure

⚠️ **WARNING: This procedure risks data loss. Only proceed if:**
- You have backups
- Data is non-critical (test environment)
- All other options exhausted

#### Step 1: Attempt Metadata Repair

```bash
# Stop the array
sudo umount /mnt/raid
sudo mdadm --stop /dev/md1

# Try to reassemble with --force
sudo mdadm --assemble --force /dev/md1 /dev/sdb /dev/sdc

# If successful, verify
sudo mdadm --detail /dev/md1
```

#### Step 2: If Repair Fails - Rebuild from One Good Member

```bash
# Identify which device has valid data
sudo mdadm --examine /dev/sdb
sudo mdadm --examine /dev/sdc

# Stop array
sudo mdadm --stop /dev/md1

# Assemble with single device
sudo mdadm --assemble /dev/md1 /dev/sdb --run

# Verify data is accessible
sudo fsck -n /dev/md1
sudo mount -o ro /dev/md1 /mnt/test

# If data looks good:
sudo umount /mnt/test

# Clean the second device
sudo wipefs -a /dev/sdc

# Add it back
sudo mdadm --manage /dev/md1 --add /dev/sdc

# Monitor rebuild
watch cat /proc/mdstat
```

#### Step 3: If Both Devices Corrupted - Complete Rebuild

```bash
# ⚠️ THIS DESTROYS ALL DATA

# Stop array
sudo mdadm --stop /dev/md1

# Clean both devices
sudo wipefs -a /dev/sdb
sudo wipefs -a /dev/sdc

# Recreate array
sudo mdadm --create /dev/md1 \
  --level=1 \
  --raid-devices=2 \
  --bitmap=internal \
  /dev/sdb /dev/sdc

# Format
sudo mkfs.ext4 /dev/md1

# Restore from backup
# (Implementation depends on backup strategy)
```

### Expected Timeline

- Diagnosis: 10-20 minutes
- Metadata repair attempt: 10-15 minutes
- Single-device reassembly: 15-30 minutes
- Rebuild: 30-120 minutes
- Complete rebuild + restore: 2-6 hours
- **Total: 1-6 hours**

---

## Scenario 5: VM Cannot Access Storage

### Symptoms

- VM shows I/O errors
- Applications freeze or timeout
- Files become inaccessible
- Filesystem goes read-only

### Diagnosis

**Inside VM:**
```bash
# Check filesystem status
mount | grep vdb
df -h

# Check for errors
dmesg | grep -i "error\|i/o"

# Test device access
sudo dd if=/dev/vdb of=/dev/null bs=1M count=10 iflag=direct
```

**On KVM host:**
```bash
# Check RAID status
cat /proc/mdstat
sudo mdadm --detail /dev/md1

# Verify disk attachment to VM
sudo virsh domblklist $VM_NAME

# Check libvirt logs
tail -f /var/log/libvirt/qemu/$VM_NAME.log
```

### Recovery Procedure

#### Step 1: Identify Layer of Failure

Test each layer bottom-up:

```bash
# On KVM host - test RAID device
sudo dd if=/dev/md1 of=/dev/null bs=1M count=10 iflag=direct

# If that works, issue is VM attachment
# If that fails, issue is RAID/iSCSI
```

#### Step 2: If RAID/iSCSI Issue

Follow Scenario 1 or 2 procedures above.

#### Step 3: If VM Attachment Issue

```bash
# Detach disk from VM
sudo virsh detach-disk $VM_NAME vdb

# Reattach
cat > /tmp/disk.xml <<EOF
<disk type='block' device='disk'>
  <driver name='qemu' type='raw' cache='none'/>
  <source dev='/dev/md1'/>
  <target dev='vdb' bus='virtio'/>
</disk>
EOF

sudo virsh attach-device $VM_NAME /tmp/disk.xml --live
```

#### Step 4: Inside VM - Remount

```bash
# If filesystem went read-only
sudo mount -o remount,rw /mnt/raid

# Or unmount and remount
sudo umount /mnt/raid
sudo fsck /dev/vdb
sudo mount /dev/vdb /mnt/raid
```

### Expected Timeline

- Diagnosis: 5-15 minutes
- Repair: 5-30 minutes (depending on root cause)
- **Total: 10-45 minutes**

---

## Emergency Contacts and Escalation

### Level 1: Self-Recovery

- Use this runbook
- Check monitoring dashboards
- Review recent changes

### Level 2: Team Escalation

- Contact: [Storage Team]
- Escalate if: >30 minutes without progress
- Escalate if: Data loss risk identified

### Level 3: Vendor Support

- ZFS/Storage vendor: [Contact]
- Hardware vendor: [Contact]
- Escalate if: Hardware failure suspected

---

## Post-Incident Review

After resolving any incident, document:

1. **Timeline:**
   - When first detected
   - Steps taken
   - Time to resolution

2. **Root Cause:**
   - What failed
   - Why it failed
   - How it was detected

3. **Impact:**
   - Affected VMs
   - Downtime duration
   - Data loss (if any)

4. **Improvements:**
   - Monitoring gaps
   - Documentation updates
   - Preventive measures

---

## Preventive Maintenance

### Daily

```bash
# Check RAID status
cat /proc/mdstat

# Check iSCSI sessions
sudo iscsiadm -m session
```

### Weekly

```bash
# Check ZFS pool health
zpool status storage

# Review system logs
journalctl -u target -since "1 week ago"
journalctl -u iscsid -since "1 week ago"
```

### Monthly

```bash
# ZFS scrub
sudo zpool scrub storage

# SMART tests on all disks
for disk in /dev/sd{a,b}; do
  sudo smartctl -t long $disk
done

# Review performance metrics
arcstat 30 10  # Sample for 5 minutes
```

### Quarterly

```bash
# Test RAID rebuild
# (In test environment only)

# Verify backup/restore procedures
# Document time to restore

# Review and update runbook
# Incorporate lessons learned
```

---

## Appendix: Quick Reference Commands

### Storage Server

```bash
# ZFS health
zpool status storage
zpool list storage

# iSCSI targets
sudo targetcli ls /iscsi
sudo iscsi-lun.sh list

# Create/remove LUNs
sudo iscsi-lun.sh create <name> <size>
sudo iscsi-lun.sh remove <name>
```

### KVM Host

```bash
# RAID status
cat /proc/mdstat
sudo mdadm --detail /dev/md1

# iSCSI sessions
sudo iscsiadm -m session
sudo iscsiadm -m node -l  # Login all
sudo iscsiadm -m node -u  # Logout all

# Device info
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
```

### Inside VM

```bash
# Filesystem status
df -h
mount | grep vdb

# Device testing
sudo dd if=/dev/vdb of=/dev/null bs=1M count=10 iflag=direct
```

### Performance Monitoring

```bash
# Storage server
zpool iostat -v storage 2
arcstat 2

# KVM host
dstat -cdngy --disk-util --io 2
iostat -xz 2
```
