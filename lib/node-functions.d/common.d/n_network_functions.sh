
#===============================================================================
# n_network_get_interfaces
# ------------------------
# Get all physical network interfaces with detailed information
#
# Behaviour:
#   - Detects all physical ethernet interfaces
#   - Gets speed, state, driver, PCI info
#   - Works on Alpine and Rocky (different naming schemes)
#   - Excludes virtual interfaces (lo, docker, bridges, etc)
#
# Returns:
#   0 always
#   Outputs interface information to stdout
#
# Example usage:
#   n_network_get_interfaces
#===============================================================================
n_network_get_interfaces() {
  echo "Physical Network Interfaces:"
  echo "==========================="
  
  # Find all network interfaces
  for iface_path in /sys/class/net/*; do
    iface=$(basename "$iface_path")
    
    # Skip loopback
    [[ "$iface" == "lo" ]] && continue
    
    # Skip if not a physical interface (check if has device symlink)
    [[ ! -L "$iface_path/device" ]] && continue
    
    # Skip bridges, bonds, vlans
    [[ -d "$iface_path/bridge" ]] && continue
    [[ -f "$iface_path/bonding/mode" ]] && continue
    [[ -f "/proc/net/vlan/$iface" ]] && continue
    
    echo "Interface: $iface"
    
    # Get state
    local state=$(cat "$iface_path/operstate" 2>/dev/null || echo "unknown")
    echo "  State: $state"
    
    # Get MAC address
    local mac=$(cat "$iface_path/address" 2>/dev/null || echo "unknown")
    echo "  MAC: $mac"
    
    # Get MTU
    local mtu=$(cat "$iface_path/mtu" 2>/dev/null || echo "unknown")
    echo "  MTU: $mtu"
    
    # Get speed (if available and link is up)
    if [[ "$state" == "up" ]] && [[ -r "$iface_path/speed" ]]; then
      local speed=$(cat "$iface_path/speed" 2>/dev/null || echo "unknown")
      [[ "$speed" != "unknown" ]] && echo "  Speed: ${speed}Mbps"
    fi
    
    # Get driver
    if [[ -L "$iface_path/device/driver" ]]; then
      local driver=$(basename "$(readlink "$iface_path/device/driver")")
      echo "  Driver: $driver"
    fi
    
    # Get PCI device
    if [[ -L "$iface_path/device" ]]; then
      local pci=$(basename "$(readlink "$iface_path/device")")
      echo "  PCI: $pci"
    fi
    
    # Check for current IPs
    local ips=$(ip -4 addr show "$iface" 2>/dev/null | grep inet | awk '{print $2}' | tr '\n' ' ')
    [[ -n "$ips" ]] && echo "  IPv4: $ips"
    
    # Check capabilities
    if [[ -r "$iface_path/device/vendor" ]]; then
      local vendor=$(cat "$iface_path/device/vendor" 2>/dev/null)
      [[ "$vendor" == "0x8086" ]] && echo "  Vendor: Intel"
      [[ "$vendor" == "0x10ec" ]] && echo "  Vendor: Realtek"
      [[ "$vendor" == "0x14e4" ]] && echo "  Vendor: Broadcom"
    fi
    
    echo
  done
}

#===============================================================================
# n_network_find_interface
# ------------------------
# Find suitable network interface for configuration
#
# Behaviour:
#   - Returns first available ethernet interface
#   - Prefers interfaces that are up
#   - Works across distros
#
# Parameters:
#   $1: Preferred state (up/down/any) default: any
#
# Returns:
#   0 on success (echoes interface name)
#   1 if no suitable interface found
#
# Example usage:
#   iface=$(n_network_find_interface "up")
#===============================================================================
n_network_find_interface() {
  local preferred_state="${1:-any}"
  local found_up=""
  local found_down=""
  
  for iface_path in /sys/class/net/*; do
    iface=$(basename "$iface_path")
    
    # Skip non-physical interfaces
    [[ "$iface" == "lo" ]] && continue
    [[ ! -L "$iface_path/device" ]] && continue
    [[ -d "$iface_path/bridge" ]] && continue
    [[ -f "$iface_path/bonding/mode" ]] && continue
    [[ -f "/proc/net/vlan/$iface" ]] && continue
    
    local state=$(cat "$iface_path/operstate" 2>/dev/null)
    
    if [[ "$state" == "up" ]]; then
      found_up="$iface"
      [[ "$preferred_state" != "down" ]] && echo "$iface" && return 0
    else
      found_down="$iface"
      [[ "$preferred_state" == "down" ]] && echo "$iface" && return 0
    fi
  done
  
  # Return any found interface
  [[ -n "$found_up" ]] && echo "$found_up" && return 0
  [[ -n "$found_down" ]] && echo "$found_down" && return 0
  
  return 1
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
  
  # Check required arguments
  if [[ -z "$phys_iface" ]] || [[ -z "$vlan_id" ]]; then
    echo "Usage: n_vlan_create <interface> <vlan_id> [mtu]"
    return 1
  fi
  
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
  
  # Check arguments
  if [[ -z "$iface" ]] || [[ -z "$ip_addr" ]] || [[ -z "$netmask" ]]; then
    echo "Usage: n_interface_add_ip <interface> <ip> <netmask>"
    return 1
  fi
  
  # Convert netmask to CIDR
  local cidr
  if [[ "$netmask" =~ ^[0-9]+$ ]]; then
    cidr="$netmask"
  else
    cidr=$(netmask_to_cidr "$netmask")
  fi
  
  # Check if IP already exists
  if ip addr show "$iface" | grep -q "$ip_addr/$cidr"; then
    n_remote_log "IP $ip_addr/$cidr already exists on $iface"
    return 0
  fi
  
  ip addr add "${ip_addr}/${cidr}" dev "$iface"
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
