__guard_source || return
# Define your functions below


host_initialise_config() {
  local mac="$1"
  local config_file="${HPS_HOST_CONFIG_DIR}/${mac}.conf"

  mkdir -p "${HPS_HOST_CONFIG_DIR}"

  host_config "$mac" set STATE "UNCONFIGURED"

#  local created_ts
#  created_ts=$(make_timestamp)

#  cat > "$config_file" <<EOF
## Host config generated automatically
## MAC: $mac
#STATE=UNCONFIGURED
#CREATED="$created_ts"
#EOF

  hps_log info "[$mac] Initialised host config: $config_file"
# commented out as this creates error on first boot when called from boot manager which needs no output 
#  echo "$config_file"

}

get_active_cluster_hosts_dir () {
  echo "$(get_active_cluster_link_path)/hosts"
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



#:name: host_network_configure
#:group: network
#:synopsis: Assign IP address and hostname to a host based on MAC address.
#:usage: host_network_configure <mac> <hosttype>
#:description:
#  Allocates a unique IP address from the DHCP range and generates
#  a unique hostname based on host type. Checks existing host configurations
#  to avoid conflicts. Persists network configuration via host_config.
#  Hostname is generated in lowercase with zero-padded sequential numbering.
#  Uses cluster helper functions to safely enumerate existing hosts.
#:parameters:
#  mac      - MAC address of the host
#  hosttype - Host type prefix for hostname generation (e.g., TCH, ROCKY)
#:returns:
#  0 on success
#  1 if configuration fails or no available IPs/hostnames
host_network_configure() {
  local macid="$1"
  local hosttype="$2"
  
  hps_log debug "host_network_configure called with MAC: $macid, TYPE: $hosttype"
  
  # Validate input parameters
  if [[ -z "$macid" ]]; then
    hps_log error "host_network_configure: MAC address not provided"
    return 1
  fi
  
  if [[ -z "$hosttype" ]]; then
    hps_log error "host_network_configure: Host type not provided"
    return 1
  fi
  
  local dhcp_ip dhcp_rangesize network_cidr netmask
  
  # Get cluster network configuration with error handling
  dhcp_ip=$(cluster_config get DHCP_IP 2>/dev/null) || dhcp_ip=""
  dhcp_rangesize=$(cluster_config get DHCP_RANGESIZE 2>/dev/null) || dhcp_rangesize=""
  network_cidr=$(cluster_config get NETWORK_CIDR 2>/dev/null) || network_cidr=""
  
  hps_log debug "Retrieved cluster config - DHCP_IP: $dhcp_ip, RANGESIZE: $dhcp_rangesize, CIDR: $network_cidr"
  
  if [[ -z "$dhcp_ip" ]]; then
    hps_log error "Missing DHCP_IP in cluster config"
    return 1
  fi
  
  if [[ -z "$dhcp_rangesize" ]]; then
    hps_log error "Missing DHCP_RANGESIZE in cluster config"
    return 1
  fi
  
  if [[ -z "$network_cidr" ]]; then
    hps_log error "Missing NETWORK_CIDR in cluster config"
    return 1
  fi
  
  # Validate DHCP IP
  if ! validate_ip_address "$dhcp_ip" 2>/dev/null; then
    hps_log error "Invalid DHCP_IP in cluster config: $dhcp_ip"
    return 1
  fi
  
  # Calculate netmask from CIDR (handles both formats)
  netmask=$(cidr_to_netmask "$network_cidr" 2>/dev/null) || netmask=""
  if [[ -z "$netmask" ]]; then
    hps_log error "Failed to calculate netmask from NETWORK_CIDR: $network_cidr"
    return 1
  fi
  
  hps_log debug "Calculated netmask: $netmask"
  
  # Find available IP address within DHCP range
  local dhcp_start_int
  dhcp_start_int=$(ip_to_int "$dhcp_ip" 2>/dev/null) || {
    hps_log error "Failed to convert DHCP_IP to integer: $dhcp_ip"
    return 1
  }
  
  hps_log debug "DHCP start IP as integer: $dhcp_start_int"
  
  # Get all currently assigned IPs using cluster helper
  local assigned_ips
  assigned_ips=$(get_cluster_host_ips 2>/dev/null)
  
  # Get current host's IP if it already has one
  local current_host_ip
  current_host_ip=$(host_config "$macid" get IP 2>/dev/null) || current_host_ip=""
  
  local try_ip=""
  local assigned_ip=""
  
  for ((i=0; i<dhcp_rangesize; i++)); do
    try_ip=$(int_to_ip $((dhcp_start_int + i)) 2>/dev/null)
    
    if [[ -z "$try_ip" ]]; then
      hps_log warning "Failed to convert IP integer to address at offset $i"
      continue
    fi
    
    # Skip the DHCP server IP itself
    if [[ "$try_ip" == "$dhcp_ip" ]]; then
      hps_log debug "Skipping DHCP server IP: $try_ip"
      continue
    fi
    
    # Check if this IP is already assigned to another host
    local ip_in_use=0
    local existing_ip
    
    while IFS= read -r existing_ip; do
      [[ -z "$existing_ip" ]] && continue
      if [[ "$existing_ip" == "$try_ip" ]]; then
        # If it's assigned to current host, that's OK (we're reconfiguring)
        if [[ "$current_host_ip" != "$try_ip" ]]; then
          ip_in_use=1
        fi
        break
      fi
    done <<< "$assigned_ips"
    
    # Found an available IP
    if [[ $ip_in_use -eq 0 ]]; then
      assigned_ip="$try_ip"
      hps_log debug "Found available IP: $assigned_ip at offset $i"
      break
    fi
  done
  
  if [[ -z "$assigned_ip" ]]; then
    hps_log error "No available IPs in DHCP range ${dhcp_ip} (size: ${dhcp_rangesize})"
    return 1
  fi
  
  # Validate assigned IP
  if ! validate_ip_address "$assigned_ip" 2>/dev/null; then
    hps_log error "Generated invalid IP address: $assigned_ip"
    return 1
  fi
  
  # Find available hostname with sequential numbering
  local hostname=""
  local hosttype_lower=$(echo "$hosttype" | tr '[:upper:]' '[:lower:]')
  local next_number=1
  
  hps_log debug "Finding available hostname for type: $hosttype_lower"
  
  # Get all existing hostnames of this type using cluster helper
  local existing_hostnames
  existing_hostnames=$(get_cluster_host_hostnames "" "$hosttype_lower" 2>/dev/null)
  
  # Find the highest existing number for this host type
  local existing_hostname
  while IFS= read -r existing_hostname; do
    [[ -z "$existing_hostname" ]] && continue
    
    hps_log debug "Checking existing hostname: $existing_hostname"
    
    # Check if hostname matches our pattern (case-insensitive)
    if [[ "$existing_hostname" =~ ^${hosttype_lower}-([0-9]+)$ ]]; then
      local num="${BASH_REMATCH[1]}"
      # Remove leading zeros for comparison
      if [[ -n "$num" ]] && [[ "$num" =~ ^[0-9]+$ ]]; then
        num=$((10#$num)) || continue
        if [[ $num -ge $next_number ]]; then
          next_number=$((num + 1))
          hps_log debug "Updated next_number to: $next_number"
        fi
      fi
    fi
  done <<< "$existing_hostnames"
  
  hps_log debug "Analyzed existing hostnames, next_number: $next_number"
  
  # Generate hostname with zero-padded number (3 digits)
  hostname=$(printf "%s-%03d" "$hosttype_lower" "$next_number" 2>/dev/null)
  
  if [[ -z "$hostname" ]]; then
    hps_log error "Failed to generate hostname using printf"
    return 1
  fi
  
  hps_log debug "Generated hostname: $hostname"
  
  # Validate generated hostname
  if ! validate_hostname "$hostname" 2>/dev/null; then
    hps_log error "Generated invalid hostname: $hostname"
    return 1
  fi
  
  # Double-check hostname isn't already in use
  local hostname_exists=0
  local check_hostname
  
  existing_hostnames=$(get_cluster_host_hostnames "" "" 2>/dev/null)
  while IFS= read -r check_hostname; do
    [[ -z "$check_hostname" ]] && continue
    if [[ "$check_hostname" == "$hostname" ]]; then
      hostname_exists=1
      break
    fi
  done <<< "$existing_hostnames"
  
  if [[ $hostname_exists -eq 1 ]]; then
    hps_log error "Generated hostname ${hostname} already exists (race condition?)"
    return 1
  fi
  
  if [[ -z "$hostname" ]]; then
    hps_log error "Failed to generate unique hostname for type: ${hosttype}"
    return 1
  fi
  
  hps_log debug "About to set host config for MAC: $macid"
  
  # Assign configuration to host
  host_config "$macid" set IP "$assigned_ip" || {
    hps_log error "Failed to set IP for MAC: $macid"
    return 1
  }
  
  host_config "$macid" set NETMASK "$netmask" || {
    hps_log error "Failed to set NETMASK for MAC: $macid"
    return 1
  }
  
  host_config "$macid" set HOSTNAME "$hostname" || {
    hps_log error "Failed to set HOSTNAME for MAC: $macid"
    return 1
  }
  
  host_config "$macid" set TYPE "$hosttype" || {
    hps_log error "Failed to set TYPE for MAC: $macid"
    return 1
  }
  
  host_config "$macid" set STATE "CONFIGURED" || {
    hps_log error "Failed to set STATE for MAC: $macid"
    return 1
  }
  
  hps_log info "Assigned IP: $assigned_ip to MAC: $macid"
  hps_log info "Assigned Hostname: $hostname to MAC: $macid"
  
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



declare -gA HOST_CONFIG
declare -g __HOST_CONFIG_PARSED=0
declare -g __HOST_CONFIG_FILE=""

#:name: host_config
#:group: host-management
#:synopsis: Manage host configuration key-value storage per MAC address.
#:usage: host_config <mac> <command> [key] [value]
#:description:
#  Parses and manages host configuration from ${HPS_HOST_CONFIG_DIR}/<mac>.conf
#  Supports get, exists, equals, and set operations on host configuration keys.
#  Configuration is cached per MAC address to avoid repeated file parsing.
#:parameters:
#  mac     - MAC address of the host (e.g., 52:54:00:9c:4c:24)
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
  local mac=$1
  local cmd="$2"
  local key="$3"
  local value="${4:-}"
  
  # Track which MAC was parsed to avoid cross-host reuse
  if [[ "${__HOST_CONFIG_PARSED:-0}" -eq 0 || "${__HOST_CONFIG_MAC:-}" != "$mac" ]]; then
    declare -gA HOST_CONFIG=()            # reset map
    __HOST_CONFIG_FILE="${HOST_CONFIG_FILE:-${HPS_HOST_CONFIG_DIR}/${mac}.conf}"
    __HOST_CONFIG_MAC="$mac"
    
    if [[ -f "$__HOST_CONFIG_FILE" ]]; then
      # Accept keys: [A-Za-z_][A-Za-z0-9_]*  (was: uppercase-only)
      # Strip surrounding double quotes if present.
      while IFS='=' read -r k v; do
        [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        # Trim leading/trailing spaces around value
        v="${v#"${v%%[![:space:]]*}"}"
        v="${v%"${v##*[![:space:]]}"}"
        # Strip surrounding "" if present
        [[ "$v" == \"*\" ]] && v="${v%\"}" && v="${v#\"}"
        HOST_CONFIG["$k"]="$v"
      done < "$__HOST_CONFIG_FILE"
    fi
    __HOST_CONFIG_PARSED=1
  fi
  
  case "$cmd" in
    get)
      # prints value if present; rc=0 if found, 1 if missing
      if [[ ${HOST_CONFIG[$key]+_} ]]; then
        printf '%s\n' "${HOST_CONFIG[$key]}"
        return 0
      else
        return 1
      fi
      ;;
    exists)
      [[ ${HOST_CONFIG[$key]+_} ]]
      return $?
      ;;
    equals)
      [[ ${HOST_CONFIG[$key]+_} && "${HOST_CONFIG[$key]}" == "$value" ]]
      return $?
      ;;
    set)
      # Validate key format
      if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        hps_log error "[$mac] Invalid key format: $key"
        return 2
      fi
      
      HOST_CONFIG["$key"]="$value"
      hps_log info "[$mac] host_config update: $key = $value"
      
      local timestamp
      timestamp="$(make_timestamp)"
      HOST_CONFIG["UPDATED"]="$timestamp"
      hps_log info "[$mac] host_config UPDATED = $timestamp"
      
      # Ensure config directory exists
      local config_dir
      config_dir="$(dirname "$__HOST_CONFIG_FILE")"
      if [[ ! -d "$config_dir" ]]; then
        if ! mkdir -p "$config_dir"; then
          hps_log error "[$mac] Failed to create config directory: $config_dir"
          return 3
        fi
      fi
      
      # Write configuration file
      {
        echo "# Auto-generated host config"
        echo "# MAC: $mac"
        # Stable output: sort keys to avoid churn in diffs
        for k in $(printf '%s\n' "${!HOST_CONFIG[@]}" | LC_ALL=C sort); do
          # Escape any embedded double quotes in values
          local v="${HOST_CONFIG[$k]//\"/\\\"}"
          printf '%s="%s"\n' "$k" "$v"
        done
      } > "$__HOST_CONFIG_FILE" || {
        hps_log error "[$mac] Failed to write config file: $__HOST_CONFIG_FILE"
        return 3
      }
      
      return 0
      ;;
    *)
      hps_log error "Invalid host_config command: $cmd"
      return 2
      ;;
  esac
}



has_sch_host() {
  local host_dir="${HPS_HOST_CONFIG_DIR}"

  [[ ! -d "$host_dir" ]] && {
    echo "[x] Host config directory not found: $host_dir" >&2
    return 1
  }

  if grep -q '^TYPE=SCH' "$host_dir"/*.conf 2>/dev/null; then
    return 0  # Found at least one
  else
    return 1  # None found
  fi
}





