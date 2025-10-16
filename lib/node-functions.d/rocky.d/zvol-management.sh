

#===============================================================================
# node_zvol_manage
# ----------------
# Manage ZFS zvol operations (create, delete, list, check).
#
# Behaviour:
#   - Dispatches zvol operations to specific handlers
#   - Validates required parameters for each action
#   - Uses remote_log for progress and error reporting
#   - Supports standard zvol lifecycle operations
#
# Arguments:
#   $1 - action (create|delete|list|check|info)
#   $@ - additional arguments (varies by action)
#
# Action-specific arguments:
#   create: --pool <pool> --name <name> --size <size>
#   delete: --pool <pool> --name <name>
#   check:  --pool <pool> --name <name>
#   info:   --pool <pool> --name <name>
#   list:   [--pool <pool>]
#
# Examples:
#   node_zvol_manage create --pool ztest --name vm-a --size 40G
#   node_zvol_manage delete --pool ztest --name vm-a
#   node_zvol_manage list --pool ztest
#
# Returns:
#   0 on success
#   1 on error (invalid action or operation failure)
#===============================================================================
node_zvol_manage() {
  local action="$1"
  shift
  
  # Validate action
  if [ -z "$action" ]; then
    remote_log "Usage: node_zvol_manage <action> [options]"
    return 1
  fi
  
  # Dispatch to action handler
  case "$action" in
    create)
      node_zvol_create "$@"
      ;;
    delete)
      node_zvol_delete "$@"
      ;;
    list)
      node_zvol_list "$@"
      ;;
    check)
      node_zvol_check "$@"
      ;;
    info)
      node_zvol_info "$@"
      ;;
    *)
      remote_log "Unknown zvol action '${action}'. Valid: create, delete, list, check, info"
      return 1
      ;;
  esac
  
  return $?
}

#===============================================================================
# node_zvol_create
# ----------------
# Create a new ZFS zvol.
#
# Behaviour:
#   - Validates required parameters (pool, name, size)
#   - Creates zvol with specified size
#   - Uses remote_log for progress reporting
#
# Arguments:
#   --pool <pool>  - ZFS pool name
#   --name <name>  - Zvol name
#   --size <size>  - Zvol size (e.g., 40G, 1T)
#
# Returns:
#   0 on success
#   1 on error (missing parameters or zfs command failure)
#===============================================================================
node_zvol_create() {
  local pool="" name="" size=""
  
  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --pool) pool="$2"; shift 2 ;;
      --name) name="$2"; shift 2 ;;
      --size) size="$2"; shift 2 ;;
      *) remote_log "Unknown parameter: $1"; return 1 ;;
    esac
  done
  
  # Validate required parameters
  if [ -z "$pool" ] || [ -z "$name" ] || [ -z "$size" ]; then
    remote_log "Missing required parameters. Usage: --pool <pool> --name <name> --size <size>"
    return 1
  fi
  
  local zvol_path="${pool}/${name}"
  
  # Check if zvol already exists
  if zfs list -t volume "$zvol_path" >/dev/null 2>&1; then
    remote_log "Zvol ${zvol_path} already exists"
    return 1
  fi
  
  # Create zvol
  remote_log "Creating zvol ${zvol_path} with size ${size}"
  if zfs create -V "$size" "$zvol_path"; then
    remote_log "Successfully created zvol ${zvol_path}"
    return 0
  else
    remote_log "Failed to create zvol ${zvol_path}"
    return 1
  fi
}

#===============================================================================
# node_zvol_delete
# ----------------
# Delete an existing ZFS zvol.
#
# Behaviour:
#   - Validates required parameters (pool, name)
#   - Deletes specified zvol
#   - Uses remote_log for progress reporting
#
# Arguments:
#   --pool <pool>  - ZFS pool name
#   --name <name>  - Zvol name
#
# Returns:
#   0 on success
#   1 on error (missing parameters or zfs command failure)
#===============================================================================
node_zvol_delete() {
  local pool="" name=""
  
  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --pool) pool="$2"; shift 2 ;;
      --name) name="$2"; shift 2 ;;
      *) remote_log "Unknown parameter: $1"; return 1 ;;
    esac
  done
  
  # Validate required parameters
  if [ -z "$pool" ] || [ -z "$name" ]; then
    remote_log "Missing required parameters. Usage: --pool <pool> --name <name>"
    return 1
  fi
  
  local zvol_path="${pool}/${name}"
  
  # Check if zvol exists
  if ! zfs list -t volume "$zvol_path" >/dev/null 2>&1; then
    remote_log "Zvol ${zvol_path} does not exist"
    return 1
  fi
  
  # Delete zvol
  remote_log "Deleting zvol ${zvol_path}"
  if zfs destroy "$zvol_path"; then
    remote_log "Successfully deleted zvol ${zvol_path}"
    return 0
  else
    remote_log "Failed to delete zvol ${zvol_path}"
    return 1
  fi
}

#===============================================================================
# node_zvol_list
# --------------
# List ZFS zvols, optionally filtered by pool.
#
# Behaviour:
#   - Lists all zvols or those in a specific pool
#   - Outputs zvol names with size information
#   - Uses remote_log for error reporting
#
# Arguments:
#   [--pool <pool>]  - Optional: filter by pool name
#
# Returns:
#   0 on success
#   1 on error
#===============================================================================
node_zvol_list() {
  local pool=""
  
  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --pool) pool="$2"; shift 2 ;;
      *) remote_log "Unknown parameter: $1"; return 1 ;;
    esac
  done
  
  # List zvols
  if [ -n "$pool" ]; then
    zfs list -t volume -o name,volsize -r "$pool" 2>/dev/null || {
      remote_log "Failed to list zvols in pool ${pool}"
      return 1
    }
  else
    zfs list -t volume -o name,volsize 2>/dev/null || {
      remote_log "Failed to list zvols"
      return 1
    }
  fi
  
  return 0
}

#===============================================================================
# node_zvol_check
# ---------------
# Check if a specific zvol exists.
#
# Behaviour:
#   - Validates required parameters (pool, name)
#   - Checks zvol existence
#   - Uses remote_log for reporting
#
# Arguments:
#   --pool <pool>  - ZFS pool name
#   --name <name>  - Zvol name
#
# Returns:
#   0 if zvol exists
#   1 if zvol does not exist or error
#===============================================================================
node_zvol_check() {
  local pool="" name=""
  
  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --pool) pool="$2"; shift 2 ;;
      --name) name="$2"; shift 2 ;;
      *) remote_log "Unknown parameter: $1"; return 1 ;;
    esac
  done
  
  # Validate required parameters
  if [ -z "$pool" ] || [ -z "$name" ]; then
    remote_log "Missing required parameters. Usage: --pool <pool> --name <name>"
    return 1
  fi
  
  local zvol_path="${pool}/${name}"
  
  if zfs list -t volume "$zvol_path" >/dev/null 2>&1; then
    remote_log "Zvol ${zvol_path} exists"
    return 0
  else
    remote_log "Zvol ${zvol_path} does not exist"
    return 1
  fi
}

#===============================================================================
# node_zvol_info
# --------------
# Display detailed information about a specific zvol.
#
# Behaviour:
#   - Validates required parameters (pool, name)
#   - Shows zvol properties and device path
#   - Uses remote_log for error reporting
#
# Arguments:
#   --pool <pool>  - ZFS pool name
#   --name <name>  - Zvol name
#
# Returns:
#   0 on success
#   1 on error (missing parameters or zvol not found)
#===============================================================================
node_zvol_info() {
  local pool="" name=""
  
  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --pool) pool="$2"; shift 2 ;;
      --name) name="$2"; shift 2 ;;
      *) remote_log "Unknown parameter: $1"; return 1 ;;
    esac
  done
  
  # Validate required parameters
  if [ -z "$pool" ] || [ -z "$name" ]; then
    remote_log "Missing required parameters. Usage: --pool <pool> --name <name>"
    return 1
  fi
  
  local zvol_path="${pool}/${name}"
  
  # Check if zvol exists
  if ! zfs list -t volume "$zvol_path" >/dev/null 2>&1; then
    remote_log "Zvol ${zvol_path} does not exist"
    return 1
  fi
  
  # Display zvol information
  echo "=== Zvol Information: ${zvol_path} ==="
  zfs list -t volume -o name,volsize,used,available,referenced "$zvol_path"
  echo ""
  echo "Device path: /dev/zvol/${zvol_path}"
  
  return 0
}
