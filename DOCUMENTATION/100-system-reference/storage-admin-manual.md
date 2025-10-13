# Storage Provisioning

## Overview

This manual documents the storage provisioning system for debugging purposes. Under normal operation, OpenSVC handles all storage provisioning automatically. This guide is for system administrators who need to manually execute storage operations for troubleshooting or testing.

## Prerequisites

All operations require the node functions to be sourced first:

```bash
# Source the functions library
. /srv/hps/lib/node_functions.sh
```

## Architecture

### Node Types

- **TCH** (Thin Compute Host) - Virtual machine hosts that request storage
- **SCH** (Storage Cluster Host) - Physical storage nodes that provide zvol/iSCSI resources

### Components

- **ZFS zvols** - Block devices for storage volumes
- **LIO/iSCSI** - Network block device targets
- **OpenSVC** - Cluster orchestration layer

## Manual Operations

### 1. Check Available Storage Capacity

Query available space on local storage pool:

```bash
# Get available bytes
storage_get_available_space

# Example output: 51504332800 (approximately 48GB)
```

Convert human-readable sizes:

```bash
# Parse capacity string to bytes
storage_parse_capacity "100G"

# Example output: 107374182400
```

### 2. Provision a Storage Volume

Create a complete storage volume with zvol and iSCSI target:

```bash
storage_provision_volume \
  --iqn iqn.2025-09.local.hps:vm-disk-001 \
  --capacity 100G \
  --zvol-name vm-disk-001
```

**What happens:**

1. Validates host type is SCH
2. Retrieves local zpool name
3. Checks available capacity
4. Creates ZFS zvol
5. Creates iSCSI target with backstore
6. Configures LUN mapping
7. Sets up demo mode (no authentication)

**Requirements:**

- Must run on SCH host
- Sufficient capacity in zpool
- Valid IQN format
- Unique zvol name

### 3. Remove a Storage Volume

Delete both iSCSI target and underlying zvol:

```bash
storage_deprovision_volume \
  --iqn iqn.2025-09.local.hps:vm-disk-001 \
  --zvol-name vm-disk-001
```

**What happens:**

1. Validates host type is SCH
2. Deletes iSCSI target configuration
3. Removes backstore
4. Destroys ZFS zvol

## Low-Level Operations

### ZFS Volume Management

Direct zvol operations via the storage manager:

```bash
# Create zvol
node_storage_manager zvol create \
  --pool ztest-pool \
  --name my-volume \
  --size 50G

# Delete zvol
node_storage_manager zvol delete \
  --pool ztest-pool \
  --name my-volume

# List zvols in pool
node_storage_manager zvol list --pool ztest-pool

# Check if zvol exists
node_storage_manager zvol check \
  --pool ztest-pool \
  --name my-volume

# Get zvol information
node_storage_manager zvol info \
  --pool ztest-pool \
  --name my-volume
```

### iSCSI Target Management

Direct LIO/targetcli operations:

```bash
# Start target service
node_storage_manager lio start

# Stop target service
node_storage_manager lio stop

# Check service status
node_storage_manager lio status

# Create iSCSI target
node_storage_manager lio create \
  --iqn iqn.2025-09.local.hps:target-name \
  --device /dev/zvol/pool/volume

# Create with ACL (optional)
node_storage_manager lio create \
  --iqn iqn.2025-09.local.hps:target-name \
  --device /dev/zvol/pool/volume \
  --acl iqn.2025-09.initiator:client1

# Delete iSCSI target
node_storage_manager lio delete \
  --iqn iqn.2025-09.local.hps:target-name

# List all targets
node_storage_manager lio list
```

## OpenSVC Integration

### Service Structure

The storage-provision service provides two tasks:

```bash
# Check capacity on all storage nodes
om storage-provision run --rid task#check-capacity --node=\*

# Provision on specific node
om storage-provision instance run \
  --rid task#provision \
  --node=SCH-001 \
  --env IQN=iqn.2025-09.local.hps:vm-disk-001 \
  --env CAPACITY=100G \
  --env VOLNAME=vm-disk-001
```

### Viewing Logs

```bash
# Get session ID from run output
om storage-provision run --rid task#check-capacity --node=\*
# Output shows: OBJECT NODE SID

# View logs for specific session
om storage-provision log --filter SID=<session-id>
```

## Troubleshooting

### Common Issues

**"ERROR: This host type is 'XXX', not 'SCH'"**

- Storage operations only allowed on Storage Cluster Hosts
- Verify: `remote_host_variable TYPE`

**"ERROR: Insufficient space"**

- Requested capacity exceeds available space
- Check: `storage_get_available_space`
- Reduce capacity or free up space

**"Zvol already exists"**

- Volume name conflict
- List existing: `node_storage_manager zvol list`
- Choose different name or delete existing

**"Failed to create backstore"**

- Backstore name already in use
- List: `node_storage_manager lio list`
- Delete conflicting target first

### Debugging Steps

1. **Verify host configuration:**
   ```bash
   remote_host_variable TYPE
   remote_host_variable ZPOOL_NAME
   ```

2. **Check available resources:**
   ```bash
   storage_get_available_space
   zpool list
   node_storage_manager zvol list
   node_storage_manager lio list
   ```

3. **Test connectivity:**
   ```bash
   node_storage_manager lio status
   systemctl status target
   ```

4. **Review logs:**
   ```bash
   journalctl -u target -n 50
   tail -f /var/log/messages
   ```

## Manual Cleanup

If automated cleanup fails, manually remove resources:

```bash
# 1. Delete iSCSI target
targetcli /iscsi delete iqn.2025-09.local.hps:target-name

# 2. Delete backstore
targetcli /backstores/block delete backstore-name

# 3. Save configuration
targetcli saveconfig

# 4. Delete zvol
zfs destroy pool-name/volume-name

# 5. Verify cleanup
zfs list -t volume
targetcli ls
```

## Safety Notes

- Always verify host type before provisioning
- Check capacity before creating large volumes
- Ensure unique IQN and volume names
- Use deprovision function for proper cleanup
- Monitor zpool space regularly

## References

- Functions location: `/srv/hps/lib/node_functions.sh`
- OpenSVC service: `storage-provision`
- Target config: `/etc/target/saveconfig.json`
- Logs: `journalctl` and `om storage-provision log`
