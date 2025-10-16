__guard_source || return




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
# storage_register_dns
# --------------------
# Register all storage network IPs in DNS (simplified version)
#
# Behaviour:
#   - Registers storage IPs with hostname-storageN format
#   - No subdomain needed since hostname includes storage identifier
#===============================================================================
storage_register_dns() {
  # Get all hostnames
  local hostnames=$(get_cluster_host_hostnames)
  if [[ -z "$hostnames" ]]; then
    hps_log "warn" "No hosts found to register"
    return 1
  fi
  
  # Get storage network count
  local storage_count=$(cluster_config "get" "network_storage_count")
  if [[ -z "$storage_count" ]]; then
    hps_log "error" "Storage networks not configured"
    return 1
  fi
  
  # Get cluster domain
  local cluster_domain=$(cluster_config "get" "DNS_DOMAIN")
  cluster_domain=${cluster_domain:-"local"}
  
  # Process each hostname
  echo "$hostnames" | while read -r hostname; do
    [[ -z "$hostname" ]] && continue
    
    # Use generic lookup function
    local mac=$(get_host_mac_by_keyvalue "hostname" "$hostname")
    if [[ -z "$mac" ]]; then
      hps_log "warn" "No MAC found for hostname $hostname"
      continue
    fi
    
    # Check each storage network
    local i
    for ((i=0; i<storage_count; i++)); do
      local ip=$(host_config "$mac" "get" "storage${i}_ip")
      local vlan=$(host_config "$mac" "get" "storage${i}_vlan")
      
      if [[ -n "$ip" ]] && [[ -n "$vlan" ]]; then
        local storage_hostname="${hostname,,}-storage$((i + 1))"
        
        # Register with cluster domain, not storage-specific subdomain
        if ! dns_host_get "$storage_hostname" >/dev/null 2>&1; then
          dns_host_add "$ip" "$storage_hostname" "$cluster_domain"
          hps_log "info" "Registered DNS: ${storage_hostname}.${cluster_domain} -> $ip"
        else
          hps_log "debug" "DNS already registered: ${storage_hostname}.${cluster_domain}"
        fi
      fi
    done
  done
  
  return 0
}



#===============================================================================
# get_network_interfaces
# ----------------------
# Get list of network interfaces with IP and gateway information
#
# Behaviour:
#   - Lists all interfaces except loopback
#   - Collects IP, CIDR, and gateway for each
#   - Outputs tab-delimited: interface|ip_cidr|gateway
#
# Returns:
#   0 on success
#   1 if no interfaces found
#===============================================================================
get_network_interfaces() {
  local found=0
  
  while IFS= read -r line; do
    local iface=$(echo "$line" | awk -F': ' '{print $2}')
    [[ "$iface" == "lo" ]] && continue
    
    local ip_cidr=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | head -n1)
    local gateway=$(ip route 2>/dev/null | awk "/^default/ && /dev $iface/ {print \$3}" | head -n1)
    
    # Output interface info
    echo "${iface}|${ip_cidr}|${gateway}"
    found=1
  done < <(ip -o link show 2>/dev/null)
  
  [[ $found -eq 1 ]] && return 0 || return 1
}

#===============================================================================
# get_interface_network_info
# --------------------------
# Get detailed network information for an interface
#
# Parameters:
#   $1 - Interface name
#
# Behaviour:
#   - Validates interface has IPv4 address
#   - Calculates network using ipcalc
#   - Outputs: interface|ip|cidr|ip_cidr|network_cidr
#
# Returns:
#   0 on success
#   1 on error (no IP, ipcalc missing, etc)
#===============================================================================
get_interface_network_info() {
  local iface="$1"
  
  [[ -z "$iface" ]] && return 1
  
  # Get IP and CIDR
  local ip_cidr=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | head -n1)
  if [[ -z "$ip_cidr" ]]; then
    hps_log "error" "Interface $iface has no IPv4 address"
    return 1
  fi
  
  local ipaddr=$(echo "$ip_cidr" | cut -d/ -f1)
  local cidr=$(echo "$ip_cidr" | cut -d/ -f2)
  
  # Check for ipcalc
  if ! command -v ipcalc &>/dev/null; then
    hps_log "error" "ipcalc is required but not installed"
    return 1
  fi
  
  # Calculate network
  local network=$(ipcalc "$ip_cidr" 2>/dev/null | awk '/^Network:/ {print $2}')
  if [[ -z "$network" ]]; then
    hps_log "error" "Failed to calculate network for $ip_cidr"
    return 1
  fi
  
  echo "${iface}|${ipaddr}|${cidr}|${ip_cidr}|${network}"
  return 0
}

#===============================================================================
# network_calculate_subnet
# ------------------------
# Calculate subnet address based on base, index, and CIDR
#
# Behaviour:
#   - Calculates subnet address for indexed networks
#   - Supports /24 networks (increments 3rd octet)
#   - Supports /16 networks (uses base as-is)
#   - Returns full subnet in CIDR notation
#
# Parameters:
#   $1: Base subnet (e.g., "10.31")
#   $2: Index (0-based)
#   $3: CIDR prefix length (16-28)
#
# Returns:
#   0 on success (echoes subnet)
#   1 on error
#===============================================================================
network_calculate_subnet() {
    local base="$1"
    local index="$2"
    local cidr="$3"
    
    # Validate inputs
    if [[ -z "$base" ]] || [[ -z "$index" ]] || [[ -z "$cidr" ]]; then
        return 1
    fi
    
    # Extract octets
    local octet1 octet2
    IFS='.' read -r octet1 octet2 <<< "$base"
    
    case "$cidr" in
        24)
            # /24 - increment third octet
            echo "${octet1}.${octet2}.$((index)).0/${cidr}"
            ;;
        16)
            # /16 - use base as-is for all indexes
            echo "${base}.0.0/${cidr}"
            ;;
        25|26|27|28)
            # Smaller subnets - calculate based on available IPs
            local hosts_per_subnet=$((2**(32-cidr)))
            local offset=$((index * hosts_per_subnet))
            # For now, simple third octet calculation
            echo "${octet1}.${octet2}.$((offset/256)).$((offset%256))/${cidr}"
            ;;
        *)
            hps_log "error" "Unsupported CIDR: /${cidr}"
            return 1
            ;;
    esac
    
    return 0
}


#:name: ip_to_int
#:group: network
#:synopsis: Convert IP address to integer representation.
#:usage: ip_to_int <ip_address>
#:description:
#  Converts a dotted-quad IP address to its integer representation.
#  Used for IP address arithmetic and range calculations.
#:parameters:
#  ip_address - IP address in dotted-quad format (e.g., 192.168.1.1)
#:returns:
#  0 on success (outputs integer to stdout)
#  1 if IP address format is invalid
ip_to_int() {
  local ip="$1"
  
  # Validate IP address format
  if ! validate_ip_address "$ip"; then
    hps_log error "Invalid IP address format: $ip"
    return 1
  fi
  
  IFS=. read -r o1 o2 o3 o4 <<< "$ip"
  echo $(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
  return 0
}

#:name: int_to_ip
#:group: network
#:synopsis: Convert integer to IP address representation.
#:usage: int_to_ip <integer>
#:description:
#  Converts an integer to its dotted-quad IP address representation.
#  Used for IP address arithmetic and range calculations.
#:parameters:
#  integer - Integer representation of an IP address
#:returns:
#  0 on success (outputs IP address to stdout)
int_to_ip() {
  local ip_int="$1"
  echo "$(( (ip_int >> 24) & 255 )).$(( (ip_int >> 16) & 255 )).$(( (ip_int >> 8) & 255 )).$(( ip_int & 255 ))"
  return 0
}
#===============================================================================
# network_subnet_to_network
# --------------------------
# Extract network address from CIDR subnet
#
# Behaviour:
#   - Removes CIDR suffix from subnet
#   - Returns network address
#
# Parameters:
#   $1: Subnet in CIDR format (e.g., 10.31.1.0/24)
#
# Returns:
#   0 on success (echoes network address)
#   1 on error
#
# Example:
#   network=$(network_subnet_to_network "10.31.1.0/24")  # Returns: 10.31.1.0
#===============================================================================
network_subnet_to_network() {
  local subnet="$1"
  
  if [[ -z "$subnet" ]]; then
    return 1
  fi
  
  # Remove CIDR suffix
  local network="${subnet%/*}"
  
  if [[ -z "$network" ]]; then
    return 1
  fi
  
  echo "$network"
  return 0
}

#===============================================================================
# network_ip_to_prefix
# --------------------
# Extract network prefix (first 3 octets) from IP address
#
# Behaviour:
#   - Removes last octet from IP
#   - Returns prefix (first 3 octets)
#
# Parameters:
#   $1: IP address (e.g., 10.31.1.0)
#
# Returns:
#   0 on success (echoes prefix)
#   1 on error
#
# Example:
#   prefix=$(network_ip_to_prefix "10.31.1.0")  # Returns: 10.31.1
#===============================================================================
network_ip_to_prefix() {
  local ip="$1"
  
  if [[ -z "$ip" ]]; then
    return 1
  fi
  
  # Remove last octet
  local prefix="${ip%.*}"
  
  if [[ -z "$prefix" ]]; then
    return 1
  fi
  
  echo "$prefix"
  return 0
}

#===============================================================================
# network_subnet_to_prefix
# ------------------------
# Extract network prefix from CIDR subnet (combines above functions)
#
# Behaviour:
#   - Removes CIDR suffix and last octet
#   - Returns network prefix
#
# Parameters:
#   $1: Subnet in CIDR format (e.g., 10.31.1.0/24)
#
# Returns:
#   0 on success (echoes prefix)
#   1 on error
#
# Example:
#   prefix=$(network_subnet_to_prefix "10.31.1.0/24")  # Returns: 10.31.1
#===============================================================================
network_subnet_to_prefix() {
  local subnet="$1"
  
  # Get network address
  local network=$(network_subnet_to_network "$subnet")
  if [[ $? -ne 0 ]] || [[ -z "$network" ]]; then
    return 1
  fi
  
  # Get prefix
  local prefix=$(network_ip_to_prefix "$network")
  if [[ $? -ne 0 ]] || [[ -z "$prefix" ]]; then
    return 1
  fi
  
  echo "$prefix"
  return 0
}

#===============================================================================
# netmask_to_cidr
# ----------------
# Convert netmask notation to CIDR prefix length
#
# Behaviour:
#   - Converts dotted decimal netmask to CIDR bits
#   - Handles common netmasks from /16 to /32
#   - Returns error for invalid netmasks
#
# Parameters:
#   $1: Netmask in dotted decimal notation (e.g., 255.255.255.0)
#
# Returns:
#   0 on success (echoes CIDR prefix length)
#   1 on invalid netmask
#
# Example usage:
#   cidr=$(netmask_to_cidr "255.255.255.0")
#   echo $cidr  # outputs: 24
#===============================================================================
netmask_to_cidr() {
    local netmask="$1"
    
    case "$netmask" in
        255.255.255.255) echo "32" ;;
        255.255.255.254) echo "31" ;;
        255.255.255.252) echo "30" ;;
        255.255.255.248) echo "29" ;;
        255.255.255.240) echo "28" ;;
        255.255.255.224) echo "27" ;;
        255.255.255.192) echo "26" ;;
        255.255.255.128) echo "25" ;;
        255.255.255.0)   echo "24" ;;
        255.255.254.0)   echo "23" ;;
        255.255.252.0)   echo "22" ;;
        255.255.248.0)   echo "21" ;;
        255.255.240.0)   echo "20" ;;
        255.255.224.0)   echo "19" ;;
        255.255.192.0)   echo "18" ;;
        255.255.128.0)   echo "17" ;;
        255.255.0.0)     echo "16" ;;
        255.254.0.0)     echo "15" ;;
        255.252.0.0)     echo "14" ;;
        255.248.0.0)     echo "13" ;;
        255.240.0.0)     echo "12" ;;
        255.224.0.0)     echo "11" ;;
        255.192.0.0)     echo "10" ;;
        255.128.0.0)     echo "9" ;;
        255.0.0.0)       echo "8" ;;
        *)
            return 1
            ;;
    esac
    
    return 0
}

#===============================================================================
# cidr_to_netmask
# ---------------
# Convert CIDR prefix length to netmask, accepting either prefix or full CIDR notation.
#
# Usage: 
#   cidr_to_netmask <prefix_length>
#   cidr_to_netmask <ip_address/prefix_length>
#
# Examples: 
#   cidr_to_netmask 24              # Returns 255.255.255.0
#   cidr_to_netmask 10.99.1.0/24    # Returns 255.255.255.0
#
# Parameters:
#   cidr - Either a prefix length (0-32) or IP address with CIDR notation
#
# Returns:
#   0 on success (outputs netmask to stdout)
#   1 on invalid input (outputs empty string)
#===============================================================================
cidr_to_netmask() {
  local input="$1"
  local prefix=""
  
  # Validate input is provided
  if [[ -z "$input" ]]; then
    hps_log warning "cidr_to_netmask: No input provided"
    return 1
  fi
  
  # Check if input contains a slash (CIDR notation with IP)
  if [[ "$input" =~ ^[0-9.]+/([0-9]+)$ ]]; then
    # Extract prefix from IP/CIDR format (e.g., 10.99.1.0/24 -> 24)
    prefix="${BASH_REMATCH[1]}"
  elif [[ "$input" =~ ^[0-9]+$ ]]; then
    # Input is just a number (prefix length)
    prefix="$input"
  else
    hps_log warning "cidr_to_netmask: Invalid CIDR format: $input"
    return 1
  fi
  
  # Validate prefix is in valid range (0-32)
  if [[ ! "$prefix" =~ ^[0-9]+$ ]] || (( prefix < 0 || prefix > 32 )); then
    hps_log warning "cidr_to_netmask: Invalid prefix length: $prefix (must be 0-32)"
    return 1
  fi
  
  local mask=""
  local full_octets=$((prefix / 8))
  local partial_octet=$((prefix % 8))
  
  # Full octets (255)
  for ((i=0; i<full_octets; i++)); do
    mask+="${mask:+.}255"
  done
  
  # Partial octet (if any)
  if (( partial_octet > 0 )); then
    local partial_value=$((256 - 2**(8-partial_octet)))
    mask+="${mask:+.}${partial_value}"
  fi
  
  # Fill remaining octets with 0
  local dot_count=$(echo "$mask" | tr -cd '.' | wc -c)
  while (( dot_count < 3 )); do
    mask+="${mask:+.}0"
    dot_count=$((dot_count + 1))
  done
  
  # Validate output has correct format
  if [[ ! "$mask" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    hps_log warning "cidr_to_netmask: Generated invalid netmask format: $mask"
    return 1
  fi
  
  echo "$mask"
  return 0
}


# detect_client_type
# ------------------
# Detects the type of caller for this CGI script based on CGI environment vars.
#
# Returns (via stdout):
#   ipxe    - iPXE boot client
#   cli     - curl or wget (host scripts)
#   browser - human browser (Mozilla/Chrome/Safari/etc)
#   script  - non-interactive/scripted caller (e.g. no UA, not ipxe/cli/browser)
#   unknown - fallback
#
# Usage:
#   client_type="$(detect_client_type)"
#   echo "Client is: ${client_type}"
detect_client_type() {
  # Guard against unset QUERY_STRING under `set -u`
  local qs="${QUERY_STRING-}"

  # Query string override first
  case ":${qs}:" in
    *":via=ipxe:"*|*":client=ipxe:"*)    echo "ipxe";    return 0 ;;
    *":via=cli:"*|*":client=cli:"*)      echo "cli";     return 0 ;;
    *":via=browser:"*|*":client=browser:"*) echo "browser"; return 0 ;;
    *":via=script:"*|*":client=script:"*) echo "script"; return 0 ;;
  esac

  # User-Agent detection (safe if unset)
  local ua="${HTTP_USER_AGENT-}"
  case "$ua" in
    *iPXE*|*ipxe*)         echo "ipxe";    return 0 ;;
    curl/*|Wget/*)         echo "cli";     return 0 ;;
    *Mozilla*|*Chrom*|*Safari*) echo "browser"; return 0 ;;
    "")                    echo "script";  return 0 ;;  # No UA → assume script
  esac

  # Default
  echo "unknown"
  return 0
}

generate_dhcp_range_simple() {
    local network_cidr="$1"   # e.g. 192.168.50.0/24
    local gateway_ip="$2"     # e.g. 192.168.50.1
    local count="${3:-20}"

    # Extract network and broadcast using ipcalc
    local network broadcast
    while read -r key value; do
        case "$key" in
            Network:)   network="${value%%/*}" ;;
            Broadcast:) broadcast="$value" ;;
        esac
    done < <(ipcalc -n -b "$network_cidr")

    local net_int=$(ip_to_int "$network")
    local bc_int=$(ip_to_int "$broadcast")
    local gw_int=$(ip_to_int "$gateway_ip")

    # Usable range: net+1 .. bc-1
    local usable_start=$((net_int + 1))
    local usable_end=$((bc_int - 1))

    # Try range just after the gateway
    local range_start=$((gw_int + 1))
    local range_end=$((range_start + count - 1))

    # Clamp to usable range
    if (( range_end > usable_end )); then
        range_end=$usable_end
        range_start=$((range_end - count + 1))
        if (( range_start < usable_start )); then
            range_start=$((usable_start + 1))
        fi
    fi

    echo "$(int_to_ip "$range_start"),$(int_to_ip "$range_end"),1h"
}




get_client_mac() {
  local ip="$1"
  local mac=""

  # Ensure IP is valid
  [[ -z "$ip" ]] && return 1
  # Trigger ARP update
  ping -c1 -W1 "$ip" > /dev/null 2>&1

  # Use regex to extract MAC from matching line
  mac="$(ip neigh | awk -v ip="$ip" '
    $1 == ip {
      for (i=1; i<=NF; i++) {
        if ($i ~ /^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$/) {
          print $i
          exit
        }
      }
    }
  ')"

#  # Fallback to arp
#  if [[ -z "$mac" ]]; then
#    mac="$(arp -n | awk -v ip="$ip" '
#      $1 == ip {
#        for (i=1; i<=NF; i++) {
#          if ($i ~ /^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$/) {
#            print $i
#            exit
#          }
#        }
#      }
#    ')"
#  fi
  echo $(normalise_mac "$mac")
}



#===============================================================================
# normalise_mac
# -------------
# Normalize MAC address to 12-character lowercase hex string without delimiters.
#
# Parameters:
#   $1 - MAC address in any common format (with :, -, ., or spaces)
#
# Output:
#   Normalized MAC address (12 hex chars, lowercase, no delimiters)
#   Error message to stderr if invalid
#
# Returns:
#   0 on success
#   1 if MAC address format is invalid
#
# Example:
#   normalise_mac "52:54:00:12:34:56"  # outputs: 525400123456
#   normalise_mac "52-54-00-12-34-56"  # outputs: 525400123456
#===============================================================================
normalise_mac() {
  local mac="$1"
  # Remove all common delimiters
  mac="${mac//:/}"
  mac="${mac//-/}"
  mac="${mac//./}"
  mac="${mac// /}"
  # Convert to lowercase
  mac="${mac,,}"
  # Validate: must be exactly 12 hex characters
  if [[ ! "$mac" =~ ^[0-9a-f]{12}$ ]]; then
    echo "[x] Invalid MAC address format: $1" >&2
    return 1
  fi
  echo "$mac"
}

#===============================================================================
# format_mac_colons
# -----------------
# Format a MAC address with colon delimiters.
#
# Parameters:
#   $1 - MAC address (with or without colons)
#
# Output:
#   MAC address in format: xx:xx:xx:xx:xx:xx (lowercase)
#   Error message to stderr if invalid
#
# Returns:
#   0 on success
#   1 if MAC address format is invalid
#
# Example:
#   format_mac_colons "525400123456"           # outputs: 52:54:00:12:34:56
#   format_mac_colons "52:54:00:12:34:56"      # outputs: 52:54:00:12:34:56
#   format_mac_colons "52-54-00-12-34-56"      # outputs: 52:54:00:12:34:56
#===============================================================================
format_mac_colons() {
  local mac="$1"
  
  if [[ -z "$mac" ]]; then
    echo "[x] MAC address required" >&2
    return 1
  fi
  
  # Remove any existing delimiters (colons, dashes, dots)
  mac="${mac//:/}"
  mac="${mac//-/}"
  mac="${mac//./}"
  
  # Validate: must be exactly 12 hex characters after removing delimiters
  if [[ ! "$mac" =~ ^[0-9a-fA-F]{12}$ ]]; then
    echo "[x] Invalid MAC address format: $1" >&2
    return 1
  fi
  
  # Convert to lowercase and insert colons
  mac="${mac,,}"
  echo "${mac:0:2}:${mac:2:2}:${mac:4:2}:${mac:6:2}:${mac:8:2}:${mac:10:2}"
  return 0
}



#===============================================================================
# strip_quotes
# ------------
# Remove surrounding quotes from a string.
#
# Parameters:
#   $1 - String potentially with quotes
#
# Output:
#   String without surrounding quotes
#
# Returns:
#   0 always (even if no quotes present)
#
# Example:
#   strip_quotes '"test1.home"'  # outputs: test1.home
#   strip_quotes "'test1.home'"  # outputs: test1.home
#   strip_quotes 'test1.home'    # outputs: test1.home
#===============================================================================
strip_quotes() {
  local str="$1"
  
  # Remove leading quote (single or double)
  str="${str#\"}"
  str="${str#\'}"
  
  # Remove trailing quote (single or double)
  str="${str%\"}"
  str="${str%\'}"
  
  echo "$str"
}

#===============================================================================
# validate_ip_address
# -------------------
# Validate IPv4 address format.
#
# Parameters:
#   $1 - IP address string to validate
#
# Returns:
#   0 if valid IPv4 format
#   1 if invalid format
#
# Note:
#   Only validates format, not reachability or subnet validity.
#   Checks each octet is 0-255.
#
# Example:
#   validate_ip_address "10.99.1.1"    # returns 0
#   validate_ip_address "192.168.1.256" # returns 1
#===============================================================================
validate_ip_address() {
  local ip="$1"
  local octet_regex='^([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])$'
  
  # Check basic format: four octets separated by dots
  if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    return 1
  fi
  
  # Split into octets and validate each
  IFS='.' read -r -a octets <<< "$ip"
  
  for octet in "${octets[@]}"; do
    if [[ ! "$octet" =~ $octet_regex ]]; then
      return 1
    fi
  done
  
  return 0
}

#===============================================================================
# validate_hostname
# -----------------
# Validate hostname format (DNS-compliant).
#
# Parameters:
#   $1 - Hostname string to validate
#
# Returns:
#   0 if valid hostname format
#   1 if invalid format
#
# Note:
#   Validates according to RFC 1123:
#   - Max 253 characters total
#   - Labels max 63 characters
#   - Alphanumeric and hyphens only
#   - Cannot start or end with hyphen
#   - Case insensitive
#
# Example:
#   validate_hostname "TCH-001"       # returns 0
#   validate_hostname "host.domain"   # returns 0
#   validate_hostname "-invalid"      # returns 1
#===============================================================================
validate_hostname() {
  local hostname="$1"
  
  # Check total length
  if [[ ${#hostname} -gt 253 ]]; then
    return 1
  fi
  
  # Check if empty
  if [[ -z "$hostname" ]]; then
    return 1
  fi
  
  # Split by dots and validate each label
  IFS='.' read -r -a labels <<< "$hostname"
  
  for label in "${labels[@]}"; do
    # Check label length
    if [[ ${#label} -gt 63 ]] || [[ ${#label} -eq 0 ]]; then
      return 1
    fi
    
    # Check label format: alphanumeric and hyphens, cannot start/end with hyphen
    if [[ ! "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
      return 1
    fi
  done
  
  return 0
}
