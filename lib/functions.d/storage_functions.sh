__guard_source || return



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

