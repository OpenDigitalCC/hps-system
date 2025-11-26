#===============================================================================
# Alpine Linux Installer Functions
# For use during PXE-based installation
#===============================================================================


#===============================================================================
# n_installer_load_ext4_modules
# ------------------------------
# Load ext4 kernel module and dependencies from modloop.
#
# Behaviour:
#   - Checks if ext4 is already available in /proc/filesystems
#   - Loads modules in dependency order: crc16, mbcache, jbd2, ext4
#   - Uses n_load_kernel_module for each (handles modloop paths)
#   - Verifies ext4 is available after loading
#
# Returns:
#   0 on success (ext4 available in /proc/filesystems)
#   1 if modloop not mounted or module loading fails
#
# Example usage:
#   n_installer_load_ext4_modules
#
#===============================================================================
n_installer_load_ext4_modules() {
  # Check if ext4 already available (built-in or already loaded)
  if grep -q ext4 /proc/filesystems 2>/dev/null; then
    n_remote_log "[DEBUG] ext4 filesystem already available"
    return 0
  fi

  n_remote_log "[INFO] ext4 not in /proc/filesystems, loading modules"

  # Verify modloop is mounted
  if ! mountpoint -q /.modloop 2>/dev/null; then
    n_remote_log "[ERROR] Modloop not mounted at /.modloop"
    n_remote_log "[ERROR] Cannot load ext4 modules without modloop"
    return 1
  fi

  # Module load order (dependencies first)
  local modules=("crc16" "mbcache" "jbd2" "ext4")
  local mod
  local load_output

  for mod in "${modules[@]}"; do
    # Check if already loaded
    if lsmod | grep -q "^${mod} "; then
      n_remote_log "[DEBUG] Module already loaded: $mod"
      continue
    fi

    n_remote_log "[DEBUG] Loading module: $mod"
    load_output=$(n_load_kernel_module "$mod" 2>&1)
    local rc=$?

    if [[ $rc -ne 0 ]]; then
      n_remote_log "[ERROR] Failed to load module: $mod (exit code: $rc)"
      n_remote_log "[ERROR] Output: $load_output"
      return 1
    fi

    n_remote_log "[DEBUG] Loaded module: $mod"
  done

  # Verify ext4 is now available
  if ! grep -q ext4 /proc/filesystems 2>/dev/null; then
    n_remote_log "[ERROR] ext4 still not in /proc/filesystems after loading modules"
    n_remote_log "[DEBUG] Available filesystems:"
    while IFS= read -r line; do
      n_remote_log "[DEBUG]   $line"
    done < /proc/filesystems
    return 1
  fi

  n_remote_log "[INFO] ext4 modules loaded successfully"
  return 0
}


#===============================================================================
# n_installer_format_partitions
# ------------------------------
# Format boot and root partitions with ext4, create swap file.
#
# Behaviour:
#   - Reads boot_device and root_device from host_config
#   - Loads ext4 kernel modules if not available
#   - Formats boot partition: ext4 with label 'boot' and metadata checksums
#   - Formats root partition: ext4 with label 'root' and metadata checksums
#   - Syncs and waits for kernel to register filesystems
#   - Mounts root to /mnt, boot to /mnt/boot
#   - Creates 1GB swap file at /mnt/swapfile
#   - Generates /mnt/etc/fstab with UUID-based entries
#
# Returns:
#   0 on success
#   1 if failed to read device config
#   2 if failed to format partitions (includes module load failure)
#   3 if failed to mount partitions
#   4 if failed to create swap
#
# Example usage:
#   n_installer_format_partitions
#
# Stores to IPS:
#   boot_uuid="<uuid>"
#   root_uuid="<uuid>"
#
#===============================================================================
n_installer_format_partitions() {
  n_remote_log "[INFO] Starting partition formatting"

  # Read device paths from host_config
  local boot_device
  local root_device

  if ! boot_device=$(n_remote_host_variable boot_device); then
    n_remote_log "[ERROR] Failed to read boot_device from host_config"
    return 1
  fi

  if ! root_device=$(n_remote_host_variable root_device); then
    n_remote_log "[ERROR] Failed to read root_device from host_config"
    return 1
  fi

  if [[ -z "$boot_device" ]]; then
    n_remote_log "[ERROR] boot_device is empty"
    return 1
  fi

  if [[ -z "$root_device" ]]; then
    n_remote_log "[ERROR] root_device is empty"
    return 1
  fi

  n_remote_log "[INFO] boot_device: $boot_device"
  n_remote_log "[INFO] root_device: $root_device"

  # Verify devices exist
  if [[ ! -b "$boot_device" ]]; then
    n_remote_log "[ERROR] boot_device not found or not a block device: $boot_device"
    ls -la "$boot_device" 2>&1 | while IFS= read -r line; do
      n_remote_log "[DEBUG] ls: $line"
    done
    return 1
  fi

  if [[ ! -b "$root_device" ]]; then
    n_remote_log "[ERROR] root_device not found or not a block device: $root_device"
    ls -la "$root_device" 2>&1 | while IFS= read -r line; do
      n_remote_log "[DEBUG] ls: $line"
    done
    return 1
  fi

  n_remote_log "[DEBUG] Block devices verified"

  # Ensure mkfs.ext4 is available
  if ! command -v mkfs.ext4 >/dev/null 2>&1; then
    n_remote_log "[INFO] Installing e2fsprogs"
    local apk_output
    apk_output=$(apk add e2fsprogs 2>&1)
    local apk_rc=$?
    if [[ $apk_rc -ne 0 ]]; then
      n_remote_log "[ERROR] Failed to install e2fsprogs (exit code: $apk_rc)"
      echo "$apk_output" | while IFS= read -r line; do
        n_remote_log "[ERROR] apk: $line"
      done
      return 2
    fi
    n_remote_log "[DEBUG] e2fsprogs installed"
  fi

  # Load ext4 kernel modules (required for mounting)
  if ! n_installer_load_ext4_modules; then
    n_remote_log "[ERROR] Cannot proceed without ext4 filesystem support"
    return 2
  fi

  # Format boot partition
  n_remote_log "[INFO] Formatting boot partition: $boot_device"
  local mkfs_output
  mkfs_output=$(mkfs.ext4 -F -L boot -O metadata_csum "$boot_device" 2>&1)
  local mkfs_rc=$?
  if [[ $mkfs_rc -ne 0 ]]; then
    n_remote_log "[ERROR] Failed to format boot partition (exit code: $mkfs_rc)"
    echo "$mkfs_output" | while IFS= read -r line; do
      n_remote_log "[ERROR] mkfs: $line"
    done
    return 2
  fi
  n_remote_log "[DEBUG] Boot partition formatted successfully"

  # Format root partition
  n_remote_log "[INFO] Formatting root partition: $root_device"
  mkfs_output=$(mkfs.ext4 -F -L root -O metadata_csum "$root_device" 2>&1)
  mkfs_rc=$?
  if [[ $mkfs_rc -ne 0 ]]; then
    n_remote_log "[ERROR] Failed to format root partition (exit code: $mkfs_rc)"
    echo "$mkfs_output" | while IFS= read -r line; do
      n_remote_log "[ERROR] mkfs: $line"
    done
    return 2
  fi
  n_remote_log "[DEBUG] Root partition formatted successfully"

  # Sync and wait for kernel to fully register new filesystems
  n_remote_log "[DEBUG] Syncing filesystems"
  sync

  n_remote_log "[DEBUG] Waiting for udev to settle"
  udevadm settle 2>/dev/null || sleep 2
  sleep 1

  # Get UUIDs for fstab
  local boot_uuid
  local root_uuid

  boot_uuid=$(blkid -s UUID -o value "$boot_device" 2>&1)
  local blkid_rc=$?
  if [[ $blkid_rc -ne 0 ]] || [[ -z "$boot_uuid" ]]; then
    n_remote_log "[ERROR] Failed to get UUID for boot partition (exit code: $blkid_rc)"
    n_remote_log "[ERROR] blkid output: $boot_uuid"
    blkid "$boot_device" 2>&1 | while IFS= read -r line; do
      n_remote_log "[DEBUG] blkid: $line"
    done
    return 2
  fi

  root_uuid=$(blkid -s UUID -o value "$root_device" 2>&1)
  blkid_rc=$?
  if [[ $blkid_rc -ne 0 ]] || [[ -z "$root_uuid" ]]; then
    n_remote_log "[ERROR] Failed to get UUID for root partition (exit code: $blkid_rc)"
    n_remote_log "[ERROR] blkid output: $root_uuid"
    blkid "$root_device" 2>&1 | while IFS= read -r line; do
      n_remote_log "[DEBUG] blkid: $line"
    done
    return 2
  fi

  n_remote_log "[DEBUG] boot_uuid: $boot_uuid"
  n_remote_log "[DEBUG] root_uuid: $root_uuid"

  # Store UUIDs to host_config
  n_remote_host_variable boot_uuid "$boot_uuid"
  n_remote_host_variable root_uuid "$root_uuid"

  # Ensure /mnt is available
  n_remote_log "[DEBUG] Preparing mount point /mnt"
  if mountpoint -q /mnt 2>/dev/null; then
    n_remote_log "[DEBUG] /mnt already mounted, unmounting"
    umount /mnt 2>/dev/null || true
  fi
  mkdir -p /mnt

  # Mount root partition
  n_remote_log "[INFO] Mounting root partition to /mnt"
  local mount_output
  mount_output=$(mount -v "$root_device" /mnt 2>&1)
  local mount_rc=$?
  if [[ $mount_rc -ne 0 ]]; then
    n_remote_log "[ERROR] Failed to mount root partition (exit code: $mount_rc)"
    echo "$mount_output" | while IFS= read -r line; do
      n_remote_log "[ERROR] mount: $line"
    done
    # Additional diagnostics
    n_remote_log "[DEBUG] Checking /proc/filesystems for ext4:"
    grep ext4 /proc/filesystems 2>&1 | while IFS= read -r line; do
      n_remote_log "[DEBUG]   $line"
    done
    n_remote_log "[DEBUG] Loaded modules:"
    lsmod | grep -E "(ext4|jbd2)" 2>&1 | while IFS= read -r line; do
      n_remote_log "[DEBUG]   $line"
    done
    return 3
  fi
  n_remote_log "[DEBUG] Root partition mounted successfully"

  # Create boot mount point and mount
  n_remote_log "[INFO] Mounting boot partition to /mnt/boot"
  mkdir -p /mnt/boot

  mount_output=$(mount -v "$boot_device" /mnt/boot 2>&1)
  mount_rc=$?
  if [[ $mount_rc -ne 0 ]]; then
    n_remote_log "[ERROR] Failed to mount boot partition (exit code: $mount_rc)"
    echo "$mount_output" | while IFS= read -r line; do
      n_remote_log "[ERROR] mount: $line"
    done
    umount /mnt 2>/dev/null
    return 3
  fi
  n_remote_log "[DEBUG] Boot partition mounted successfully"

  # Create essential directories
  n_remote_log "[DEBUG] Creating essential directories"
  mkdir -p /mnt/etc
  mkdir -p /mnt/var
  mkdir -p /mnt/proc
  mkdir -p /mnt/sys
  mkdir -p /mnt/dev
  mkdir -p /mnt/run

  # Create swap file (1GB)
  n_remote_log "[INFO] Creating 1GB swap file"

  local dd_output
  dd_output=$(dd if=/dev/zero of=/mnt/swapfile bs=1M count=1024 status=progress 2>&1)
  local dd_rc=$?
  if [[ $dd_rc -ne 0 ]]; then
    n_remote_log "[ERROR] Failed to create swap file (exit code: $dd_rc)"
    echo "$dd_output" | while IFS= read -r line; do
      n_remote_log "[ERROR] dd: $line"
    done
    umount /mnt/boot 2>/dev/null
    umount /mnt 2>/dev/null
    return 4
  fi
  n_remote_log "[DEBUG] Swap file created"

  chmod 600 /mnt/swapfile

  local mkswap_output
  mkswap_output=$(mkswap /mnt/swapfile 2>&1)
  local mkswap_rc=$?
  if [[ $mkswap_rc -ne 0 ]]; then
    n_remote_log "[ERROR] Failed to initialize swap file (exit code: $mkswap_rc)"
    echo "$mkswap_output" | while IFS= read -r line; do
      n_remote_log "[ERROR] mkswap: $line"
    done
    umount /mnt/boot 2>/dev/null
    umount /mnt 2>/dev/null
    return 4
  fi
  n_remote_log "[DEBUG] Swap file initialized"

  # Generate fstab
  n_remote_log "[INFO] Generating /mnt/etc/fstab"

  cat > /mnt/etc/fstab << EOF
# /etc/fstab - Static filesystem table
# Generated by HPS Alpine Installer
#
# <filesystem>                            <mount>  <type>  <options>         <dump> <pass>
UUID=${root_uuid}  /        ext4    defaults          1      1
UUID=${boot_uuid}  /boot    ext4    defaults,noatime  1      2
/swapfile                                 none     swap    sw                0      0
EOF

  if [[ ! -f /mnt/etc/fstab ]]; then
    n_remote_log "[ERROR] Failed to create fstab"
    umount /mnt/boot 2>/dev/null
    umount /mnt 2>/dev/null
    return 4
  fi

  n_remote_log "[DEBUG] fstab created:"
  while IFS= read -r line; do
    [[ -n "$line" ]] && n_remote_log "[DEBUG]   $line"
  done < /mnt/etc/fstab

  n_remote_log "[INFO] Partition formatting complete"
  n_remote_log "[INFO] Root mounted at /mnt, boot at /mnt/boot"

  return 0
}


#===============================================================================
# n_installer_detect_target_disks
# --------------------------------
# Detect suitable disk(s) for Alpine OS installation.
#
# Behaviour:
#   - Checks ROOT_RAID setting from host_config via n_remote_host_variable
#   - Scans /sys/block for non-removable block devices >= 10GB
#   - If ROOT_RAID=1: Requires 2 suitable disks for RAID1
#   - If ROOT_RAID unset or !=1: Uses first suitable disk
#   - Stores result to IPS: n_remote_host_variable os_disk
#
# Returns:
#   0 on success (required disk(s) found and stored)
#   1 if no suitable disk found
#   2 if ROOT_RAID=1 but fewer than 2 disks found
#
# Example usage:
#   n_installer_detect_target_disks
#
# Stores to IPS:
#   os_disk="/dev/sda" (single) or os_disk="/dev/sda,/dev/sdb" (RAID1)
#
#===============================================================================
n_installer_detect_target_disks() {
  n_remote_log "[INFO] Starting target disk detection"
  
  # Check if RAID is requested
  local root_raid=""
  root_raid=$(n_remote_host_variable ROOT_RAID 2>/dev/null) || true
  
  local require_raid=0
  if [[ "$root_raid" == "1" ]]; then
    require_raid=1
    n_remote_log "[INFO] ROOT_RAID=1 set, will search for 2 disks"
  else
    n_remote_log "[INFO] Single disk mode (ROOT_RAID not set or !=1)"
  fi
  
  local suitable_disks=()
  local min_size_gb=10
  local min_size_bytes=$((min_size_gb * 1024 * 1024 * 1024))
  
  # Scan all block devices
  for disk in /sys/block/*; do
    [[ -d "$disk" ]] || continue
    
    local dev_name
    dev_name=$(basename "$disk")
    local dev_path="/dev/$dev_name"
    
    n_remote_log "[DEBUG] Examining device: $dev_path"
    
    # Skip if removable
    if [[ -f "$disk/removable" ]] && [[ $(cat "$disk/removable") == "1" ]]; then
      n_remote_log "[DEBUG] Skipping $dev_path: removable device"
      continue
    fi
    
    # Skip if not a disk device type
    if [[ ! "$dev_name" =~ ^(sd|hd|vd|nvme|xvd)[a-z0-9]*$ ]]; then
      n_remote_log "[DEBUG] Skipping $dev_path: not a disk device"
      continue
    fi
    
    # Skip partition devices (e.g., sda1, nvme0n1p1)
    if [[ "$dev_name" =~ [0-9]$ ]] && [[ ! "$dev_name" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
      n_remote_log "[DEBUG] Skipping $dev_path: partition, not whole disk"
      continue
    fi
    
    # Check size
    if [[ -f "$disk/size" ]]; then
      local size_sectors
      size_sectors=$(cat "$disk/size")
      local size_bytes=$((size_sectors * 512))
      local size_gb=$((size_bytes / 1024 / 1024 / 1024))
      
      n_remote_log "[DEBUG] $dev_path size: ${size_gb}GB"
      
      if [[ $size_bytes -lt $min_size_bytes ]]; then
        n_remote_log "[DEBUG] Skipping $dev_path: too small (< ${min_size_gb}GB)"
        continue
      fi
      
      # Disk is suitable
      n_remote_log "[DEBUG] $dev_path is suitable for OS installation"
      suitable_disks+=("$dev_path")
      
      # Stop searching based on mode
      if [[ $require_raid -eq 1 ]] && [[ ${#suitable_disks[@]} -eq 2 ]]; then
        n_remote_log "[DEBUG] Found 2 suitable disks for RAID1, stopping search"
        break
      elif [[ $require_raid -eq 0 ]] && [[ ${#suitable_disks[@]} -eq 1 ]]; then
        n_remote_log "[DEBUG] Found suitable disk for single-disk install, stopping search"
        break
      fi
    else
      n_remote_log "[DEBUG] Skipping $dev_path: cannot determine size"
    fi
  done
  
  # Validate results
  local disk_count=${#suitable_disks[@]}
  n_remote_log "[INFO] Found $disk_count suitable disk(s)"
  
  if [[ $disk_count -eq 0 ]]; then
    n_remote_log "[ERROR] No suitable disk found for OS installation"
    n_remote_log "[ERROR] Requirements: non-removable disk >= ${min_size_gb}GB"
    return 1
  fi
  
  if [[ $require_raid -eq 1 ]] && [[ $disk_count -lt 2 ]]; then
    n_remote_log "[ERROR] ROOT_RAID=1 requires 2 disks, only found $disk_count"
    return 2
  fi
  
  # Build result string
  local os_disk_value
  if [[ $require_raid -eq 1 ]]; then
    os_disk_value="${suitable_disks[0]},${suitable_disks[1]}"
    n_remote_log "[INFO] RAID1 install selected: $os_disk_value"
  else
    os_disk_value="${suitable_disks[0]}"
    n_remote_log "[INFO] Single disk install selected: $os_disk_value"
  fi
  
  # Store to IPS
  n_remote_log "[INFO] Storing os_disk to IPS: $os_disk_value"
  if ! n_remote_host_variable os_disk "$os_disk_value"; then
    n_remote_log "[ERROR] Failed to store os_disk to IPS"
    return 1
  fi
  
  n_remote_log "[INFO] Target disk detection complete: $os_disk_value"
  return 0
}


#===============================================================================
# n_installer_partition_disks
# ----------------------------
# Create GPT partition layout on detected disk(s) for Alpine installation.
#
# Behaviour:
#   - Reads os_disk from host_config via n_remote_host_variable
#   - Installs sfdisk and mdadm (if RAID1) if not present
#   - Wipes existing partition tables
#   - Creates GPT partitions using sfdisk
#   - If RAID1: Assembles md arrays (md0=/boot, md1=/)
#   - Stores device paths to host_config: boot_device, root_device
#
# Partition Layout:
#   1: 2MB    ef02 (BIOS boot) - bootloader code
#   2: 512MB  fd00/8300        - /boot (RAID1 or ext4)
#   3: 9GB    fd00/8300        - / (RAID1 or ext4)
#   (remaining space unallocated for ZFS)
#
# Returns:
#   0 on success
#   1 if failed to read os_disk or invalid config
#   2 if failed to partition disk
#   3 if failed to assemble RAID arrays
#
# Example usage:
#   n_installer_partition_disks
#
# Stores to IPS:
#   boot_device="/dev/sda2" or "/dev/md0"
#   root_device="/dev/sda3" or "/dev/md1"
#
#===============================================================================
n_installer_partition_disks() {
  n_remote_log "[INFO] Starting disk partitioning"
  
  # Read os_disk from host_config
  local os_disk_value
  if ! os_disk_value=$(n_remote_host_variable os_disk); then
    n_remote_log "[ERROR] Failed to read os_disk from host_config"
    return 1
  fi
  
  if [[ -z "$os_disk_value" ]]; then
    n_remote_log "[ERROR] os_disk is empty"
    return 1
  fi
  
  n_remote_log "[INFO] os_disk: $os_disk_value"
  
  # Parse disk list
  IFS=',' read -ra disks <<< "$os_disk_value"
  local disk_count=${#disks[@]}
  local raid_mode=0
  
  if [[ $disk_count -eq 2 ]]; then
    raid_mode=1
    n_remote_log "[INFO] RAID1 mode: ${disks[0]} and ${disks[1]}"
  elif [[ $disk_count -eq 1 ]]; then
    n_remote_log "[INFO] Single disk mode: ${disks[0]}"
  else
    n_remote_log "[ERROR] Invalid disk count: $disk_count"
    return 1
  fi
  
  # Ensure required tools are installed
  n_remote_log "[INFO] Checking for required tools"
  if ! command -v sfdisk >/dev/null 2>&1; then
    n_remote_log "[INFO] Installing sfdisk (util-linux)"
    if ! apk add --quiet util-linux >/dev/null 2>&1; then
      n_remote_log "[ERROR] Failed to install util-linux"
      return 2
    fi
  fi
  
  if [[ $raid_mode -eq 1 ]]; then
    if ! command -v mdadm >/dev/null 2>&1; then
      n_remote_log "[INFO] Installing mdadm"
      if ! apk add --quiet mdadm >/dev/null 2>&1; then
        n_remote_log "[ERROR] Failed to install mdadm"
        return 2
      fi
    fi
  fi
  
  # Partition type codes for sfdisk
  local type_bios="21686148-6449-6E6F-744E-656564454649"  # BIOS boot (ef02)
  local type_raid="A19D880F-05FC-4D3B-A006-743F0F84911E"  # Linux RAID (fd00)
  local type_linux="0FC63DAF-8483-4772-8E79-3D69D8477DE4" # Linux filesystem (8300)
  
  # Determine partition type based on mode
  local part_type
  if [[ $raid_mode -eq 1 ]]; then
    part_type="$type_raid"
  else
    part_type="$type_linux"
  fi
  
  # Partition each disk
  for disk in "${disks[@]}"; do
    n_remote_log "[INFO] Partitioning $disk"
    
    # Determine partition naming (NVMe uses 'p' separator)
    local part_prefix=""
    if [[ "$disk" =~ nvme[0-9]+n[0-9]+$ ]]; then
      part_prefix="p"
    fi
    
    # Stop any existing md arrays using this disk
    if [[ $raid_mode -eq 1 ]]; then
      n_remote_log "[DEBUG] Stopping any existing md arrays on $disk"
      mdadm --stop --scan 2>/dev/null || true
      mdadm --zero-superblock "${disk}"* 2>/dev/null || true
    fi
    
    # Wipe existing partition table
    n_remote_log "[DEBUG] Wiping partition table on $disk"
    if ! wipefs -a "$disk" >/dev/null 2>&1; then
      n_remote_log "[ERROR] Failed to wipe $disk"
      return 2
    fi
    
    # Create GPT partition table with sfdisk
    n_remote_log "[DEBUG] Creating GPT partitions on $disk"
    
    # sfdisk script: size in sectors (512 bytes each)
    # 2MB = 4096 sectors, 512MB = 1048576 sectors, 9GB = 18874368 sectors
    local sfdisk_script="label: gpt
unit: sectors

${disk}${part_prefix}1 : size=4096, type=${type_bios}
${disk}${part_prefix}2 : size=1048576, type=${part_type}
${disk}${part_prefix}3 : size=18874368, type=${part_type}
"
    
    if ! echo "$sfdisk_script" | sfdisk --quiet "$disk" 2>/dev/null; then
      n_remote_log "[ERROR] Failed to partition $disk"
      return 2
    fi
    
    n_remote_log "[DEBUG] Partitioning complete for $disk"
  done
  
  # Wait for partition devices to appear
  n_remote_log "[DEBUG] Waiting for partition devices"
  sleep 2
  partprobe "${disks[@]}" 2>/dev/null || true
  sleep 1
  
  # Helper function to get partition device name
  # Handles NVMe naming (nvme0n1p1) vs standard (sda1)
  _get_partition_device() {
    local disk="$1"
    local part_num="$2"
    if [[ "$disk" =~ nvme[0-9]+n[0-9]+$ ]]; then
      echo "${disk}p${part_num}"
    else
      echo "${disk}${part_num}"
    fi
  }
  
  # Set up device paths
  local boot_device
  local root_device
  
  if [[ $raid_mode -eq 1 ]]; then
    # Assemble RAID arrays
    n_remote_log "[INFO] Assembling RAID1 arrays"
    
    local disk1="${disks[0]}"
    local disk2="${disks[1]}"
    local disk1_p2=$(_get_partition_device "$disk1" 2)
    local disk1_p3=$(_get_partition_device "$disk1" 3)
    local disk2_p2=$(_get_partition_device "$disk2" 2)
    local disk2_p3=$(_get_partition_device "$disk2" 3)
    
    # Create md0 for /boot
    n_remote_log "[DEBUG] Creating md0 (boot) from ${disk1_p2} and ${disk2_p2}"
    if ! mdadm --create /dev/md0 --level=1 --raid-devices=2 \
         --metadata=1.0 "${disk1_p2}" "${disk2_p2}" --run --force >/dev/null 2>&1; then
      n_remote_log "[ERROR] Failed to create md0"
      return 3
    fi
    
    # Create md1 for /
    n_remote_log "[DEBUG] Creating md1 (root) from ${disk1_p3} and ${disk2_p3}"
    if ! mdadm --create /dev/md1 --level=1 --raid-devices=2 \
         --metadata=1.2 "${disk1_p3}" "${disk2_p3}" --run --force >/dev/null 2>&1; then
      n_remote_log "[ERROR] Failed to create md1"
      return 3
    fi
    
    boot_device="/dev/md0"
    root_device="/dev/md1"
    
    n_remote_log "[INFO] RAID arrays created: md0 (boot), md1 (root)"
    
  else
    # Single disk - use partitions directly
    boot_device=$(_get_partition_device "${disks[0]}" 2)
    root_device=$(_get_partition_device "${disks[0]}" 3)
  fi
  
  # Store device paths to host_config
  n_remote_log "[INFO] Storing device paths to host_config"
  
  if ! n_remote_host_variable boot_device "$boot_device"; then
    n_remote_log "[ERROR] Failed to store boot_device"
    return 1
  fi
  
  if ! n_remote_host_variable root_device "$root_device"; then
    n_remote_log "[ERROR] Failed to store root_device"
    return 1
  fi
  
  n_remote_log "[INFO] Partitioning complete"
  n_remote_log "[INFO] boot_device: $boot_device"
  n_remote_log "[INFO] root_device: $root_device"
  
  return 0
}


#===============================================================================
# n_installer_format_partitions
# ------------------------------
# Format boot and root partitions with ext4, create swap file.
#
# Behaviour:
#   - Reads boot_device and root_device from host_config
#   - Formats boot partition: ext4 with label 'boot' and metadata checksums
#   - Formats root partition: ext4 with label 'root' and metadata checksums
#   - Mounts root to /mnt, boot to /mnt/boot
#   - Creates 1GB swap file at /mnt/swapfile
#   - Generates /mnt/etc/fstab with UUID-based entries
#
# Returns:
#   0 on success
#   1 if failed to read device config
#   2 if failed to format partitions
#   3 if failed to mount partitions
#   4 if failed to create swap
#
# Example usage:
#   n_installer_format_partitions
#
# Stores to IPS:
#   boot_uuid="<uuid>"
#   root_uuid="<uuid>"
#
#===============================================================================
n_installer_format_partitions() {
  n_remote_log "[INFO] Starting partition formatting"
  
  # Read device paths from host_config
  local boot_device
  local root_device
  
  if ! boot_device=$(n_remote_host_variable boot_device); then
    n_remote_log "[ERROR] Failed to read boot_device from host_config"
    return 1
  fi
  
  if ! root_device=$(n_remote_host_variable root_device); then
    n_remote_log "[ERROR] Failed to read root_device from host_config"
    return 1
  fi
  
  if [[ -z "$boot_device" ]] || [[ -z "$root_device" ]]; then
    n_remote_log "[ERROR] boot_device or root_device is empty"
    return 1
  fi
  
  n_remote_log "[INFO] boot_device: $boot_device"
  n_remote_log "[INFO] root_device: $root_device"
  
  # Ensure mkfs.ext4 is available
  if ! command -v mkfs.ext4 >/dev/null 2>&1; then
    n_remote_log "[INFO] Installing e2fsprogs"
    if ! apk add --quiet e2fsprogs >/dev/null 2>&1; then
      n_remote_log "[ERROR] Failed to install e2fsprogs"
      return 2
    fi
  fi
  
  # Format boot partition
  n_remote_log "[INFO] Formatting boot partition: $boot_device"
  if ! mkfs.ext4 -F -L boot -O metadata_csum "$boot_device" >/dev/null 2>&1; then
    n_remote_log "[ERROR] Failed to format boot partition"
    return 2
  fi
  n_remote_log "[DEBUG] Boot partition formatted successfully"
  
  # Format root partition
  n_remote_log "[INFO] Formatting root partition: $root_device"
  if ! mkfs.ext4 -F -L root -O metadata_csum "$root_device" >/dev/null 2>&1; then
    n_remote_log "[ERROR] Failed to format root partition"
    return 2
  fi
  n_remote_log "[DEBUG] Root partition formatted successfully"
  
  # Get UUIDs for fstab
  local boot_uuid
  local root_uuid
  
  boot_uuid=$(blkid -s UUID -o value "$boot_device")
  root_uuid=$(blkid -s UUID -o value "$root_device")
  
  if [[ -z "$boot_uuid" ]] || [[ -z "$root_uuid" ]]; then
    n_remote_log "[ERROR] Failed to get UUIDs for partitions"
    return 2
  fi
  
  n_remote_log "[DEBUG] boot_uuid: $boot_uuid"
  n_remote_log "[DEBUG] root_uuid: $root_uuid"
  
  # Store UUIDs to host_config
  n_remote_host_variable boot_uuid "$boot_uuid"
  n_remote_host_variable root_uuid "$root_uuid"


  sync
  sleep 1
  udevadm settle 2>/dev/null || sleep 1
  
  # Mount root partition
  n_remote_log "[INFO] Mounting root partition to /mnt"
  
  # Ensure /mnt exists and is empty
  umount /mnt 2>/dev/null || true
  mkdir -p /mnt
  
  if ! mount "$root_device" /mnt; then
    n_remote_log "[ERROR] Failed to mount root partition"
    return 3
  fi
  
  # Create boot mount point and mount
  n_remote_log "[INFO] Mounting boot partition to /mnt/boot"
  mkdir -p /mnt/boot
  
  if ! mount "$boot_device" /mnt/boot; then
    n_remote_log "[ERROR] Failed to mount boot partition"
    umount /mnt
    return 3
  fi
  
  # Create essential directories
  n_remote_log "[DEBUG] Creating essential directories"
  mkdir -p /mnt/etc
  mkdir -p /mnt/var
  mkdir -p /mnt/proc
  mkdir -p /mnt/sys
  mkdir -p /mnt/dev
  mkdir -p /mnt/run
  
  # Create swap file (1GB)
  n_remote_log "[INFO] Creating 1GB swap file"
  
  if ! dd if=/dev/zero of=/mnt/swapfile bs=1M count=1024 status=none 2>/dev/null; then
    n_remote_log "[ERROR] Failed to create swap file"
    umount /mnt/boot
    umount /mnt
    return 4
  fi
  
  chmod 600 /mnt/swapfile
  
  if ! mkswap /mnt/swapfile >/dev/null 2>&1; then
    n_remote_log "[ERROR] Failed to initialize swap file"
    umount /mnt/boot
    umount /mnt
    return 4
  fi
  
  n_remote_log "[DEBUG] Swap file created successfully"
  
  # Generate fstab
  n_remote_log "[INFO] Generating /mnt/etc/fstab"
  
  cat > /mnt/etc/fstab << EOF
# /etc/fstab - Static filesystem table
# Generated by HPS Alpine Installer
#
# <filesystem>                            <mount>  <type>  <options>         <dump> <pass>
UUID=${root_uuid}  /        ext4    defaults          1      1
UUID=${boot_uuid}  /boot    ext4    defaults,noatime  1      2
/swapfile                                 none     swap    sw                0      0
EOF
  
  if [[ ! -f /mnt/etc/fstab ]]; then
    n_remote_log "[ERROR] Failed to create fstab"
    umount /mnt/boot
    umount /mnt
    return 4
  fi
  
  n_remote_log "[DEBUG] fstab created:"
  while IFS= read -r line; do
    [[ -n "$line" ]] && n_remote_log "[DEBUG]   $line"
  done < /mnt/etc/fstab
  
  n_remote_log "[INFO] Partition formatting complete"
  n_remote_log "[INFO] Root mounted at /mnt, boot at /mnt/boot"
  
  return 0
}


#===============================================================================
# n_installer_install_alpine
# ---------------------------
# Install Alpine Linux base system to mounted target using setup-disk.
#
# Behaviour:
#   - Verifies /mnt is mounted with root and boot filesystems
#   - Gets os_id from host_config, repo_path from IPS os_config
#   - Configures apk repositories pointing to IPS
#   - Runs setup-disk -m sys /mnt to install Alpine base system
#   - Installs linux-lts kernel and extlinux bootloader
#
# Prerequisites:
#   - n_installer_format_partitions must have been run
#   - /mnt mounted with root filesystem
#   - /mnt/boot mounted with boot filesystem
#   - os_id set in host_config (inherited from cluster)
#
# Returns:
#   0 on success
#   1 if failed to get os_id or repo_path
#   2 if /mnt not mounted properly
#   3 if failed to configure repositories
#   4 if setup-disk failed
#
# Example usage:
#   n_installer_install_alpine
#
#===============================================================================
n_installer_install_alpine() {
  n_remote_log "[INFO] Starting Alpine installation"
  
  # Verify /mnt is mounted
  if ! mountpoint -q /mnt 2>/dev/null; then
    n_remote_log "[ERROR] /mnt is not mounted"
    return 2
  fi
  
  if ! mountpoint -q /mnt/boot 2>/dev/null; then
    n_remote_log "[ERROR] /mnt/boot is not mounted"
    return 2
  fi
  
  n_remote_log "[DEBUG] Mount points verified: /mnt and /mnt/boot"
  
  # Get os_id from host_config
  local os_id
  if ! os_id=$(n_remote_host_variable os_id); then
    n_remote_log "[ERROR] Failed to get os_id from host_config"
    return 1
  fi
  
  if [[ -z "$os_id" ]]; then
    n_remote_log "[ERROR] os_id is empty"
    return 1
  fi
  
  n_remote_log "[INFO] os_id: $os_id"
  
  # Get repo_path from IPS os_config
  local repo_path
  if ! repo_path=$(n_ips_command os_variable os_id="$os_id" name=repo_path); then
    n_remote_log "[ERROR] Failed to get repo_path from IPS"
    return 1
  fi
  
  if [[ -z "$repo_path" ]]; then
    n_remote_log "[ERROR] repo_path is empty"
    return 1
  fi
  
  n_remote_log "[INFO] repo_path: $repo_path"
  
  # Get IPS hostname/IP
  local ips_host
  if ! ips_host=$(n_get_provisioning_node); then
    n_remote_log "[ERROR] Failed to determine IPS host"
    return 1
  fi
  
  n_remote_log "[DEBUG] IPS host: $ips_host"
  
  # Construct repository URLs
  local repo_base="http://${ips_host}/distros/${repo_path}/apks"
  local repo_main="${repo_base}/main"
  local repo_community="${repo_base}/community"
  
  n_remote_log "[INFO] Repository base: $repo_base"
  
  # Configure apk repositories for the live system (used by setup-disk)
  n_remote_log "[INFO] Configuring apk repositories"
  
  mkdir -p /etc/apk
  cat > /etc/apk/repositories << EOF
${repo_main}
${repo_community}
EOF
  
  if [[ ! -f /etc/apk/repositories ]]; then
    n_remote_log "[ERROR] Failed to create /etc/apk/repositories"
    return 3
  fi
  
  n_remote_log "[DEBUG] Live system repositories configured"
  
  # Also create repositories for the target system
  mkdir -p /mnt/etc/apk
  cat > /mnt/etc/apk/repositories << EOF
${repo_main}
${repo_community}
EOF
  
  if [[ ! -f /mnt/etc/apk/repositories ]]; then
    n_remote_log "[ERROR] Failed to create /mnt/etc/apk/repositories"
    return 3
  fi
  
  n_remote_log "[DEBUG] Target system repositories configured"
  
  # Update apk index
  n_remote_log "[INFO] Updating apk package index"
  if ! apk update >/dev/null 2>&1; then
    n_remote_log "[ERROR] Failed to update apk index"
    return 3
  fi
  
  # Ensure setup-disk is available (part of alpine-conf)
  if ! command -v setup-disk >/dev/null 2>&1; then
    n_remote_log "[INFO] Installing alpine-conf for setup-disk"
    if ! apk add --quiet alpine-conf >/dev/null 2>&1; then
      n_remote_log "[ERROR] Failed to install alpine-conf"
      return 4
    fi
  fi
  
  # Ensure grub tools available for bootloader install
if ! command -v grub-install >/dev/null 2>&1; then
  n_remote_log "[INFO] Installing grub package"
  apk add --quiet grub grub-bios >/dev/null 2>&1 || {
    n_remote_log "[WARNING] Failed to install grub tools"
  }
fi

  
  
  # Run setup-disk to install Alpine
  # -m sys: system disk mode (full install)
  # -k lts: use linux-lts kernel
  # -s 0: no swap (we created swapfile manually)
  n_remote_log "[INFO] Running setup-disk to install Alpine base system"
  n_remote_log "[INFO] This may take several minutes..."
  
  # Export variables that setup-disk uses
  export KERNELOPTS="quiet"
  export DISKLABEL="gpt"
  
  if ! setup-disk -m sys -k lts -s 0 /mnt 2>&1 | while IFS= read -r line; do
    n_remote_log "[DEBUG] setup-disk: $line"
  done; then
    n_remote_log "[ERROR] setup-disk failed"
    return 4
  fi


# Install GRUB bootloader to disk boot sector (required for GPT+BIOS)
n_remote_log "[INFO] Installing GRUB bootloader to disk"

# Get os_disk for grub-install target
local os_disk
os_disk=$(n_remote_host_variable os_disk) || true

if [[ -z "$os_disk" ]]; then
  n_remote_log "[ERROR] Cannot install GRUB: os_disk not set"
  return 4
fi

# For RAID, install to first disk only (GRUB handles this)
local grub_target
IFS=',' read -ra disk_array <<< "$os_disk"
grub_target="${disk_array[0]}"

n_remote_log "[DEBUG] GRUB target disk: $grub_target"

# Ensure grub-bios is installed in target
if ! chroot /mnt /bin/sh -c "apk info -e grub-bios >/dev/null 2>&1"; then
  n_remote_log "[DEBUG] Installing grub-bios in target"
  chroot /mnt /bin/sh -c "apk add --quiet grub-bios" 2>/dev/null || {
    n_remote_log "[WARNING] Failed to install grub-bios in target"
  }
fi

# Install GRUB to disk
local grub_output
grub_output=$(grub-install --target=i386-pc --boot-directory=/mnt/boot "$grub_target" 2>&1)
local grub_rc=$?

if [[ $grub_rc -ne 0 ]]; then
  n_remote_log "[ERROR] Failed to install GRUB (exit code: $grub_rc)"
  echo "$grub_output" | while IFS= read -r line; do
    n_remote_log "[ERROR] grub-install: $line"
  done
  return 4
fi

n_remote_log "[DEBUG] GRUB installed successfully"
echo "$grub_output" | while IFS= read -r line; do
  [[ -n "$line" ]] && n_remote_log "[DEBUG] grub-install: $line"
done

  

# Verify installation
n_remote_log "[INFO] Verifying installation"

if [[ ! -f /mnt/bin/busybox ]]; then
  n_remote_log "[ERROR] Installation verification failed: /mnt/bin/busybox not found"
  return 4
fi

if [[ ! -f /mnt/boot/vmlinuz-lts ]]; then
  n_remote_log "[ERROR] Installation verification failed: /mnt/boot/vmlinuz-lts not found"
  return 4
fi

# Check for bootloader (grub or extlinux)
if [[ -d /mnt/boot/grub ]]; then
  n_remote_log "[DEBUG] Bootloader: grub"
elif [[ -d /mnt/boot/extlinux ]]; then
  n_remote_log "[DEBUG] Bootloader: extlinux"
else
  n_remote_log "[ERROR] Installation verification failed: no bootloader found (checked grub, extlinux)"
  return 4
fi

n_remote_log "[INFO] Alpine base system installed successfully"
n_remote_log "[DEBUG] Kernel: linux-lts"



  
  return 0
}


#===============================================================================
# n_installer_install_hps_init
# -----------------------------
# Install HPS bootstrap library and init service to target system.
#
# Behaviour:
#   - Copies bootstrap library from running system to target
#   - Creates OpenRC local.d script to run HPS init on boot
#   - Enables local service in default runlevel
#   - Configures root with no password (development mode)
#   - Sets hostname from host_config
#
# Prerequisites:
#   - n_installer_install_alpine must have been run
#   - /mnt mounted with installed Alpine system
#   - Bootstrap library available at /usr/local/lib/hps-bootstrap-lib.sh
#
# Returns:
#   0 on success
#   1 if bootstrap library not found
#   2 if failed to create init script
#   3 if failed to configure system
#
# Example usage:
#   n_installer_install_hps_init
#
#===============================================================================
n_installer_install_hps_init() {
  n_remote_log "[INFO] Installing HPS init system"
  
  # Verify target is mounted
  if ! mountpoint -q /mnt 2>/dev/null; then
    n_remote_log "[ERROR] /mnt is not mounted"
    return 1
  fi
  
  # Source bootstrap library path
  local bootstrap_src="/usr/local/lib/hps-bootstrap-lib.sh"
  local bootstrap_dst="/mnt/usr/local/lib/hps-bootstrap-lib.sh"
  
  # Verify source bootstrap exists
  if [[ ! -f "$bootstrap_src" ]]; then
    n_remote_log "[ERROR] Bootstrap library not found: $bootstrap_src"
    return 1
  fi
  
  # Create target directory
  n_remote_log "[INFO] Installing bootstrap library"
  mkdir -p /mnt/usr/local/lib
  
  if ! cp "$bootstrap_src" "$bootstrap_dst"; then
    n_remote_log "[ERROR] Failed to copy bootstrap library"
    return 1
  fi
  
  chmod 0755 "$bootstrap_dst"
  n_remote_log "[DEBUG] Bootstrap library installed: $bootstrap_dst"
  
  # Create local.d init script
  n_remote_log "[INFO] Creating HPS init script"
  mkdir -p /mnt/etc/local.d
  
  cat > /mnt/etc/local.d/z-hps-init.start << 'EOF'
#!/bin/sh
#===============================================================================
# HPS Init Runner
# Loads node functions from IPS and executes init sequence
#===============================================================================

echo "[HPS] Starting HPS init sequence"

# Source bootstrap library
if [ ! -f /usr/local/lib/hps-bootstrap-lib.sh ]; then
  echo "[HPS] ERROR: Bootstrap library not found"
  logger -t hps-init -p user.err "Bootstrap library not found"
  exit 1
fi

. /usr/local/lib/hps-bootstrap-lib.sh

# Load node functions (with caching and update from IPS)
echo "[HPS] Loading node functions from IPS"
if ! hps_load_node_functions; then
  echo "[HPS] ERROR: Failed to load node functions"
  logger -t hps-init -p user.err "Failed to load node functions"
  exit 1
fi

# Run init sequence
echo "[HPS] Executing init sequence"
if ! n_init_run; then
  echo "[HPS] WARNING: Init sequence completed with errors"
  logger -t hps-init -p user.warning "Init sequence completed with errors"
  exit 0
fi

echo "[HPS] Init sequence completed successfully"
logger -t hps-init -p user.info "Init sequence completed successfully"
exit 0
EOF
  
  if [[ ! -f /mnt/etc/local.d/z-hps-init.start ]]; then
    n_remote_log "[ERROR] Failed to create init script"
    return 2
  fi
  
  chmod 0755 /mnt/etc/local.d/z-hps-init.start
  n_remote_log "[DEBUG] Init script created: /mnt/etc/local.d/z-hps-init.start"
  
  # Enable local service in default runlevel
  n_remote_log "[INFO] Enabling local service"
  mkdir -p /mnt/etc/runlevels/default
  
  if [[ ! -e /mnt/etc/runlevels/default/local ]]; then
    ln -s /etc/init.d/local /mnt/etc/runlevels/default/local
  fi
  
  n_remote_log "[DEBUG] Local service enabled in default runlevel"
  
  # Configure root with no password (development mode)
  n_remote_log "[INFO] Configuring root account (no password - dev mode)"
  
  if [[ -f /mnt/etc/shadow ]]; then
    # Remove password hash for root (set to empty)
    sed -i 's/^root:[^:]*:/root::/' /mnt/etc/shadow
    n_remote_log "[DEBUG] Root password removed"
  else
    n_remote_log "[WARNING] /mnt/etc/shadow not found, skipping password config"
  fi
  
  # Get hostname from host_config
  local hostname
  hostname=$(n_remote_host_variable hostname 2>/dev/null) || hostname="alpine-sch"
  
  n_remote_log "[INFO] Setting hostname: $hostname"
  echo "$hostname" > /mnt/etc/hostname
  
  # Configure /etc/hosts
  cat > /mnt/etc/hosts << EOF
127.0.0.1	localhost localhost.localdomain
127.0.1.1	${hostname} ${hostname}.localdomain

::1		localhost localhost.localdomain
EOF
  
  n_remote_log "[DEBUG] Hostname and hosts configured"
  
  # Ensure bash is available (required for HPS functions)
  n_remote_log "[INFO] Ensuring bash is installed in target"
  if ! chroot /mnt /bin/sh -c "apk info -e bash >/dev/null 2>&1"; then
    n_remote_log "[DEBUG] Installing bash in target system"
    chroot /mnt /bin/sh -c "apk add --quiet bash" 2>/dev/null || {
      n_remote_log "[WARNING] Failed to install bash, may be installed later"
    }
  fi
  
  # Enable networking service
  n_remote_log "[INFO] Enabling networking service"
  if [[ ! -e /mnt/etc/runlevels/default/networking ]]; then
    ln -s /etc/init.d/networking /mnt/etc/runlevels/default/networking 2>/dev/null || true
  fi
  
  # Enable sshd for remote access during development
  n_remote_log "[INFO] Enabling SSH service"
  if [[ ! -e /mnt/etc/runlevels/default/sshd ]]; then
    ln -s /etc/init.d/sshd /mnt/etc/runlevels/default/sshd 2>/dev/null || true
  fi
  
  # Configure SSH to allow root login without password (dev mode)
  if [[ -f /mnt/etc/ssh/sshd_config ]]; then
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /mnt/etc/ssh/sshd_config
    sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords yes/' /mnt/etc/ssh/sshd_config
    n_remote_log "[DEBUG] SSH configured for root access"
  fi
  
  n_remote_log "[INFO] HPS init system installed successfully"
  
  return 0
}


#===============================================================================
# n_installer_finalize
# ---------------------
# Finalize installation, save RAID config, update state, and reboot.
#
# Behaviour:
#   - Syncs filesystems
#   - If RAID1: Saves mdadm.conf to target for array detection on boot
#   - Unmounts /mnt/boot and /mnt
#   - Updates host_config STATE to INSTALLED
#   - Reboots the system
#
# Prerequisites:
#   - All installer functions must have been run
#   - /mnt and /mnt/boot mounted
#
# Returns:
#   0 on success (before reboot)
#   1 if unmount fails
#   2 if state update fails
#   (Does not return if reboot succeeds)
#
# Example usage:
#   n_installer_finalize
#
#===============================================================================
n_installer_finalize() {
  n_remote_log "[INFO] Finalizing installation"
  
  # Sync filesystems
  n_remote_log "[DEBUG] Syncing filesystems"
  sync
  
  # Check if RAID1 was used (md devices exist)
  if [[ -e /dev/md0 ]] || [[ -e /dev/md1 ]]; then
    n_remote_log "[INFO] RAID1 detected, saving mdadm configuration"
    
    # Create mdadm.conf in target system
    mkdir -p /mnt/etc/mdadm
    
    # Generate mdadm.conf
    {
      echo "# mdadm.conf - Generated by HPS Alpine Installer"
      echo "MAILADDR root"
      mdadm --detail --scan
    } > /mnt/etc/mdadm/mdadm.conf
    
    if [[ -f /mnt/etc/mdadm/mdadm.conf ]]; then
      n_remote_log "[DEBUG] mdadm.conf created"
      
      # Log the config
      while IFS= read -r line; do
        [[ -n "$line" ]] && n_remote_log "[DEBUG]   $line"
      done < /mnt/etc/mdadm/mdadm.conf
    else
      n_remote_log "[WARNING] Failed to create mdadm.conf"
    fi
    
    # Ensure mdadm is installed and enabled in target
    if chroot /mnt /bin/sh -c "apk info -e mdadm >/dev/null 2>&1"; then
      n_remote_log "[DEBUG] mdadm already installed in target"
    else
      n_remote_log "[INFO] Installing mdadm in target system"
      chroot /mnt /bin/sh -c "apk add --quiet mdadm" 2>/dev/null || {
        n_remote_log "[WARNING] Failed to install mdadm in target"
      }
    fi
    
    # Enable mdadm service
    if [[ ! -e /mnt/etc/runlevels/boot/mdadm ]]; then
      ln -s /etc/init.d/mdadm /mnt/etc/runlevels/boot/mdadm 2>/dev/null || true
      n_remote_log "[DEBUG] mdadm service enabled in boot runlevel"
    fi
    
    # Update initramfs to include mdadm
    n_remote_log "[INFO] Updating initramfs for RAID support"
    chroot /mnt /bin/sh -c "mkinitfs" 2>/dev/null || {
      n_remote_log "[WARNING] Failed to update initramfs"
    }
  fi
  
  # Sync again after any changes
  sync
  sleep 1
  
  # Unmount filesystems
  n_remote_log "[INFO] Unmounting filesystems"
  
  if mountpoint -q /mnt/boot 2>/dev/null; then
    if ! umount /mnt/boot; then
      n_remote_log "[ERROR] Failed to unmount /mnt/boot"
      return 1
    fi
    n_remote_log "[DEBUG] Unmounted /mnt/boot"
  fi
  
  if mountpoint -q /mnt 2>/dev/null; then
    if ! umount /mnt; then
      n_remote_log "[ERROR] Failed to unmount /mnt"
      return 1
    fi
    n_remote_log "[DEBUG] Unmounted /mnt"
  fi
  
  # Update host_config STATE to INSTALLED
  n_remote_log "[INFO] Updating host state to INSTALLED"
  
  if ! n_remote_host_variable STATE "INSTALLED"; then
    n_remote_log "[ERROR] Failed to update STATE to INSTALLED"
    return 2
  fi
  
  n_remote_log "[INFO] Installation complete"
  n_remote_log "[INFO] Rebooting system..."
  
  # Final sync
  sync
  sleep 2
  
  # Reboot
  reboot
  
  # Should not reach here
  return 0
}


#===============================================================================
# n_installer_run
# ----------------
# Master function to run complete Alpine SCH installation.
#
# Behaviour:
#   - Executes all installer functions in sequence
#   - Logs progress and errors to IPS
#   - Reboots on successful completion
#
# Sequence:
#   1. n_installer_detect_target_disks - Find OS disk(s)
#   2. n_installer_partition_disks - Create GPT partitions
#   3. n_installer_format_partitions - Format ext4, create swap
#   4. n_installer_install_alpine - Install Alpine base system
#   5. n_installer_install_hps_init - Install HPS bootstrap and init
#   6. n_installer_finalize - Save config, unmount, reboot
#
# Returns:
#   Does not return on success (reboots)
#   1-6 indicating which step failed
#
# Example usage:
#   n_installer_run
#
#===============================================================================
n_installer_run() {
  n_remote_log "[INFO] =============================================="
  n_remote_log "[INFO] Starting Alpine SCH Installation"
  n_remote_log "[INFO] =============================================="
  
  # Update state to INSTALLING
  n_remote_host_variable STATE "INSTALLING"
  
  # Step 1: Detect target disks
  n_remote_log "[INFO] Step 1/6: Detecting target disks"
  if ! n_installer_detect_target_disks; then
    n_remote_log "[ERROR] Step 1 failed: Disk detection"
    n_remote_host_variable STATE "INSTALL_FAILED"
    n_remote_host_variable INSTALL_ERROR "disk_detection"
    return 1
  fi
  
  # Step 2: Partition disks
  n_remote_log "[INFO] Step 2/6: Partitioning disks"
  if ! n_installer_partition_disks; then
    n_remote_log "[ERROR] Step 2 failed: Partitioning"
    n_remote_host_variable STATE "INSTALL_FAILED"
    n_remote_host_variable INSTALL_ERROR "partitioning"
    return 2
  fi
  
  # Step 3: Format partitions
  n_remote_log "[INFO] Step 3/6: Formatting partitions"
  if ! n_installer_format_partitions; then
    n_remote_log "[ERROR] Step 3 failed: Formatting"
    n_remote_host_variable STATE "INSTALL_FAILED"
    n_remote_host_variable INSTALL_ERROR "formatting"
    return 3
  fi
  
  # Step 4: Install Alpine
  n_remote_log "[INFO] Step 4/6: Installing Alpine base system"
  if ! n_installer_install_alpine; then
    n_remote_log "[ERROR] Step 4 failed: Alpine installation"
    n_remote_host_variable STATE "INSTALL_FAILED"
    n_remote_host_variable INSTALL_ERROR "alpine_install"
    return 4
  fi
  
  # Step 5: Install HPS init
  n_remote_log "[INFO] Step 5/6: Installing HPS init system"
  if ! n_installer_install_hps_init; then
    n_remote_log "[ERROR] Step 5 failed: HPS init installation"
    n_remote_host_variable STATE "INSTALL_FAILED"
    n_remote_host_variable INSTALL_ERROR "hps_init"
    return 5
  fi
  
  # Step 6: Finalize and reboot
  n_remote_log "[INFO] Step 6/6: Finalizing installation"
  if ! n_installer_finalize; then
    n_remote_log "[ERROR] Step 6 failed: Finalization"
    n_remote_host_variable STATE "INSTALL_FAILED"
    n_remote_host_variable INSTALL_ERROR "finalize"
    return 6
  fi
  
  # Should not reach here (finalize reboots)
  return 0
}



#===============================================================================
# n_installer_cleanup
# --------------------
# Clean up and wipe partitions from a failed or previous installation.
#
# Behaviour:
#   - Reads os_disk, boot_device, root_device from host_config
#   - Unmounts any mounted partitions (/mnt/boot, /mnt)
#   - Stops any active md arrays if RAID was used
#   - Wipes filesystem signatures from partitions
#   - Optionally wipes partition table from os_disk
#   - Clears installation-related host_config variables
#   - Prompts for confirmation unless -f/--force flag provided
#
# Arguments:
#   -f, --force    Skip confirmation prompts
#   --wipe-table   Also wipe the partition table (requires re-partitioning)
#
# Returns:
#   0 on success
#   1 if failed to read host_config or no devices configured
#   2 if user cancelled
#   3 if cleanup operation failed
#
# Example usage:
#   n_installer_cleanup           # Interactive with prompts
#   n_installer_cleanup -f        # Force without prompts
#   n_installer_cleanup --wipe-table -f  # Wipe everything including partition table
#
#===============================================================================
n_installer_cleanup() {
  local force=0
  local wipe_table=0

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--force)
        force=1
        shift
        ;;
      --wipe-table)
        wipe_table=1
        shift
        ;;
      *)
        echo "Usage: n_installer_cleanup [-f|--force] [--wipe-table]" >&2
        return 1
        ;;
    esac
  done

  n_remote_log "[INFO] Starting installation cleanup"

  # Read device configuration from host_config
  local os_disk=""
  local boot_device=""
  local root_device=""
  local boot_uuid=""
  local root_uuid=""

  os_disk=$(n_remote_host_variable os_disk 2>/dev/null) || true
  boot_device=$(n_remote_host_variable boot_device 2>/dev/null) || true
  root_device=$(n_remote_host_variable root_device 2>/dev/null) || true
  boot_uuid=$(n_remote_host_variable boot_uuid 2>/dev/null) || true
  root_uuid=$(n_remote_host_variable root_uuid 2>/dev/null) || true

  # Check if we have anything to clean
  if [[ -z "$os_disk" ]] && [[ -z "$boot_device" ]] && [[ -z "$root_device" ]]; then
    n_remote_log "[WARNING] No installation devices found in host_config"
    echo "No installation devices configured. Nothing to clean." >&2
    return 1
  fi

  # Display what we found
  n_remote_log "[INFO] Found configuration:"
  echo "=== Installation Cleanup ===" >&2
  echo "Devices found in host_config:" >&2
  [[ -n "$os_disk" ]] && echo "  os_disk:      $os_disk" >&2
  [[ -n "$boot_device" ]] && echo "  boot_device:  $boot_device" >&2
  [[ -n "$root_device" ]] && echo "  root_device:  $root_device" >&2
  [[ -n "$boot_uuid" ]] && echo "  boot_uuid:    $boot_uuid" >&2
  [[ -n "$root_uuid" ]] && echo "  root_uuid:    $root_uuid" >&2
  echo "" >&2

  # Verify devices exist
  local devices_to_wipe=()

  if [[ -n "$boot_device" ]] && [[ -b "$boot_device" ]]; then
    devices_to_wipe+=("$boot_device")
    n_remote_log "[DEBUG] boot_device exists: $boot_device"
  elif [[ -n "$boot_device" ]]; then
    n_remote_log "[WARNING] boot_device not found: $boot_device"
    echo "  WARNING: boot_device not found: $boot_device" >&2
  fi

  if [[ -n "$root_device" ]] && [[ -b "$root_device" ]]; then
    devices_to_wipe+=("$root_device")
    n_remote_log "[DEBUG] root_device exists: $root_device"
  elif [[ -n "$root_device" ]]; then
    n_remote_log "[WARNING] root_device not found: $root_device"
    echo "  WARNING: root_device not found: $root_device" >&2
  fi

  # Check for md arrays (RAID)
  local md_arrays=()
  if [[ -e /dev/md0 ]]; then
    md_arrays+=("/dev/md0")
  fi
  if [[ -e /dev/md1 ]]; then
    md_arrays+=("/dev/md1")
  fi

  if [[ ${#md_arrays[@]} -gt 0 ]]; then
    echo "  MD arrays found: ${md_arrays[*]}" >&2
    n_remote_log "[INFO] MD arrays found: ${md_arrays[*]}"
  fi

  # Show what will be done
  echo "Actions to perform:" >&2
  echo "  1. Unmount /mnt/boot and /mnt (if mounted)" >&2
  [[ ${#md_arrays[@]} -gt 0 ]] && echo "  2. Stop MD arrays: ${md_arrays[*]}" >&2
  echo "  3. Wipe filesystem signatures from: ${devices_to_wipe[*]}" >&2
  [[ $wipe_table -eq 1 ]] && [[ -n "$os_disk" ]] && echo "  4. Wipe partition table on: $os_disk" >&2
  echo "  5. Clear host_config variables" >&2
  echo "" >&2

  # Confirmation
  if [[ $force -eq 0 ]]; then
    echo -n "Proceed with cleanup? [y/N]: " >&2
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      n_remote_log "[INFO] Cleanup cancelled by user"
      echo "Cancelled." >&2
      return 2
    fi
  else
    n_remote_log "[INFO] Force flag set, skipping confirmation"
  fi

  # Step 1: Unmount filesystems
  n_remote_log "[INFO] Unmounting filesystems"
  echo "Unmounting filesystems..." >&2

  if mountpoint -q /mnt/boot 2>/dev/null; then
    if umount /mnt/boot 2>/dev/null; then
      n_remote_log "[DEBUG] Unmounted /mnt/boot"
      echo "  Unmounted /mnt/boot" >&2
    else
      n_remote_log "[WARNING] Failed to unmount /mnt/boot"
      echo "  WARNING: Failed to unmount /mnt/boot" >&2
    fi
  fi

  if mountpoint -q /mnt 2>/dev/null; then
    if umount /mnt 2>/dev/null; then
      n_remote_log "[DEBUG] Unmounted /mnt"
      echo "  Unmounted /mnt" >&2
    else
      n_remote_log "[WARNING] Failed to unmount /mnt"
      echo "  WARNING: Failed to unmount /mnt" >&2
    fi
  fi

  # Step 2: Stop MD arrays
  if [[ ${#md_arrays[@]} -gt 0 ]]; then
    n_remote_log "[INFO] Stopping MD arrays"
    echo "Stopping MD arrays..." >&2

    for md in "${md_arrays[@]}"; do
      if mdadm --stop "$md" 2>/dev/null; then
        n_remote_log "[DEBUG] Stopped $md"
        echo "  Stopped $md" >&2
      else
        n_remote_log "[WARNING] Failed to stop $md"
        echo "  WARNING: Failed to stop $md" >&2
      fi
    done

    # Zero superblocks on member devices
    if [[ -n "$os_disk" ]]; then
      IFS=',' read -ra disks <<< "$os_disk"
      for disk in "${disks[@]}"; do
        n_remote_log "[DEBUG] Zeroing MD superblocks on ${disk}*"
        mdadm --zero-superblock "${disk}"* 2>/dev/null || true
      done
    fi
  fi

  # Step 3: Wipe filesystem signatures
  if [[ ${#devices_to_wipe[@]} -gt 0 ]]; then
    n_remote_log "[INFO] Wiping filesystem signatures"
    echo "Wiping filesystem signatures..." >&2

    for dev in "${devices_to_wipe[@]}"; do
      if [[ -b "$dev" ]]; then
        local wipe_output
        wipe_output=$(wipefs -a "$dev" 2>&1)
        local wipe_rc=$?
        if [[ $wipe_rc -eq 0 ]]; then
          n_remote_log "[DEBUG] Wiped signatures from $dev"
          echo "  Wiped: $dev" >&2
        else
          n_remote_log "[WARNING] Failed to wipe $dev: $wipe_output"
          echo "  WARNING: Failed to wipe $dev" >&2
        fi
      fi
    done
  fi

  # Step 4: Wipe partition table (optional)
  if [[ $wipe_table -eq 1 ]] && [[ -n "$os_disk" ]]; then
    n_remote_log "[INFO] Wiping partition table"
    echo "Wiping partition table..." >&2

    IFS=',' read -ra disks <<< "$os_disk"
    for disk in "${disks[@]}"; do
      if [[ -b "$disk" ]]; then
        local wipe_output
        wipe_output=$(wipefs -a "$disk" 2>&1)
        local wipe_rc=$?
        if [[ $wipe_rc -eq 0 ]]; then
          n_remote_log "[DEBUG] Wiped partition table from $disk"
          echo "  Wiped partition table: $disk" >&2
        else
          n_remote_log "[WARNING] Failed to wipe partition table on $disk: $wipe_output"
          echo "  WARNING: Failed to wipe partition table on $disk" >&2
        fi
      fi
    done
  fi

  # Step 5: Clear host_config variables
  n_remote_log "[INFO] Clearing host_config variables"
  echo "Clearing host_config..." >&2

  local vars_to_clear=("boot_device" "root_device" "boot_uuid" "root_uuid" "INSTALL_ERROR")
  [[ $wipe_table -eq 1 ]] && vars_to_clear+=("os_disk")

  for var in "${vars_to_clear[@]}"; do
    if n_remote_host_variable "$var" "" 2>/dev/null; then
      n_remote_log "[DEBUG] Cleared $var"
      echo "  Cleared: $var" >&2
    fi
  done

  # Reset state to allow re-installation
  n_remote_host_variable STATE "INSTALLING" 2>/dev/null || true
  n_remote_log "[DEBUG] Reset STATE to INSTALLING"
  echo "  Reset STATE to INSTALLING" >&2

  n_remote_log "[INFO] Cleanup complete"
  echo "" >&2
  echo "Cleanup complete." >&2

  return 0
}

#===============================================================================
# Alpine Linux Rescue Functions
# For use during network rescue boot (NRB) mode
#===============================================================================


#===============================================================================
# n_rescue_load_modules
# ---------------------
# Load all kernel modules required for rescue operations.
#
# Behaviour:
#   - Loads ext4 modules (filesystem support)
#   - Loads ZFS modules if available (for SCH storage nodes)
#   - Loads mdadm/RAID modules (for RAID1 systems)
#   - Reports success/failure for each module group
#   - Continues on partial failure (best-effort loading)
#
# Returns:
#   0 if all modules loaded successfully
#   1 if some modules failed (non-fatal, continues to rescue shell)
#
# Example usage:
#   n_rescue_load_modules
#
#===============================================================================
n_rescue_load_modules() {
  local failed=0
  
  n_remote_log "[INFO] Loading rescue mode kernel modules"
  echo "=== Loading Kernel Modules ===" >&2
  
  # Load ext4 modules
  echo -n "Loading ext4 modules... " >&2
  if n_installer_load_ext4_modules >/dev/null 2>&1; then
    echo "OK" >&2
    n_remote_log "[INFO] ext4 modules loaded"
  else
    echo "FAILED" >&2
    n_remote_log "[WARNING] Failed to load ext4 modules"
    failed=1
  fi
  
  # Load ZFS modules
  echo -n "Loading ZFS modules... " >&2
  if command -v modprobe >/dev/null 2>&1; then
    if modprobe zfs 2>/dev/null; then
      echo "OK" >&2
      n_remote_log "[INFO] ZFS modules loaded"
    else
      echo "NOT AVAILABLE" >&2
      n_remote_log "[DEBUG] ZFS modules not available (may not be needed)"
    fi
  else
    echo "SKIPPED (no modprobe)" >&2
  fi
  
  # Load mdadm/RAID modules
  echo -n "Loading RAID modules... " >&2
  local raid_modules=("raid1" "raid456")
  local raid_loaded=0
  
  for mod in "${raid_modules[@]}"; do
    if command -v modprobe >/dev/null 2>&1; then
      if modprobe "$mod" 2>/dev/null; then
        raid_loaded=1
      fi
    fi
  done
  
  if [[ $raid_loaded -eq 1 ]]; then
    echo "OK" >&2
    n_remote_log "[INFO] RAID modules loaded"
  else
    echo "NOT AVAILABLE" >&2
    n_remote_log "[DEBUG] RAID modules not available (may not be needed)"
  fi
  
  # Ensure mdadm tool is available
  if ! command -v mdadm >/dev/null 2>&1; then
    echo -n "Installing mdadm tool... " >&2
    if apk add --quiet mdadm 2>/dev/null; then
      echo "OK" >&2
      n_remote_log "[INFO] mdadm tool installed"
    else
      echo "FAILED" >&2
      n_remote_log "[WARNING] Failed to install mdadm"
    fi
  fi
  
  echo "" >&2
  
  return $failed
}


#===============================================================================
# n_rescue_display_config
# -----------------------
# Display disk configuration from IPS host_config.
#
# Behaviour:
#   - Reads os_disk, boot_device, root_device, boot_uuid, root_uuid
#   - Displays configuration if found
#   - Shows suggested mount commands if devices exist
#   - Reports if no configuration found (blank disk scenario)
#   - Does NOT attempt any mounting operations
#
# Returns:
#   0 if configuration displayed
#   1 if no configuration found
#
# Example usage:
#   n_rescue_display_config
#
#===============================================================================
n_rescue_display_config() {
  n_remote_log "[INFO] Displaying disk configuration from IPS"
  
  # Read configuration from host_config
  local os_disk=""
  local boot_device=""
  local root_device=""
  local boot_uuid=""
  local root_uuid=""
  
  os_disk=$(n_remote_host_variable os_disk 2>/dev/null) || true
  boot_device=$(n_remote_host_variable boot_device 2>/dev/null) || true
  root_device=$(n_remote_host_variable root_device 2>/dev/null) || true
  boot_uuid=$(n_remote_host_variable boot_uuid 2>/dev/null) || true
  root_uuid=$(n_remote_host_variable root_uuid 2>/dev/null) || true
  
  echo "=== Disk Configuration from IPS ===" >&2
  echo "" >&2
  
  # Check if we have any configuration
  if [[ -z "$os_disk" ]] && [[ -z "$boot_device" ]] && [[ -z "$root_device" ]]; then
    echo "No disk configuration found in host_config." >&2
    echo "This may be a new system or installation failed before disk detection." >&2
    echo "" >&2
    echo "Use 'lsblk' or 'fdisk -l' to explore available disks." >&2
    n_remote_log "[INFO] No disk configuration in host_config"
    return 1
  fi
  
  # Display configuration
  [[ -n "$os_disk" ]] && echo "OS Disk:       $os_disk" >&2
  [[ -n "$boot_device" ]] && echo "Boot Device:   $boot_device" >&2
  [[ -n "$root_device" ]] && echo "Root Device:   $root_device" >&2
  [[ -n "$boot_uuid" ]] && echo "Boot UUID:     $boot_uuid" >&2
  [[ -n "$root_uuid" ]] && echo "Root UUID:     $root_uuid" >&2
  echo "" >&2
  
  # Check if devices actually exist
  local devices_exist=0
  
  if [[ -n "$root_device" ]] && [[ -b "$root_device" ]]; then
    devices_exist=1
    echo "Root device exists: $root_device" >&2
  elif [[ -n "$root_device" ]]; then
    echo "WARNING: Root device not found: $root_device" >&2
  fi
  
  if [[ -n "$boot_device" ]] && [[ -b "$boot_device" ]]; then
    devices_exist=1
    echo "Boot device exists: $boot_device" >&2
  elif [[ -n "$boot_device" ]]; then
    echo "WARNING: Boot device not found: $boot_device" >&2
  fi
  
  echo "" >&2
  
  # Provide suggested commands if devices exist
  if [[ $devices_exist -eq 1 ]]; then
    echo "Suggested mount commands:" >&2
    [[ -n "$root_device" ]] && [[ -b "$root_device" ]] && \
      echo "  n_rescue_mount $root_device" >&2
    [[ -n "$root_device" ]] && [[ -b "$root_device" ]] && \
      [[ -n "$boot_device" ]] && [[ -b "$boot_device" ]] && \
      echo "  # OR for both:" >&2
    [[ -n "$root_device" ]] && [[ -b "$root_device" ]] && \
      [[ -n "$boot_device" ]] && [[ -b "$boot_device" ]] && \
      echo "  n_rescue_mount $root_device $boot_device" >&2
    echo "" >&2
  else
    echo "No valid block devices found from configuration." >&2
    echo "Use 'lsblk' to explore available devices." >&2
    echo "" >&2
  fi
  
  n_remote_log "[INFO] Disk configuration displayed"
  return 0
}


#===============================================================================
# n_rescue_show_help
# ------------------
# Display rescue mode help and available commands.
#
# Behaviour:
#   - Displays rescue mode banner
#   - Lists all available n_rescue_* commands
#   - Shows common rescue workflows
#   - Displays exit instructions
#
# Returns:
#   0 always
#
# Example usage:
#   n_rescue_show_help
#
#===============================================================================
n_rescue_show_help() {
  n_remote_log "[INFO] Displaying rescue mode help"
  
  cat >&2 << 'EOF'

╔══════════════════════════════════════════════════════════════════════════╗
║                        HPS NETWORK RESCUE BOOT                           ║
║                                                                          ║
║  You are in rescue mode with full network connectivity and disk access. ║
║  All HPS node functions (n_*) are available.                            ║
╚══════════════════════════════════════════════════════════════════════════╝

AVAILABLE RESCUE COMMANDS
─────────────────────────

  n_rescue_show_help           Show this help message
  n_rescue_display_config      Display disk config from IPS
  n_rescue_mount [root] [boot] Mount installed filesystems
  n_rescue_chroot              Chroot into installed system
  n_rescue_reinstall_grub      Reinstall GRUB bootloader
  n_rescue_fsck [device]       Run filesystem check

COMMON WORKFLOWS
────────────────

  1. GRUB Repair (boot failure):
     
     n_rescue_mount              # Mount filesystems from config
     n_rescue_reinstall_grub     # Reinstall bootloader
     n_remote_host_variable STATE INSTALLED
     reboot

  2. Filesystem Repair:
     
     n_rescue_fsck /dev/vdb3     # Check/repair filesystem
     n_remote_host_variable STATE INSTALLED
     reboot

  3. Manual Recovery:
     
     n_rescue_mount
     n_rescue_chroot             # Get shell in installed system
     # ... perform repairs ...
     exit
     umount /mnt/boot /mnt
     n_remote_host_variable STATE INSTALLED
     reboot

  4. Inspect Without Mounting:
     
     lsblk                       # List block devices
     fdisk -l                    # Show partition tables
     blkid                       # Show filesystem UUIDs
     mdadm --detail /dev/md0     # Check RAID status

EXITING RESCUE MODE
───────────────────

  To exit rescue mode and attempt normal boot:

    n_remote_host_variable STATE INSTALLED
    reboot

  Or to restart installation from scratch:

    n_remote_host_variable STATE INSTALLING
    reboot

REMOTE LOGGING
──────────────

  All rescue operations are logged to IPS.
  Use n_remote_log to add custom log messages:

    n_remote_log "[INFO] Your message here"

EOF

  n_remote_log "[INFO] Rescue mode help displayed"
  return 0
}


#===============================================================================
# n_rescue_mount
# --------------
# Mount installed filesystems to /mnt for rescue operations.
#
# Behaviour:
#   - If called with no args, reads boot_device and root_device from config
#   - If called with args: n_rescue_mount <root_device> [boot_device]
#   - Unmounts /mnt if already mounted
#   - Mounts root to /mnt
#   - Mounts boot to /mnt/boot if boot_device specified
#   - Creates essential directories (/mnt/proc, /mnt/sys, /mnt/dev)
#
# Arguments:
#   $1 - root_device (optional, reads from config if not provided)
#   $2 - boot_device (optional)
#
# Returns:
#   0 on success
#   1 if failed to read config or invalid device
#   2 if mount operation failed
#
# Example usage:
#   n_rescue_mount                      # Mount from config
#   n_rescue_mount /dev/vdb3            # Mount root only
#   n_rescue_mount /dev/vdb3 /dev/vdb2  # Mount root and boot
#
#===============================================================================
n_rescue_mount() {
  local root_device="$1"
  local boot_device="$2"
  
  n_remote_log "[INFO] Starting rescue mount operation"
  
  # If no args provided, read from config
  if [[ -z "$root_device" ]]; then
    echo "Reading device configuration from IPS..." >&2
    
    root_device=$(n_remote_host_variable root_device 2>/dev/null) || true
    boot_device=$(n_remote_host_variable boot_device 2>/dev/null) || true
    
    if [[ -z "$root_device" ]]; then
      echo "ERROR: No root_device in config and none specified" >&2
      echo "Usage: n_rescue_mount <root_device> [boot_device]" >&2
      n_remote_log "[ERROR] No root_device available"
      return 1
    fi
    
    echo "  Root: $root_device" >&2
    [[ -n "$boot_device" ]] && echo "  Boot: $boot_device" >&2
  fi
  
  # Verify root device exists
  if [[ ! -b "$root_device" ]]; then
    echo "ERROR: Root device not found or not a block device: $root_device" >&2
    n_remote_log "[ERROR] Root device not found: $root_device"
    return 1
  fi
  
  # Verify boot device if specified
  if [[ -n "$boot_device" ]] && [[ ! -b "$boot_device" ]]; then
    echo "ERROR: Boot device not found or not a block device: $boot_device" >&2
    n_remote_log "[ERROR] Boot device not found: $boot_device"
    return 1
  fi
  
  # Unmount /mnt if already mounted
  if mountpoint -q /mnt 2>/dev/null; then
    echo "Unmounting existing /mnt..." >&2
    umount -R /mnt 2>/dev/null || umount /mnt 2>/dev/null || true
  fi
  
  # Ensure /mnt exists
  mkdir -p /mnt
  
  # Mount root
  echo "Mounting root: $root_device -> /mnt" >&2
  if ! mount "$root_device" /mnt 2>&1 | while IFS= read -r line; do
    echo "  $line" >&2
    n_remote_log "[DEBUG] mount: $line"
  done; then
    echo "ERROR: Failed to mount root device" >&2
    n_remote_log "[ERROR] Failed to mount root: $root_device"
    return 2
  fi
  
  echo "  Root mounted successfully" >&2
  n_remote_log "[INFO] Root mounted: $root_device -> /mnt"
  
  # Mount boot if specified
  if [[ -n "$boot_device" ]]; then
    mkdir -p /mnt/boot
    
    echo "Mounting boot: $boot_device -> /mnt/boot" >&2
    if ! mount "$boot_device" /mnt/boot 2>&1 | while IFS= read -r line; do
      echo "  $line" >&2
      n_remote_log "[DEBUG] mount: $line"
    done; then
      echo "WARNING: Failed to mount boot device" >&2
      n_remote_log "[WARNING] Failed to mount boot: $boot_device"
    else
      echo "  Boot mounted successfully" >&2
      n_remote_log "[INFO] Boot mounted: $boot_device -> /mnt/boot"
    fi
  fi
  
  # Create essential directories for chroot
  echo "Creating chroot directories..." >&2
  mkdir -p /mnt/proc /mnt/sys /mnt/dev /mnt/run
  
  echo "" >&2
  echo "Filesystems mounted successfully." >&2
  echo "Use 'n_rescue_chroot' to enter the installed system." >&2
  echo "" >&2
  
  n_remote_log "[INFO] Rescue mount complete"
  return 0
}


#===============================================================================
# n_rescue_chroot
# ---------------
# Chroot into installed system at /mnt.
#
# Behaviour:
#   - Verifies /mnt is mounted
#   - Bind mounts /proc, /sys, /dev, /run if not already mounted
#   - Executes chroot /mnt /bin/bash (or /bin/sh if bash unavailable)
#   - Cleans up bind mounts on exit
#   - Interactive shell, returns when user exits
#
# Prerequisites:
#   - Root filesystem must be mounted at /mnt
#   - Typically called after n_rescue_mount
#
# Returns:
#   0 on successful chroot and exit
#   1 if /mnt not mounted or chroot failed
#
# Example usage:
#   n_rescue_mount
#   n_rescue_chroot
#   # ... perform repairs inside chroot ...
#   exit
#
#===============================================================================
n_rescue_chroot() {
  n_remote_log "[INFO] Starting chroot into installed system"
  
  # Verify /mnt is mounted
  if ! mountpoint -q /mnt 2>/dev/null; then
    echo "ERROR: /mnt is not mounted" >&2
    echo "Run 'n_rescue_mount' first" >&2
    n_remote_log "[ERROR] Cannot chroot: /mnt not mounted"
    return 1
  fi
  
  echo "Preparing chroot environment..." >&2
  
  # Bind mount essential filesystems if not already mounted
  if ! mountpoint -q /mnt/proc 2>/dev/null; then
    mount --bind /proc /mnt/proc || mount -t proc proc /mnt/proc
  fi
  
  if ! mountpoint -q /mnt/sys 2>/dev/null; then
    mount --bind /sys /mnt/sys || mount -t sysfs sysfs /mnt/sys
  fi
  
  if ! mountpoint -q /mnt/dev 2>/dev/null; then
    mount --bind /dev /mnt/dev || mount -t devtmpfs devtmpfs /mnt/dev
  fi
  
  if ! mountpoint -q /mnt/run 2>/dev/null; then
    mount --bind /run /mnt/run 2>/dev/null || mount -t tmpfs tmpfs /mnt/run
  fi
  
  # Determine shell to use
  local shell="/bin/bash"
  if [[ ! -x "/mnt${shell}" ]]; then
    shell="/bin/sh"
  fi
  
  echo "" >&2
  echo "╔══════════════════════════════════════════════════════════════════╗" >&2
  echo "║  Entering chroot environment                                     ║" >&2
  echo "║  You are now inside the installed system                         ║" >&2
  echo "║  Type 'exit' to return to rescue shell                           ║" >&2
  echo "╚══════════════════════════════════════════════════════════════════╝" >&2
  echo "" >&2
  
  n_remote_log "[INFO] Executing chroot shell"
  
  # Execute chroot
  chroot /mnt "$shell"
  local chroot_rc=$?
  
  echo "" >&2
  echo "Exited chroot environment" >&2
  n_remote_log "[INFO] Exited chroot (rc: $chroot_rc)"
  
  # Cleanup bind mounts
  echo "Cleaning up bind mounts..." >&2
  umount /mnt/run 2>/dev/null || true
  umount /mnt/dev 2>/dev/null || true
  umount /mnt/sys 2>/dev/null || true
  umount /mnt/proc 2>/dev/null || true
  
  echo "" >&2
  n_remote_log "[INFO] Chroot cleanup complete"
  
  return 0
}


#===============================================================================
# n_rescue_reinstall_grub
# -----------------------
# Reinstall GRUB bootloader to disk.
#
# Behaviour:
#   - Detects os_disk from host_config
#   - Ensures /mnt and /mnt/boot are mounted (calls n_rescue_mount if needed)
#   - Installs grub and grub-bios packages if not present
#   - Runs grub-install --target=i386-pc --boot-directory=/mnt/boot
#   - Verifies GRUB files installed correctly
#   - Updates /mnt/boot/grub/grub.cfg if grub-mkconfig available
#
# Prerequisites:
#   - os_disk must be set in host_config
#   - Root filesystem should contain valid Alpine installation
#
# Returns:
#   0 on successful GRUB installation
#   1 if failed to read config or disk not found
#   2 if mount operations failed
#   3 if GRUB installation failed
#
# Example usage:
#   n_rescue_reinstall_grub
#
#===============================================================================
n_rescue_reinstall_grub() {
  n_remote_log "[INFO] Starting GRUB reinstallation"
  
  echo "=== GRUB Bootloader Reinstallation ===" >&2
  echo "" >&2
  
  # Get os_disk from config
  local os_disk=""
  os_disk=$(n_remote_host_variable os_disk 2>/dev/null) || true
  
  if [[ -z "$os_disk" ]]; then
    echo "ERROR: No os_disk found in host_config" >&2
    echo "Cannot determine target disk for GRUB installation" >&2
    n_remote_log "[ERROR] No os_disk in config"
    return 1
  fi
  
  # Handle RAID - extract first disk from comma-separated list
  local target_disk=""
  if [[ "$os_disk" =~ , ]]; then
    IFS=',' read -ra disks <<< "$os_disk"
    target_disk="${disks[0]}"
    echo "RAID detected: using first disk $target_disk" >&2
  else
    target_disk="$os_disk"
  fi
  
  # Verify target disk exists
  if [[ ! -b "$target_disk" ]]; then
    echo "ERROR: Target disk not found: $target_disk" >&2
    n_remote_log "[ERROR] Target disk not found: $target_disk"
    return 1
  fi
  
  echo "Target disk: $target_disk" >&2
  echo "" >&2
  
  # Ensure filesystems are mounted
  if ! mountpoint -q /mnt 2>/dev/null; then
    echo "Root not mounted, mounting filesystems..." >&2
    if ! n_rescue_mount; then
      echo "ERROR: Failed to mount filesystems" >&2
      n_remote_log "[ERROR] Failed to mount for GRUB install"
      return 2
    fi
    echo "" >&2
  else
    echo "Root already mounted at /mnt" >&2
  fi
  
  if ! mountpoint -q /mnt/boot 2>/dev/null; then
    echo "WARNING: /mnt/boot not mounted" >&2
    echo "GRUB installation may fail without boot partition" >&2
  fi
  
  # Ensure GRUB packages are installed
  echo "Checking for GRUB packages..." >&2
  local grub_packages=("grub" "grub-bios")
  local need_install=0
  
  for pkg in "${grub_packages[@]}"; do
    if ! apk info -e "$pkg" >/dev/null 2>&1; then
      need_install=1
      break
    fi
  done
  
  if [[ $need_install -eq 1 ]]; then
    echo "Installing GRUB packages..." >&2
    if ! apk add --quiet grub grub-bios 2>&1 | while IFS= read -r line; do
      echo "  $line" >&2
      n_remote_log "[DEBUG] apk: $line"
    done; then
      echo "ERROR: Failed to install GRUB packages" >&2
      n_remote_log "[ERROR] Failed to install GRUB packages"
      return 3
    fi
    echo "  GRUB packages installed" >&2
  else
    echo "  GRUB packages already installed" >&2
  fi
  
  echo "" >&2
  
  # Run grub-install
  echo "Installing GRUB to $target_disk..." >&2
  echo "(This may take a moment...)" >&2
  echo "" >&2
  
  if ! grub-install \
    --target=i386-pc \
    --boot-directory=/mnt/boot \
    "$target_disk" 2>&1 | while IFS= read -r line; do
      echo "  $line" >&2
      n_remote_log "[DEBUG] grub-install: $line"
    done; then
    echo "" >&2
    echo "ERROR: grub-install failed" >&2
    n_remote_log "[ERROR] grub-install failed"
    return 3
  fi
  
  echo "" >&2
  
  # Verify GRUB files exist
  if [[ ! -d /mnt/boot/grub/i386-pc ]]; then
    echo "ERROR: GRUB installation verification failed" >&2
    echo "/mnt/boot/grub/i386-pc directory not found" >&2
    n_remote_log "[ERROR] GRUB files not found after install"
    return 3
  fi
  
  echo "✓ GRUB installed successfully" >&2
  n_remote_log "[INFO] GRUB installed to $target_disk"
  
  # Update grub.cfg if grub-mkconfig is available
  if command -v grub-mkconfig >/dev/null 2>&1; then
    echo "" >&2
    echo "Updating GRUB configuration..." >&2
    
    if grub-mkconfig -o /mnt/boot/grub/grub.cfg 2>&1 | while IFS= read -r line; do
      echo "  $line" >&2
    done; then
      echo "✓ GRUB configuration updated" >&2
      n_remote_log "[INFO] GRUB config updated"
    else
      echo "WARNING: grub-mkconfig failed (may not be critical)" >&2
      n_remote_log "[WARNING] grub-mkconfig failed"
    fi
  fi
  
  echo "" >&2
  echo "═══════════════════════════════════════════════════════════" >&2
  echo "GRUB bootloader reinstalled successfully!" >&2
  echo "" >&2
  echo "Next steps:" >&2
  echo "  1. Verify with: ls -la /mnt/boot/grub/i386-pc/" >&2
  echo "  2. Exit rescue mode: n_remote_host_variable STATE INSTALLED" >&2
  echo "  3. Reboot: reboot" >&2
  echo "═══════════════════════════════════════════════════════════" >&2
  echo "" >&2
  
  n_remote_log "[INFO] GRUB reinstallation complete"
  return 0
}


#===============================================================================
# n_rescue_fsck
# -------------
# Run filesystem check on a device.
#
# Behaviour:
#   - Accepts device path as argument
#   - If no arg provided, shows available devices from config
#   - Ensures device is unmounted before checking
#   - Runs e2fsck -f -y (force check, auto-repair)
#   - Reports results
#
# Arguments:
#   $1 - device path (required)
#
# Returns:
#   0 if fsck completed successfully or no errors found
#   1 if device not specified or invalid
#   2 if fsck failed or found uncorrectable errors
#
# Example usage:
#   n_rescue_fsck /dev/vdb3
#
#===============================================================================
n_rescue_fsck() {
  local device="$1"
  
  n_remote_log "[INFO] Starting filesystem check"
  
  # Show help if no device specified
  if [[ -z "$device" ]]; then
    echo "Usage: n_rescue_fsck <device>" >&2
    echo "" >&2
    echo "Available devices from config:" >&2
    
    local root_device=""
    local boot_device=""
    root_device=$(n_remote_host_variable root_device 2>/dev/null) || true
    boot_device=$(n_remote_host_variable boot_device 2>/dev/null) || true
    
    [[ -n "$root_device" ]] && echo "  Root: $root_device" >&2
    [[ -n "$boot_device" ]] && echo "  Boot: $boot_device" >&2
    
    echo "" >&2
    echo "Or list all devices with: lsblk" >&2
    
    n_remote_log "[ERROR] No device specified for fsck"
    return 1
  fi
  
  # Verify device exists
  if [[ ! -b "$device" ]]; then
    echo "ERROR: Device not found or not a block device: $device" >&2
    n_remote_log "[ERROR] Device not found: $device"
    return 1
  fi
  
  echo "=== Filesystem Check: $device ===" >&2
  echo "" >&2
  
  # Check if device is mounted
  if mountpoint -q "$device" 2>/dev/null || grep -q "$device" /proc/mounts 2>/dev/null; then
    echo "Device is currently mounted, unmounting..." >&2
    
    # Try to unmount
    if ! umount "$device" 2>/dev/null; then
      echo "ERROR: Failed to unmount $device" >&2
      echo "Device may be in use or mounted at multiple locations" >&2
      echo "" >&2
      echo "Try: umount -R /mnt" >&2
      n_remote_log "[ERROR] Cannot unmount device for fsck: $device"
      return 1
    fi
    
    echo "  Unmounted successfully" >&2
    echo "" >&2
  fi
  
  # Ensure e2fsck is available
  if ! command -v e2fsck >/dev/null 2>&1; then
    echo "Installing e2fsprogs..." >&2
    if ! apk add --quiet e2fsprogs 2>/dev/null; then
      echo "ERROR: Failed to install e2fsprogs" >&2
      return 2
    fi
  fi
  
  # Run filesystem check
  echo "Running filesystem check (this may take several minutes)..." >&2
  echo "e2fsck will automatically repair errors found" >&2
  echo "" >&2
  
  # Run e2fsck
  # -f: force check even if filesystem appears clean
  # -y: assume 'yes' to all prompts (auto-repair)
  # -v: verbose
  local fsck_rc
  e2fsck -f -y -v "$device" 2>&1 | while IFS= read -r line; do
    echo "  $line" >&2
    n_remote_log "[DEBUG] e2fsck: $line"
  done
  fsck_rc=${PIPESTATUS[0]}
  
  echo "" >&2
  
  # Interpret fsck return code
  # 0: no errors
  # 1: errors corrected
  # 2: errors corrected, reboot suggested
  # 4: errors left uncorrected
  # 8: operational error
  # 16: usage error
  # 32: e2fsck cancelled by user
  # 128: shared library error
  
  case $fsck_rc in
    0)
      echo "✓ Filesystem is clean, no errors found" >&2
      n_remote_log "[INFO] fsck complete: no errors ($device)"
      return 0
      ;;
    1)
      echo "✓ Filesystem errors corrected successfully" >&2
      n_remote_log "[INFO] fsck complete: errors corrected ($device)"
      return 0
      ;;
    2)
      echo "✓ Filesystem errors corrected, reboot recommended" >&2
      n_remote_log "[WARNING] fsck complete: reboot suggested ($device)"
      return 0
      ;;
    4)
      echo "✗ ERROR: Filesystem has uncorrectable errors" >&2
      n_remote_log "[ERROR] fsck failed: uncorrectable errors ($device)"
      return 2
      ;;
    8)
      echo "✗ ERROR: Operational error during fsck" >&2
      n_remote_log "[ERROR] fsck operational error ($device)"
      return 2
      ;;
    *)
      echo "✗ ERROR: fsck failed with code $fsck_rc" >&2
      n_remote_log "[ERROR] fsck failed with code $fsck_rc ($device)"
      return 2
      ;;
  esac
}

