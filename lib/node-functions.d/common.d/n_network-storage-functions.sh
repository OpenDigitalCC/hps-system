


#===============================================================================
# ips_allocate_storage_ip
# ------------------------
# Allocate storage IP address for requesting host
#
# Behaviour:
#   - Validates arguments
#   - Checks if storage network exists
#   - Finds next available IP
#   - Stores allocation in host_config
#
# Parameters:
#   $1: Storage network index (0, 1, etc.)
#   $2: Source MAC (provided by n_ips_command framework)
#
# Returns:
#   Echoes "vlan_id:ip:netmask:gateway:mtu" on success
#   Echoes "ERROR: message" on failure
#===============================================================================
ips_allocate_storage_ip() {
  local storage_index="$1"
  local source_mac="$2"
  
  # Validate arguments
  if [[ -z "$storage_index" ]] || [[ -z "$source_mac" ]]; then
    echo "ERROR: Missing arguments. Usage: ips_allocate_storage_ip <index> <mac>"
    return 1
  fi
  
  source_mac=$(normalise_mac "$source_mac")
  if [[ $? -ne 0 ]]; then
    echo "ERROR: Invalid MAC address: $2"
    return 1
  fi
  
  # Check if storage network is configured
  local base_vlan=$(cluster_config "get" "network_storage_base_vlan")
  local storage_count=$(cluster_config "get" "network_storage_count")
  
  if [[ -z "$base_vlan" ]] || [[ -z "$storage_count" ]]; then
    echo "ERROR: Storage network not initialized"
    return 1
  fi
  
  # Validate storage index
  if [[ "$storage_index" -ge "$storage_count" ]]; then
    echo "ERROR: Storage network index $storage_index not configured (only 0-$((storage_count-1)) available)"
    return 1
  fi
  
  # Calculate VLAN ID
  local vlan_id=$((base_vlan + storage_index))
  
  # Check if this VLAN is configured
  local subnet=$(cluster_config "get" "network_storage_vlan${vlan_id}_subnet")
  if [[ -z "$subnet" ]]; then
    echo "ERROR: VLAN $vlan_id not configured"
    return 1
  fi
  
  # Check if already allocated
  local existing_ip=$(host_config "$source_mac" "get" "storage${storage_index}_ip")
  if [[ -n "$existing_ip" ]]; then
    # Return existing allocation
    local netmask=$(cluster_config "get" "network_storage_vlan${vlan_id}_netmask")
    local gateway=$(cluster_config "get" "network_storage_vlan${vlan_id}_gateway")
    local mtu=$(cluster_config "get" "network_storage_mtu")
    
    hps_log "info" "Returning existing storage allocation for $source_mac: $existing_ip"
    echo "${vlan_id}:${existing_ip}:${netmask}:${gateway}:${mtu}"
    return 0
  fi
  
  # Get network configuration
  local netmask=$(cluster_config "get" "network_storage_vlan${vlan_id}_netmask")
  local gateway=$(cluster_config "get" "network_storage_vlan${vlan_id}_gateway")
  local mtu=$(cluster_config "get" "network_storage_mtu")
  
    
  # Extract network prefix
  local ip_prefix=$(network_subnet_to_prefix "$subnet")
  if [[ $? -ne 0 ]] || [[ -z "$ip_prefix" ]]; then
    echo "ERROR: Failed to parse subnet $subnet"
    return 1
  fi
  
  # Build new IP
  new_ip="${ip_prefix}.${ip_offset}"

  
  # Find used IPs - fixed to properly scan all hosts
  local used_ips=()
  local host_dir="/srv/hps-config/clusters/$(readlink /srv/hps-config/clusters/active-cluster)/hosts"
  
  if [[ -d "$host_dir" ]]; then
    for host_file in "$host_dir"/*; do
      [[ -f "$host_file" ]] || continue
      local stored_ip=$(grep "^storage${storage_index}_ip=" "$host_file" 2>/dev/null | cut -d= -f2-)
      [[ -n "$stored_ip" ]] && used_ips+=("$stored_ip")
    done
  fi
  
  # Find next available IP (starting at .100)
  local ip_offset=100
  local new_ip
  while [[ $ip_offset -lt 250 ]]; do
    new_ip="${ip_prefix}.${ip_offset}"
    
    # Check if IP is already used
    local ip_used=0
    for used in "${used_ips[@]}"; do
      if [[ "$used" == "$new_ip" ]]; then
        ip_used=1
        break
      fi
    done
    
    if [[ $ip_used -eq 0 ]]; then
      # Found available IP
      break
    fi
    
    ((ip_offset++))
  done
  
  if [[ $ip_offset -ge 250 ]]; then
    echo "ERROR: No available IPs in storage network $vlan_id"
    return 1
  fi
  
  # Allocate and store
  host_config "$source_mac" "set" "storage${storage_index}_vlan" "$vlan_id"
  host_config "$source_mac" "set" "storage${storage_index}_ip" "$new_ip"
  
  # Get hostname from host config
  local hostname=$(host_config "$source_mac" "get" "hostname")
  if [[ -z "$hostname" ]]; then
    # Try to derive from MAC
    hostname="host-${source_mac//:/-}"
  fi

  # Get cluster domain instead of storage-specific domain
  local domain=$(cluster_config "get" "DNS_DOMAIN")
  domain=${domain:-"local"}
    

  # Register in DNS
  # Storage hostname format: hostname-storageN
  local storage_hostname="${hostname}-storage$((storage_index + 1))"
  dns_host_add "$new_ip" "$storage_hostname" "$domain"
  
  
  # Also add a CNAME-style entry for the base hostname on storage network
  dns_host_add "$new_ip" "$hostname" "$domain" "${hostname}-vlan${vlan_id}"
  
  hps_log "info" "Allocated $new_ip to $source_mac, DNS: ${storage_hostname}.${domain}"
  
  echo "${vlan_id}:${new_ip}:${netmask}:${gateway}:${mtu}"
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
