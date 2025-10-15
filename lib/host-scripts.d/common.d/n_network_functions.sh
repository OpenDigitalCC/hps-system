#===============================================================================
# n_storage_network_setup
# ------------------------
# Setup storage network using IPS allocation
#
# Behaviour:
#   - Requests IP allocation from IPS (MAC detected automatically)
#   - Configures storage VLAN interface
#   - Cross-distro compatible (Alpine/Rocky)
#
# Parameters:
#   $1: Physical interface (e.g., eth0)
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

#===============================================================================
# n_show_vlan_interfaces
# -----------------------
# Show all VLAN interfaces and their configuration
#
# Behaviour:
#   - Lists VLAN interfaces with IPs and status
#   - Cross-distro compatible (uses /sys and ip command)
#
# Returns:
#   0 always
#===============================================================================
n_show_vlan_interfaces() {
  echo "VLAN Interfaces:"
  echo "================"
  
  # Use ip command for cross-distro compatibility
  ip -d link show | grep -B1 "vlan protocol" | grep -E "^[0-9]+:" | while read line; do
    local iface=$(echo "$line" | cut -d: -f2 | tr -d ' ')
    [[ "$iface" =~ \. ]] || continue  # Skip non-VLAN interfaces
    
    echo "Interface: $iface"
    
    # Get VLAN ID (cross-distro method)
    local vlan_id=$(ip -d link show "$iface" | grep "vlan protocol" | grep -o "id [0-9]*" | cut -d' ' -f2)
    echo "  VLAN ID: $vlan_id"
    
    # Get IP addresses
    ip -4 addr show "$iface" | grep inet | awk '{print "  IP: " $2}'
    
    # Get state
    local state=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "unknown")
    echo "  State: $state"
    
    # Get MTU
    local mtu=$(cat "/sys/class/net/$iface/mtu" 2>/dev/null || echo "unknown")
    echo "  MTU: $mtu"
    echo
  done
}



#===============================================================================
# n_vlan_create
# --------------
# Create a VLAN interface on a physical interface
#
# Behaviour:
#   - Creates VLAN interface
#   - Handles MTU properly (sets physical first if needed)
#   - Works on both Alpine and Rocky Linux
#   - Idempotent - removes existing before creating
#
# Parameters:
#   $1: Physical interface (e.g., eth0)
#   $2: VLAN ID
#   $3: MTU (optional, default 1500)
#
# Returns:
#   0 on success
#   1 on error
#===============================================================================
n_vlan_create() {
  local phys_iface="$1"
  local vlan_id="$2"
  local mtu="${3:-1500}"
  
  if [[ ! -d "/sys/class/net/$phys_iface" ]]; then
    n_remote_log "ERROR: Physical interface $phys_iface not found"
    return 1
  fi
  
  local vlan_iface="${phys_iface}.${vlan_id}"
  
  # Remove if exists
  if [[ -d "/sys/class/net/$vlan_iface" ]]; then
    ip link delete "$vlan_iface" 2>/dev/null
    sleep 1
  fi
  
  # Check physical interface MTU
  local phys_mtu=$(cat "/sys/class/net/$phys_iface/mtu")
  
  # If requested MTU > physical MTU, update physical first
  if [[ "$mtu" -gt "$phys_mtu" ]]; then
    n_remote_log "Setting $phys_iface MTU to $mtu"
    if ! ip link set dev "$phys_iface" mtu "$mtu"; then
      n_remote_log "WARNING: Could not set MTU $mtu on $phys_iface"
      # Continue with current physical MTU
      mtu="$phys_mtu"
    fi
  fi
  
  # Create VLAN
  if ! ip link add link "$phys_iface" name "$vlan_iface" type vlan id "$vlan_id"; then
    n_remote_log "ERROR: Failed to create VLAN $vlan_id on $phys_iface"
    return 1
  fi
  
  # Set MTU on VLAN
  if ! ip link set dev "$vlan_iface" mtu "$mtu"; then
    n_remote_log "WARNING: Could not set MTU $mtu on $vlan_iface"
  fi
  
  # Bring up
  ip link set dev "$vlan_iface" up
  
  n_remote_log "Created VLAN interface $vlan_iface with MTU $mtu"
  return 0
}


#===============================================================================
# n_interface_add_ip
# ------------------
# Add IP address to an interface
#===============================================================================
n_interface_add_ip() {
  local iface="$1"
  local ip_addr="$2"
  local netmask="$3"
  
  # Convert netmask to CIDR if needed
  local cidr
  if [[ "$netmask" =~ ^[0-9]+$ ]]; then
    cidr="$netmask"
  else
    cidr=$(netmask_to_cidr "$netmask")
  fi
  
  ip addr add "${ip_addr}/${cidr}" dev "$iface"
  return $?
}

#===============================================================================
# n_vlan_status
# -------------
# Show status of a VLAN interface
#
# Behaviour:
#   - Shows VLAN ID, IP, state, MTU
#   - Works on both Alpine and Rocky
#
# Parameters:
#   $1: VLAN interface name (e.g., eth0.31)
#
# Returns:
#   0 if interface exists
#   1 if not found
#===============================================================================
n_vlan_status() {
  local vlan_iface="$1"
  
  if [[ ! -d "/sys/class/net/$vlan_iface" ]]; then
    echo "Interface $vlan_iface not found"
    return 1
  fi
  
  # Get VLAN info
  if [[ -f "/proc/net/vlan/$vlan_iface" ]]; then
    local vlan_id=$(grep "VID:" "/proc/net/vlan/$vlan_iface" | awk '{print $3}')
    echo "VLAN ID: $vlan_id"
  fi
  
  # Get IPs
  ip -4 addr show "$vlan_iface" | grep inet | awk '{print "IP: " $2}'
  
  # Get state and MTU
  echo "State: $(cat /sys/class/net/$vlan_iface/operstate)"
  echo "MTU: $(cat /sys/class/net/$vlan_iface/mtu)"
  
  return 0
}
