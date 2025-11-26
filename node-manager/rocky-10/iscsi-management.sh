
## NODE Functions


#===============================================================================
# node_lio_manage
# ---------------
# Manage LIO iSCSI target operations (create, delete, start, stop, status).
#
# Behaviour:
#   - Dispatches LIO operations to specific handlers
#   - Validates required parameters for each action
#   - Uses remote_log for progress and error reporting
#   - Supports iSCSI target lifecycle operations
#
# Arguments:
#   $1 - action (create|delete|start|stop|status|list)
#   $@ - additional arguments (varies by action)
#
# Action-specific arguments:
#   create: --iqn <iqn> --device <device> [--acl <initiator-iqn>]
#   delete: --iqn <iqn>
#   start:  (starts targetcli service)
#   stop:   (stops targetcli service)
#   status: (shows target status)
#   list:   (lists all targets)
#
# Examples:
#   node_lio_manage start
#   node_lio_manage create --iqn iqn.2025-09.local:vm-a --device /dev/zvol/pool/vol1
#   node_lio_manage delete --iqn iqn.2025-09.local:vm-a
#
# Returns:
#   0 on success
#   1 on error (invalid action or operation failure)
#===============================================================================
node_lio_manage() {
  local action="$1"
  shift
  
  # Validate action
  if [ -z "$action" ]; then
    remote_log "Usage: node_lio_manage <action> [options]"
    return 1
  fi
  
  # Dispatch to action handler
  case "$action" in
    create)
      node_lio_create "$@"
      ;;
    delete)
      node_lio_delete "$@"
      ;;
    start)
      node_lio_start "$@"
      ;;
    stop)
      node_lio_stop "$@"
      ;;
    status)
      node_lio_status "$@"
      ;;
    list)
      node_lio_list "$@"
      ;;
    *)
      remote_log "Unknown LIO action '${action}'. Valid: create, delete, start, stop, status, list"
      return 1
      ;;
  esac
  
  return $?
}

#===============================================================================
# node_lio_create
# ---------------
# Create iSCSI target with backstore and optional ACL.
#
# Behaviour:
#   - Validates required parameters (iqn, device)
#   - Creates block backstore from device
#   - Creates iSCSI target with specified IQN
#   - Creates LUN mapping
#   - Optionally configures initiator ACL
#   - Uses remote_log for progress reporting
#
# Arguments:
#   --iqn <iqn>              - iSCSI Qualified Name
#   --device <device>        - Block device path (e.g., /dev/zvol/pool/vol1)
#   [--acl <initiator-iqn>]  - Optional: initiator IQN for ACL
#
# Returns:
#   0 on success
#   1 on error (missing parameters or targetcli failure)
#===============================================================================
node_lio_create() {
  local iqn="" device="" acl=""
  
  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --iqn) iqn="$2"; shift 2 ;;
      --device) device="$2"; shift 2 ;;
      --acl) acl="$2"; shift 2 ;;
      *) remote_log "Unknown parameter: $1"; return 1 ;;
    esac
  done
  
  # Validate required parameters
  if [ -z "$iqn" ] || [ -z "$device" ]; then
    remote_log "Missing required parameters. Usage: --iqn <iqn> --device <device> [--acl <initiator-iqn>]"
    return 1
  fi
  
  # Check if device exists
  if [ ! -e "$device" ]; then
    remote_log "Device ${device} does not exist"
    return 1
  fi
  
  # Extract backstore name from IQN (use last part after colon)
  local backstore_name="${iqn##*:}"
  
  # Create backstore
  remote_log "Creating backstore ${backstore_name} for device ${device}"
  if ! targetcli /backstores/block create name="${backstore_name}" dev="${device}"; then
    remote_log "Failed to create backstore ${backstore_name}"
    return 1
  fi
  
  # Create iSCSI target
  remote_log "Creating iSCSI target ${iqn}"
  if ! targetcli /iscsi create "${iqn}"; then
    remote_log "Failed to create iSCSI target ${iqn}"
    targetcli /backstores/block delete "${backstore_name}"
    return 1
  fi
  
  # Create LUN (using default TPG1)
  remote_log "Creating LUN for ${iqn}"
  if ! targetcli "/iscsi/${iqn}/tpg1/luns" create "/backstores/block/${backstore_name}"; then
    remote_log "Failed to create LUN"
    targetcli /iscsi delete "${iqn}"
    targetcli /backstores/block delete "${backstore_name}"
    return 1
  fi
  
  # Configure ACL if provided
  if [ -n "$acl" ]; then
    remote_log "Configuring ACL for initiator ${acl}"
    if ! targetcli "/iscsi/${iqn}/tpg1/acls" create "${acl}"; then
      remote_log "Failed to create ACL"
      targetcli /iscsi delete "${iqn}"
      targetcli /backstores/block delete "${backstore_name}"
      return 1
    fi
  else
    # Disable authentication for demo/testing (enable write access for any initiator)
    remote_log "Disabling authentication (demo mode)"
    targetcli "/iscsi/${iqn}/tpg1" set attribute authentication=0 demo_mode_write_protect=0 generate_node_acls=1
  fi
  
  # Save configuration
  targetcli saveconfig
  
  remote_log "Successfully created iSCSI target ${iqn} with device ${device}"
  return 0
}



#===============================================================================
# node_lio_delete
# ---------------
# Delete iSCSI target and associated backstore.
#
# Behaviour:
#   - Validates required parameter (iqn)
#   - Checks if target exists before deletion
#   - Deletes iSCSI target
#   - Deletes associated backstore if it exists
#   - Uses remote_log for progress reporting
#
# Arguments:
#   --iqn <iqn>  - iSCSI Qualified Name
#
# Returns:
#   0 on success
#   1 on error (missing parameters or targetcli failure)
#===============================================================================
node_lio_delete() {
  local iqn=""
  
  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --iqn) iqn="$2"; shift 2 ;;
      *) remote_log "Unknown parameter: $1"; return 1 ;;
    esac
  done
  
  # Validate required parameters
  if [ -z "$iqn" ]; then
    remote_log "Missing required parameter. Usage: --iqn <iqn>"
    return 1
  fi
  
  # Extract backstore name from IQN
  local backstore_name="${iqn##*:}"
  
  # Check if target exists
  if ! targetcli /iscsi ls 2>/dev/null | grep -q "${iqn}"; then
    remote_log "iSCSI target ${iqn} does not exist"
    return 1
  fi
  
  # Delete iSCSI target
  remote_log "Deleting iSCSI target ${iqn}"
  if targetcli /iscsi delete "${iqn}" 2>&1; then
    remote_log "Successfully deleted iSCSI target ${iqn}"
  else
    remote_log "Failed to delete iSCSI target ${iqn}"
    return 1
  fi
  
  # Check if backstore exists before trying to delete
  if targetcli /backstores/block ls 2>/dev/null | grep -q "${backstore_name}"; then
    remote_log "Deleting backstore ${backstore_name}"
    if targetcli /backstores/block delete "${backstore_name}" 2>&1; then
      remote_log "Successfully deleted backstore ${backstore_name}"
    else
      remote_log "Warning: Failed to delete backstore ${backstore_name}"
    fi
  else
    remote_log "Backstore ${backstore_name} does not exist, skipping"
  fi
  
  # Save configuration
  targetcli saveconfig
  
  return 0
}




#===============================================================================
# node_lio_start
# --------------
# Start the target service.
#
# Behaviour:
#   - Starts and enables the target service
#   - Uses remote_log for progress reporting
#
# Arguments:
#   None
#
# Returns:
#   0 on success
#   1 on error
#===============================================================================
node_lio_start() {
  remote_log "Starting target service"
  
  if systemctl start target && systemctl enable target; then
    remote_log "Successfully started target service"
    return 0
  else
    remote_log "Failed to start target service"
    return 1
  fi
}

#===============================================================================
# node_lio_stop
# -------------
# Stop the target service.
#
# Behaviour:
#   - Stops the target service
#   - Uses remote_log for progress reporting
#
# Arguments:
#   None
#
# Returns:
#   0 on success
#   1 on error
#===============================================================================
node_lio_stop() {
  remote_log "Stopping target service"
  
  if systemctl stop target; then
    remote_log "Successfully stopped target service"
    return 0
  else
    remote_log "Failed to stop target service"
    return 1
  fi
}

#===============================================================================
# node_lio_status
# ---------------
# Show target service status and configuration.
#
# Behaviour:
#   - Displays systemd service status
#   - Shows current target configuration
#   - Uses remote_log for error reporting
#
# Arguments:
#   None
#
# Returns:
#   0 on success
#   1 on error
#===============================================================================
node_lio_status() {
  echo "=== Target Service Status ==="
  systemctl status target --no-pager
  
  echo ""
  echo "=== LIO Configuration ==="
  targetcli ls
  
  return 0
}

#===============================================================================
# node_lio_list
# -------------
# List all configured iSCSI targets.
#
# Behaviour:
#   - Lists all iSCSI targets and their LUNs
#   - Uses remote_log for error reporting
#
# Arguments:
#   None
#
# Returns:
#   0 on success
#   1 on error
#===============================================================================
node_lio_list() {
  echo "=== iSCSI Targets ==="
  targetcli /iscsi ls
  
  echo ""
  echo "=== Block Backstores ==="
  targetcli /backstores/block ls
  
  return 0
}




