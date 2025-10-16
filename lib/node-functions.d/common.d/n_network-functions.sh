#===============================================================================
# n_network_find_unconfigured_interface
# --------------------------------------
# Find physical interface without IP configuration
#
# Behaviour:
#   - Prioritizes interfaces with no IP addresses
#   - Falls back to interface with fewest IPs
#   - Excludes VLANs, bridges, bonds
#   - Prefers faster interfaces when multiple match
#
# Returns:
#   0 on success (echoes interface name)
#   1 if no interface found
#===============================================================================
n_network_find_unconfigured_interface() {
  local best_iface=""
  local best_ip_count=999
  local best_speed=0
  
  n_network_get_interfaces | while IFS=: read -r iface state mac mtu speed driver ips; do
    # Count IPs (empty = 0, otherwise count commas + 1)
    local ip_count=0
    if [[ -n "$ips" ]]; then
      ip_count=$(echo "$ips" | tr -cd ',' | wc -c)
      ip_count=$((ip_count + 1))
    fi
    
    # Convert empty speed to 0
    speed=${speed:-0}
    
    # Select based on: fewer IPs first, then faster speed
    if [[ $ip_count -lt $best_ip_count ]]; then
      best_iface="$iface"
      best_ip_count=$ip_count
      best_speed=$speed
    elif [[ $ip_count -eq $best_ip_count ]] && [[ $speed -gt $best_speed ]]; then
      best_iface="$iface"
      best_speed=$speed
    fi
    
    # If we found one with no IPs and decent speed, we could break early
    if [[ $ip_count -eq 0 ]] && [[ $speed -ge 1000 ]]; then
      echo "$iface"
      return 0
    fi
  done
  
  [[ -n "$best_iface" ]] && echo "$best_iface"
}


#===============================================================================
# n_interface_unconfigure
# ------------------------
# Remove network configuration from an interface
#
# Behaviour:
#   - Detects DHCP addresses and warns
#   - Only removes static addresses
#   - Deletes VLAN interfaces
#
# Parameters:
#   $1: Interface name
#   $2: Action (flush|delete|down)
#   $3: Force flag (optional, "force" to override DHCP check)
#
# Returns:
#   0 on success
#   1 on error
#===============================================================================
n_interface_unconfigure() {
  local iface="$1"
  local action="${2:-flush}"
  local force="${3:-}"
  
  if [[ -z "$iface" ]]; then
    echo "Usage: n_interface_unconfigure <interface> [flush|delete|down] [force]"
    return 1
  fi
  
  if [[ ! -d "/sys/class/net/$iface" ]]; then
    n_remote_log "ERROR: Interface $iface not found"
    return 1
  fi
  
  case "$action" in
    flush)
      # Check for DHCP assignment
      if ip -4 addr show "$iface" 2>/dev/null | grep -q "dynamic"; then
        if [[ "$force" != "force" ]]; then
          n_remote_log "WARNING: $iface has DHCP-assigned address. Use 'force' to flush anyway."
          return 1
        fi
      fi
      
      n_remote_log "Flushing IPs from $iface"
      ip addr flush dev "$iface"
      ;;
      
    delete)
      if [[ "$iface" =~ \. ]]; then
        n_remote_log "Deleting VLAN interface $iface"
        ip link delete "$iface"
      else
        n_remote_log "ERROR: Cannot delete physical interface $iface"
        return 1
      fi
      ;;
      
    down)
      n_remote_log "Bringing down $iface"
      ip link set dev "$iface" down
      ;;
      
    *)
      echo "Unknown action: $action (use flush|delete|down)"
      return 1
      ;;
  esac
  
  return 0
}


#===============================================================================
# n_network_find_best_interface
# ------------------------------
# Find best interface based on criteria (Alpine/Rocky compatible)
#
# Parameters:
#   $1: Minimum speed in Mbps (optional, default: 0)
#   $2: Required state (up/down/any) (optional, default: up)
#
# Returns:
#   0 on success (echoes interface name)
#   1 if no suitable interface found
#===============================================================================
n_network_find_best_interface() {
  local min_speed="${1:-0}"
  local req_state="${2:-up}"
  
  local best_iface=""
  local best_speed=0
  
  # Process line by line without subshell
  n_network_get_interfaces | {
    while IFS=: read -r iface state mac mtu speed driver ips; do
      # Skip if state doesn't match requirement
      if [[ "$req_state" != "any" ]] && [[ "$state" != "$req_state" ]]; then
        continue
      fi
      
      # Convert empty speed to 0
      speed=${speed:-0}
      
      # Check minimum speed requirement
      [[ "$speed" -lt "$min_speed" ]] && continue
      
      # Track fastest interface
      if [[ "$speed" -gt "$best_speed" ]]; then
        best_speed="$speed"
        best_iface="$iface"
      fi
    done
    
    # Output result without newline
    [[ -n "$best_iface" ]] && printf "%s" "$best_iface"
  }
}

#===============================================================================
# n_network_get_interfaces
# ------------------------
# Get all physical network interfaces with detailed information
#
# Behaviour:
#   - Outputs: iface:state:mac:mtu:speed:driver:ips:ip_type
#   - ip_type shows static/dhcp/none
#   - Lists ALL physical interfaces
#
# Returns:
#   0 always
#
# Example output:
#   eth0:up:52:54:00:23:45:ee:1500:1000:virtio_net:10.99.1.10/24:static
#   eth1:down:52:54:00:23:45:ef:1500::e1000::none
#   enp8s0:up:52:54:00:d3:27:c8:1500:1000:e1000e:10.99.1.52/24:dhcp
#===============================================================================
n_network_get_interfaces() {
  for iface_path in /sys/class/net/*; do
    iface=$(basename "$iface_path")
    
    # Skip non-physical interfaces
    [[ "$iface" == "lo" ]] && continue
    [[ ! -L "$iface_path/device" ]] && continue
    [[ -d "$iface_path/bridge" ]] && continue
    [[ -f "$iface_path/bonding/mode" ]] && continue
    [[ -f "/proc/net/vlan/$iface" ]] && continue
    
    # Get basic attributes
    local state=$(cat "$iface_path/operstate" 2>/dev/null || echo "unknown")
    local mac=$(cat "$iface_path/address" 2>/dev/null || echo "")
    local mtu=$(cat "$iface_path/mtu" 2>/dev/null || echo "1500")
    
    # Get speed
    local speed=""
    if [[ -r "$iface_path/speed" ]]; then
      speed=$(cat "$iface_path/speed" 2>/dev/null || echo "")
      [[ "$speed" == "-1" ]] || [[ "$speed" == "65535" ]] && speed=""
    fi
    
    # Get driver
    local driver=""
    if [[ -L "$iface_path/device/driver" ]]; then
      driver=$(basename "$(readlink "$iface_path/device/driver")")
    fi
    
    # Get IPs and determine type
    local ips=$(ip -4 addr show "$iface" 2>/dev/null | grep inet | awk '{print $2}' | tr '\n' ',')
    ips=${ips%,}
    
    # Determine IP assignment type
    local ip_type="none"
    if [[ -n "$ips" ]]; then
      # Check for dynamic flag (DHCP)
      if ip -4 addr show "$iface" | grep -q "dynamic"; then
        ip_type="dhcp"
      else
        ip_type="static"
      fi
    fi
    
    echo "${iface}:${state}:${mac}:${mtu}:${speed}:${driver}:${ips}:${ip_type}"
  done
}


#===============================================================================
# n_network_show_vlans
# ---------------------
# Show all VLAN interfaces with their configuration
#
# Returns:
#   0 always
#===============================================================================
n_network_show_vlans() {
  for iface in /sys/class/net/*.*; do
    [[ -d "$iface" ]] || continue
    
    local name=$(basename "$iface")
    local state=$(cat "$iface/operstate" 2>/dev/null)
    local mtu=$(cat "$iface/mtu" 2>/dev/null)
    
    # Get VLAN ID from interface name
    local vlan_id="${name##*.}"
    
    # Get IPs
    local ips=$(ip -4 addr show "$name" 2>/dev/null | grep inet | awk '{print $2}' | tr '\n' ',')
    ips=${ips%,}
    
    echo "${name}:${state}:${ips}:${mtu}:${vlan_id}"
  done
}


#===============================================================================
# n_network_find_best_interface
# ------------------------------
# Find best interface based on criteria
#
# Behaviour:
#   - Finds fastest available interface
#   - Prefers up interfaces over down
#   - Can filter by minimum speed
#
# Parameters:
#   $1: Minimum speed in Mbps (optional, default: 0)
#   $2: Required state (up/down/any) (optional, default: up)
#
# Returns:
#   0 on success (echoes interface name)
#   1 if no suitable interface found
#
# Example usage:
#   iface=$(n_network_find_best_interface 10000)  # Find 10G+ interface
#===============================================================================
n_network_find_best_interface() {
  local min_speed="${1:-0}"
  local req_state="${2:-up}"
  
  local best_iface=""
  local best_speed=0
  
  while IFS=: read -r iface state mac mtu speed driver ips; do
    # Skip if state doesn't match requirement
    if [[ "$req_state" != "any" ]] && [[ "$state" != "$req_state" ]]; then
      continue
    fi
    
    # Convert empty speed to 0
    speed=${speed:-0}
    
    # Check minimum speed requirement
    [[ "$speed" -lt "$min_speed" ]] && continue
    
    # Track fastest interface
    if [[ "$speed" -gt "$best_speed" ]]; then
      best_speed="$speed"
      best_iface="$iface"
    elif [[ "$speed" -eq "$best_speed" ]] && [[ -z "$best_iface" ]]; then
      # Same speed but we had none before
      best_iface="$iface"
    fi
  done < <(n_network_get_interfaces)
  
  [[ -n "$best_iface" ]] && echo "$best_iface" && return 0
  return 1
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
