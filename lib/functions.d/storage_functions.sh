__guard_source || return



#===============================================================================
# storage_allocate_network
# ------------------------
# Allocate a storage network to a storage host
#
# Behaviour:
#   - Finds first available storage network
#   - Marks network as allocated in cluster_config
#   - Records host MAC address for the allocation
#   - Assigns IP address from the subnet
#
# Parameters:
#   $1: MAC address of storage host (normalized)
#   $2: IP offset within subnet (optional, default: 100)
#
# Returns:
#   0 on success (echoes "vlan:ip:gateway:netmask:domain")
#   1 if no networks available or error
#===============================================================================
storage_allocate_network() {
    local mac_address="$1"
    local ip_offset="${2:-100}"
    
    # Validate MAC address
    mac_address=$(normalise_mac "$mac_address")
    if [[ $? -ne 0 ]]; then
        hps_log "error" "Invalid MAC address: $1"
        return 1
    fi
    
    # Check if host already has allocation
    local existing_vlan=$(storage_get_host_vlan "$mac_address")
    if [[ -n "$existing_vlan" ]]; then
        hps_log "warn" "Host $mac_address already allocated to VLAN $existing_vlan"
        return 1
    fi
    
    # Get storage network configuration
    local storage_count=$(cluster_config "get" "network_storage_count")
    local base_vlan=$(cluster_config "get" "network_storage_base_vlan")
    
    if [[ -z "$storage_count" ]] || [[ -z "$base_vlan" ]]; then
        hps_log "error" "Storage network not initialized"
        return 1
    fi
    
    # Find first available network
    local i
    for ((i=0; i<storage_count; i++)); do
        local vlan=$((base_vlan + i))
        local allocated=$(cluster_config "get" "network_storage_vlan${vlan}_allocated")
        
        if [[ "$allocated" == "false" ]]; then
            # Get network configuration
            local subnet=$(cluster_config "get" "network_storage_vlan${vlan}_subnet")
            local gateway=$(cluster_config "get" "network_storage_vlan${vlan}_gateway")
            local netmask=$(cluster_config "get" "network_storage_vlan${vlan}_netmask")
            local domain=$(cluster_config "get" "network_storage_vlan${vlan}_domain")
            
            # Calculate host IP
            local network_base="${subnet%/*}"
            local network_prefix="${network_base%.*}"
            local host_ip="${network_prefix}.${ip_offset}"
            
            # Validate IP is within subnet
            if ! validate_ip_address "$host_ip"; then
                hps_log "error" "Invalid IP address calculated: $host_ip"
                continue
            fi
            
            # Allocate the network
            cluster_config "set" "network_storage_vlan${vlan}_allocated" "true"
            cluster_config "set" "network_storage_vlan${vlan}_host_mac" "$mac_address"
            cluster_config "set" "network_storage_vlan${vlan}_host_ip" "$host_ip"
            
            # Record in host config
            host_config "$mac_address" "set" "storage_vlan" "$vlan"
            host_config "$mac_address" "set" "storage_ip" "$host_ip"
            host_config "$mac_address" "set" "storage_gateway" "$gateway"
            host_config "$mac_address" "set" "storage_netmask" "$netmask"
            host_config "$mac_address" "set" "storage_domain" "$domain"
            
            hps_log "info" "Allocated storage network VLAN $vlan to host $mac_address ($host_ip)"
            
            # Return configuration
            echo "${vlan}:${host_ip}:${gateway}:${netmask}:${domain}"
            return 0
        fi
    done
    
    hps_log "error" "No available storage networks"
    return 1
}

#===============================================================================
# storage_get_host_vlan
# ---------------------
# Get storage VLAN assigned to a host
#
# Behaviour:
#   - Looks up storage VLAN allocation for given MAC
#   - Returns VLAN ID if found
#
# Parameters:
#   $1: MAC address of host
#
# Returns:
#   0 on success (echoes VLAN ID)
#   1 if not found
#===============================================================================
storage_get_host_vlan() {
    local mac_address="$1"
    
    mac_address=$(normalise_mac "$mac_address")
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    # Check host config first
    local vlan=$(host_config "$mac_address" "get" "storage_vlan")
    if [[ -n "$vlan" ]]; then
        echo "$vlan"
        return 0
    fi
    
    return 1
}



###################

detect_storage_devices() {
  local dev
  local output=""
  local devs
  devs=($(get_all_block_devices))

  for name in "${devs[@]}"; do
    dev="/dev/$name"
    output+="device=$dev\n"
    output+="model=$(get_device_model "$dev")\n"
    output+="vendor=$(get_device_vendor "$dev")\n"
    output+="serial=$(get_device_serial "$dev")\n"
    output+="type=$(get_device_bus_type "$dev")\n"
    output+="bus=$(get_device_type "$dev")\n"
    output+="size=$(get_device_size "$dev")\n"
    output+="usage=$(get_device_usage "$dev")\n"
    output+="speed=$(get_device_speed "$dev")\n"
    output+="---\n"
  done

  echo -e "$output"
}


get_all_block_devices() {
  local dev
  for dev in /sys/block/*; do
    devname=$(basename "$dev")
    # Only include devices with ID_TYPE=disk (skip loop, md, dm, etc.)
    if [[ "$(get_device_type "/dev/$devname")" == "disk" ]]; then
      echo "$devname"
    fi
  done
}

get_device_model() {
  local dev="$1"
  cat "/sys/block/$(basename "$dev")/device/model" 2>/dev/null | tr -d ' ' || echo "unknown"
}

get_device_vendor() {
  local dev="$1"
  cat "/sys/block/$(basename "$dev")/device/vendor" 2>/dev/null | tr -d ' ' || echo "unknown"
}

get_device_serial() {
  local dev="$1"
  udevadm info --query=property --name="$dev" 2>/dev/null | grep '^ID_SERIAL=' | cut -d= -f2 || echo "unknown"
}

get_device_rotational() {
  local dev="$1"
  cat "/sys/block/$(basename "$dev")/queue/rotational" 2>/dev/null || echo "1"
}

get_device_type() {
  local dev="$1"
  udevadm info --query=property --name="$dev" 2>/dev/null | grep '^ID_TYPE=' | cut -d= -f2 || echo "disk"
}

get_device_bus_type() {
  local dev="$1"
  case "$dev" in
    /dev/nvme*) echo "NVMe" ;;
    *) if [[ "$(get_device_rotational "$dev")" == "0" ]]; then echo "SSD"; else echo "HDD"; fi ;;
  esac
}

get_device_size() {
  local dev="$1"
  lsblk -d -n -o SIZE "$dev" || echo "unknown"
}

get_device_usage() {
  local dev="$1"
  local usage
  usage=$(lsblk -n -o MOUNTPOINTS "$dev" | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
  echo "${usage:-unused}"
}

get_device_speed() {
  local dev="$1"
  dd if="$dev" of=/dev/null bs=1M count=64 iflag=direct status=none 2>&1 | grep -o '[0-9.]\+ MB/s' || echo "N/A"
}

