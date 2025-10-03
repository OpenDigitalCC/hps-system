


# Default implementation (fallback)
build_zfs_source() {
  log "Running default build_zfs_source (not distro-specific)"
  echo "This system must implement its own ZFS build process through the local system config file."
  return 1
}



#===============================================================================
# node_storage_manager
# --------------------
# Wrapper function to manage zvol and iSCSI operations on storage nodes.
#
# Behaviour:
#   - Validates component and action arguments
#   - Dispatches to component-specific management functions
#   - Uses remote_log for all progress and error reporting
#   - Returns appropriate exit codes for orchestration
#
# Arguments:
#   $1 - component (lio|zvol)
#   $2 - action (start|stop|create|delete|etc)
#   $@ - additional arguments passed to component function
#
# Examples:
#   node_storage_manager lio start
#   node_storage_manager zvol create --pool ztest --name vm-a --size 40G
#
# Returns:
#   0 on success
#   1 on error (invalid component or operation failure)
#===============================================================================
node_storage_manager() {
  local component="$1"
  local action="$2"
  shift 2
  
  # Validate arguments
  if [ -z "$component" ] || [ -z "$action" ]; then
    remote_log "Usage: node_storage_manager <component> <action> [options]"
    return 1
  fi
  
  # Dispatch to appropriate function
  case "$component" in
    lio)
      remote_log "Executing LIO ${action}"
      node_lio_manage "$action" "$@"
      ;;
    zvol)
      remote_log "Executing zvol ${action}"
      node_zvol_manage "$action" "$@"
      ;;
    *)
      remote_log "Unknown component '${component}'. Valid: lio, zvol"
      return 1
      ;;
  esac
  
  local result=$?
  if [ $result -eq 0 ]; then
    remote_log "${component} ${action} completed successfully"
  else
    remote_log "${component} ${action} failed with code ${result}"
  fi
  
  return $result
}

