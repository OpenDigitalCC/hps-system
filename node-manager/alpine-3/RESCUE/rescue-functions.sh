#===============================================================================
# Alpine Linux Rescue Functions
# For use during network rescue boot (NRB) mode
#===============================================================================


#===============================================================================
# n_rescue_validate_device
# ------------------------
# Validate that a device exists and is a block device.
#
# Behaviour:
#   - Checks device string is non-empty
#   - Verifies device exists as block device with -b test
#   - Logs validation result
#   - Silent operation (no echo output)
#
# Arguments:
#   $1 - device : Device path to validate (e.g., /dev/vdb3)
#
# Returns:
#   0 if device is valid block device
#   1 if device is empty, not found, or not a block device
#
# Example usage:
#   if n_rescue_validate_device "/dev/vdb3"; then
#     echo "Device is valid"
#   else
#     echo "Invalid device"
#   fi
#
#===============================================================================
n_rescue_validate_device() {
  local device="$1"
  
  if [[ -z "$device" ]]; then
    n_remote_log "[ERROR] Device validation failed: empty device path"
    return 1
  fi
  
  if [[ ! -b "$device" ]]; then
    n_remote_log "[ERROR] Device validation failed: $device not a block device"
    return 1
  fi
  
  n_remote_log "[DEBUG] Device validated: $device"
  return 0
}


#===============================================================================
# n_rescue_unmount_recursive
# --------------------------
# Safely unmount a filesystem and all sub-mounts.
#
# Behaviour:
#   - Checks if path is mounted with mountpoint -q
#   - Attempts umount -R (recursive) first
#   - Falls back to individual bind mount cleanup if -R fails
#   - Tries proc, sys, dev, run, boot subdirectories
#   - Logs all operations
#   - Reports success/failure via echo to stderr
#
# Arguments:
#   $1 - mount_point : Path to unmount (e.g., /mnt)
#
# Returns:
#   0 if successfully unmounted or not mounted
#   1 if failed to unmount after all attempts
#
# Example usage:
#   n_rescue_unmount_recursive /mnt
#
#===============================================================================
n_rescue_unmount_recursive() {
  local mount_point="$1"
  
  if [[ -z "$mount_point" ]]; then
    n_remote_log "[ERROR] No mount point specified for unmount"
    return 1
  fi
  
  # Check if mounted
  if ! mountpoint -q "$mount_point" 2>/dev/null; then
    n_remote_log "[DEBUG] $mount_point not mounted, nothing to do"
    return 0
  fi
  
  n_remote_log "[INFO] Unmounting $mount_point"
  
  # Try recursive unmount
  if umount -R "$mount_point" 2>/dev/null; then
    echo "  ✓ Unmounted $mount_point" >&2
    n_remote_log "[INFO] Successfully unmounted $mount_point"
    return 0
  fi
  
  # Failed, try individual bind mounts
  echo "  Unmount -R failed, trying individual mounts..." >&2
  n_remote_log "[DEBUG] Recursive unmount failed, trying bind mounts"
  
  local submounts=("proc" "sys" "dev" "run" "boot")
  for sub in "${submounts[@]}"; do
    local subpath="${mount_point}/${sub}"
    if mountpoint -q "$subpath" 2>/dev/null; then
      if umount "$subpath" 2>/dev/null; then
        echo "    ✓ Unmounted $subpath" >&2
      else
        echo "    ✗ Failed to unmount $subpath" >&2
      fi
    fi
  done
  
  # Try main mount again
  if umount "$mount_point" 2>/dev/null; then
    echo "  ✓ Unmounted $mount_point" >&2
    n_remote_log "[INFO] Successfully unmounted $mount_point"
    return 0
  else
    echo "  ✗ Failed to unmount $mount_point" >&2
    n_remote_log "[ERROR] Failed to unmount $mount_point"
    return 1
  fi
}


#===============================================================================
# n_rescue_read_disk_config
# -------------------------
# Read disk configuration from IPS host_config.
#
# Behaviour:
#   - Reads os_disk, boot_device, root_device, boot_uuid, root_uuid
#   - Returns nothing if all values are empty
#   - Outputs variable assignments suitable for eval
#   - Silent on errors (caller checks if variables set)
#   - Logs read operation
#
# Arguments:
#   None (reads from current host's config)
#
# Returns:
#   0 if at least one value found
#   1 if all values empty (no config)
#
# Output format (to stdout):
#   os_disk='/dev/vdb'
#   boot_device='/dev/vdb2'
#   root_device='/dev/vdb3'
#   boot_uuid='xxxx-yyyy'
#   root_uuid='zzzz-aaaa'
#
# Example usage:
#   eval "$(n_rescue_read_disk_config)"
#   if [[ -n "$root_device" ]]; then
#     echo "Root: $root_device"
#   fi
#
#===============================================================================
n_rescue_read_disk_config() {
  n_remote_log "[DEBUG] Reading disk configuration from IPS"
  
  local os_disk=""
  local boot_device=""
  local root_device=""
  local boot_uuid=""
  local root_uuid=""
  local found=0
  
  os_disk=$(n_remote_host_variable os_disk 2>/dev/null) || true
  boot_device=$(n_remote_host_variable boot_device 2>/dev/null) || true
  root_device=$(n_remote_host_variable root_device 2>/dev/null) || true
  boot_uuid=$(n_remote_host_variable boot_uuid 2>/dev/null) || true
  root_uuid=$(n_remote_host_variable root_uuid 2>/dev/null) || true
  
  # Check if we have any config
  [[ -n "$os_disk" ]] && found=1
  [[ -n "$boot_device" ]] && found=1
  [[ -n "$root_device" ]] && found=1
  [[ -n "$boot_uuid" ]] && found=1
  [[ -n "$root_uuid" ]] && found=1
  
  if [[ $found -eq 0 ]]; then
    n_remote_log "[DEBUG] No disk configuration found"
    return 1
  fi
  
  # Output variable assignments
  echo "os_disk='$os_disk'"
  echo "boot_device='$boot_device'"
  echo "root_device='$root_device'"
  echo "boot_uuid='$boot_uuid'"
  echo "root_uuid='$root_uuid'"
  
  n_remote_log "[DEBUG] Disk config read: os_disk=$os_disk boot=$boot_device root=$root_device"
  return 0
}


#===============================================================================
# n_rescue_load_modules
# ---------------------
# Load all kernel modules required for rescue operations.
#
# Behaviour:
#   - Loads ext4 modules (filesystem support) using n_load_kernel_module
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
  local ext4_loaded=0
  for mod in ext4 mbcache jbd2; do
    if n_load_kernel_module "$mod" 2>/dev/null; then
      ext4_loaded=1
    fi
  done
  
  if [[ $ext4_loaded -eq 1 ]]; then
    echo "OK" >&2
    n_remote_log "[INFO] ext4 modules loaded"
  else
    echo "FAILED" >&2
    n_remote_log "[WARNING] Failed to load ext4 modules"
    failed=1
  fi
  
  # Load ZFS modules
  echo -n "Loading ZFS modules... " >&2
  if n_load_kernel_module zfs 2>/dev/null; then
    echo "OK" >&2
    n_remote_log "[INFO] ZFS modules loaded"
  else
    echo "NOT AVAILABLE" >&2
    n_remote_log "[DEBUG] ZFS modules not available (may not be needed)"
  fi
  
  # Load mdadm/RAID modules
  echo -n "Loading RAID modules... " >&2
  local raid_modules=("raid1" "raid456" "md_mod")
  local raid_loaded=0
  
  for mod in "${raid_modules[@]}"; do
    if n_load_kernel_module "$mod" 2>/dev/null; then
      raid_loaded=1
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
# n_rescue_install_tools
# ----------------------
# Install essential rescue and repair tools.
#
# Behaviour:
#   - Installs disk partitioning tools (sfdisk, parted, gdisk)
#   - Installs filesystem tools (e2fsprogs, dosfstools, xfsprogs)
#   - Installs RAID tools (mdadm)
#   - Installs bootloader tools (grub, grub-bios)
#   - Installs diagnostic tools (smartmontools, hdparm)
#   - Installs cleanup tools (wipefs from util-linux)
#   - Uses apk for Alpine
#   - Logs installation progress
#
# Returns:
#   0 on success
#   1 if package installation fails
#
# Example usage:
#   n_rescue_install_tools
#
#===============================================================================
n_rescue_install_tools() {
  n_remote_log "[INFO] Installing rescue tools"
  echo "Installing rescue and repair tools..." >&2
  
  # Define package groups
  local disk_tools="sfdisk parted gdisk util-linux"
  local fs_tools="e2fsprogs e2fsprogs-extra dosfstools xfsprogs xfsprogs-extra"
  local raid_tools="mdadm"
  local boot_tools="grub grub-bios syslinux"
  local diagnostic_tools="smartmontools hdparm lsblk"
  local network_tools="rsync wget curl"
  local editors="vim nano"
  
  # Combine all packages
  local all_packages="$disk_tools $fs_tools $raid_tools $boot_tools $diagnostic_tools $network_tools $editors"
  
  echo "Packages to install:" >&2
  echo "  Disk tools: $disk_tools" >&2
  echo "  Filesystem tools: $fs_tools" >&2
  echo "  RAID tools: $raid_tools" >&2
  echo "  Bootloader tools: $boot_tools" >&2
  echo "  Diagnostic tools: $diagnostic_tools" >&2
  echo "  Network tools: $network_tools" >&2
  echo "  Editors: $editors" >&2
  echo "" >&2
  
  # Update package index first
  n_remote_log "[INFO] Updating package index"
  echo "Updating package index..." >&2
  if ! apk update 2>&1 | while IFS= read -r line; do
    n_remote_log "[DEBUG] apk update: $line"
  done; then
    n_remote_log "[ERROR] Failed to update package index"
    echo "ERROR: Failed to update package index" >&2
    return 1
  fi
  
  # Install packages
  n_remote_log "[INFO] Installing rescue tools: $all_packages"
  echo "Installing packages - this may take a few minutes..." >&2
  
  # Use --no-progress for cleaner output
  if apk add --no-progress $all_packages 2>&1 | while IFS= read -r line; do
    # Only log important lines
    if [[ "$line" =~ ^ERROR || "$line" =~ ^WARNING || "$line" =~ ^fetch || "$line" =~ Installing ]]; then
      n_remote_log "[DEBUG] apk: $line"
      echo "  $line" >&2
    fi
  done; then
    n_remote_log "[INFO] Rescue tools installed successfully"
    echo "" >&2
    echo "✓ Rescue tools installed successfully" >&2
    return 0
  else
    n_remote_log "[ERROR] Failed to install some rescue tools"
    echo "" >&2
    echo "✗ Failed to install some rescue tools" >&2
    echo "You may need to install specific tools manually with: apk add PACKAGE_NAME" >&2
    return 1
  fi
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
  
  if ! eval "$(n_rescue_read_disk_config)"; then
    echo "=== Disk Configuration from IPS ===" >&2
    echo "" >&2
    echo "No disk configuration found in host_config." >&2
    echo "This may be a new system or installation failed before disk detection." >&2
    echo "" >&2
    echo "Use 'lsblk' or 'fdisk -l' to explore available disks." >&2
    n_remote_log "[INFO] No disk configuration in host_config"
    return 1
  fi
  
  echo "=== Disk Configuration from IPS ===" >&2
  echo "" >&2
  
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
  n_rescue_install_tools       Install rescue and repair tools
  n_rescue_mount [root] [boot] Mount installed filesystems
  n_rescue_chroot              Chroot into installed system
  n_rescue_reinstall_grub      Reinstall GRUB bootloader
  n_rescue_fsck [device]       Run filesystem check
  n_rescue_cleanup [disk]      Clean disk(s) and reset for reinstall
  n_rescue_exit [state]        Exit rescue mode (default: INSTALLED)
  n_set_state <STATE>          Change node state

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

  5. Clean Failed Installation:
     
     n_rescue_cleanup            # Clean disks from config
     # Choose 'y' to reset state to UNCONFIGURED
     reboot

  6. Repurpose Disk from Another System:
     
     n_rescue_cleanup /dev/vdb --wipe-table -f
     # This disk can now be used for fresh install

EXITING RESCUE MODE
───────────────────

  Quick exit (recommended):

    n_rescue_exit               # Exit to INSTALLED, clear RESCUE flag
    reboot

  Exit and trigger reinstall:

    n_rescue_exit INSTALLING    # Will reinstall on reboot
    reboot

  Manual exit:

    n_remote_host_variable RESCUE ""
    n_set_state INSTALLED
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
# n_rescue_cleanup
# ----------------
# Clean up and wipe partitions from a disk or previous installation.
#
# Behaviour:
#   MODE 1 - Config-based (no disk arg):
#     - Reads os_disk, boot_device, root_device from host_config
#     - Unmounts any mounted partitions using n_rescue_unmount_recursive
#     - Stops any active md arrays if RAID was used
#     - Wipes filesystem signatures from partitions
#     - Optionally wipes partition table from os_disk
#     - Clears installation-related host_config variables
#     - Prompts to reset node state to UNCONFIGURED
#
#   MODE 2 - Manual disk (disk arg provided):
#     - Uses specified disk path
#     - Detects and wipes all partitions on disk
#     - Optionally wipes partition table
#     - Does NOT modify host_config
#     - Does NOT prompt for state reset
#
#   Both modes:
#     - Safety check: prevents wiping mounted or in-use disks
#     - Stop MD arrays and zero superblocks
#     - Use wipefs for signature removal
#     - Verify cleanup succeeded
#     - Prompt for confirmation unless -f flag
#
# Arguments:
#   disk - Optional: Manual disk path (e.g., /dev/vdb)
#          If omitted, uses host_config
#
# Options:
#   -f, --force      Skip confirmation prompts
#   --wipe-table     Also wipe partition table (full disk wipe)
#
# Returns:
#   0 on success
#   1 if no devices found or invalid arguments
#   2 if user cancelled
#   3 if cleanup operation failed
#   4 if disk is in use (safety check failed)
#
# Example usage:
#   n_rescue_cleanup                    # Clean from config, interactive
#   n_rescue_cleanup -f                 # Clean from config, no prompts
#   n_rescue_cleanup --wipe-table -f    # Full wipe from config
#   n_rescue_cleanup /dev/vdb           # Clean specific disk, interactive
#   n_rescue_cleanup /dev/vdb -f --wipe-table  # Full wipe of specific disk
#
#===============================================================================
n_rescue_cleanup() {
  local force=0
  local wipe_table=0
  local manual_disk=""
  
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
      -*)
        echo "ERROR: Unknown option: $1" >&2
        echo "Usage: n_rescue_cleanup [disk] [-f|--force] [--wipe-table]" >&2
        return 1
        ;;
      *)
        if [[ -z "$manual_disk" ]]; then
          manual_disk="$1"
          shift
        else
          echo "ERROR: Multiple disk arguments not supported" >&2
          echo "Usage: n_rescue_cleanup [disk] [-f|--force] [--wipe-table]" >&2
          return 1
        fi
        ;;
    esac
  done
  
  n_remote_log "[INFO] Starting disk cleanup"
  
  # Determine mode and setup variables
  local mode=""
  local os_disk=""
  local boot_device=""
  local root_device=""
  local devices_to_wipe=()
  local disks_to_check=()
  
  if [[ -n "$manual_disk" ]]; then
    # MODE 2: Manual disk mode
    mode="manual"
    n_remote_log "[INFO] Manual disk mode: $manual_disk"
    
    # Validate manual disk
    if ! n_rescue_validate_device "$manual_disk"; then
      echo "ERROR: Invalid disk: $manual_disk" >&2
      return 1
    fi
    
    os_disk="$manual_disk"
    disks_to_check+=("$manual_disk")
    
    # Detect partitions using lsblk
    echo "Detecting partitions on $manual_disk..." >&2
    local partitions
    partitions=$(lsblk -ln -o NAME "$manual_disk" 2>/dev/null | tail -n +2) || true
    
    if [[ -n "$partitions" ]]; then
      while IFS= read -r part; do
        devices_to_wipe+=("/dev/$part")
      done <<< "$partitions"
      echo "  Found ${#devices_to_wipe[@]} partition(s)" >&2
    else
      echo "  No partitions found (disk may be empty or have non-standard layout)" >&2
    fi
    
  else
    # MODE 1: Config-based mode
    mode="config"
    n_remote_log "[INFO] Config-based mode: reading from host_config"
    
    # Read configuration from host_config
    eval "$(n_rescue_read_disk_config)" || true
    
    # Check if we have anything to clean
    if [[ -z "$os_disk" ]] && [[ -z "$boot_device" ]] && [[ -z "$root_device" ]]; then
      n_remote_log "[WARNING] No installation devices found in host_config"
      echo "No installation devices configured. Nothing to clean." >&2
      echo "" >&2
      echo "To clean a specific disk manually:" >&2
      echo "  n_rescue_cleanup /dev/sdX" >&2
      return 1
    fi
    
    # Build devices list
    if [[ -n "$boot_device" ]] && n_rescue_validate_device "$boot_device"; then
      devices_to_wipe+=("$boot_device")
      n_remote_log "[DEBUG] boot_device exists: $boot_device"
    elif [[ -n "$boot_device" ]]; then
      n_remote_log "[WARNING] boot_device not found: $boot_device"
      echo "  WARNING: boot_device not found: $boot_device" >&2
    fi
    
    if [[ -n "$root_device" ]] && n_rescue_validate_device "$root_device"; then
      devices_to_wipe+=("$root_device")
      n_remote_log "[DEBUG] root_device exists: $root_device"
    elif [[ -n "$root_device" ]]; then
      n_remote_log "[WARNING] root_device not found: $root_device"
      echo "  WARNING: root_device not found: $root_device" >&2
    fi
    
    # Build disks list (for RAID handling and safety checks)
    if [[ -n "$os_disk" ]]; then
      IFS=',' read -ra disk_array <<< "$os_disk"
      disks_to_check+=("${disk_array[@]}")
    fi
  fi
  
  # Safety check: ensure no disk is mounted or in use
  echo "" >&2
  echo "=== Safety Checks ===" >&2
  local safety_failed=0
  
  for disk in "${disks_to_check[@]}"; do
    # Check for mounted partitions
    if grep -q "^${disk}" /proc/mounts 2>/dev/null; then
      echo "✗ ERROR: $disk has mounted partitions" >&2
      echo "  Mounted partitions:" >&2
      grep "^${disk}" /proc/mounts | awk '{print "    " $1 " on " $2}' >&2
      echo "  Unmount with: n_rescue_unmount_recursive /mnt" >&2
      safety_failed=1
    fi
    
    # Check if disk is part of active MD array
    if command -v mdadm >/dev/null 2>&1; then
      local md_info
      md_info=$(mdadm --examine "$disk" 2>/dev/null) || true
      if [[ -n "$md_info" ]]; then
        echo "✗ WARNING: $disk is part of an MD array" >&2
        echo "  Array will be stopped during cleanup" >&2
      fi
    fi
  done
  
  if [[ $safety_failed -eq 1 ]]; then
    n_remote_log "[ERROR] Safety check failed: disk(s) in use"
    return 4
  fi
  
  echo "✓ All disks safe to clean" >&2
  
  # Display what will be done
  echo "" >&2
  echo "=== Cleanup Plan ===" >&2
  
  if [[ "$mode" == "config" ]]; then
    echo "Mode: Config-based cleanup" >&2
    [[ -n "$os_disk" ]] && echo "  os_disk:      $os_disk" >&2
    [[ -n "$boot_device" ]] && echo "  boot_device:  $boot_device" >&2
    [[ -n "$root_device" ]] && echo "  root_device:  $root_device" >&2
  else
    echo "Mode: Manual disk cleanup" >&2
    echo "  Disk: $manual_disk" >&2
  fi
  
  echo "" >&2
  echo "Actions to perform:" >&2
  echo "  1. Unmount any filesystems under /mnt" >&2
  
  # Check for MD arrays
  local md_arrays=()
  if [[ -e /dev/md0 ]]; then md_arrays+=("/dev/md0"); fi
  if [[ -e /dev/md1 ]]; then md_arrays+=("/dev/md1"); fi
  
  if [[ ${#md_arrays[@]} -gt 0 ]]; then
    echo "  2. Stop MD arrays: ${md_arrays[*]}" >&2
    echo "  3. Zero MD superblocks on all partitions" >&2
  fi
  
  if [[ ${#devices_to_wipe[@]} -gt 0 ]]; then
    echo "  4. Wipe filesystem signatures from: ${devices_to_wipe[*]}" >&2
  else
    echo "  4. Wipe filesystem signatures (no specific partitions detected)" >&2
  fi
  
  if [[ $wipe_table -eq 1 ]] && [[ -n "$os_disk" ]]; then
    echo "  5. Wipe partition table on: $os_disk" >&2
  fi
  
  if [[ "$mode" == "config" ]]; then
    echo "  6. Clear host_config variables" >&2
    echo "  7. Prompt to reset node state" >&2
  fi
  
  echo "" >&2
  
  # Confirmation
  if [[ $force -eq 0 ]]; then
    echo -n "⚠ Proceed with cleanup? This will DESTROY DATA! [y/N]: " >&2
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      n_remote_log "[INFO] Cleanup cancelled by user"
      echo "Cancelled." >&2
      return 2
    fi
  else
    n_remote_log "[INFO] Force flag set, skipping confirmation"
    echo "⚠ Force mode: proceeding without confirmation" >&2
  fi
  
  echo "" >&2
  echo "=== Executing Cleanup ===" >&2
  
  # Step 1: Unmount filesystems
  n_remote_log "[INFO] Unmounting filesystems"
  echo "Unmounting filesystems..." >&2
  n_rescue_unmount_recursive /mnt
  echo "" >&2
  
  # Step 2: Stop MD arrays
  if [[ ${#md_arrays[@]} -gt 0 ]]; then
    n_remote_log "[INFO] Stopping MD arrays"
    echo "Stopping MD arrays..." >&2
    
    for md in "${md_arrays[@]}"; do
      if mdadm --stop "$md" 2>/dev/null; then
        n_remote_log "[DEBUG] Stopped $md"
        echo "  ✓ Stopped $md" >&2
      else
        n_remote_log "[WARNING] Failed to stop $md"
        echo "  ✗ Failed to stop $md (may not exist)" >&2
      fi
    done
    echo "" >&2
  fi
  
  # Step 3: Zero MD superblocks
  if [[ ${#disks_to_check[@]} -gt 0 ]] && command -v mdadm >/dev/null 2>&1; then
    n_remote_log "[INFO] Zeroing MD superblocks"
    echo "Zeroing MD superblocks..." >&2
    
    for disk in "${disks_to_check[@]}"; do
      n_remote_log "[DEBUG] Zeroing MD superblocks on all partitions of $disk"
      
      # Get all partition devices for this disk
      local partitions
      partitions=$(lsblk -ln -o NAME "$disk" 2>/dev/null | tail -n +2) || true
      
      if [[ -n "$partitions" ]]; then
        while IFS= read -r part; do
          mdadm --zero-superblock "/dev/$part" 2>/dev/null || true
        done <<< "$partitions"
        echo "  ✓ Zeroed superblocks on $disk partitions" >&2
      fi
    done
    echo "" >&2
  fi
  
  # Step 4: Wipe filesystem signatures
  if [[ ${#devices_to_wipe[@]} -gt 0 ]]; then
    n_remote_log "[INFO] Wiping filesystem signatures"
    echo "Wiping filesystem signatures..." >&2
    
    # Ensure wipefs is available
    if ! command -v wipefs >/dev/null 2>&1; then
      echo "  Installing wipefs..." >&2
      if ! apk add --quiet util-linux 2>/dev/null; then
        echo "  ERROR: Failed to install wipefs" >&2
        n_remote_log "[ERROR] Failed to install wipefs"
        return 3
      fi
    fi
    
    for dev in "${devices_to_wipe[@]}"; do
      if n_rescue_validate_device "$dev"; then
        echo "  Wiping $dev..." >&2
        local wipe_output
        wipe_output=$(wipefs -a "$dev" 2>&1)
        local wipe_rc=$?
        
        if [[ $wipe_rc -eq 0 ]]; then
          n_remote_log "[DEBUG] Wiped signatures from $dev"
          echo "    ✓ Wiped: $dev" >&2
          
          # Verify signatures removed
          local verify_output
          verify_output=$(wipefs "$dev" 2>&1) || true
          if echo "$verify_output" | grep -q "PTUUID\|UUID\|TYPE"; then
            echo "    ⚠ WARNING: Some signatures may remain on $dev" >&2
            n_remote_log "[WARNING] Verification: signatures may remain on $dev"
          fi
        else
          n_remote_log "[WARNING] Failed to wipe $dev: $wipe_output"
          echo "    ✗ Failed to wipe $dev" >&2
        fi
      fi
    done
    echo "" >&2
  fi
  
  # Step 5: Wipe partition table (optional)
  if [[ $wipe_table -eq 1 ]] && [[ -n "$os_disk" ]]; then
    n_remote_log "[INFO] Wiping partition table"
    echo "Wiping partition table..." >&2
    
    IFS=',' read -ra disk_array <<< "$os_disk"
    for disk in "${disk_array[@]}"; do
      if n_rescue_validate_device "$disk"; then
        echo "  Wiping $disk..." >&2
        local wipe_output
        wipe_output=$(wipefs -a "$disk" 2>&1)
        local wipe_rc=$?
        
        if [[ $wipe_rc -eq 0 ]]; then
          n_remote_log "[DEBUG] Wiped partition table from $disk"
          echo "    ✓ Wiped partition table: $disk" >&2
          
          # Verify partition table removed
          local verify_output
          verify_output=$(wipefs "$disk" 2>&1) || true
          if echo "$verify_output" | grep -q "PTUUID\|TYPE"; then
            echo "    ⚠ WARNING: Partition table may remain on $disk" >&2
            n_remote_log "[WARNING] Verification: partition table may remain on $disk"
          fi
        else
          n_remote_log "[WARNING] Failed to wipe partition table on $disk: $wipe_output"
          echo "    ✗ Failed to wipe partition table on $disk" >&2
        fi
      fi
    done
    echo "" >&2
  fi
  
  # Step 6: Clear host_config (config mode only)
  if [[ "$mode" == "config" ]]; then
    n_remote_log "[INFO] Clearing host_config variables"
    echo "Clearing host_config..." >&2
    
    local vars_to_clear=("boot_device" "root_device" "boot_uuid" "root_uuid" "INSTALL_ERROR")
    [[ $wipe_table -eq 1 ]] && vars_to_clear+=("os_disk")
    
    for var in "${vars_to_clear[@]}"; do
      if n_remote_host_variable "$var" "" 2>/dev/null; then
        n_remote_log "[DEBUG] Cleared $var"
        echo "  ✓ Cleared: $var" >&2
      fi
    done
    echo "" >&2
  fi
  
  n_remote_log "[INFO] Cleanup complete"
  echo "═══════════════════════════════════════════════════════════" >&2
  echo "✓ Cleanup complete!" >&2
  echo "═══════════════════════════════════════════════════════════" >&2
  echo "" >&2
  
  # Step 7: State reset prompt (config mode only)
  if [[ "$mode" == "config" ]] && [[ $force -eq 0 ]]; then
    echo "Would you like to reset node state? This will:" >&2
    echo "  - Set STATE to UNCONFIGURED" >&2
    echo "  - Clear all node configuration" >&2
    echo "  - Prepare node for fresh provisioning" >&2
    echo "" >&2
    echo -n "Reset node state? [y/N]: " >&2
    read -r reset_state
    
    if [[ "$reset_state" =~ ^[Yy]$ ]]; then
      n_remote_host_variable STATE "UNCONFIGURED"
      echo "" >&2
      echo "✓ State set to UNCONFIGURED" >&2
      echo "  On next boot, node will go through full provisioning" >&2
      n_remote_log "[INFO] State reset to UNCONFIGURED"
    else
      echo "" >&2
      echo "State unchanged. Set manually with:" >&2
      echo "  n_set_state UNCONFIGURED    # Full reset" >&2
      echo "  n_set_state INSTALLING      # Reinstall only" >&2
    fi
  elif [[ "$mode" == "config" ]] && [[ $force -eq 1 ]]; then
    echo "To reset node state:" >&2
    echo "  n_set_state UNCONFIGURED    # Full reset" >&2
    echo "  n_set_state INSTALLING      # Reinstall only" >&2
  else
    echo "Disk cleaned. To use for HPS installation:" >&2
    echo "  1. Configure the node with this disk in IPS" >&2
    echo "  2. Set STATE to INSTALLING" >&2
    echo "  3. Reboot the node" >&2
  fi
  
  echo "" >&2
  
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
    
    eval "$(n_rescue_read_disk_config)" || true
    
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
  if ! n_rescue_validate_device "$root_device"; then
    echo "ERROR: Root device not found or not a block device: $root_device" >&2
    return 1
  fi
  
  # Verify boot device if specified
  if [[ -n "$boot_device" ]] && ! n_rescue_validate_device "$boot_device"; then
    echo "ERROR: Boot device not found or not a block device: $boot_device" >&2
    return 1
  fi
  
  # Unmount /mnt if already mounted
  echo "Checking for existing mounts..." >&2
  n_rescue_unmount_recursive /mnt
  
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
  for submount in run dev sys proc; do
    umount "/mnt/$submount" 2>/dev/null || true
  done
  
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
  eval "$(n_rescue_read_disk_config)" || true
  
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
  if ! n_rescue_validate_device "$target_disk"; then
    echo "ERROR: Target disk not found: $target_disk" >&2
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
  echo "═══════════════════════════════════════════════════════════════" >&2
  echo "GRUB bootloader reinstalled successfully!" >&2
  echo "" >&2
  echo "Next steps:" >&2
  echo "  1. Verify with: ls -la /mnt/boot/grub/i386-pc/" >&2
  echo "  2. Exit rescue mode: n_remote_host_variable STATE INSTALLED" >&2
  echo "  3. Reboot: reboot" >&2
  echo "═══════════════════════════════════════════════════════════════" >&2
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
    eval "$(n_rescue_read_disk_config)" || true
    
    [[ -n "$root_device" ]] && echo "  Root: $root_device" >&2
    [[ -n "$boot_device" ]] && echo "  Boot: $boot_device" >&2
    
    echo "" >&2
    echo "Or list all devices with: lsblk" >&2
    
    n_remote_log "[ERROR] No device specified for fsck"
    return 1
  fi
  
  # Verify device exists
  if ! n_rescue_validate_device "$device"; then
    echo "ERROR: Device not found or not a block device: $device" >&2
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


#===============================================================================
# n_rescue_exit
# -------------
# Properly exit rescue mode and prepare for normal boot.
#
# Behaviour:
#   - Unmounts any mounted filesystems under /mnt
#   - Clears RESCUE flag in host config
#   - Sets STATE to specified value (default: INSTALLED)
#   - Displays instructions for reboot
#   - Does NOT reboot automatically (user must confirm)
#
# Arguments:
#   $1 - target_state (optional, default: INSTALLED)
#        Valid: INSTALLED, RUNNING, INSTALLING
#
# Returns:
#   0 on success
#   1 on error
#
# Example usage:
#   n_rescue_exit                    # Exit to INSTALLED state
#   n_rescue_exit RUNNING            # Exit to RUNNING state
#   n_rescue_exit INSTALLING         # Trigger reinstallation
#
#===============================================================================
n_rescue_exit() {
  local target_state="${1:-INSTALLED}"
  
  n_remote_log "[INFO] Exiting rescue mode, target state: $target_state"
  
  echo "═══════════════════════════════════════════════════════════" >&2
  echo "Exiting RESCUE Mode" >&2
  echo "═══════════════════════════════════════════════════════════" >&2
  echo "" >&2
  
  # Unmount any filesystems under /mnt
  echo "Unmounting filesystems..." >&2
  n_rescue_unmount_recursive /mnt
  echo "" >&2
  
  # Clear RESCUE flag
  echo "Clearing RESCUE flag..." >&2
  if n_remote_host_variable RESCUE ""; then
    echo "  ✓ RESCUE flag cleared" >&2
    n_remote_log "[INFO] RESCUE flag cleared"
  else
    echo "  ✗ Failed to clear RESCUE flag" >&2
    n_remote_log "[ERROR] Failed to clear RESCUE flag"
    return 1
  fi
  
  # Set target state
  echo "Setting state to: $target_state" >&2
  if n_remote_host_variable STATE "$target_state"; then
    echo "  ✓ State set to $target_state" >&2
    n_remote_log "[INFO] State set to $target_state"
  else
    echo "  ✗ Failed to set state" >&2
    n_remote_log "[ERROR] Failed to set state to $target_state"
    return 1
  fi
  
  echo "" >&2
  echo "═══════════════════════════════════════════════════════════" >&2
  echo "Ready to exit rescue mode" >&2
  echo "" >&2
  echo "Next state: $target_state" >&2
  
  case "$target_state" in
    INSTALLED|RUNNING)
      echo "Boot method: System will attempt to boot from disk" >&2
      ;;
    INSTALLING)
      echo "Boot method: System will netboot and run installer" >&2
      ;;
  esac
  
  echo "" >&2
  echo "To reboot now, run: reboot" >&2
  echo "═══════════════════════════════════════════════════════════" >&2
  
  n_remote_log "[INFO] Rescue mode exit prepared, waiting for manual reboot"
  return 0
}


#===============================================================================
# n_set_state
# -----------
# Set the node STATE in host config.
#
# Behaviour:
#   - Updates STATE in IPS host config
#   - Validates state value against known states
#   - Logs the change
#   - Displays confirmation
#
# Arguments:
#   $1 - state : Target state
#        Valid: PROVISIONING, INSTALLING, INSTALLED, RUNNING, FAILED
#
# Returns:
#   0 on success
#   1 on invalid state or update failure
#
# Example usage:
#   n_set_state INSTALLED
#   n_set_state RUNNING
#   n_set_state INSTALLING      # Trigger reinstall on reboot
#
#===============================================================================
n_set_state() {
  local new_state="$1"
  
  if [[ -z "$new_state" ]]; then
    echo "Usage: n_set_state <STATE>" >&2
    echo "" >&2
    echo "Valid states:" >&2
    echo "  PROVISIONING  - Initial setup" >&2
    echo "  INSTALLING    - Installation in progress" >&2
    echo "  INSTALLED     - Installation complete" >&2
    echo "  RUNNING       - Normal operation" >&2
    echo "  FAILED        - Error state" >&2
    echo "" >&2
    return 1
  fi
  
  # Validate state
  case "$new_state" in
    PROVISIONING|INSTALLING|INSTALLED|RUNNING|FAILED)
      # Valid
      ;;
    *)
      echo "ERROR: Invalid state '$new_state'" >&2
      echo "Valid states: PROVISIONING, INSTALLING, INSTALLED, RUNNING, FAILED" >&2
      n_remote_log "[ERROR] Invalid state requested: $new_state"
      return 1
      ;;
  esac
  
  # Set state
  n_remote_log "[INFO] Setting STATE to: $new_state"
  
  if n_remote_host_variable STATE "$new_state"; then
    echo "✓ State set to: $new_state" >&2
    n_remote_log "[INFO] STATE updated to $new_state"
    
    # Provide context about what this means
    case "$new_state" in
      INSTALLING)
        echo "" >&2
        echo "Note: On next boot, the installer will run" >&2
        ;;
      INSTALLED|RUNNING)
        echo "" >&2
        echo "Note: On next boot, system will attempt disk boot" >&2
        ;;
    esac
    
    return 0
  else
    echo "✗ Failed to set state" >&2
    n_remote_log "[ERROR] Failed to set STATE to $new_state"
    return 1
  fi
}
