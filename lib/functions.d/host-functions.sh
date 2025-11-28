__guard_source || return


#===============================================================================
# get_active_cluster_hosts_dir
# ----------------------------
# Get the hosts directory for the active cluster.
#
# Returns:
#   Path via stdout
#   1 if active cluster cannot be determined
#===============================================================================
get_active_cluster_hosts_dir() {
  local cluster_dir
  cluster_dir=$(get_active_cluster_dir 2>/dev/null) || return 1
  echo "${cluster_dir}/hosts"
}


#===============================================================================
# process_host_audit
# -----------------
# Process generic host data received from iPXE.
#
# Parameters:
#   $1 - MAC address of the host
#   $2 - Data string (pipe-delimited key=value pairs)
#   $3 - Prefix for host config keys (default: "host")
#
# Returns:
#   0 on success
#
#===============================================================================
process_host_audit() {
  local mac="$1"
  local encoded_data="$2"
  local prefix="${3:-host}"
  # send ipxe header
  ipxe_header
    
  # URL decode
  local data="${encoded_data//+/ }"
  data=$(printf '%b' "${data//%/\\x}")
  
  hps_log debug "Processing decoded data: ${data}"
  
  # Create temp file for all operations
  local temp_file="/tmp/audit_${mac//:/}_$$"
  > "$temp_file"
  
  # Process fields - NO function calls inside the loop
  echo "$data" | sed 's/|/\n/g' | while IFS= read -r field; do
  if [[ "$field" =~ ^([^=]+)=(.*)$ ]]; then
    local key="${BASH_REMATCH[1]}"
    local value="${BASH_REMATCH[2]}"
  
    # URL decode the individual value
    value="${value//+/ }"
    value=$(printf '%b' "${value//%/\\x}")
      
      # Sanitize key
      local safe_key=$(echo "$key" | tr ':. ' '_')
      
      # Check for invalid data
      if [[ "$value" =~ [[:cntrl:]] ]] || [[ "$value" == *"FFFFFF"* ]]; then
        value="INVALID_DATA"
      fi
      
      # Write to file instead of calling any functions
      echo "${prefix}_${safe_key}=${value}" >> "$temp_file"
    fi
  done
  
  # Now process the temp file outside the pipe
  if [[ -f "$temp_file" ]] && [[ -s "$temp_file" ]]; then
    while IFS='=' read -r key value; do
      # Now we can safely call functions
      host_registry "$mac" "set" "$key" "$value"
      hps_log debug "Stored: $key = $value"
    done < "$temp_file"
    
    local field_count=$(wc -l < "$temp_file")
    rm -f "$temp_file"
  else
    local field_count=0
  fi
  
  # Store metadata
  host_registry "$mac" "set" "${prefix}_timestamp" "$(date +%s)"
  host_registry "$mac" "set" "${prefix}_count" "$field_count"
  
  hps_log info "Host data collection '${prefix}' completed for ${mac}: ${field_count} fields"
  return 0
}


#===============================================================================
# get_host_os_id
# ---------------
# Get the configured OS identifier for a host based on MAC address.
#
# Behaviour:
#   - Looks up host type and architecture from host config
#   - Returns the appropriate OS ID from cluster config
#   - Falls back through architecture-specific → generic → error
#
# Arguments:
#   $1: MAC address
#
# Returns:
#   OS identifier string (e.g., "x86_64:alpine:3.20")
#   Empty string if not found
#
# Example usage:
#   os_id=$(get_host_os_id "00:11:22:33:44:55")
#
#===============================================================================
get_host_os_id() {
  local mac="$1"
  
  # Get host info
  local host_type=$(host_registry "$mac" "get" "TYPE")
  local arch=$(host_registry "$mac" "get" "arch")
  
  # Validate we have required info
  if [[ -z "$host_type" ]]; then
    hps_log error "[get_host_os_id] No host type found for $mac"
    return 1
  fi
  
  # Default to x86_64 if no arch specified
  [[ -z "$arch" ]] && arch="x86_64"
  
  # Build the cluster config key
  local os_key="os_$(echo $host_type | tr '[:upper:]' '[:lower:]')_${arch}"
  local os_id=$(cluster_registry "get" "$os_key")
  
  # Fallback to non-architecture-specific if not found
  if [[ -z "$os_id" ]]; then
    os_key="os_$(echo $host_type | tr '[:upper:]' '[:lower:]')"
    os_id=$(cluster_registry "get" "$os_key")
    
    # If found non-arch specific, prepend architecture
    if [[ -n "$os_id" ]] && [[ "$os_id" != *:* ]]; then
      os_id="${arch}:${os_id}"
    fi
  fi
  
  if [[ -z "$os_id" ]]; then
    hps_log error "[get_host_os_id] No OS configured for $host_type/$arch"
    return 1
  fi
  
  # Verify the OS exists in registry
  if ! os_registry "$os_id" "exists"; then
    hps_log error "[get_host_os_id] OS '$os_id' not found in registry"
    return 1
  fi
  
  echo "$os_id"
  return 0
}

#===============================================================================
# get_host_os_version
# --------------------
# Get just the version string for a host's configured OS.
#
# Arguments:
#   $1: MAC address
#
# Returns:
#   Version string (e.g., "3.20" or "10")
#
# Example usage:
#   version=$(get_host_os_version "00:11:22:33:44:55")
#
#===============================================================================
get_host_os_version() {
  local mac="$1"
  local os_id=$(get_host_os_id "$mac")
  
  [[ -z "$os_id" ]] && return 1
  
  os_registry "$os_id" get "version"
}


#===============================================================================
# host_initialise_config
# ----------------------
# Initialize a new host configuration in registry.
#
# Usage:
#   host_initialise_config <mac> <arch>
#
# Parameters:
#   mac  - MAC address of the host
#   arch - Architecture (e.g., x86_64)
#
# Returns:
#   0 on success
#   1 if MAC not provided or initialization fails
#===============================================================================
host_initialise_config() {
  local mac="$1"
  local arch="$2"
  
  # Validate MAC address is provided
  if [[ -z "$mac" ]]; then
    hps_log error "MAC address not provided"
    return 1
  fi
  
  # Get the hosts directory for the active cluster
  local hosts_dir
  hosts_dir=$(get_active_cluster_hosts_dir 2>/dev/null)
  
  if [[ -z "$hosts_dir" ]]; then
    hps_log error "Cannot determine active cluster hosts directory"
    return 1
  fi
  
  # Ensure the hosts directory exists
  if [[ ! -d "$hosts_dir" ]]; then
    if ! mkdir -p "$hosts_dir" 2>/dev/null; then
      hps_log error "Failed to create hosts directory: $hosts_dir"
      return 1
    fi
    hps_log debug "Created hosts directory: $hosts_dir"
  fi
  
  # Set initial state using host_registry (which will create the registry)
  if ! host_registry "$mac" set STATE "UNCONFIGURED"; then
    hps_log error "Failed to set initial state for MAC: $mac"
    return 1
  fi
  
  if ! host_registry "$mac" set arch "$arch"; then
    hps_log error "Failed to set arch for MAC: $mac"
    return 1
  fi
  
  return 0
}


#===============================================================================
# _find_available_ip
# ------------------
# Find an available IP address in DHCP range.
#
# Usage:
#   _find_available_ip <mac> <dhcp_ip> <dhcp_rangesize>
#
# Parameters:
#   mac            - MAC address of host (to check current IP)
#   dhcp_ip        - DHCP server IP (start of range)
#   dhcp_rangesize - Size of DHCP range
#
# Returns:
#   0 on success (outputs IP to stdout)
#   1 if no available IPs found
#===============================================================================
_find_available_ip() {
  local mac="$1"
  local dhcp_ip="$2"
  local dhcp_rangesize="$3"
  
  # Get all currently assigned IPs
  local assigned_ips
  assigned_ips=$(get_cluster_host_ips 2>/dev/null)
  
  # Get current host's IP if it already has one
  local current_host_ip
  current_host_ip=$(host_registry "$mac" get IP 2>/dev/null) || current_host_ip=""
  
  # Convert DHCP start IP to integer
  local dhcp_start_int
  dhcp_start_int=$(ip_to_int "$dhcp_ip" 2>/dev/null) || return 1
  
  # Scan range for available IP
  local try_ip
  for ((i=0; i<dhcp_rangesize; i++)); do
    try_ip=$(int_to_ip $((dhcp_start_int + i)) 2>/dev/null)
    [[ -z "$try_ip" ]] && continue
    
    # Skip DHCP server IP
    [[ "$try_ip" == "$dhcp_ip" ]] && continue
    
    # Check if IP is in use by another host
    local ip_in_use=0
    while IFS= read -r existing_ip; do
      [[ -z "$existing_ip" ]] && continue
      if [[ "$existing_ip" == "$try_ip" ]]; then
        # OK if it's our current IP (reconfiguring)
        [[ "$current_host_ip" != "$try_ip" ]] && ip_in_use=1
        break
      fi
    done <<< "$assigned_ips"
    
    # Found available IP
    if [[ $ip_in_use -eq 0 ]]; then
      echo "$try_ip"
      return 0
    fi
  done
  
  return 1
}

#===============================================================================
# _find_available_hostname
# ------------------------
# Find available hostname with sequential numbering.
#
# Usage:
#   _find_available_hostname <hosttype>
#
# Parameters:
#   hosttype - Host type prefix (e.g., TCH, ROCKY)
#
# Returns:
#   0 on success (outputs hostname to stdout)
#   1 on failure
#===============================================================================
_find_available_hostname() {
  local hosttype="$1"
  local hosttype_lower=$(echo "$hosttype" | tr '[:upper:]' '[:lower:]')
  local next_number=1
  
  # Get all existing hostnames of this type
  local existing_hostnames
  existing_hostnames=$(get_cluster_host_hostnames "" "$hosttype_lower" 2>/dev/null)
  
  # Find highest existing number
  while IFS= read -r existing_hostname; do
    [[ -z "$existing_hostname" ]] && continue
    
    if [[ "$existing_hostname" =~ ^${hosttype_lower}-([0-9]+)$ ]]; then
      local num="${BASH_REMATCH[1]}"
      if [[ -n "$num" ]] && [[ "$num" =~ ^[0-9]+$ ]]; then
        num=$((10#$num)) || continue
        [[ $num -ge $next_number ]] && next_number=$((num + 1))
      fi
    fi
  done <<< "$existing_hostnames"
  
  # Generate hostname with zero-padding
  printf "%s-%03d" "$hosttype_lower" "$next_number"
  return 0
}

#===============================================================================
# host_network_configure
# ----------------------
# Assign IP address and hostname to a host based on MAC address.
#
# Usage:
#   host_network_configure <mac>
#
# Parameters:
#   mac - MAC address of the host
#
# Returns:
#   0 on success
#   1 if configuration fails or no available IPs/hostnames
#===============================================================================
host_network_configure() {
  local macid="$1"

  local hosttype=$(host_registry "$macid" get TYPE 2>/dev/null)
  
  hps_log debug "host_network_configure called with MAC: $macid, TYPE: $hosttype"
  
  # Validate input parameters
  if [[ -z "$macid" ]]; then
    hps_log error "MAC address not provided"
    return 1
  fi
  
  if [[ -z "$hosttype" ]]; then
    hps_log error "Host type not provided"
    return 1
  fi
  
  # Get cluster network configuration
  local dhcp_ip dhcp_rangesize network_cidr
  dhcp_ip=$(cluster_registry get DHCP_IP 2>/dev/null)
  dhcp_rangesize=$(cluster_registry get DHCP_RANGESIZE 2>/dev/null)
  network_cidr=$(cluster_registry get NETWORK_CIDR 2>/dev/null)

  hps_log debug "Configuring with network $network_cidr"

  # Validate cluster config
  if [[ -z "$dhcp_ip" ]] || [[ -z "$dhcp_rangesize" ]] || [[ -z "$network_cidr" ]]; then
    hps_log error "Missing required cluster network configuration"
    return 1
  fi
  
  if ! validate_ip_address "$dhcp_ip" 2>/dev/null; then
    hps_log error "Invalid DHCP_IP: $dhcp_ip"
    return 1
  fi
  
  # Calculate netmask
  local netmask
  netmask=$(cidr_to_netmask "$network_cidr" 2>/dev/null)
  if [[ -z "$netmask" ]]; then
    hps_log error "Failed to calculate netmask from: $network_cidr"
    return 1
  fi

  
  # Check if network config already exists - if so, preserve it
  local assigned_ip assigned_hostname
    # Check if IP already exists before trying to get it
  if host_registry "$macid" exists IP; then
    assigned_ip=$(host_registry "$macid" get IP 2>/dev/null)
  else
    assigned_ip=""
  fi
  
  # Check if HOSTNAME already exists before trying to get it
  if host_registry "$macid" exists HOSTNAME; then
    assigned_hostname=$(host_registry "$macid" get HOSTNAME 2>/dev/null)
  else
    assigned_hostname=""
  fi

  # Allocate IP if not already set
  if [[ -z "$assigned_ip" ]]; then
    hps_log debug "No existing IP, allocating new one"
    assigned_ip=$(_find_available_ip "$macid" "$dhcp_ip" "$dhcp_rangesize")
    
    if [[ -z "$assigned_ip" ]]; then
      hps_log error "No available IPs in DHCP range"
      return 1
    fi
    
    if ! validate_ip_address "$assigned_ip" 2>/dev/null; then
      hps_log error "Generated invalid IP: $assigned_ip"
      return 1
    fi
    
    hps_log info "Allocated IP: $assigned_ip"
  else
    hps_log debug "Preserving existing IP: $assigned_ip"
  fi
  
  # Allocate hostname if not already set
  if [[ -z "$assigned_hostname" ]]; then
    hps_log debug "No existing hostname, generating new one"
    assigned_hostname=$(_find_available_hostname "$hosttype")
    
    if [[ -z "$assigned_hostname" ]]; then
      hps_log error "Failed to generate hostname"
      return 1
    fi
    
    if ! validate_hostname "$assigned_hostname" 2>/dev/null; then
      hps_log error "Generated invalid hostname: $assigned_hostname"
      return 1
    fi
    
    hps_log info "Generated hostname: $assigned_hostname"
  else
    hps_log debug "Preserving existing hostname: $assigned_hostname"
  fi
  
  # Write configuration (only updates changed values)
  host_registry "$macid" set IP "$assigned_ip" || {
    hps_log error "Failed to set IP"
    return 1
  }
  
  host_registry "$macid" set NETMASK "$netmask" || {
    hps_log error "Failed to set NETMASK"
    return 1
  }
  
  host_registry "$macid" set HOSTNAME "$assigned_hostname" || {
    hps_log error "Failed to set HOSTNAME"
    return 1
  }
  
  host_registry "$macid" set TYPE "$hosttype" || {
    hps_log error "Failed to set TYPE"
    return 1
  }
  
  host_registry "$macid" set STATE "CONFIGURED" || {
    hps_log error "Failed to set STATE"
    return 1
  }
  
  hps_log info "Network configuration complete for $macid: $assigned_hostname ($assigned_ip)"
  return 0
}


#===============================================================================
# host_config_delete
# ------------------
# Delete a host's configuration from registry.
#
# Usage:
#   host_config_delete <mac>
#
# Parameters:
#   mac - MAC address of the host
#
# Returns:
#   0 on success (registry deleted)
#   1 if MAC not provided
#   2 if registry does not exist
#   3 if deletion fails
#===============================================================================
host_config_delete() {
  local mac="$1"
  
  # Validate MAC address is provided
  if [[ -z "$mac" ]]; then
    hps_log error "host_config_delete: MAC address not provided"
    return 1
  fi
  
  # Check if host registry exists
  if ! host_registry "$mac" exists; then
    hps_log warning "[$mac] Host registry not found"
    return 2
  fi
  
  # Get the hosts directory
  local hosts_dir
  hosts_dir=$(get_active_cluster_hosts_dir 2>/dev/null)
  if [[ -z "$hosts_dir" ]]; then
    hps_log error "[$mac] Cannot determine hosts directory"
    return 1
  fi
  
  # Normalize MAC for directory name
  local mac_normalized
  mac_normalized=$(normalise_mac "$mac") || {
    hps_log error "[$mac] Failed to normalize MAC"
    return 1
  }
  
  local registry_dir="${hosts_dir}/${mac_normalized}.db"
  
  # Delete the entire registry directory
  if rm -rf "$registry_dir" 2>/dev/null; then
    hps_log info "[$mac] Deleted host registry: $registry_dir"
    return 0
  else
    hps_log error "[$mac] Failed to delete registry directory: $registry_dir"
    return 3
  fi
}


#===============================================================================
# host_config_show
# ----------------
# Display a host's configuration from registry.
#
# Usage:
#   host_config_show <mac>
#
# Parameters:
#   mac - MAC address of the host
#
# Returns:
#   0 on success (outputs config to stdout)
#   1 if MAC not provided or config cannot be read
#===============================================================================
host_config_show() {
  local mac="$1"
  
  # Validate MAC address is provided
  if [[ -z "$mac" ]]; then
    hps_log error "host_config_show: MAC address not provided"
    return 1
  fi
  
  # Check if host exists
  if ! host_registry "$mac" exists; then
    hps_log info "No host config found for MAC: $mac"
    return 1
  fi
  
  # Use registry view to get all keys as JSON, then convert to key=value
  local view_output
  view_output=$(host_registry "$mac" view 2>/dev/null) || {
    hps_log error "Failed to read host registry for MAC: $mac"
    return 1
  }
  
  # Convert JSON to key=value format with proper quoting
  echo "$view_output" | jq -r 'to_entries[] | "\(.key)=\"\(.value)\""'
  
  return 0
}


#===============================================================================
# host_config_exists
# ------------------
# Check if a host's configuration exists in registry.
#
# Usage:
#   host_config_exists <mac>
#
# Parameters:
#   mac - MAC address of the host
#
# Returns:
#   0 if config exists
#   1 if MAC not provided or config doesn't exist
#===============================================================================
host_config_exists() {
  local mac="$1"
  
  # Validate MAC address is provided
  if [[ -z "$mac" ]]; then
    return 1
  fi
  
  # Use host_registry exists (which checks for .db directory)
  host_registry "$mac" exists >/dev/null 2>&1
  return $?
}

#===============================================================================
# host_post_config_hooks
# ----------------------
# Execute post-configuration hooks when host config changes.
#
# Usage:
#   host_post_config_hooks <key> <value>
#
# Parameters:
#   key   - Configuration key that was changed
#   value - New value
#
# Returns:
#   0 always (hooks don't fail the main operation)
#===============================================================================
host_post_config_hooks() {
    local key="$1"
    local value="$2"
    
    # Define hook mappings
    declare -A hooks=(
        ["IP"]="update_dns_dhcp_files"
        ["HOSTNAME"]="update_dns_dhcp_files"
    )
    
    # Check if we have a hook for this key
    if [[ -n "${hooks[$key]}" ]]; then
        local hook_function="${hooks[$key]}"
        
        # Verify the function exists before calling it
        if type -t "$hook_function" >/dev/null 2>&1; then
            # Log that we're calling the hook
            hps_log info "host_post_config_hooks: Calling $hook_function for $key change"
            
            # Call the hook function with output suppression
            if ! "$hook_function" >/dev/null 2>&1; then
                hps_log warn "host_post_config_hooks: Hook $hook_function failed for $key=$value"
            fi
        else
            hps_log warn "host_post_config_hooks: Hook function $hook_function not found"
        fi
    fi
    
    # Always return success
    return 0
}


#===============================================================================
# host_config
# -----------
# Alias to host_registry for backward compatibility
#===============================================================================
host_config() {
  host_registry "$@"
}

#===============================================================================
# get_host_mac_by_keyvalue
# -------------------------
# Find host MAC address by searching for key/value pair using registry search.
#
# Usage:
#   get_host_mac_by_keyvalue <key> <value>
#
# Parameters:
#   key   - Key to search for (e.g., "HOSTNAME", "IP", "storage0_ip")
#   value - Value to match
#
# Returns:
#   0 on success (echoes MAC address)
#   1 if not found
#
# Example usage:
#   mac=$(get_host_mac_by_keyvalue "HOSTNAME" "tch-001")
#   mac=$(get_host_mac_by_keyvalue "IP" "10.99.1.8")
#===============================================================================
get_host_mac_by_keyvalue() {
  local search_key="$1"
  local search_value="$2"
  
  if [[ -z "$search_key" ]] || [[ -z "$search_value" ]]; then
    return 1
  fi
  
  # Use registry_search which searches JSON files directly
  local result
  result=$(registry_search host "$search_key" "$search_value" 2>/dev/null)
  
  if [[ -n "$result" ]]; then
    echo "$result"
    return 0
  fi
  
  return 1
}

#===============================================================================
# get_all_hosts_by_keyvalue
# --------------------------
# Find all host MAC addresses matching a key/value pair.
#
# Usage:
#   get_all_hosts_by_keyvalue <key> <value>
#
# Parameters:
#   key   - Key to search for
#   value - Value to match
#
# Returns:
#   0 if any found (echoes all MACs, one per line)
#   1 if none found
#
# Example usage:
#   macs=$(get_all_hosts_by_keyvalue "TYPE" "TCH")
#===============================================================================
get_all_hosts_by_keyvalue() {
  local search_key="$1"
  local search_value="$2"
  
  if [[ -z "$search_key" ]] || [[ -z "$search_value" ]]; then
    return 1
  fi
  
  # Scan all hosts and check for matching key/value
  local found=0
  local mac
  
  while IFS= read -r mac; do
    [[ -z "$mac" ]] && continue
    
    local stored_value
    stored_value=$(host_registry "$mac" get "$search_key" 2>/dev/null)
    
    if [[ "$stored_value" == "$search_value" ]]; then
      echo "$mac"
      found=1
    fi
  done < <(list_cluster_hosts)
  
  return $((found ? 0 : 1))
}


#===============================================================================
# has_sch_host
# ------------
# Check if the active cluster has any SCH (Storage/Compute Host) hosts.
#
# Returns:
#   0 if at least one SCH host exists
#   1 if no SCH hosts found or cluster cannot be determined
#===============================================================================
has_sch_host() {
  # Get all SCH hosts using the cluster helper with type filter
  local sch_hosts
  sch_hosts=$(get_cluster_host_hostnames "" "sch" 2>/dev/null)
  
  # If we got any output, at least one SCH host exists
  if [[ -n "$sch_hosts" ]]; then
    return 0
  else
    return 1
  fi
}
