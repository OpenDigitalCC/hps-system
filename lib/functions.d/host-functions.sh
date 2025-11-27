__guard_source || return
# Define your functions below




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
      host_config "$mac" "set" "$key" "$value"
      hps_log debug "Stored: $key = $value"
    done < "$temp_file"
    
    local field_count=$(wc -l < "$temp_file")
    rm -f "$temp_file"
  else
    local field_count=0
  fi
  
  # Store metadata
  host_config "$mac" "set" "${prefix}_timestamp" "$(date +%s)"
  host_config "$mac" "set" "${prefix}_count" "$field_count"
  
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
  local host_type=$(host_config "$mac" "get" "TYPE")
  local arch=$(host_config "$mac" "get" "arch")
  
  # Validate we have required info
  if [[ -z "$host_type" ]]; then
    hps_log error "[get_host_os_id] No host type found for $mac"
    return 1
  fi
  
  # Default to x86_64 if no arch specified
  [[ -z "$arch" ]] && arch="x86_64"
  
  # Build the cluster config key
  local os_key="os_$(echo $host_type | tr '[:upper:]' '[:lower:]')_${arch}"
  local os_id=$(cluster_config "get" "$os_key")
  
  # Fallback to non-architecture-specific if not found
  if [[ -z "$os_id" ]]; then
    os_key="os_$(echo $host_type | tr '[:upper:]' '[:lower:]')"
    os_id=$(cluster_config "get" "$os_key")
    
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
  if ! os_config "$os_id" "exists"; then
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
  
  os_config "$os_id" "get" "version"
}



#:name: host_initialise_config
#:group: host-management
#:synopsis: Initialize a new host configuration file.
#:usage: host_initialise_config <mac>
#:description:
#  Creates a new configuration file for a host identified by MAC address.
#  Sets the initial STATE to UNCONFIGURED. Creates the hosts directory if needed.
#  Uses get_active_cluster_hosts_dir to determine the correct location.
#:parameters:
#  mac - MAC address of the host
#:returns:
#  0 on success
#  1 if MAC not provided or initialization fails
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
  
  # Set initial state using host_config (which will create the file)
  if ! host_config "$mac" set STATE "UNCONFIGURED"; then
    hps_log error "Failed to set initial state for MAC: $mac"
    return 1
  fi
  
  if ! host_config "$mac" set arch "$arch"; then
    hps_log error "Failed to set arch for MAC: $mac"
    return 1
  fi
  
  return 0
}


get_active_cluster_hosts_dir () {
  echo "$(get_active_cluster_link_path)/hosts"
}


#:name: get_mac_from_conffile
#:group: host-management
#:synopsis: Extract MAC address from a host configuration filename.
#:usage: get_mac_from_conffile <conf_file_path>
#:description:
#  Extracts the MAC address from a host configuration file path.
#  The MAC is the basename of the file without the .conf extension.
#:parameters:
#  conf_file_path - Full path to the configuration file
#:returns:
#  0 on success (outputs MAC address to stdout)
#  1 if filename is invalid or cannot be parsed
get_mac_from_conffile() {
  local conf_file="$1"
  
  if [[ -z "$conf_file" ]]; then
    hps_log error "get_mac_from_conffile: No config file provided"
    return 1
  fi
  
  local mac
  mac=$(basename "$conf_file" .conf 2>/dev/null)
  
  if [[ -z "$mac" ]] || [[ "$mac" == "$conf_file" ]]; then
    hps_log error "get_mac_from_conffile: Cannot extract MAC from: $conf_file"
    return 1
  fi
  
  echo "$mac"
  return 0
}



#:name: get_host_conf_filename
#:group: host-management
#:synopsis: Get the full path to a host's configuration file.
#:usage: get_host_conf_filename <mac>
#:description:
#  Returns the full path to the configuration file for a host identified by MAC address.
#  Uses the active cluster's hosts directory to construct the path.
#  Validates that the hosts directory can be determined and the config file exists and is readable.
#:parameters:
#  mac - MAC address of the host
#:returns:
#  0 on success (outputs config file path to stdout)
#  1 if MAC not provided or hosts directory cannot be determined
#  2 if config file does not exist or is not readable
get_host_conf_filename() {
  local mac="$1"
  
  # Validate MAC address is provided
  if [[ -z "$mac" ]]; then
    hps_log error "get_host_conf_filename: MAC address not provided"
    return 1
  fi
  
  # Get active cluster hosts directory
  local hosts_dir
  hosts_dir=$(get_active_cluster_hosts_dir 2>/dev/null)
  
  if [[ -z "$hosts_dir" ]]; then
    hps_log error "get_host_conf_filename: Cannot determine active cluster hosts directory"
    return 1
  fi
  
  # Construct the config file path
  local conf_file="${hosts_dir}/${mac}.conf"
  
  # Verify file exists and is readable
  if [[ ! -f "$conf_file" ]]; then
    hps_log error "get_host_conf_filename: Config file does not exist: $conf_file"
    return 2
  fi
  
  if [[ ! -r "$conf_file" ]]; then
    hps_log error "get_host_conf_filename: Config file is not readable: $conf_file"
    return 2
  fi
  
  # Output the config file path
  echo "$conf_file"
  return 0
}

#:name: _find_available_ip
#:group: network
#:synopsis: Find an available IP address in DHCP range.
#:usage: _find_available_ip <mac> <dhcp_ip> <dhcp_rangesize>
#:description:
#  Scans DHCP range for available IP address.
#  Skips DHCP server IP and already-assigned IPs.
#  Preserves current host IP if already assigned.
#:parameters:
#  mac            - MAC address of host (to check current IP)
#  dhcp_ip        - DHCP server IP (start of range)
#  dhcp_rangesize - Size of DHCP range
#:returns:
#  0 on success (outputs IP to stdout)
#  1 if no available IPs found
_find_available_ip() {
  local mac="$1"
  local dhcp_ip="$2"
  local dhcp_rangesize="$3"
  
  # Get all currently assigned IPs
  local assigned_ips
  assigned_ips=$(get_cluster_host_ips 2>/dev/null)
  
  # Get current host's IP if it already has one
  local current_host_ip
  current_host_ip=$(host_config "$mac" get IP 2>/dev/null) || current_host_ip=""
  
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

#:name: _find_available_hostname
#:group: network
#:synopsis: Find available hostname with sequential numbering.
#:usage: _find_available_hostname <hosttype>
#:description:
#  Generates hostname by finding highest existing number for host type
#  and incrementing. Returns hostname in format: type-NNN (lowercase, zero-padded).
#:parameters:
#  hosttype - Host type prefix (e.g., TCH, ROCKY)
#:returns:
#  0 on success (outputs hostname to stdout)
#  1 on failure
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

#:name: host_network_configure
#:group: network
#:synopsis: Assign IP address and hostname to a host based on MAC address.
#:usage: host_network_configure <mac> <hosttype>
#:description:
#  Allocates a unique IP address from the DHCP range and generates
#  a unique hostname based on host type. Preserves existing network
#  configuration if already set. Persists configuration via host_config.
#:parameters:
#  mac      - MAC address of the host
#  hosttype - Host type prefix for hostname generation (e.g., TCH, ROCKY)
#:returns:
#  0 on success
#  1 if configuration fails or no available IPs/hostnames
host_network_configure() {
  local macid="$1"

  local hosttype=$(host_config "$macid" get TYPE 2>/dev/null)
  
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
  dhcp_ip=$(cluster_config get DHCP_IP 2>/dev/null)
  dhcp_rangesize=$(cluster_config get DHCP_RANGESIZE 2>/dev/null)
  network_cidr=$(cluster_config get NETWORK_CIDR 2>/dev/null)

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
  if host_config "$macid" exists IP; then
    assigned_ip=$(host_config "$macid" get IP 2>/dev/null)
  else
    assigned_ip=""
  fi
  
  # Check if HOSTNAME already exists before trying to get it
  if host_config "$macid" exists HOSTNAME; then
    assigned_hostname=$(host_config "$macid" get HOSTNAME 2>/dev/null)
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
  host_config "$macid" set IP "$assigned_ip" || {
    hps_log error "Failed to set IP"
    return 1
  }
  
  host_config "$macid" set NETMASK "$netmask" || {
    hps_log error "Failed to set NETMASK"
    return 1
  }
  
  host_config "$macid" set HOSTNAME "$assigned_hostname" || {
    hps_log error "Failed to set HOSTNAME"
    return 1
  }
  
  host_config "$macid" set TYPE "$hosttype" || {
    hps_log error "Failed to set TYPE"
    return 1
  }
  
  host_config "$macid" set STATE "CONFIGURED" || {
    hps_log error "Failed to set STATE"
    return 1
  }
  
  hps_log info "Network configuration complete for $macid: $assigned_hostname ($assigned_ip)"
  return 0
}


#:name: host_config_delete
#:group: host-management
#:synopsis: Delete a host's configuration file.
#:usage: host_config_delete <mac>
#:description:
#  Deletes the configuration file for a host identified by MAC address.
#  Uses get_host_conf_filename to locate the file in the active cluster.
#  Validates the file exists before attempting deletion.
#:parameters:
#  mac - MAC address of the host
#:returns:
#  0 on success (file deleted)
#  1 if MAC not provided or config file cannot be determined
#  2 if config file does not exist
#  3 if deletion fails
host_config_delete() {
  local mac="$1"
  
  # Validate MAC address is provided
  if [[ -z "$mac" ]]; then
    hps_log error "host_config_delete: MAC address not provided"
    return 1
  fi
  
  # Get the config file path using helper function
  local config_file
  config_file=$(get_host_conf_filename "$mac" 2>/dev/null)
  
  # Check if get_host_conf_filename succeeded
  if [[ $? -ne 0 ]] || [[ -z "$config_file" ]]; then
    hps_log error "[$mac] Cannot determine config file location"
    return 1
  fi
  
  # Verify file exists (get_host_conf_filename already checks this, but double-check)
  if [[ ! -f "$config_file" ]]; then
    hps_log warning "[$mac] Host config not found: $config_file"
    return 2
  fi
  
  # Attempt to delete the file
  if rm -f "$config_file" 2>/dev/null; then
    hps_log info "[$mac] Deleted host config: $config_file"
    
    # Reset the host_config cache for this MAC
    if [[ "${__HOST_CONFIG_MAC:-}" == "$mac" ]]; then
      __HOST_CONFIG_PARSED=0
      __HOST_CONFIG_MAC=""
      __HOST_CONFIG_FILE=""
    fi
    
    return 0
  else
    hps_log error "[$mac] Failed to delete config file: $config_file"
    return 3
  fi
}


#:name: host_config_show
#:group: host-management
#:synopsis: Display a host's configuration.
#:usage: host_config_show <mac>
#:description:
#  Displays the configuration for a host identified by MAC address.
#  Reads the config file and outputs each key-value pair with proper quoting.
#  Skips comments and empty lines.
#:parameters:
#  mac - MAC address of the host
#:returns:
#  0 on success (outputs config to stdout)
#  1 if MAC not provided or config file cannot be read
host_config_show() {
  local mac="$1"
  
  # Validate MAC address is provided
  if [[ -z "$mac" ]]; then
    hps_log error "host_config_show: MAC address not provided"
    return 1
  fi
  
  # Get the config file path using helper function
  local config_file
  config_file=$(get_host_conf_filename "$mac" 2>/dev/null)
  
  # Check if file exists and is readable
  if [[ $? -ne 0 ]] || [[ -z "$config_file" ]]; then
    hps_log info "No host config found for MAC: $mac"
    return 1
  fi
  
  # Read and display the config file
  while IFS='=' read -r k v; do
    # Skip comments and empty lines
    [[ "$k" =~ ^#.*$ || -z "$k" ]] && continue
    
    # Strip surrounding quotes from value
    v="${v%\"}"
    v="${v#\"}"
    
    # Escape embedded quotes and backslashes
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    
    # Output key-value pair with proper quoting
    echo "${k}=\"${v}\""
  done < "$config_file"
  
  return 0
}




#:name: host_config_exists
#:group: host-management
#:synopsis: Check if a host's configuration file exists.
#:usage: host_config_exists <mac>
#:description:
#  Checks if a configuration file exists for a host identified by MAC address.
#  Uses get_host_conf_filename to locate the file in the active cluster.
#:parameters:
#  mac - MAC address of the host
#:returns:
#  0 if config file exists and is readable
#  1 if MAC not provided, config file doesn't exist, or cannot be determined
host_config_exists() {
  local mac="$1"
  
  # Validate MAC address is provided
  if [[ -z "$mac" ]]; then
    return 1
  fi
  
  # Use get_host_conf_filename which validates existence and readability
  # If it returns successfully (exit code 0), the file exists and is readable
  get_host_conf_filename "$mac" >/dev/null 2>&1
  return $?
}

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



#:name: host_config
#:group: host-management
#:synopsis: Manage host configuration key-value storage per MAC address.
#:usage: host_config <mac> <command> [key] [value]
#:description:
#  Parses and manages host configuration from active cluster hosts directory.
#  Supports get, exists, equals, and set operations on host configuration keys.
#  MAC addresses are normalized (colons removed) for filenames.
#:parameters:
#  mac     - MAC address of the host (e.g., 52:54:00:9c:4c:24 or 5254009c4c24)
#  command - Operation: get, exists, equals, set
#  key     - Configuration key name (alphanumeric and underscore)
#  value   - Value to set (only for 'set' and 'equals' commands)
#:returns:
#  get:    0 if key exists (prints value), 1 if key not found
#  exists: 0 if key exists, 1 if not
#  equals: 0 if key exists and matches value, 1 otherwise
#  set:    0 on success
#  other:  2 for invalid command
host_config() {
  local mac_param=$1
  local cmd="$2"
  local key="$3"
  local value="${4:-}"
  
  # Use a local variable name that won't collide
  local _host_mac="$mac_param"
  
  # Validate MAC format if provided
  if [[ -n "$_host_mac" ]]; then
    if [[ ! "$_host_mac" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] && \
       [[ ! "$_host_mac" =~ ^[0-9a-fA-F]{12}$ ]]; then
      echo "ERROR: Invalid MAC address format: $_host_mac" >&2
      return 1
    fi
  else
    echo "ERROR: MAC address required" >&2
    return 1
  fi
  
  # Normalize MAC address for filename (remove colons, lowercase)
  local _mac_normalized
  _mac_normalized=$(normalise_mac "$_host_mac") || {
    echo "ERROR: Failed to normalize MAC address: $_host_mac" >&2
    return 1
  }
  
  # Get active cluster hosts directory and construct path
  local hosts_dir
  hosts_dir=$(get_active_cluster_hosts_dir 2>/dev/null)
  if [[ -z "$hosts_dir" ]]; then
    echo "ERROR: Cannot determine active cluster hosts directory" >&2
    return 1
  fi
  
  local config_file="${hosts_dir}/${_mac_normalized}.conf"
  
  case "$cmd" in
    get)
      # Read value directly from file
      if [[ ! -f "$config_file" ]]; then
        return 1
      fi
      
      local val
      val=$(grep -E "^${key}=" "$config_file" 2>/dev/null | cut -d= -f2- | tr -d '"')
      
      if [[ -n "$val" ]]; then
        printf '%s\n' "$val"
        return 0
      else
        return 1
      fi
      ;;
      
    exists)
      [[ -f "$config_file" ]] && grep -qE "^${key}=" "$config_file" 2>/dev/null
      return $?
      ;;
      
    equals)
      if [[ ! -f "$config_file" ]]; then
        return 1
      fi
      
      local val
      val=$(grep -E "^${key}=" "$config_file" 2>/dev/null | cut -d= -f2- | tr -d '"')
      [[ "$val" == "$value" ]]
      return $?
      ;;
      
    set)
      # Validate key format
      if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "ERROR: Invalid key format: $key" >&2
        return 2
      fi
      
      # Ensure config directory exists
      local config_dir
      config_dir="$(dirname "$config_file")"
      if [[ ! -d "$config_dir" ]]; then
        mkdir -p "$config_dir" || return 3
      fi
      
      # Read existing config into associative array
      declare -A config
      if [[ -f "$config_file" ]]; then
        while IFS='=' read -r k v; do
          [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
          v="${v#"${v%%[![:space:]]*}"}"
          v="${v%"${v##*[![:space:]]}"}"
          [[ "$v" == \"*\" ]] && v="${v%\"}" && v="${v#\"}"
          config["$k"]="$v"
        done < "$config_file"
      fi
      
      # Update key and timestamp
      config["$key"]="$value"
      config["UPDATED"]="$(make_timestamp)"
      
      # Write configuration file
      {
        echo "# Auto-generated host config"
        echo "# MAC: $_host_mac"
        for k in $(printf '%s\n' "${!config[@]}" | LC_ALL=C sort); do
          local v="${config[$k]//\"/\\\"}"
          printf '%s="%s"\n' "$k" "$v"
        done
      } > "$config_file" || return 3
      
      # Log after write completes (use original MAC format for display)
      hps_log info "[$_host_mac] host_config updated: $key = $value"
      
      return 0
      ;;

    # In host_config function, add this case:
      unset|delete)
      if [[ ! -f "$config_file" ]]; then
        return 0  # Already doesn't exist
      fi
      
      # Remove the key from the file
      local temp_file="${config_file}.tmp"
      grep -v "^${key}=" "$config_file" > "$temp_file" 2>/dev/null
      
      # Update timestamp
      echo "UPDATED=\"$(make_timestamp)\"" >> "$temp_file"
      
      mv "$temp_file" "$config_file"
      hps_log info "[$_host_mac] host_config removed: $key"
      return 0
      ;;

      
    *)
      echo "ERROR: Invalid host_config command: $cmd" >&2
      return 2
      ;;
  esac
}

#===============================================================================
# get_host_mac_by_keyvalue
# -------------------------
# Find host MAC address by searching for key/value pair
#
# Behaviour:
#   - Searches all host configs for matching key=value
#   - Returns MAC address (filename) of matching host
#   - Case-insensitive for both key and value
#
# Parameters:
#   $1: Key to search for (e.g., "hostname", "ip", "storage0_ip")
#   $2: Value to match
#
# Returns:
#   0 on success (echoes MAC address)
#   1 if not found
#
# Example usage:
#   mac=$(get_host_mac_by_keyvalue "hostname" "tch-001")
#   mac=$(get_host_mac_by_keyvalue "ip" "10.99.1.8")
#   mac=$(get_host_mac_by_keyvalue "storage0_ip" "10.31.0.100")
#===============================================================================
get_host_mac_by_keyvalue() {
  local search_key="${1^^}"  # uppercase for case-insensitive match
  local search_value="${2,,}"  # lowercase for case-insensitive match
  
  if [[ -z "$search_key" ]] || [[ -z "$search_value" ]]; then
    return 1
  fi
  
  local host_dir="$(get_active_cluster_hosts_dir)"
  [[ ! -d "$host_dir" ]] && return 1
  
  for host_file in "$host_dir"/*.conf; do
    [[ ! -f "$host_file" ]] && continue
    
    # Search for key=value pattern (case-insensitive)
    while IFS='=' read -r key value; do
      # Skip comments and empty lines
      [[ "$key" =~ ^#.*$ ]] || [[ -z "$key" ]] && continue
      
      # Clean up quotes if present
      value="${value//\"/}"
      
      # Case-insensitive comparison
      if [[ "${key^^}" == "$search_key" ]] && [[ "${value,,}" == "$search_value" ]]; then
        # Extract MAC from filename
        local filename=$(basename "$host_file" .conf)
        echo "$filename"
        return 0
      fi
    done < "$host_file"
  done
  
  return 1
}

#===============================================================================
# get_all_hosts_by_keyvalue
# --------------------------
# Find all host MAC addresses matching a key/value pair
#
# Behaviour:
#   - Similar to get_host_mac_by_keyvalue but returns all matches
#   - Useful for finding all hosts with same property
#
# Parameters:
#   $1: Key to search for
#   $2: Value to match
#
# Returns:
#   0 if any found (echoes all MACs, one per line)
#   1 if none found
#
# Example usage:
#   macs=$(get_all_hosts_by_keyvalue "type" "TCH")
#===============================================================================
get_all_hosts_by_keyvalue() {
  local search_key="${1^^}"
  local search_value="${2,,}"
  local found=0
  
  if [[ -z "$search_key" ]] || [[ -z "$search_value" ]]; then
    return 1
  fi
  
  local host_dir="$(get_active_cluster_hosts_dir)"
  [[ ! -d "$host_dir" ]] && return 1
  
  for host_file in "$host_dir"/*.conf; do
    [[ ! -f "$host_file" ]] && continue
    
    while IFS='=' read -r key value; do
      [[ "$key" =~ ^#.*$ ]] || [[ -z "$key" ]] && continue
      
      value="${value//\"/}"
      
      if [[ "${key^^}" == "$search_key" ]] && [[ "${value,,}" == "$search_value" ]]; then
        local filename=$(basename "$host_file" .conf)
        echo "$filename"
        found=1
        break
      fi
    done < "$host_file"
  done
  
  return $((found ? 0 : 1))
}


#:name: has_sch_host
#:group: cluster
#:synopsis: Check if the active cluster has any SCH (Storage/Compute Host) hosts.
#:usage: has_sch_host
#:description:
#  Checks if at least one host in the active cluster is configured with TYPE=SCH.
#  Uses get_cluster_host_hostnames to check for SCH type hosts.
#:returns:
#  0 if at least one SCH host exists
#  1 if no SCH hosts found or cluster cannot be determined
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






