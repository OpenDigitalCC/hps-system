#!/bin/bash
#===============================================================================
# HPS Storage Functions for Alpine Linux
# ZFS and iSCSI management for SCH (Storage Cluster Host) nodes
#===============================================================================

#===============================================================================
# Helper Functions
#===============================================================================

#===============================================================================
# zpool_slug
# ----------
# Normalize cluster names for pool IDs.
#
# Behaviour:
#   - Converts to lowercase
#   - Keeps only [a-z0-9-]
#   - Collapses multiple dashes
#   - Trims leading/trailing dashes
#   - Caps length to maxlen
#
# Arguments:
#   $1 - string to normalize
#   $2 - max length (optional, default: 12)
#
# Returns:
#   0 on success
#
# Example usage:
#   slug=$(zpool_slug "Prod-A" 12)  # returns "prod-a"
#
#===============================================================================
zpool_slug() {
  local s="$1"
  local maxlen="${2:-12}"
  
  # Lowercase
  s="${s,,}"
  
  # Replace non-alphanumeric with dash
  s="${s//[^a-z0-9-]/-}"
  
  # Collapse multiple dashes
  while [[ "$s" == *--* ]]; do
    s="${s//--/-}"
  done
  
  # Trim leading/trailing dashes
  s="${s#-}"
  s="${s%-}"
  
  # Cap length
  printf '%.*s' "$maxlen" "$s"
}

#===============================================================================
# zpool_name_generate
# -------------------
# Generate canonical pool name: z<cluster>-p<class>-u<hexsecs><hexrand6>
#
# Behaviour:
#   - Reads CLUSTER_NAME from cluster config
#   - Slugifies cluster name (max 12 chars)
#   - Validates pool class
#   - Generates time-ordered unique ID (8 hex chars timestamp + 6 hex random)
#   - Returns formatted pool name
#
# Arguments:
#   $1 - class: nvme|ssd|hdd|arc|mix
#
# Returns:
#   0 on success (prints pool name to stdout)
#   2 on invalid arguments
#
# Example usage:
#   pool_name=$(zpool_name_generate ssd)  # returns "ztest-pssd-u6743a8b2abc123"
#
#===============================================================================
zpool_name_generate() {
  local class="$1"
  
  if [[ -z "$class" ]]; then
    echo "usage: zpool_name_generate <class>" >&2
    return 2
  fi
  
  # Normalize and validate class
  class="${class,,}"
  case "$class" in
    nvme|ssd|hdd|arc|mix) ;;
    *)
      echo "invalid class: $class (nvme|ssd|hdd|arc|mix)" >&2
      return 2
      ;;
  esac
  
  # Get cluster name
  local cluster
  cluster="$(n_remote_cluster_variable CLUSTER_NAME 2>/dev/null | tr -d '"')"
  cluster="${cluster:-default}"
  
  # Slugify cluster name
  cluster="$(zpool_slug "$cluster" 12)"
  
  # Generate timestamp (8 hex chars)
  local secs
  secs=$(printf '%08x' "$(date +%s)")
  
  # Generate random suffix (6 hex chars)
  local rand
  if command -v od >/dev/null 2>&1; then
    rand=$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  else
    rand=$(printf '%06x' "$((RANDOM<<16 ^ RANDOM))")
  fi
  
  # Return formatted pool name
  echo "z${cluster}-p${class}-u${secs}${rand}"
  return 0
}

#===============================================================================
# disks_free_list_simple
# ----------------------
# List whole disks that appear unused (quick check with explicit rules).
#
# Behaviour:
#   - Finds disks of TYPE=disk, non-removable
#   - Excludes loop, ram, md, dm devices
#   - Checks for no partitions
#   - Checks not mounted
#   - Checks not flagged as LVM2_member/linux_raid_member/zfs_member
#   - Checks not present in current zpool status
#   - Prefers stable paths (/dev/disk/by-id if available)
#
# Returns:
#   0 on success (prints newline-separated disk paths to stdout)
#
# Example usage:
#   free_disks=$(disks_free_list_simple)
#   first_disk=$(disks_free_list_simple | head -n1)
#
#===============================================================================
disks_free_list_simple() {
  lsblk -dn -o NAME,TYPE,RM 2>/dev/null | while read -r name type rm; do
    # Must be disk type
    [[ "$type" == "disk" ]] || continue
    
    # Skip removable
    [[ "$rm" -eq 1 ]] && continue
    
    # Skip special devices
    [[ "$name" =~ ^(loop|ram|md|dm-) ]] && continue
    
    local dev="/dev/$name"
    
    # Check for partitions
    if lsblk -rno NAME,TYPE "$dev" 2>/dev/null | awk '$2=="part"{found=1} END{exit !found}'; then
      continue
    fi
    
    # Check if mounted
    if lsblk -rno MOUNTPOINTS "$dev" 2>/dev/null | grep -q '.'; then
      continue
    fi
    
    # Check for filesystem signatures
    if lsblk -rno FSTYPE "$dev" 2>/dev/null | grep -Eq 'LVM2_member|linux_raid_member|zfs_member'; then
      continue
    fi
    
    # Check if already in a zpool
    if command -v zpool >/dev/null 2>&1; then
      local real
      real="$(readlink -f "$dev")"
      if zpool status -P 2>/dev/null | grep -q -- "$real"; then
        continue
      fi
    fi
    
    # Prefer stable by-id path (WWN first)
    local real
    real="$(readlink -f "$dev")"
    
    if [[ -d /dev/disk/by-id ]]; then
      local p
      for p in /dev/disk/by-id/wwn-* /dev/disk/by-id/*; do
        [[ -e "$p" ]] || continue
        [[ "$p" =~ -part[0-9]+$ ]] && continue
        
        if [[ "$(readlink -f "$p")" == "$real" ]]; then
          echo "$p"
          continue 2
        fi
      done
    fi
    
    # Fallback to device path
    echo "$real"
  done
}

#===============================================================================
# zfs_get_defaults
# ----------------
# Return recommended ZFS default settings.
#
# Behaviour:
#   - Sets pool options (passed by reference to array)
#   - Sets dataset properties (passed by reference to array)
#   - Intentionally omits immutable properties (normalization, casesensitivity)
#
# Arguments:
#   $1 - name of array variable for pool options
#   $2 - name of array variable for zfs properties
#
# Returns:
#   0 on success (populates arrays)
#
# Example usage:
#   declare -a POOL_OPTS ZFS_PROPS
#   zfs_get_defaults POOL_OPTS ZFS_PROPS
#
#===============================================================================
zfs_get_defaults() {
  local -n _POOL_OPTS="$1"
  local -n _ZFS_PROPS="$2"
  
  _POOL_OPTS=(
    -o ashift=12  # 4K-sector safe default
  )
  
  _ZFS_PROPS=(
    compression=zstd
    atime=off
    relatime=on
    xattr=sa
    acltype=posixacl
    aclinherit=passthrough
    aclmode=passthrough
    dnodesize=auto
    logbias=throughput
  )
}

#===============================================================================
# Core ZFS Functions
#===============================================================================

#===============================================================================
# n_install_zfs_packages
# ----------------------
# Install ZFS packages required for SCH storage nodes.
#
# Behaviour:
#   - Installs core ZFS packages: zfs, zfs-lts, zfs-udev, zfs-libs
#   - Uses n_install_packages to handle package installation
#   - Does NOT start services (no OpenRC involvement)
#   - Does NOT load kernel modules (see n_load_zfs_module)
#   - Logs progress to IPS via n_remote_log
#
# Arguments:
#   None
#
# Returns:
#   0 on success (all packages installed)
#   1 on installation failure
#
# Example usage:
#   n_install_zfs_packages
#
#===============================================================================
n_install_zfs_packages() {
  n_remote_log "[ZFS] Installing ZFS packages"
  
  local packages=(
    "zfs"
    "zfs-lts"
    "zfs-udev"
    "zfs-libs"
  )
  
  n_remote_log "[ZFS] Packages to install: ${packages[*]}"
  
  if ! n_install_packages "${packages[@]}"; then
    n_remote_log "[ZFS] ERROR: Failed to install ZFS packages"
    return 1
  fi
  
  # Verify installation
  local missing=()
  for pkg in "${packages[@]}"; do
    if ! apk info -e "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done
  
  if [[ ${#missing[@]} -gt 0 ]]; then
    n_remote_log "[ZFS] ERROR: Installation verification failed. Missing: ${missing[*]}"
    return 1
  fi
  
  n_remote_log "[ZFS] Successfully installed ZFS packages"
  return 0
}

#===============================================================================
# n_zpool_create_on_free_disk
# ---------------------------
# High-level wrapper to create ZFS pool on free disk space.
#
# Behaviour:
#   - Checks if ZPOOL_NAME already configured (prevents duplicate pools)
#   - Generates pool name using zpool_name_generate
#   - Finds free disk using disks_free_list_simple
#   - Gets default ZFS properties from zfs_get_defaults
#   - Creates pool using n_zpool_create
#   - Stores ZPOOL_NAME in host_config for persistence
#   - Supports dry-run mode for testing
#
# Arguments:
#   --strategy <first|largest>   Disk selection (default: first)
#   --mountpoint <path>          Mount point (default: /srv/storage)
#   --class <type>               Pool class for naming (default: ssd)
#   -f                           Force creation
#   --dry-run                    Show what would be done
#   --no-defaults                Skip applying default properties
#
# Returns:
#   0 on success
#   1 on invalid arguments or configuration error
#   2 on disk detection failure
#   3 on pool creation failure
#   4 if ZPOOL_NAME already configured (pool exists or should exist)
#
# Example usage:
#   n_zpool_create_on_free_disk
#   n_zpool_create_on_free_disk --strategy largest --mountpoint /data
#   n_zpool_create_on_free_disk --dry-run
#
#===============================================================================
n_zpool_create_on_free_disk() {
  local strategy="first"
  local mountpoint="/srv/storage"
  local pool_class="ssd"
  local force=0
  local dry_run=0
  local apply_defaults=1
  local host_short
  host_short="$(hostname -s)"
  
  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --strategy)
        strategy="${2:?--strategy requires value: first|largest}"
        shift 2
        ;;
      --mountpoint)
        mountpoint="${2:?--mountpoint requires value}"
        shift 2
        ;;
      --class)
        pool_class="${2:?--class requires value}"
        shift 2
        ;;
      -f)
        force=1
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --no-defaults)
        apply_defaults=0
        shift
        ;;
      *)
        n_remote_log "[ZPOOL] ERROR: Unknown argument: $1"
        return 1
        ;;
    esac
  done
  
  # Validate strategy
  if [[ "$strategy" != "first" ]] && [[ "$strategy" != "largest" ]]; then
    n_remote_log "[ZPOOL] ERROR: Invalid strategy '$strategy' (use: first|largest)"
    return 1
  fi
  
  n_remote_log "[ZPOOL] Starting pool creation on free disk"
  n_remote_log "[ZPOOL] Strategy: $strategy, Class: $pool_class, Mountpoint: $mountpoint"
  
  # Check if ZPOOL_NAME already configured
  local configured_pool
  configured_pool=$(n_remote_host_variable ZPOOL_NAME 2>/dev/null) || true
  
  if [[ -n "$configured_pool" ]]; then
    n_remote_log "[ZPOOL] ZPOOL_NAME already configured: $configured_pool"
    
    # Check if pool actually exists
    if zpool list "$configured_pool" >/dev/null 2>&1; then
      n_remote_log "[ZPOOL] Configured pool '$configured_pool' exists. Nothing to do."
      return 4
    else
      n_remote_log "[ZPOOL] WARNING: Configured pool '$configured_pool' not found"
      n_remote_log "[ZPOOL] This may indicate a previous failed creation"
      
      # List any pools that do exist
      local existing_pools
      existing_pools=$(zpool list -H -o name 2>/dev/null)
      if [[ -n "$existing_pools" ]]; then
        n_remote_log "[ZPOOL] Existing pools found: $existing_pools"
      else
        n_remote_log "[ZPOOL] No pools currently imported"
      fi
      
      n_remote_log "[ZPOOL] Aborting to prevent duplicate pool creation"
      n_remote_log "[ZPOOL] To proceed: clear ZPOOL_NAME or import/destroy existing pool"
      return 4
    fi
  fi
  
  # Generate pool name
  local pool_name
  if ! pool_name=$(zpool_name_generate "$pool_class"); then
    n_remote_log "[ZPOOL] ERROR: Failed to generate pool name"
    return 1
  fi
  
  if [[ -z "$pool_name" ]]; then
    n_remote_log "[ZPOOL] ERROR: Pool name generation returned empty"
    return 1
  fi
  
  n_remote_log "[ZPOOL] Generated pool name: $pool_name"
  
  # Find free disk
  n_remote_log "[ZPOOL] Searching for free disk (strategy: $strategy)..."
  
  local disk=""
  if command -v disks_free_list_simple >/dev/null 2>&1; then
    case "$strategy" in
      first)
        disk=$(disks_free_list_simple | head -n1)
        ;;
      largest)
        disk=$(disks_free_list_simple \
          | xargs -r -I{} sh -c 'd="{}"; sz=$(blockdev --getsize64 "$d" 2>/dev/null || echo 0); echo "$sz $d"' \
          | sort -nrk1,1 | awk 'NR==1{print $2}')
        ;;
    esac
  else
    n_remote_log "[ZPOOL] ERROR: disks_free_list_simple function not available"
    return 2
  fi
  
  if [[ -z "$disk" ]]; then
    n_remote_log "[ZPOOL] ERROR: No free disk found"
    n_remote_log "[ZPOOL] Available disks:"
    lsblk -dno NAME,SIZE,TYPE 2>&1 | while IFS= read -r line; do
      n_remote_log "[ZPOOL]   $line"
    done
    return 2
  fi
  
  n_remote_log "[ZPOOL] Selected free disk: $disk"
  
  # Get disk size for logging
  local disk_size_bytes
  disk_size_bytes=$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)
  local disk_size_gb=$((disk_size_bytes / 1024 / 1024 / 1024))
  n_remote_log "[ZPOOL] Disk size: ${disk_size_gb}GB"
  
  # Get default properties if enabled
  local -a pool_opts=()
  local -a zfs_props=()
  
  if [[ $apply_defaults -eq 1 ]]; then
    if command -v zfs_get_defaults >/dev/null 2>&1; then
      zfs_get_defaults pool_opts zfs_props
      n_remote_log "[ZPOOL] Loaded default ZFS properties: ${#zfs_props[@]} properties"
    else
      n_remote_log "[ZPOOL] WARNING: zfs_get_defaults not available, using minimal defaults"
      zfs_props=(
        "compression=zstd"
        "atime=off"
        "relatime=on"
      )
    fi
  else
    n_remote_log "[ZPOOL] Skipping default properties (--no-defaults)"
  fi
  
  # Extract ashift from pool_opts if present
  local ashift="12"
  for opt in "${pool_opts[@]}"; do
    if [[ "$opt" =~ ^-o[[:space:]]+ashift=([0-9]+)$ ]]; then
      ashift="${BASH_REMATCH[1]}"
    elif [[ "$opt" =~ ^ashift=([0-9]+)$ ]]; then
      ashift="${BASH_REMATCH[1]}"
    fi
  done
  
  # Dry-run mode
  if [[ $dry_run -eq 1 ]]; then
    n_remote_log "[ZPOOL] DRY-RUN MODE"
    n_remote_log "[ZPOOL] Would create pool: $pool_name"
    n_remote_log "[ZPOOL] On disk: $disk (${disk_size_gb}GB)"
    n_remote_log "[ZPOOL] Mountpoint: $mountpoint"
    n_remote_log "[ZPOOL] Ashift: $ashift"
    n_remote_log "[ZPOOL] Force: $force"
    
    if [[ ${#zfs_props[@]} -gt 0 ]]; then
      n_remote_log "[ZPOOL] Properties to apply:"
      for prop in "${zfs_props[@]}"; do
        n_remote_log "[ZPOOL]   - $prop"
      done
    fi
    
    n_remote_log "[ZPOOL] Would store ZPOOL_NAME=$pool_name in host_config"
    return 0
  fi
  
  # Build n_zpool_create arguments
  local -a create_args=(
    --name "$pool_name"
    --vdev-type single
    --devices "$disk"
    --mountpoint "$mountpoint"
    --ashift "$ashift"
  )
  
  if [[ $force -eq 1 ]]; then
    create_args+=(--force)
  fi
  
  # Add ZFS properties
  for prop in "${zfs_props[@]}"; do
    create_args+=(--property "$prop")
  done
  
  # Create the pool
  n_remote_log "[ZPOOL] Creating pool..."
  
  if ! n_zpool_create "${create_args[@]}"; then
    n_remote_log "[ZPOOL] ERROR: Pool creation failed"
    return 3
  fi
  
  n_remote_log "[ZPOOL] Pool created successfully: $pool_name"
  
  # Verify pool exists
  if ! zpool list "$pool_name" >/dev/null 2>&1; then
    n_remote_log "[ZPOOL] ERROR: Pool created but not visible"
    return 3
  fi
  
  # Store ZPOOL_NAME in host_config
  n_remote_log "[ZPOOL] Storing ZPOOL_NAME in host_config"
  
  if ! n_remote_host_variable ZPOOL_NAME "$pool_name"; then
    n_remote_log "[ZPOOL] ERROR: Failed to store ZPOOL_NAME in host_config"
    n_remote_log "[ZPOOL] WARNING: Pool created but not persisted to config"
    return 1
  fi
  
  n_remote_log "[ZPOOL] Successfully stored ZPOOL_NAME=$pool_name"
  
  # Show final pool status
  n_remote_log "[ZPOOL] Final pool status:"
  zpool list "$pool_name" 2>&1 | while IFS= read -r line; do
    n_remote_log "[ZPOOL]   $line"
  done
  
  n_remote_log "[ZPOOL] Pool creation complete"
  return 0
}

#===============================================================================
# n_load_zfs_module
# -----------------
# Load ZFS kernel module and verify availability.
#
# Behaviour:
#   - Checks if ZFS module already loaded via lsmod
#   - Uses n_load_kernel_module to load if not present
#   - Verifies module loaded successfully
#   - Checks for /dev/zfs device
#   - Verifies zpool command is functional
#   - Logs all progress to IPS via n_remote_log
#
# Arguments:
#   None
#
# Returns:
#   0 on success (module loaded and verified)
#   1 if module load failed
#   2 if verification failed
#
# Example usage:
#   n_load_zfs_module
#
#===============================================================================
n_load_zfs_module() {
  n_remote_log "[ZFS] Loading ZFS kernel module"
  
  # Check if already loaded
  if lsmod | grep -q "^zfs "; then
    n_remote_log "[ZFS] Module already loaded"
  else
    n_remote_log "[ZFS] Module not loaded, attempting to load"
    
    if ! n_load_kernel_module zfs; then
      n_remote_log "[ZFS] ERROR: Failed to load ZFS kernel module"
      return 1
    fi
    
    n_remote_log "[ZFS] Kernel module loaded successfully"
  fi
  
  # Verify module is loaded
  if ! lsmod | grep -q "^zfs "; then
    n_remote_log "[ZFS] ERROR: Module not in lsmod after load attempt"
    return 2
  fi
  
  # Verify /dev/zfs exists
  if [[ ! -c /dev/zfs ]]; then
    n_remote_log "[ZFS] ERROR: /dev/zfs device not found"
    return 2
  fi
  
  n_remote_log "[ZFS] Device /dev/zfs verified"
  
  # Verify zpool command works
  if ! command -v zpool >/dev/null 2>&1; then
    n_remote_log "[ZFS] ERROR: zpool command not found"
    return 2
  fi
  
  # Test zpool command (should return 0 or 1 for no pools, but not crash)
  if zpool list >/dev/null 2>&1 || [[ $? -eq 1 ]]; then
    n_remote_log "[ZFS] zpool command verified functional"
  else
    n_remote_log "[ZFS] ERROR: zpool command failed verification"
    return 2
  fi
  
  n_remote_log "[ZFS] ZFS module loaded and verified successfully"
  return 0
}

#===============================================================================
# n_zpool_create
# --------------
# Thin wrapper around zpool create with argument validation and RAID support.
#
# Behaviour:
#   - Validates pool name format
#   - Verifies all devices exist and are block devices
#   - Checks devices not already in use by ZFS
#   - Validates RAID configuration (minimum devices, size matching)
#   - Builds zpool create command with all options
#   - Applies ZFS properties at creation time (-O flags)
#   - Verifies pool created successfully
#   - Logs all operations via n_remote_log
#
# Arguments:
#   --name <pool_name>           Pool name (required)
#   --vdev-type <type>           Vdev type: single, mirror, raidz, raidz2, raidz3 (required)
#   --devices <dev1> [dev2...]   Vdev devices space-separated (required)
#   --cache <dev>                Cache device (optional)
#   --log <dev>                  Log device (optional)
#   --mountpoint <path>          Mount point (optional, default: /<poolname>)
#   --ashift <value>             Ashift value (optional, default: 12)
#   -f, --force                  Force creation, skip some checks
#   --property <key=value>       ZFS property, repeatable (optional)
#
# Returns:
#   0 on success
#   1 on invalid arguments
#   2 on device validation failure
#   3 on zpool create failure
#
# Example usage:
#   # Simple pool
#   n_zpool_create --name mypool --vdev-type single --devices /dev/vda4
#
#   # Mirror pool
#   n_zpool_create --name mypool --vdev-type mirror --devices /dev/vda4 /dev/vdb4 -f
#
#   # RAIDZ2 with cache and properties
#   n_zpool_create --name mypool --vdev-type raidz2 \
#     --devices /dev/vda4 /dev/vdb4 /dev/vdc4 /dev/vdd4 \
#     --cache /dev/nvme0n1p1 --log /dev/nvme0n1p2 \
#     --property compression=zstd --property atime=off \
#     --mountpoint /srv/storage
#
#===============================================================================
n_zpool_create() {
  local pool_name=""
  local vdev_type=""
  local -a devices=()
  local cache_dev=""
  local log_dev=""
  local mountpoint=""
  local ashift="12"
  local force=0
  local -a properties=()
  
  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        pool_name="$2"
        shift 2
        ;;
      --vdev-type)
        vdev_type="$2"
        shift 2
        ;;
      --devices)
        shift
        while [[ $# -gt 0 ]] && [[ ! "$1" =~ ^- ]]; do
          devices+=("$1")
          shift
        done
        ;;
      --cache)
        cache_dev="$2"
        shift 2
        ;;
      --log)
        log_dev="$2"
        shift 2
        ;;
      --mountpoint)
        mountpoint="$2"
        shift 2
        ;;
      --ashift)
        ashift="$2"
        shift 2
        ;;
      -f|--force)
        force=1
        shift
        ;;
      --property)
        properties+=("$2")
        shift 2
        ;;
      *)
        n_remote_log "[ZPOOL] ERROR: Unknown argument: $1"
        return 1
        ;;
    esac
  done
  
  # Validate required arguments
  if [[ -z "$pool_name" ]]; then
    n_remote_log "[ZPOOL] ERROR: --name is required"
    return 1
  fi
  
  if [[ -z "$vdev_type" ]]; then
    n_remote_log "[ZPOOL] ERROR: --vdev-type is required"
    return 1
  fi
  
  if [[ ${#devices[@]} -eq 0 ]]; then
    n_remote_log "[ZPOOL] ERROR: --devices is required"
    return 1
  fi
  
  # Validate pool name format (alphanumeric, hyphens, underscores)
  if [[ ! "$pool_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    n_remote_log "[ZPOOL] ERROR: Invalid pool name format: $pool_name"
    return 1
  fi
  
  # Validate vdev type
  case "$vdev_type" in
    single|mirror|raidz|raidz1|raidz2|raidz3) ;;
    *)
      n_remote_log "[ZPOOL] ERROR: Invalid vdev-type: $vdev_type (use: single, mirror, raidz, raidz2, raidz3)"
      return 1
      ;;
  esac
  
  # Normalize raidz1 to raidz
  if [[ "$vdev_type" == "raidz1" ]]; then
    vdev_type="raidz"
  fi
  
  n_remote_log "[ZPOOL] Creating pool: $pool_name"
  n_remote_log "[ZPOOL] Vdev type: $vdev_type"
  n_remote_log "[ZPOOL] Devices: ${devices[*]}"
  
  # Validate minimum device requirements
  local min_devices=1
  case "$vdev_type" in
    mirror)
      min_devices=2
      ;;
    raidz)
      min_devices=3
      ;;
    raidz2)
      min_devices=4
      ;;
    raidz3)
      min_devices=5
      ;;
  esac
  
  if [[ ${#devices[@]} -lt $min_devices ]]; then
    n_remote_log "[ZPOOL] ERROR: $vdev_type requires at least $min_devices devices, got ${#devices[@]}"
    return 1
  fi
  
  # Verify all devices exist and are block devices
  n_remote_log "[ZPOOL] Validating devices..."
  local -a device_sizes=()
  
  for dev in "${devices[@]}"; do
    if [[ ! -b "$dev" ]]; then
      n_remote_log "[ZPOOL] ERROR: Device not found or not a block device: $dev"
      return 2
    fi
    
    # Get device size in bytes
    local size_bytes
    size_bytes=$(blockdev --getsize64 "$dev" 2>/dev/null)
    if [[ -z "$size_bytes" ]]; then
      n_remote_log "[ZPOOL] ERROR: Could not determine size of device: $dev"
      return 2
    fi
    
    device_sizes+=("$size_bytes")
    local size_gb=$((size_bytes / 1024 / 1024 / 1024))
    n_remote_log "[ZPOOL] Device $dev: ${size_gb}GB"
  done
  
  # For RAID configurations, verify all devices are same size
  if [[ "$vdev_type" != "single" ]]; then
    local first_size="${device_sizes[0]}"
    local sizes_match=1
    
    for size in "${device_sizes[@]}"; do
      # Allow 1% size variance (some drives report slightly different sizes)
      local diff=$((first_size > size ? first_size - size : size - first_size))
      local variance=$((first_size / 100))
      
      if [[ $diff -gt $variance ]]; then
        sizes_match=0
        break
      fi
    done
    
    if [[ $sizes_match -eq 0 ]]; then
      n_remote_log "[ZPOOL] ERROR: RAID configuration requires all devices to be same size"
      n_remote_log "[ZPOOL] Device sizes (bytes): ${device_sizes[*]}"
      return 2
    fi
    
    n_remote_log "[ZPOOL] All devices are same size (within 1% tolerance)"
  fi
  
  # Check if devices are already in use by ZFS
  if [[ $force -eq 0 ]]; then
    n_remote_log "[ZPOOL] Checking if devices are in use..."
    for dev in "${devices[@]}"; do
      if zpool status -P 2>/dev/null | grep -q "$(readlink -f "$dev")"; then
        n_remote_log "[ZPOOL] ERROR: Device already in use by ZFS: $dev"
        n_remote_log "[ZPOOL] Use --force to override"
        return 2
      fi
    done
  fi
  
  # Validate cache device if specified
  if [[ -n "$cache_dev" ]]; then
    if [[ ! -b "$cache_dev" ]]; then
      n_remote_log "[ZPOOL] ERROR: Cache device not found: $cache_dev"
      return 2
    fi
    n_remote_log "[ZPOOL] Cache device: $cache_dev"
  fi
  
  # Validate log device if specified
  if [[ -n "$log_dev" ]]; then
    if [[ ! -b "$log_dev" ]]; then
      n_remote_log "[ZPOOL] ERROR: Log device not found: $log_dev"
      return 2
    fi
    n_remote_log "[ZPOOL] Log device: $log_dev"
  fi
  
  # Build zpool create command
  local -a cmd=(zpool create)
  
  # Add force flag
  if [[ $force -eq 1 ]]; then
    cmd+=(-f)
  fi
  
  # Add pool options (-o)
  cmd+=(-o "ashift=${ashift}")
  
  # Add dataset properties (-O)
  for prop in "${properties[@]}"; do
    cmd+=(-O "$prop")
  done
  
  # Add mountpoint
  if [[ -n "$mountpoint" ]]; then
    cmd+=(-m "$mountpoint")
  else
    # Default: no automatic mount
    cmd+=(-m "none")
  fi
  
  # Add pool name
  cmd+=("$pool_name")
  
  # Add vdev specification
  if [[ "$vdev_type" != "single" ]]; then
    cmd+=("$vdev_type")
  fi
  cmd+=("${devices[@]}")
  
  # Add cache device
  if [[ -n "$cache_dev" ]]; then
    cmd+=(cache "$cache_dev")
  fi
  
  # Add log device
  if [[ -n "$log_dev" ]]; then
    cmd+=(log "$log_dev")
  fi
  
  # Log the command
  n_remote_log "[ZPOOL] Executing: ${cmd[*]}"
  
  # Execute zpool create
  local output
  output=$("${cmd[@]}" 2>&1)
  local rc=$?
  
  if [[ $rc -ne 0 ]]; then
    n_remote_log "[ZPOOL] ERROR: zpool create failed (exit code: $rc)"
    n_remote_log "[ZPOOL] Output: $output"
    return 3
  fi
  
  # Verify pool was created
  if ! zpool list "$pool_name" >/dev/null 2>&1; then
    n_remote_log "[ZPOOL] ERROR: Pool created but not visible in zpool list"
    return 3
  fi
  
  n_remote_log "[ZPOOL] Pool created successfully: $pool_name"
  
  # Show pool status
  local status
  status=$(zpool status "$pool_name" 2>&1)
  n_remote_log "[ZPOOL] Pool status:"
  while IFS= read -r line; do
    n_remote_log "[ZPOOL]   $line"
  done <<< "$status"
  
  return 0
}
