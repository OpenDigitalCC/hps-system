

# Default implementation (fallback)
build_zfs_source() {
  log "Running default build_zfs_source (not distro-specific)"
  echo "This system must implement its own ZFS build process through the local system config file."
  return 1
}


#===============================================================================
# n_storage_configure_interface
# -----------------------------
# Configure storage VLAN interface on node
#
# Behaviour:
#   - Creates VLAN interface on specified physical interface
#   - Sets MTU based on cluster configuration
#   - Assigns IP address and netmask
#   - Brings interface up
#   - Validates connectivity to gateway
#
# Parameters:
#   $1: Physical interface name (e.g., eth0, eth1, bond1)
#   $2: VLAN ID
#   $3: IP address
#   $4: Netmask
#   $5: Gateway
#   $6: MTU
#
# Returns:
#   0 on success
#   1 on error
#
# Example usage:
#   n_storage_configure_interface eth0 31 10.31.0.100 255.255.255.0 10.31.0.1 9000
#===============================================================================
n_storage_configure_interface() {
    local phys_iface="$1"
    local vlan_id="$2"
    local ip_addr="$3"
    local netmask="$4"
    local gateway="$5"
    local mtu="${6:-1500}"
    
    # Validate parameters
    if [[ -z "$phys_iface" ]] || [[ -z "$vlan_id" ]] || [[ -z "$ip_addr" ]] || \
       [[ -z "$netmask" ]] || [[ -z "$gateway" ]]; then
        n_remote_log "ERROR: Missing required parameters for storage interface"
        return 1
    fi
    
    # Check if physical interface exists
    if [[ ! -d "/sys/class/net/$phys_iface" ]]; then
        n_remote_log "ERROR: Physical interface $phys_iface does not exist"
        return 1
    fi
    
    local vlan_iface="${phys_iface}.${vlan_id}"
    
    n_remote_log "Configuring storage interface $vlan_iface with IP $ip_addr"
    
    # Remove existing VLAN interface if it exists
    if [[ -d "/sys/class/net/$vlan_iface" ]]; then
        n_remote_log "Removing existing VLAN interface $vlan_iface"
        ip link delete "$vlan_iface" 2>/dev/null
        sleep 1
    fi
    
    # Create VLAN interface
    if ! ip link add link "$phys_iface" name "$vlan_iface" type vlan id "$vlan_id"; then
        n_remote_log "ERROR: Failed to create VLAN interface $vlan_iface"
        return 1
    fi
    
    # Set MTU on VLAN interface
    if ! ip link set dev "$vlan_iface" mtu "$mtu"; then
        n_remote_log "ERROR: Failed to set MTU $mtu on $vlan_iface"
        return 1
    fi
    
    # Bring interface up
    if ! ip link set dev "$vlan_iface" up; then
        n_remote_log "ERROR: Failed to bring up $vlan_iface"
        return 1
    fi
    
    # Assign IP address
    local cidr_bits=$(netmask_to_cidr "$netmask")
    if [[ $? -ne 0 ]]; then
      n_remote_log "ERROR: Invalid netmask $netmask"
      return 1
    fi

    
    if ! ip addr add "${ip_addr}/${cidr_bits}" dev "$vlan_iface"; then
        n_remote_log "ERROR: Failed to assign IP ${ip_addr}/${cidr_bits} to $vlan_iface"
        return 1
    fi
    
    # Add route to storage network if gateway is not directly reachable
    # (Gateway should be on the same subnet for storage networks)
    
    # Store configuration for persistence
    n_remote_host_variable "storage_vlan_interface" "$vlan_iface"
    n_remote_host_variable "storage_vlan_ip" "$ip_addr"
    n_remote_host_variable "storage_vlan_mtu" "$mtu"
    
    # Validate connectivity with ping (3 attempts)
    sleep 2
    if ping -c 3 -W 2 -s $((mtu - 28)) -M do "$gateway" &>/dev/null; then
        n_remote_log "Storage interface $vlan_iface configured successfully, gateway reachable"
        return 0
    else
        n_remote_log "WARNING: Storage interface configured but gateway $gateway not reachable"
        # Still return success as interface is configured
        return 0
    fi
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

