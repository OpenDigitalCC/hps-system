

# Default implementation (fallback)
build_zfs_source() {
  log "Running default build_zfs_source (not distro-specific)"
  echo "This system must implement its own ZFS build process through the local system config file."
  return 1
}


#===============================================================================
# n_storage_network_setup
# ------------------------
# Setup storage network using IPS allocation
#
# Behaviour:
#   - Requests IP allocation from IPS
#   - Configures storage VLAN
#   - Uses generic network functions
#
# Parameters:
#   $1: Physical interface
#   $2: Storage network index (0, 1, etc.)
#
# Returns:
#   0 on success
#   1 on error
#
# Example usage:
#   n_storage_network_setup eth0 0
#===============================================================================
n_storage_network_setup() {
  local phys_iface="$1"
  local storage_index="${2:-0}"
  
  # Get our MAC for identification
  local mac=$(cat /sys/class/net/${phys_iface}/address)
  
  # Request IP allocation from IPS
  n_remote_log "Requesting storage IP allocation from IPS"
  local allocation=$(n_ips_command "allocate_storage_ip" \
    "mac=$mac" \
    "storage_index=$storage_index")
  
  if [[ -z "$allocation" ]] || [[ "$allocation" == "ERROR"* ]]; then
    n_remote_log "ERROR: Failed to get IP allocation from IPS"
    return 1
  fi
  
  # Parse allocation (format: vlan_id:ip:netmask:gateway:mtu)
  local vlan_id ip netmask gateway mtu
  IFS=':' read -r vlan_id ip netmask gateway mtu <<< "$allocation"
  
  # Create VLAN
  if ! n_vlan_create "$phys_iface" "$vlan_id" "$mtu"; then
    return 1
  fi
  
  # Add IP
  local vlan_iface="${phys_iface}.${vlan_id}"
  if ! n_interface_add_ip "$vlan_iface" "$ip" "$netmask"; then
    return 1
  fi
  
  # Store in host variables
  n_remote_host_variable "storage${storage_index}_interface" "$vlan_iface"
  n_remote_host_variable "storage${storage_index}_ip" "$ip"
  n_remote_host_variable "storage${storage_index}_gateway" "$gateway"
  
  # Test gateway
  if ping -c 1 -W 2 "$gateway" &>/dev/null; then
    n_remote_log "Storage network configured, gateway $gateway reachable"
  else
    n_remote_log "Storage network configured, gateway $gateway not yet reachable"
  fi
  
  return 0
}



#===============================================================================
# n_storage_validate_jumbo_frames
# --------------------------------
# Validate jumbo frame support on storage network
#
# Behaviour:
#   - Tests large packet transmission to gateway
#   - Uses ping with don't fragment flag
#   - Reports MTU issues to IPS
#
# Parameters:
#   $1: Storage VLAN interface name (e.g., eth0.31)
#   $2: Target IP (usually gateway)
#   $3: Expected MTU (default 9000)
#
# Returns:
#   0 if jumbo frames work
#   1 if MTU issue detected
#
# Example usage:
#   n_storage_validate_jumbo_frames eth0.31 10.31.0.1 9000
#===============================================================================
n_storage_validate_jumbo_frames() {
    local vlan_iface="$1"
    local target_ip="$2"
    local expected_mtu="${3:-9000}"
    
    # Calculate ping packet size (MTU - IP header - ICMP header)
    local packet_size=$((expected_mtu - 28))
    
    n_remote_log "Testing jumbo frames to $target_ip with packet size $packet_size"
    
    if ping -c 3 -W 2 -s "$packet_size" -M do -I "$vlan_iface" "$target_ip" &>/dev/null; then
        n_remote_log "Jumbo frames validated successfully on $vlan_iface"
        return 0
    else
        n_remote_log "ERROR: Jumbo frame test failed on $vlan_iface to $target_ip"
        n_remote_log "Switch may not support MTU $expected_mtu on storage VLAN"
        return 1
    fi
}


########

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

