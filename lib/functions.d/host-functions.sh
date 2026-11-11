
# The host_config compatibility alias (host_config -> host_registry) is defined
# once, canonically, in lib/hps-registry.sh alongside host_registry. It was
# previously duplicated here identically; removed to keep a single definition.

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
#   - Uses the host's own os_id key when set and present in the OS registry
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

  # An explicit per-host os_id (written by hps-onboard assign) wins over the
  # cluster-wide os_<type>_<arch> default; TYPE may be a comma list there.
  local host_os_id
  host_os_id=$(host_registry "$mac" get os_id 2>/dev/null) || host_os_id=""
  if [[ -n "$host_os_id" ]] && os_registry "$host_os_id" exists; then
    echo "$host_os_id"
    return 0
  fi
  
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
  local cluster
  cluster=$(hps_get_config active_cluster) || {
    hps_log error "[get_host_os_id] No active cluster"
    return 1
  }
  local os_key="os_$(echo $host_type | tr '[:upper:]' '[:lower:]')_${arch}"
  local os_id=$(cluster_registry "$cluster" get "$os_key")
  
  # Fallback to non-architecture-specific if not found
  if [[ -z "$os_id" ]]; then
    os_key="os_$(echo $host_type | tr '[:upper:]' '[:lower:]')"
    os_id=$(cluster_registry "$cluster" get "$os_key")
    
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
# Behaviour:
#   - Creates new host registry entry
#   - Sets initial STATE to UNCONFIGURED
#   - Sets architecture
#   - Sets initialised_at timestamp
#   - Fails if host already exists
#
# Parameters:
#   mac  - MAC address of the host
#   arch - Architecture (e.g., x86_64)
#   state - initial STATE (optional, default UNCONFIGURED; unknown MACs at boot
#           are registered HELD)
#
# Returns:
#   0 on success
#   1 if MAC not provided
#   2 if host already exists
#   3 if initialization fails
#
# Example usage:
#   host_initialise_config "00:11:22:33:44:55" "x86_64"
#
#===============================================================================
host_initialise_config() {
  local mac="$1"
  local arch="$2"
  local state="${3:-UNCONFIGURED}"
  
  if [[ -z "${mac}" ]]; then
    hps_log error "MAC address not provided"
    return 1
  fi
  
  if [[ -z "${arch}" ]]; then
    hps_log error "Architecture not provided"
    return 1
  fi
  
  # Check if host already exists
  if host_registry "${mac}" exists; then
    hps_log warning "Host already exists: ${mac}"
    return 2
  fi
  
  hps_log info "Initialising new host: ${mac} (${arch})"
  
  # Set initial values
  if ! host_registry "${mac}" set STATE "${state}"; then
    hps_log error "Failed to set STATE for: ${mac}"
    return 3
  fi
  
  if ! host_registry "${mac}" set arch "${arch}"; then
    hps_log error "Failed to set arch for: ${mac}"
    return 3
  fi
  
  if ! host_registry "${mac}" set initialised_at "$(date -Iseconds)"; then
    hps_log error "Failed to set initialised_at for: ${mac}"
    return 3
  fi
  
  hps_log info "Host initialised: ${mac}"
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
# Behaviour:
#   - Removes entire host registry using host_registry destroy
#   - Logs deletion for audit purposes
#
# Parameters:
#   mac - MAC address of the host
#
# Returns:
#   0 on success (registry deleted)
#   1 if MAC not provided or registry does not exist
#   3 if deletion fails or lock timeout
#
# Example usage:
#   host_config_delete "00:11:22:33:44:55"
#
#===============================================================================
host_config_delete() {
  local mac="$1"
  
  if [[ -z "${mac}" ]]; then
    hps_log error "host_config_delete: MAC address not provided"
    return 1
  fi
  
  # Check if host registry exists
  if ! host_registry "${mac}" exists; then
    hps_log warning "[${mac}] Host registry not found"
    return 1
  fi
  
  # Destroy the host registry
  if host_registry "${mac}" destroy; then
    hps_log info "[${mac}] Deleted host registry"
    return 0
  else
    local rc=$?
    hps_log error "[${mac}] Failed to delete registry (error code: ${rc})"
    return ${rc}
  fi
}


#===============================================================================
# _find_available_ip
# ------------------
# Find a free address in the cluster's static pool.
#
# Usage:
#   _find_available_ip <mac> <static_start> <static_end> [reserved] [ips_ip]
#
# Parameters:
#   mac           - MAC address of host (its own current IP stays allocatable)
#   static_start  - first address of the static pool (network_static_start)
#   static_end    - last address of the static pool (network_static_end)
#   reserved      - space-separated addresses to skip (network_reserved)
#   ips_ip        - IPS address, skipped even if the pool were to contain it
#
# Skips reserved addresses and every IP already in a host registry. There is
# no fallback outside the pool: a missing or invalid pool, or a full one, logs
# an error and returns 1 with no output.
#
# Returns:
#   0 on success (outputs IP to stdout)
#   1 if the pool is invalid or exhausted
#===============================================================================
_find_available_ip() {
  local mac="$1"
  local static_start="${2:-}"
  local static_end="${3:-}"
  local reserved="${4:-}"
  local ips_ip="${5:-}"

  if [[ -z "$static_start" || -z "$static_end" ]]; then
    hps_log error "[$mac] static pool not declared (network_static_start/_end unset); re-run cluster-bootstrap with --static-range"
    return 1
  fi

  local start_int end_int
  start_int=$(ip_to_int "$static_start" 2>/dev/null) || start_int=""
  end_int=$(ip_to_int "$static_end" 2>/dev/null) || end_int=""
  if [[ -z "$start_int" || -z "$end_int" ]] || (( start_int > end_int )); then
    hps_log error "[$mac] static pool $static_start-$static_end is invalid"
    return 1
  fi

  # Get all currently assigned IPs
  local assigned_ips
  assigned_ips=$(get_cluster_host_ips 2>/dev/null) || assigned_ips=""

  # Get current host's IP if it already has one
  local current_host_ip
  current_host_ip=$(host_registry "$mac" get IP 2>/dev/null) || current_host_ip=""

  local n try_ip skip existing_ip r
  for ((n=start_int; n<=end_int; n++)); do
    try_ip=$(int_to_ip "$n" 2>/dev/null) || continue
    [[ -z "$try_ip" ]] && continue
    [[ -n "$ips_ip" && "$try_ip" == "$ips_ip" ]] && continue

    skip=0
    for r in $reserved; do
      [[ "$r" == "$try_ip" ]] && skip=1
    done
    [[ $skip -eq 1 ]] && continue

    # In use by another host (its own current IP is fine: reconfiguring)
    while IFS= read -r existing_ip; do
      [[ -z "$existing_ip" ]] && continue
      if [[ "$existing_ip" == "$try_ip" && "$current_host_ip" != "$try_ip" ]]; then
        skip=1
        break
      fi
    done <<< "$assigned_ips"
    [[ $skip -eq 1 ]] && continue

    echo "$try_ip"
    return 0
  done

  hps_log error "[$mac] static pool $static_start-$static_end exhausted (reserved: ${reserved:-none})"
  return 1
}

#===============================================================================
# fqdn_join / host_fqdn / cluster_dns_domain
# ------------------------------------------
# The one hostname rule (docs/NAMING.md): a host's identity everywhere (kernel
# hostname, om3 node name, ctrl-exec agent name, iSCSI IQN) is the FQDN
# <label>.<cluster dns domain>. The registry keeps the label (HOSTNAME); the
# FQDN is derived here and nowhere else on the IPS.
#
#   fqdn_join <name> [domain]   <first label of name, lower case>.<domain>; the
#                               label alone when the domain is empty. Returns 1
#                               (message on stderr) for an unusable label or
#                               domain, or an FQDN over 63 characters (om3's
#                               node-name cap).
#   cluster_dns_domain [cluster] the cluster's network_dns_domain, empty when
#                               unset or not a usable domain (active cluster
#                               when none is named)
#   host_fqdn <mac>             fqdn_join of the host's HOSTNAME and its
#                               cluster's domain. Returns 1 when the host has no
#                               HOSTNAME or the FQDN is refused.
#===============================================================================
fqdn_join() {
  local label="${1%%.*}"
  local domain="${2:-}"
  local name
  label="${label,,}"
  domain="${domain,,}"
  if [[ ! "$label" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    echo "fqdn_join: '${1:-}' has no usable host label" >&2
    return 1
  fi
  if [[ -n "$domain" && ! "$domain" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
    echo "fqdn_join: '${domain}' is not a usable DNS domain" >&2
    return 1
  fi
  name="$label"
  if [[ -n "$domain" ]]; then
    name="${label}.${domain}"
  fi
  if [[ ${#name} -gt 63 ]]; then
    echo "fqdn_join: ${name} is ${#name} characters; the limit is 63 (om3 node names). Use a shorter cluster DNS domain." >&2
    return 1
  fi
  printf '%s\n' "$name"
}

cluster_dns_domain() {
  local cluster="${1:-}" domain
  if [[ -z "$cluster" ]]; then
    cluster=$(hps_get_config active_cluster 2>/dev/null) || cluster=""
  fi
  [[ -n "$cluster" ]] || return 0
  domain=$(cluster_registry "$cluster" get network_dns_domain 2>/dev/null) || domain=""
  domain="${domain//\"/}"
  domain="${domain,,}"
  if [[ "$domain" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
    printf '%s\n' "$domain"
  fi
  return 0
}

host_fqdn() {
  local mac="${1:?Usage: host_fqdn <mac>}" name domain
  name=$(host_registry "$mac" get HOSTNAME 2>/dev/null) || name=""
  if [[ -z "$name" ]]; then
    return 1
  fi
  domain=$(cluster_dns_domain)
  fqdn_join "$name" "$domain"
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
  # TYPE may be a comma list (SCH,TCH): the name prefix is the first element.
  hosttype="${hosttype%%,*}"
  local hosttype_lower=$(echo "$hosttype" | tr '[:upper:]' '[:lower:]')
  local next_number=1
  
  # Get all existing hostnames of this type
  local existing_hostnames
  existing_hostnames=$(get_cluster_host_hostnames "" "" 2>/dev/null)
  
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

  local hosttype
  hosttype=$(host_registry "$macid" get TYPE 2>/dev/null)

  local cluster
  cluster=$(hps_get_config active_cluster) || {
    hps_log error "No active cluster configured"
    return 1
  }
  
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
  local dhcp_ip network_cidr static_start static_end reserved
  dhcp_ip=$(cluster_registry "$cluster" get network_dhcp_ip 2>/dev/null)
  network_cidr=$(cluster_registry "$cluster" get network_cidr 2>/dev/null)
  static_start=$(cluster_registry "$cluster" get network_static_start 2>/dev/null) || static_start=""
  static_end=$(cluster_registry "$cluster" get network_static_end 2>/dev/null) || static_end=""
  reserved=$(cluster_registry "$cluster" get network_reserved 2>/dev/null) || reserved=""

  hps_log debug "Configuring with network $network_cidr"

  # Validate cluster config
  if [[ -z "$dhcp_ip" ]] || [[ -z "$network_cidr" ]]; then
    hps_log error "Missing required cluster network configuration"
    return 1
  fi
  
  if ! validate_ip_address "$dhcp_ip" 2>/dev/null; then
    hps_log error "Invalid network_dhcp_ip: $dhcp_ip"
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
    assigned_ip=$(_find_available_ip "$macid" "$static_start" "$static_end" "$reserved" "$dhcp_ip") || assigned_ip=""
    
    if [[ -z "$assigned_ip" ]]; then
      hps_log error "[$macid] no static address available (pool ${static_start:-unset}-${static_end:-unset})"
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

  # One hostname rule: the FQDN <hostname>.<cluster dns domain> must be usable
  # (om3 refuses node names over 63 characters). Refuse before anything is written.
  fqdn_join "$assigned_hostname" "$(cluster_dns_domain)" > /dev/null || {
    hps_log error "[$macid] $assigned_hostname plus the cluster DNS domain is not a usable host name (63 character limit); not configuring"
    return 1
  }
  
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
  
  # Rebuild DHCP/DNS files now rather than waiting for the next service start.
  # host_post_config_hooks maps IP and HOSTNAME to update_dns_dhcp_files (one
  # full rebuild, so one call covers both). A failure is logged and never
  # aborts the boot script.
  host_post_config_hooks IP "$assigned_ip" || \
    hps_log warn "host_post_config_hooks failed for $macid (continuing)"

  hps_log info "Network configuration complete for $macid: $assigned_hostname ($assigned_ip)"
  return 0
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


#===============================================================================
# The MAC index (IPS-15)
# ----------------------
# A host is stored under the MAC it first booted from (the host key). The host
# key `macs` lists every physical NIC MAC its audit found. The index maps each
# of those MACs, and each host key, to its host. It is computed from the
# registry when asked (a scan of the hosts; the exact-key case needs no scan)
# and never stored, so forgetting a host frees its MACs. Every caller that has
# a MAC off the wire goes through host_resolve_mac; none reads hosts/<mac>.db
# from a raw MAC. The Perl twin is HPS::Registry->resolve_mac.
#===============================================================================

#===============================================================================
# host_macs_of
# ------------
# The MACs of one host, 12 lower-case hex, one per line: the host key first,
# then the recorded `macs` in order, no repeats.
#
# Parameters:
#   $1 - host key (any MAC form)
#===============================================================================
host_macs_of() {
  local key norm json
  key="${1:-}"
  norm=$(normalise_mac "$key") || return 1
  printf '%s\n' "$norm"
  json=$(host_registry "$norm" get macs 2> /dev/null) || return 0
  [[ -n "$json" ]] || return 0
  jq -r '.[]? | (if type == "object" then .mac else . end) // empty
         | ascii_downcase | gsub("[^0-9a-f]"; "") | select(length == 12)' <<< "$json" 2> /dev/null \
    | awk -v k="$norm" '$0 != k && !seen[$0]++' || true
}

#===============================================================================
# host_mac_owner
# --------------
# The host key of the host that lists a MAC among its recorded `macs` (a MAC
# that is itself a host key is not looked up here; see host_resolve_mac).
#
# Parameters:
#   $1 - MAC, 12 hex
#
# Returns: 0 and the key, 1 when no host lists it
#===============================================================================
host_mac_owner() {
  local want="${1:-}" h
  while IFS= read -r h; do
    [[ -n "$h" ]] || continue
    if host_macs_of "$h" | grep -qx -- "$want"; then
      printf '%s\n' "$h"
      return 0
    fi
  done < <(host_registry list_all 2> /dev/null)
  return 1
}

#===============================================================================
# host_resolve_mac
# ----------------
# The MAC to use for registry calls for a MAC seen on the wire.
#   - a MAC that is a host key: printed as given (no scan)
#   - a MAC recorded under another host: that host's key, 12 hex
#   - an unknown MAC, or text that is not a MAC (an IP tag): printed as given,
#     so an unknown MAC still becomes a new HELD host
# A MAC is never moved between hosts: this only reads.
#
# Parameters:
#   $1 - MAC in any form
#
# Returns: 0 known (host key or recorded port), 1 unknown, 2 not a MAC
#===============================================================================
host_resolve_mac() {
  local mac="${1:-}" norm owner
  norm=$(normalise_mac "$mac" 2> /dev/null) || {
    printf '%s\n' "$mac"
    return 2
  }
  if host_registry "$norm" exists; then
    printf '%s\n' "$mac"
    return 0
  fi
  if owner=$(host_mac_owner "$norm") && [[ -n "$owner" ]]; then
    printf '%s\n' "$owner"
    return 0
  fi
  printf '%s\n' "$mac"
  return 1
}

#===============================================================================
# host_mac_conflicts
# ------------------
# Which of the given MACs another host already holds, as its key or among its
# recorded MACs. One "<mac> <owner key>" line each; no output means no clash.
#
# Parameters:
#   $1   - host key of the host that wants the MACs
#   $2.. - MACs, 12 hex
#===============================================================================
host_mac_conflicts() {
  local self m owner
  self=$(normalise_mac "${1:-}") || return 1
  shift
  for m in "$@"; do
    [[ "$m" == "$self" ]] && continue
    if host_registry "$m" exists; then
      printf '%s %s\n' "$m" "$m"
    elif owner=$(host_mac_owner "$m") && [[ "$owner" != "$self" ]]; then
      printf '%s %s\n' "$m" "$owner"
    fi
  done
  return 0
}

#===============================================================================
# host_audit_macs
# ---------------
# The physical NIC MACs of an audit, as the JSON array stored in the host key
# `macs`: [{mac (colons), ifname, driver, speed}], the host key's MAC first.
#
# Which interfaces count: the loopback never; a virtual interface (veth,
# bridge, bond, vlan, tap, dummy, ...) never. The audit's net.nics (hps-audit
# collect_nics) says which are real: `physical` is true when the interface has
# a bus device behind it. Locally administered addresses are NOT dropped by
# their address bit: a VM's virtio NIC (52:54:00:...) has that bit set and is
# the machine's real NIC, so a real device decides. An older audit without
# net.nics is read from net.link by interface name and enslavement.
#
# Parameters:
#   $1 - audit JSON file
#   $2 - host key (its MAC is listed first when it is among the NICs)
#===============================================================================
host_audit_macs() {
  local file="${1:?}" key="${2:?}"
  jq -c --arg key "$key" '
    def norm: ascii_downcase | gsub("[^0-9a-f]"; "");
    def colons: [match(".."; "g").string] | join(":");
    def virt: test("^(lo|veth|br|bond|vlan|tap|tun|docker|virbr|vnet|dummy|ifb|macvlan|ipvlan|vxlan|gre|sit|wg|nlmon)") or test("[.]");
    (if (.net.nics | type) == "array"
       then [.net.nics[] | select(.physical == true)
             | {mac: .mac, ifname: .ifname, driver: (.driver // null), speed: (.speed // null)}]
       else [(.net.link // [])[] | select(.link_type == "ether" and ((.ifname // "") | virt | not) and (.master == null))
             | {mac: .address, ifname: .ifname, driver: null, speed: null}]
     end)
    | map(select((.mac | type) == "string" and ((.mac | norm | length) == 12) and ((.mac | norm) != "000000000000")))
    | map(.mac |= (norm | colons))
    | reduce .[] as $x ([]; if any(.[]; .mac == $x.mac) then . else . + [$x] end)
    | (map(select((.mac | norm) == $key))) + (map(select((.mac | norm) != $key)))' "$file"
}

#===============================================================================
# host_audit_refuse
# -----------------
# Refuse a node_audit request: HTTP status line, plain-text message, log line.
#
# Parameters:
#   $1 - status, e.g. "403 Forbidden"
#   $2 - message
#===============================================================================
host_audit_refuse() {
  local status="$1"
  local msg="$2"
  echo "Status: ${status}"
  cgi_fail "node_audit refused: ${msg}"
}

#===============================================================================
# host_bmc_select
# ---------------
# After an audit is stored: let the controller pick the BMC driver from it
# (hps-bmc select, IPS-08). An operator choice is kept by hps-bmc itself. A
# failure is logged and never fails the audit intake.
#
# Parameters:
#   $1 - MAC of the host
#===============================================================================
host_bmc_select() {
  local mac="${1:-}"
  local bin="${HPS_BMC_BIN:-${HPS_SYSTEM_BASE:-}/bin/hps-bmc}"
  [[ -x "$bin" ]] || return 0
  if ! "$bin" select "$mac" > /dev/null 2>&1; then
    hps_log warn "[$mac] BMC driver selection from the audit failed (hps-bmc select)"
  fi
  return 0
}

#===============================================================================
# host_audit_intake
# -----------------
# Receive a hardware audit (schema hps-audit/1) POSTed by a held node.
#
# Behaviour:
#   - POST only; body read up to HPS_AUDIT_MAX_BYTES (default 262144)
#   - body must be JSON with .schema == "hps-audit/1"
#   - the caller (MAC) must exist and be STATE=HELD
#   - refuses (409) when a NIC MAC of the audit is held by another host
#   - stores the JSON as host key "audit", the time as "audit_at" and the NIC
#     MACs as "macs" (host_audit_macs)
#   - replies "ok" (plain text)
#
# Parameters:
#   $1 - MAC of the caller
#
# Returns:
#   0 stored, 1 refused
#===============================================================================
host_audit_intake() {
  local mac="${1:-}"
  local max="${HPS_AUDIT_MAX_BYTES:-262144}"
  local tmp="/tmp/hps-audit-in-$$"
  local size state schema detail key macs_json conflicts
  local -a macs12

  if [[ "${REQUEST_METHOD:-}" != "POST" ]]; then
    host_audit_refuse "405 Method Not Allowed" "POST required"
    return 1
  fi

  if [[ -z "$mac" ]] || ! host_registry "$mac" exists; then
    hps_log warn "node_audit refused: unknown caller '${mac}'"
    host_audit_refuse "403 Forbidden" "caller is not a known host"
    return 1
  fi
  state="$(host_registry "$mac" get STATE 2>/dev/null)" || state=""
  if [[ "$state" != "HELD" ]]; then
    hps_log warn "[$mac] node_audit refused: STATE is '${state}', not HELD"
    host_audit_refuse "403 Forbidden" "host is not held"
    return 1
  fi

  if [[ "${CONTENT_LENGTH:-}" =~ ^[0-9]+$ ]] && (( CONTENT_LENGTH > max )); then
    hps_log warn "[$mac] node_audit refused: Content-Length ${CONTENT_LENGTH} over ${max}"
    host_audit_refuse "413 Payload Too Large" "body over ${max} bytes"
    return 1
  fi
  head -c $((max + 1)) > "$tmp"
  size="$(wc -c < "$tmp")"
  if (( size > max )); then
    rm -f "$tmp"
    hps_log warn "[$mac] node_audit refused: body over ${max} bytes"
    host_audit_refuse "413 Payload Too Large" "body over ${max} bytes"
    return 1
  fi

  schema="$(jq -r '.schema // empty' "$tmp" 2>/dev/null)" || schema=""
  if [[ "$schema" != "hps-audit/1" ]]; then
    rm -f "$tmp"
    hps_log warn "[$mac] node_audit refused: bad or missing schema"
    host_audit_refuse "400 Bad Request" "body is not an hps-audit/1 document"
    return 1
  fi

  key="$(normalise_mac "$mac")" || key="$mac"
  macs_json="$(host_audit_macs "$tmp" "$key" 2> /dev/null)" || macs_json="[]"
  mapfile -t macs12 < <(jq -r '.[].mac | gsub(":"; "")' <<< "$macs_json" 2> /dev/null)
  conflicts="$(host_mac_conflicts "$key" "${macs12[@]}")"
  if [[ -n "$conflicts" ]]; then
    rm -f "$tmp"
    hps_log warn "[$mac] node_audit refused: MAC already held by another host: ${conflicts//$'\n'/; } (hps-onboard forget the other host to free it)"
    host_audit_refuse "409 Conflict" "a MAC of this machine is held by another host: ${conflicts//$'\n'/; }"
    return 1
  fi

  detail="$(jq -r '"controllers=" + ((.storage_controllers.scsi_hosts // []) | map(.hba_mode_enabled | tostring) | join(",") | if . == "" then "none" else . end) + " disks=" + ([.block.blockdevices[]? | select(.type == "disk")] | length | tostring)' "$tmp" 2>/dev/null)" || detail=""
  if ! host_registry "$mac" set audit "$(cat "$tmp")"; then
    rm -f "$tmp"
    hps_log error "[$mac] node_audit: could not store the audit"
    host_audit_refuse "500 Internal Server Error" "could not store the audit"
    return 1
  fi
  rm -f "$tmp"
  host_registry "$mac" set audit_at "$(make_timestamp)"
  # a new audit clears the stale mark set by hps-onboard reaudit (IPS-14)
  host_registry "$mac" delete audit_stale > /dev/null 2>&1 || true
  host_registry "$mac" set macs "$macs_json" || hps_log warn "[$mac] node_audit: could not store the MAC list"
  host_bmc_select "$mac"
  hps_log info "[$mac] node_audit stored: ${size} bytes ${detail} (hba_mode_enabled per controller)"
  cgi_success "ok"
  return 0
}

#===============================================================================
# host_init_refuse
# ----------------
# Refuse a host_init_result request: HTTP status line, plain-text message.
#
# Parameters:
#   $1 - status, e.g. "403 Forbidden"
#   $2 - message
#===============================================================================
host_init_refuse() {
  local status="$1"
  local msg="$2"
  echo "Status: ${status}"
  cgi_fail "host_init_result refused: ${msg}"
}

#===============================================================================
# host_init_normalise
# -------------------
# Validate an init result body and print the stored form: only the known
# fields, steps as {name, rc, seconds, message}, plus received_at. The pin is
# the node's claim, else the host's system_pin.
#
# Parameters:
#   $1 - file holding the body
#   $2 - received_at text
#   $3 - fallback pin
#
# Returns:
#   0 normalised JSON on stdout, 1 body is not a valid init result
#===============================================================================
host_init_normalise() {
  local file="$1" received="$2" fallback_pin="$3"
  jq -e -c --arg rcv "$received" --arg fpin "$fallback_pin" '
    if (type == "object") and ((.steps // null) | type == "array")
       and (.steps | all(.[]; (type == "object") and (.name | type == "string")
            and (.rc | type == "number") and (.rc == (.rc | floor))))
    then {
      boot_id: ((.boot_id // "") | tostring),
      pin: (if ((.pin // "") | tostring) == "" then $fpin else (.pin | tostring) end),
      started_at: ((.started_at // "") | tostring),
      finished_at: ((.finished_at // "") | tostring),
      received_at: $rcv,
      steps: [.steps[] | {name: .name, rc: .rc,
                          seconds: ((.seconds // 0) | if type == "number" then . else 0 end),
                          message: ((.message // "") | tostring)}]
    } else empty end' "$file" 2>/dev/null
}

#===============================================================================
# host_init_intake
# ----------------
# Receive the init result a node POSTs at the end of n_init_run
# (cmd=host_init_result).
#
# Behaviour:
#   - POST only; body read up to HPS_INIT_RESULT_MAX_BYTES (default 8192)
#   - the caller (MAC from the connection) must be a known host; an
#     X-HPS-MAC header naming another MAC is refused (403)
#   - body must be JSON {boot_id, pin, started_at, finished_at, steps[]}
#   - stores host key init_result, moves the previous one to init_result_prev,
#     sets init_ok to true (every step rc 0) or false
#   - replies "ok" (plain text)
#
# Parameters:
#   $1 - MAC of the caller
#
# Returns:
#   0 stored, 1 refused
#===============================================================================
host_init_intake() {
  local mac="${1:-}"
  local max="${HPS_INIT_RESULT_MAX_BYTES:-8192}"
  local tmp="/tmp/hps-init-in-$$"
  local claim="${HTTP_X_HPS_MAC:-}"
  local size pin stored prev ok nfail failed

  if [[ "${REQUEST_METHOD:-}" != "POST" ]]; then
    host_init_refuse "405 Method Not Allowed" "POST required"
    return 1
  fi

  if [[ -z "$mac" ]] || ! host_registry "$mac" exists; then
    hps_log warn "host_init_result refused: unknown caller '${mac}'"
    host_init_refuse "403 Forbidden" "caller is not a known host"
    return 1
  fi
  if [[ -n "$claim" && "${claim,,}" != "${mac,,}" ]]; then
    hps_log warn "[$mac] host_init_result refused: X-HPS-MAC names ${claim}"
    host_init_refuse "403 Forbidden" "MAC is not the caller's"
    return 1
  fi

  if [[ "${CONTENT_LENGTH:-}" =~ ^[0-9]+$ ]] && (( CONTENT_LENGTH > max )); then
    hps_log warn "[$mac] host_init_result refused: Content-Length ${CONTENT_LENGTH} over ${max}"
    host_init_refuse "413 Payload Too Large" "body over ${max} bytes"
    return 1
  fi
  head -c $((max + 1)) > "$tmp"
  size="$(wc -c < "$tmp")"
  if (( size > max )); then
    rm -f "$tmp"
    hps_log warn "[$mac] host_init_result refused: body over ${max} bytes"
    host_init_refuse "413 Payload Too Large" "body over ${max} bytes"
    return 1
  fi

  pin="$(host_registry "$mac" get system_pin 2>/dev/null)" || pin=""
  pin="${pin//\"/}"
  if ! stored="$(host_init_normalise "$tmp" "$(make_timestamp)" "$pin")"; then
    rm -f "$tmp"
    hps_log warn "[$mac] host_init_result refused: not a valid init result"
    host_init_refuse "400 Bad Request" "body is not a valid init result"
    return 1
  fi
  rm -f "$tmp"

  if prev="$(host_registry "$mac" get init_result 2>/dev/null)" && [[ -n "$prev" ]]; then
    host_registry "$mac" set init_result_prev "$prev"
  fi
  if ! host_registry "$mac" set init_result "$stored"; then
    hps_log error "[$mac] host_init_result: could not store the result"
    host_init_refuse "500 Internal Server Error" "could not store the result"
    return 1
  fi
  nfail="$(jq -r '[.steps[] | select(.rc != 0)] | length' <<< "$stored")"
  failed="$(jq -r '[.steps[] | select(.rc != 0) | .name] | join(", ")' <<< "$stored")"
  ok=true
  (( nfail > 0 )) && ok=false
  host_registry "$mac" set init_ok "$ok"
  if [[ "$ok" == true ]]; then
    hps_log info "[$mac] host_init_result stored: ${size} bytes, all steps ok"
  else
    hps_log error "[$mac] host_init_result stored: ${nfail} step(s) failed: ${failed}"
  fi
  cgi_success "ok"
  return 0
}
