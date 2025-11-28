#!/bin/bash
#===============================================================================
# HPS Storage Functions for Alpine Linux
# High-level storage orchestration and workflow functions
#===============================================================================

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
