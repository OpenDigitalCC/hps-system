

#===============================================================================
# n_storage_provision
# --------------------
# Provision storage networks on node
#
# Behaviour:
#   - Loads network modules
#   - Finds available interfaces
#   - Requests allocation from IPS
#   - Configures VLANs
#
# Returns:
#   0 on success
#   1 on error
#===============================================================================
n_storage_provision() {
  n_remote_log "Starting storage network provisioning"
  
  # Load network modules first
  n_auto_load_network_modules
  sleep 2
  
  # Get storage count from cluster config
  local storage_count=$(n_remote_cluster_variable "network_storage_count")
  if [[ -z "$storage_count" ]]; then
    n_remote_log "ERROR: Storage network count not configured"
    return 1
  fi
  
  n_remote_log "Configuring $storage_count storage networks"
  
  # Simple interface detection - check eth1, eth2, etc.
  local interfaces=()
  local if_num=1
  while [[ ${#interfaces[@]} -lt $storage_count ]]; do
    local test_if="eth${if_num}"
    
    # Check if interface exists and has no IP
    if [[ -d "/sys/class/net/$test_if" ]]; then
      if ! ip addr show "$test_if" 2>/dev/null | grep -q "inet "; then
        interfaces+=("$test_if")
        n_remote_log "Found available interface: $test_if"
      fi
    fi
    
    ((if_num++))
    # Safety check to avoid infinite loop
    [[ $if_num -gt 10 ]] && break
  done
  
  if [[ ${#interfaces[@]} -eq 0 ]]; then
    n_remote_log "ERROR: No available interfaces for storage"
    return 1
  fi
  
  # Configure each storage network
  local i
  for ((i=0; i<storage_count && i<${#interfaces[@]}; i++)); do
    local iface="${interfaces[$i]}"
    
    # Bring up interface
    n_remote_log "Bringing up $iface"
    ip link set "$iface" up
    sleep 2
    
    # Request allocation
    n_remote_log "Requesting storage allocation $i on $iface"
    local allocation=$(n_ips_command "host_allocate_networks" "index=$i")
    
    if [[ -z "$allocation" ]] || [[ "$allocation" == "ERROR"* ]]; then
      n_remote_log "ERROR: Allocation failed: $allocation"
      continue
    fi
    
    # Parse response
    local vlan_id ip netmask gateway mtu
    IFS=':' read -r vlan_id ip netmask gateway mtu <<< "$allocation"
    
    n_remote_log "Allocated: VLAN=$vlan_id IP=$ip MTU=$mtu"
    
    # Create VLAN
    if n_vlan_create "$iface" "$vlan_id" "$mtu"; then
      # Add IP
      if n_interface_add_ip "${iface}.${vlan_id}" "$ip" "$netmask"; then
        n_remote_log "Storage $i configured: ${iface}.${vlan_id} = $ip"
        
        # Store success
        n_remote_host_variable "storage${i}_interface" "${iface}.${vlan_id}"
        n_remote_host_variable "storage${i}_configured" "yes"
      else
        n_remote_log "ERROR: Failed to add IP $ip"
      fi
    else
      n_remote_log "ERROR: Failed to create VLAN $vlan_id on $iface"
    fi
  done
  
  # Show final state
  n_remote_log "Storage provisioning complete. Current VLANs: $(n_network_show_vlans)"
  
  return 0
}



#===============================================================================
# n_network_select_storage_interface
# -----------------------------------
# Select best interface for storage based on speed
#
# Behaviour:
#   - Prefers 10G+ interfaces
#   - Falls back to fastest available
#   - Only considers 'up' interfaces
#
# Returns:
#   0 on success (echoes interface name)
#   1 if no suitable interface found
#
# Example usage:
#   storage_if=$(n_network_select_storage_interface)
#===============================================================================
n_network_select_storage_interface() {
  # First try to find 10G+ interface
  local iface=$(n_network_find_best_interface 10000 up)
  
  # If not found, get fastest available
  if [[ -z "$iface" ]]; then
    iface=$(n_network_find_best_interface 0 up)
  fi
  
  if [[ -n "$iface" ]]; then
    n_remote_log "Selected $iface for storage ($(n_network_get_interfaces | grep "^$iface:" | cut -d: -f5)Mbps)"
    echo "$iface"
    return 0
  fi
  
  return 1
}


#===============================================================================
# n_storage_auto_configure
# -------------------------
# Automatically configure storage network on best available interface
#
# Behaviour:
#   - Uses existing interface selection functions
#   - Gets allocation from IPS
#   - Configures VLAN and IP
#
# Parameters:
#   $1: Storage network index (optional, default: 0)
#   $2: Preferred interface (optional, auto-detect if not specified)
#
# Returns:
#   0 on success
#   1 on error
#===============================================================================
n_storage_auto_configure() {
  local storage_index="${1:-0}"
  local pref_iface="${2:-}"
  
  # Use existing selector if no preference
  if [[ -z "$pref_iface" ]]; then
    pref_iface=$(n_network_select_storage_interface)
    if [[ -z "$pref_iface" ]]; then
      n_remote_log "ERROR: No suitable interface for storage"
      return 1
    fi
  fi
  
  n_remote_log "Configuring storage network $storage_index on $pref_iface"
  
  # Bring interface up if down
  if ! grep -q "up" "/sys/class/net/$pref_iface/operstate" 2>/dev/null; then
    n_remote_log "Bringing up interface $pref_iface"
    ip link set dev "$pref_iface" up
    sleep 2
  fi
  
  # Get allocation from IPS
  local allocation=$(n_ips_command "allocate_storage_ip" "index=$storage_index")
  if [[ -z "$allocation" ]] || [[ "$allocation" == "ERROR"* ]]; then
    n_remote_log "ERROR: Failed to get allocation: $allocation"
    return 1
  fi
  
  # Parse allocation
  local vlan_id ip netmask gateway mtu
  IFS=':' read -r vlan_id ip netmask gateway mtu <<< "$allocation"
  
  # Configure VLAN
  if ! n_vlan_create "$pref_iface" "$vlan_id" "$mtu"; then
    return 1
  fi
  
  # Add IP
  if ! n_interface_add_ip "${pref_iface}.${vlan_id}" "$ip" "$netmask"; then
    return 1
  fi
  
  n_remote_log "Storage network configured: ${pref_iface}.${vlan_id} = $ip"
  
  # Quick connectivity test
  if ping -c 1 -W 2 "$gateway" &>/dev/null; then
    n_remote_log "Gateway $gateway reachable"
  fi
  
  return 0
}



#===============================================================================
# n_network_select_storage_interface
# -----------------------------------
# Select best interface for storage (simplified)
#
# Returns:
#   0 on success (echoes interface name)
#   1 if no suitable interface found
#===============================================================================
n_network_select_storage_interface() {
  local iface
  
  # Try 10G+ first
  iface=$(n_network_find_best_interface 10000 up)
  
  # Fallback to any speed
  if [[ -z "$iface" ]]; then
    iface=$(n_network_find_best_interface 0 up)
  fi
  
  if [[ -n "$iface" ]]; then
    # Clean any whitespace
    iface=$(echo -n "$iface" | tr -d '\n\r')
    echo "$iface"
    return 0
  fi
  
  return 1
}


#===============================================================================
# n_storage_unconfigure
# ----------------------
# Remove storage network configuration
#
# Behaviour:
#   - Removes storage VLAN and clears host variables
#   - Can unconfigure specific storage index
#
# Parameters:
#   $1: Storage index (default: 0)
#
# Returns:
#   0 on success
#   1 on error
#===============================================================================
n_storage_unconfigure() {
  local storage_index="${1:-0}"
  
  # Get current config
  local vlan_iface=$(n_remote_host_variable "storage${storage_index}_interface")
  local ip=$(n_remote_host_variable "storage${storage_index}_ip")
  local hostname=$(hostname)
  
  # Remove DNS entries if we have the IP
  if [[ -n "$ip" ]]; then
    local storage_hostname="${hostname}-storage$((storage_index + 1))"
    dns_host_remove "$storage_hostname" 2>/dev/null
    dns_host_remove "$ip" 2>/dev/null
    n_remote_log "Removed DNS entries for $ip"
  fi
  
  # Remove VLAN interface
  if [[ -n "$vlan_iface" ]] && [[ -d "/sys/class/net/$vlan_iface" ]]; then
    n_interface_unconfigure "$vlan_iface" delete
  fi
  
  # Clear host variables
  n_remote_host_variable "storage${storage_index}_interface" ""
  n_remote_host_variable "storage${storage_index}_interface_name" ""
  n_remote_host_variable "storage${storage_index}_ip" ""
  
  n_remote_log "Storage network $storage_index unconfigured"
  return 0
}




#===============================================================================
# n_storage_select_interface
# ---------------------------
# Select and persist storage interface selection
#
# Behaviour:
#   - Checks if storage interface already configured
#   - Otherwise finds best unconfigured interface
#   - Saves selection to host config
#
# Parameters:
#   $1: Storage network index (default: 0)
#
# Returns:
#   0 on success (echoes interface name)
#   1 on error
#===============================================================================
n_storage_select_interface() {
  local storage_index="${1:-0}"
  
  # Check if already selected and persisted
  local saved_iface=$(n_remote_host_variable "storage${storage_index}_interface_name")
  if [[ -n "$saved_iface" ]]; then
    # Verify it still exists
    if [[ -d "/sys/class/net/$saved_iface" ]]; then
      echo "$saved_iface"
      return 0
    fi
    n_remote_log "WARNING: Saved interface $saved_iface no longer exists"
  fi
  
  # Find best unconfigured interface
  local selected=$(n_network_find_unconfigured_interface)
  if [[ -z "$selected" ]]; then
    n_remote_log "ERROR: No suitable interface for storage"
    return 1
  fi
  
  # Persist selection
  n_remote_host_variable "storage${storage_index}_interface_name" "$selected"
  n_remote_log "Selected interface $selected for storage network $storage_index"
  
  echo "$selected"
  return 0
}

#===============================================================================
# n_storage_auto_configure
# -------------------------
# Configure storage with proper interface selection
#
# Parameters:
#   $1: Storage network index (default: 0)
#   $2: Override interface (optional)
#
# Returns:
#   0 on success
#   1 on error
#===============================================================================
n_storage_auto_configure() {
  local storage_index="${1:-0}"
  local override_iface="${2:-}"
  
  local iface
  if [[ -n "$override_iface" ]]; then
    iface="$override_iface"
    # Save override for persistence
    n_remote_host_variable "storage${storage_index}_interface_name" "$iface"
  else
    iface=$(n_storage_select_interface "$storage_index")
    if [[ -z "$iface" ]]; then
      return 1
    fi
  fi
  
  n_remote_log "Configuring storage network $storage_index on $iface"
  
  # Bring up if needed
  local state=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)
  if [[ "$state" != "up" ]]; then
    n_remote_log "Bringing up interface $iface"
    ip link set dev "$iface" up
    sleep 2
  fi
  
  # Get allocation from IPS
  local allocation=$(n_ips_command "allocate_storage_ip" "index=$storage_index")
  if [[ -z "$allocation" ]] || [[ "$allocation" == "ERROR"* ]]; then
    n_remote_log "ERROR: Failed to get allocation: $allocation"
    return 1
  fi
  
  # Parse and configure
  local vlan_id ip netmask gateway mtu
  IFS=':' read -r vlan_id ip netmask gateway mtu <<< "$allocation"
  
  if ! n_vlan_create "$iface" "$vlan_id" "$mtu"; then
    return 1
  fi
  
  if ! n_interface_add_ip "${iface}.${vlan_id}" "$ip" "$netmask"; then
    return 1
  fi
  
  n_remote_log "Storage network ready: ${iface}.${vlan_id} = $ip"
  return 0
}


#===============================================================================
# n_storage_network_setup
# ------------------------
# Setup storage network with auto-detection
#
# Parameters:
#   $1: Physical interface (optional - auto-detects if not specified)
#   $2: Storage network index (0, 1, etc.)
#
# Returns:
#   0 on success
#   1 on error
#===============================================================================
n_storage_network_setup() {
  local phys_iface="${1:-}"
  local storage_index="${2:-0}"
  
  # Auto-detect interface if not specified
  if [[ -z "$phys_iface" ]]; then
    phys_iface=$(n_network_find_interface "up")
    if [[ -z "$phys_iface" ]]; then
      n_remote_log "ERROR: No suitable network interface found"
      return 1
    fi
    n_remote_log "Auto-detected interface: $phys_iface"
  fi
  
  
  # Request allocation from IPS (no MAC needed)
  n_remote_log "Requesting storage IP allocation from IPS"
  local allocation=$(n_ips_command "allocate_storage_ip" "index=$storage_index")
  
  if [[ -z "$allocation" ]] || [[ "$allocation" == "ERROR"* ]]; then
    n_remote_log "ERROR: Failed to get IP allocation: $allocation"
    return 1
  fi
  
  # Parse allocation
  local vlan_id ip netmask gateway mtu
  IFS=':' read -r vlan_id ip netmask gateway mtu <<< "$allocation"
  
  n_remote_log "Received allocation: VLAN $vlan_id, IP $ip"
  
  # Create VLAN interface
  if ! n_vlan_create "$phys_iface" "$vlan_id" "$mtu"; then
    return 1
  fi
  
  # Add IP address
  local vlan_iface="${phys_iface}.${vlan_id}"
  if ! n_interface_add_ip "$vlan_iface" "$ip" "$netmask"; then
    return 1
  fi
  
  # Test connectivity
  if ping -c 1 -W 2 "$gateway" &>/dev/null; then
    n_remote_log "Storage network ready - gateway $gateway reachable"
  else
    n_remote_log "Storage network configured - gateway $gateway not responding"
  fi
  
  return 0
}
