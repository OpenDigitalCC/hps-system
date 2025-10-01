#===============================================================================
# storage_provision_volume
# -----------------------
# Provision a complete storage volume with iSCSI target on a storage host.
#
# Behaviour:
#   - Validates host type is SCH (Storage Cluster Host)
#   - Gets local zpool name from host configuration
#   - Creates ZFS zvol with specified capacity
#   - Creates iSCSI target with the zvol as backing device
#   - Configures target for demo mode (no authentication)
#   - Uses remote_log for all progress and error reporting
#
# Arguments:
#   --iqn <iqn>            - iSCSI Qualified Name for the target
#   --capacity <size>      - Volume size (e.g., 40G, 1T)
#   --zvol-name <name>     - Name for the zvol (without pool prefix)
#
# Examples:
#   storage_provision_volume --iqn iqn.2025-09.local.hps:vm-a-disk1 --capacity 100G --zvol-name vm-a-disk1
#
# Returns:
#   0 on success
#   1 on error (wrong host type, missing parameters, or operation failure)
#===============================================================================
storage_provision_volume() {
  local iqn="" capacity="" zvol_name=""
  
  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --iqn) iqn="$2"; shift 2 ;;
      --capacity) capacity="$2"; shift 2 ;;
      --zvol-name) zvol_name="$2"; shift 2 ;;
      *) remote_log "Unknown parameter: $1"; return 1 ;;
    esac
  done
  
  # Validate required parameters
  if [ -z "$iqn" ] || [ -z "$capacity" ] || [ -z "$zvol_name" ]; then
    remote_log "Missing required parameters. Usage: --iqn <iqn> --capacity <size> --zvol-name <name>"
    return 1
  fi
  
  # Verify this is a storage host
  local host_type=$(remote_host_variable TYPE)
  if [ "$host_type" != "SCH" ]; then
    remote_log "ERROR: This host type is '${host_type}', not 'SCH'. Storage provisioning only allowed on Storage Cluster Hosts"
    return 1
  fi
  
  # Get local zpool name
  local zpool=$(remote_host_variable ZPOOL_NAME)
  if [ -z "$zpool" ]; then
    remote_log "ERROR: Could not determine ZPOOL_NAME for this host"
    return 1
  fi
  

  # Check available space
  local available_bytes=$(storage_get_available_space)
  if [ $? -ne 0 ]; then
    remote_log "ERROR: Could not determine available space"
   return 1
  fi

  local required_bytes=$(storage_parse_capacity "$capacity")
  if [ $? -ne 0 ]; then
    remote_log "ERROR: Invalid capacity format: ${capacity}"
    return 1
  fi

  # Calculate available GB for logging
  local available_gb=$((available_bytes / 1024 / 1024 / 1024))

  if [ "$required_bytes" -gt "$available_bytes" ]; then
    remote_log "ERROR: Insufficient space. Requested ${capacity}, only ${available_gb}G available"
    return 1
  fi

  local available_gb=$((available_bytes / 1024 / 1024 / 1024))

  remote_log "Space check passed: ${capacity} requested, ${available_gb}G available"

  
  remote_log "Provisioning storage volume on SCH with zpool ${zpool}"
  
  # Create zvol
  remote_log "Creating zvol ${zpool}/${zvol_name} with capacity ${capacity}"
  if ! node_storage_manager zvol create --pool "$zpool" --name "$zvol_name" --size "$capacity"; then
    remote_log "ERROR: Failed to create zvol"
    return 1
  fi
  
  # Get device path
  local device="/dev/zvol/${zpool}/${zvol_name}"
  
  # Create iSCSI target
  remote_log "Creating iSCSI target ${iqn} for device ${device}"
  if ! node_storage_manager lio create --iqn "$iqn" --device "$device"; then
    remote_log "ERROR: Failed to create iSCSI target, rolling back zvol"
    node_storage_manager zvol delete --pool "$zpool" --name "$zvol_name"
    return 1
  fi
  
  remote_log "Successfully provisioned volume ${zvol_name} with target ${iqn}"
  return 0
}

#===============================================================================
# storage_deprovision_volume
# --------------------------
# Remove a storage volume and its iSCSI target from a storage host.
#
# Behaviour:
#   - Validates host type is SCH (Storage Cluster Host)
#   - Gets local zpool name from host configuration
#   - Deletes iSCSI target
#   - Deletes ZFS zvol
#   - Uses remote_log for all progress and error reporting
#
# Arguments:
#   --iqn <iqn>            - iSCSI Qualified Name for the target
#   --zvol-name <name>     - Name of the zvol to delete (without pool prefix)
#
# Examples:
#   storage_deprovision_volume --iqn iqn.2025-09.local.hps:vm-a-disk1 --zvol-name vm-a-disk1
#
# Returns:
#   0 on success
#   1 on error (wrong host type, missing parameters, or operation failure)
#===============================================================================
storage_deprovision_volume() {
  local iqn="" zvol_name=""
  
  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --iqn) iqn="$2"; shift 2 ;;
      --zvol-name) zvol_name="$2"; shift 2 ;;
      *) remote_log "Unknown parameter: $1"; return 1 ;;
    esac
  done
  
  # Validate required parameters
  if [ -z "$iqn" ] || [ -z "$zvol_name" ]; then
    remote_log "Missing required parameters. Usage: --iqn <iqn> --zvol-name <name>"
    return 1
  fi
  
  # Verify this is a storage host
  local host_type=$(remote_host_variable TYPE)
  if [ "$host_type" != "SCH" ]; then
    remote_log "ERROR: This host type is '${host_type}', not 'SCH'. Storage deprovisioning only allowed on Storage Cluster Hosts"
    return 1
  fi
  
  # Get local zpool name
  local zpool=$(remote_host_variable ZPOOL_NAME)
  if [ -z "$zpool" ]; then
    remote_log "ERROR: Could not determine ZPOOL_NAME for this host"
    return 1
  fi
  
  remote_log "Deprovisioning storage volume on SCH with zpool ${zpool}"
  
  # Delete iSCSI target
  remote_log "Deleting iSCSI target ${iqn}"
  if ! node_storage_manager lio delete --iqn "$iqn"; then
    remote_log "WARNING: Failed to delete iSCSI target (may not exist)"
  fi
  
  # Delete zvol
  remote_log "Deleting zvol ${zpool}/${zvol_name}"
  if ! node_storage_manager zvol delete --pool "$zpool" --name "$zvol_name"; then
    remote_log "ERROR: Failed to delete zvol"
    return 1
  fi
  
  remote_log "Successfully deprovisioned volume ${zvol_name}"
  return 0
}

#===============================================================================
# storage_get_available_space
# ---------------------------
# Get available space in the local zpool in bytes.
#
# Behaviour:
#   - Gets local zpool name from host configuration
#   - Queries ZFS for available space
#   - Returns space in bytes for easy calculation
#   - Uses remote_log for error reporting
#
# Arguments:
#   None (uses remote_host_variable ZPOOL_NAME)
#
# Returns:
#   0 on success (prints available bytes to stdout)
#   1 on error
#===============================================================================
storage_get_available_space() {
  local zpool=$(remote_host_variable ZPOOL_NAME)
  
  if [ -z "$zpool" ]; then
    remote_log "ERROR: Could not determine ZPOOL_NAME"
    return 1
  fi
  
  # Get available space in bytes
  local available=$(zfs get -Hp -o value available "$zpool" 2>/dev/null)
  
  if [ -z "$available" ]; then
    remote_log "ERROR: Could not get available space for pool ${zpool}"
    return 1
  fi
  
  echo "$available"
  return 0
}

#===============================================================================
# storage_parse_capacity
# ----------------------
# Convert human-readable capacity (e.g., 100G, 2T) to bytes.
#
# Behaviour:
#   - Parses size suffixes: K, M, G, T
#   - Returns size in bytes
#
# Arguments:
#   $1 - capacity string (e.g., "100G", "2T")
#
# Returns:
#   0 on success (prints bytes to stdout)
#   1 on error (invalid format)
#===============================================================================
storage_parse_capacity() {
  local capacity="$1"
  
  if [ -z "$capacity" ]; then
    return 1
  fi
  
  # Extract number and suffix
  local number="${capacity%[KMGT]*}"
  local suffix="${capacity##*[0-9]}"
  
  if [ -z "$number" ]; then
    return 1
  fi
  
  local bytes="$number"
  case "$suffix" in
    K|k) bytes=$((number * 1024)) ;;
    M|m) bytes=$((number * 1024 * 1024)) ;;
    G|g) bytes=$((number * 1024 * 1024 * 1024)) ;;
    T|t) bytes=$((number * 1024 * 1024 * 1024 * 1024)) ;;
    "") bytes="$number" ;; # Already in bytes
    *) return 1 ;;
  esac
  
  echo "$bytes"
  return 0
}
