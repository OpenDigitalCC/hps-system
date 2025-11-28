

#===============================================================================
# load_cluster_config
# ------------------
# Load active cluster configuration variables into environment.
# Exports each cluster config key as an environment variable.
#
# Usage:
#   load_cluster_config
#
# Returns:
#   0 on success, 1 if no active cluster
#===============================================================================
load_cluster_config() {
  # Check if active cluster exists
  local active_cluster
  active_cluster=$(system_registry get ACTIVE_CLUSTER 2>/dev/null) || return 1
  
  # Load each config key as environment variable
  if cluster_registry list >/dev/null 2>&1; then
    while IFS= read -r key; do
      local value
      value=$(cluster_registry get "$key" 2>/dev/null)
      if [[ -n "$value" && "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        export "${key}=${value}"
      fi
    done < <(cluster_registry list)
  fi
  
  return 0
}


#===============================================================================
# get_active_cluster_name
# -----------------------
# Get the name of the currently active cluster.
#
# Returns:
#   Cluster name via stdout, or non-zero on error.
#===============================================================================
get_active_cluster_name() {
  system_registry get ACTIVE_CLUSTER 2>/dev/null
}

#===============================================================================
# get_cluster_dir
# ----------------
# Return the absolute path to a cluster directory given its name.
#
# Arguments:
#   $1 - Cluster name
#
# Returns:
#   Path via stdout, or non-zero if the name is empty.
#===============================================================================
get_cluster_dir() {
  local cluster_name="$1"
  [[ -z "$cluster_name" ]] && {
    echo "[ERROR] Usage: get_cluster_dir <cluster-name>" >&2
    return 1
  }
  echo "${HPS_CLUSTER_CONFIG_BASE_DIR}/${cluster_name}"
}

#===============================================================================
# get_active_cluster_dir
# ----------------------
# Get the absolute path to the active cluster directory.
#
# Returns:
#   Path via stdout, or non-zero with error message on stderr.
#===============================================================================
get_active_cluster_dir() {
  local cluster_name
  cluster_name=$(get_active_cluster_name) || {
    echo "[ERROR] No active cluster set" >&2
    return 1
  }
  
  local cluster_dir
  cluster_dir=$(get_cluster_dir "$cluster_name") || return 1
  
  if [[ ! -d "$cluster_dir" ]]; then
    echo "[ERROR] Active cluster directory not found: $cluster_dir" >&2
    return 1
  fi
  
  echo "$cluster_dir"
}

#===============================================================================
# get_active_cluster_hosts_dir
# ----------------------------
# Get the hosts directory for the active cluster.
#
# Returns:
#   Path via stdout
#===============================================================================
get_active_cluster_hosts_dir() {
  local cluster_dir
  cluster_dir=$(get_active_cluster_dir) || return 1
  echo "${cluster_dir}/hosts"
}

#===============================================================================
# get_active_cluster_info
# -----------------------
# Print human-readable information about the current cluster context.
#
# Behaviour:
#   - If an active cluster is set, print its name, dir, and selected metadata.
#   - Else, if exactly one real cluster exists, print it as "(Only; not Active)".
#   - Else, print that no active cluster is set and list available clusters.
#
# Metadata fields (queried via cluster_registry):
#   DESCRIPTION, NETWORK_CIDR, DNS_DOMAIN
#
# Returns:
#   0 on success, non-zero if no clusters exist or other error.
#===============================================================================
get_active_cluster_info() {
  local dirs=()
  _collect_cluster_dirs dirs

  if (( ${#dirs[@]} == 0 )); then
    echo "[!] No clusters found in ${HPS_CLUSTER_CONFIG_BASE_DIR}" >&2
    return 1
  fi

  # Helper: print a key via cluster_registry get (skip silently if empty)
  _print_meta() {
    local key="$1" label="$2" val=""
    if val="$(cluster_registry get "$key" 2>/dev/null)"; then
      [[ -n "$val" ]] && echo "${label}: ${val}"
    fi
  }

  # Case 1: Active cluster exists
  local active_name
  if active_name="$(get_active_cluster_name 2>/dev/null)"; then
    local active_dir
    active_dir=$(get_active_cluster_dir 2>/dev/null)
    echo "Cluster: ${active_name} (Active)"
    echo "Directory: ${active_dir}"
    _print_meta "DESCRIPTION"   "Description"
    _print_meta "NETWORK_CIDR"  "Network CIDR"
    _print_meta "DNS_DOMAIN"    "DNS Domain"
    return 0
  fi

  # Case 2: No active; if exactly one cluster, show it
  if (( ${#dirs[@]} == 1 )); then
    local only_dir="${dirs[0]}"
    local only_name
    only_name="$(basename -- "$only_dir")"
    echo "Cluster: ${only_name} (Only; not Active)"
    echo "Config directory: ${only_dir}"
    echo "Description: (unknown; no active cluster)"
    echo "Network CIDR: (unknown; no active cluster)"
    echo "DNS Domain: (unknown; no active cluster)"
    return 0
  fi

  # Case 3: Multiple clusters, none active
  echo "[!] No active cluster set."
  echo "Available clusters:"
  local d n
  for d in "${dirs[@]}"; do
    n="$(basename -- "$d")"
    echo "  - ${n}  (${d})"
  done
  return 0
}

#===============================================================================
# _collect_cluster_dirs
# ---------------------
# Populate a nameref array with absolute paths of *real* cluster directories
# under ${HPS_CLUSTER_CONFIG_BASE_DIR}, excluding symlinks.
#
# Args:
#   $1  - nameref to an array variable to receive results
#
# Returns:
#   0 on success (array may be empty), non-zero on unexpected errors
#===============================================================================
_collect_cluster_dirs() {
  local -n __out="$1"
  local base_dir="${HPS_CLUSTER_CONFIG_BASE_DIR}"

  __out=()
  if [[ ! -d "$base_dir" ]]; then
    echo "[!] Cluster config base directory not found: $base_dir" >&2
    return 0
  fi

  local entry
  shopt -s nullglob
  for entry in "$base_dir"/*; do
    # NOTE: no trailing slash so we don't dereference symlinks
    if [[ -d "$entry" && ! -L "$entry" ]]; then
      __out+=("$entry")
    fi
  done
  shopt -u nullglob
}

#===============================================================================
# count_clusters
# --------------
# Count the number of *real* cluster directories (excluding symlinks).
#
# Returns:
#   Integer count via stdout. Emits warnings to stderr when base dir is missing
#   or when none are found.
#===============================================================================
count_clusters() {
  local clusters=()
  _collect_cluster_dirs clusters

  if (( ${#clusters[@]} == 0 )); then
    echo "[!] No clusters found in ${HPS_CLUSTER_CONFIG_BASE_DIR}" >&2
    echo 0
    return 0
  fi

  echo "${#clusters[@]}"
}

#===============================================================================
# list_clusters
# -------------
# List all *real* cluster directories under ${HPS_CLUSTER_CONFIG_BASE_DIR}.
# Appends " (Active)" to the active one.
#
# Usage:
#   list_clusters
#===============================================================================
list_clusters() {
  local clusters=()
  _collect_cluster_dirs clusters

  # Determine active cluster name once; ignore errors if not set
  local active_name=""
  active_name="$(get_active_cluster_name 2>/dev/null)" || true

  if (( ${#clusters[@]} == 0 )); then
    echo "[!] No clusters found in ${HPS_CLUSTER_CONFIG_BASE_DIR}" >&2
    return 0
  fi

  local c name
  for c in "${clusters[@]}"; do
    name="$(basename -- "$c")"
    if [[ -n "$active_name" && "$name" == "$active_name" ]]; then
      echo "${name} (Active)"
    else
      echo "${name}"
    fi
  done
}

#===============================================================================
# list_cluster_hosts
# ------------------
# List all host MAC addresses in a cluster.
#
# Usage:
#   list_cluster_hosts [cluster_name]
#
# Parameters:
#   cluster_name - (optional) Name of the cluster. If empty, uses active cluster.
#
# Returns:
#   0 on success (outputs MAC addresses to stdout, one per line)
#   1 if cluster directory doesn't exist or cannot be determined
#===============================================================================
list_cluster_hosts() {
  local cluster_name="${1:-}"
  local hosts_dir
  
  # Determine hosts directory
  if [[ -z "$cluster_name" ]]; then
    hosts_dir=$(get_active_cluster_hosts_dir 2>/dev/null)
    if [[ -z "$hosts_dir" ]]; then
      hps_log error "list_cluster_hosts: Cannot determine active cluster hosts directory"
      return 1
    fi
  else
    local cluster_dir
    cluster_dir=$(get_cluster_dir "$cluster_name" 2>/dev/null)
    if [[ -z "$cluster_dir" ]]; then
      hps_log error "list_cluster_hosts: Cannot get directory for cluster: $cluster_name"
      return 1
    fi
    hosts_dir="${cluster_dir}/hosts"
  fi
  
  # Validate hosts directory exists
  if [[ ! -d "$hosts_dir" ]]; then
    hps_log debug "list_cluster_hosts: No hosts directory: $hosts_dir"
    return 0
  fi
  
  # List only .db directories (registry format only)
  if compgen -G "${hosts_dir}/*.db" > /dev/null 2>&1; then
    for db_dir in "${hosts_dir}"/*.db; do
      [[ ! -d "$db_dir" ]] && continue
      basename "$db_dir" .db
    done | sort -u
  fi
  
  return 0
}

#===============================================================================
# get_cluster_host_ips
# --------------------
# Get IP addresses of all hosts in a cluster.
#
# Usage:
#   get_cluster_host_ips [cluster_name]
#
# Parameters:
#   cluster_name - (optional) Name of the cluster. If empty, uses active cluster.
#
# Returns:
#   0 on success (outputs IP addresses to stdout, one per line)
#   1 if cluster cannot be determined
#===============================================================================
get_cluster_host_ips() {
  local cluster_name="${1:-}"
  local mac ip
  
  # Get list of all MACs in cluster
  while IFS= read -r mac; do
    [[ -z "$mac" ]] && continue
    
    ip=$(host_registry "$mac" get IP 2>/dev/null)
    if [[ -n "$ip" ]]; then
      echo "$ip"
    fi
  done < <(list_cluster_hosts "$cluster_name")
  
  return 0
}

#===============================================================================
# get_cluster_host_hostnames
# --------------------------
# Get hostnames of all hosts in a cluster.
#
# Usage:
#   get_cluster_host_hostnames [cluster_name] [hosttype_filter]
#
# Parameters:
#   cluster_name     - (optional) Name of the cluster. If empty, uses active cluster.
#   hosttype_filter  - (optional) Filter by host type (e.g., TCH, ROCKY)
#
# Returns:
#   0 on success (outputs hostnames to stdout, one per line)
#   1 if cluster cannot be determined
#===============================================================================
get_cluster_host_hostnames() {
  local cluster_name="${1:-}"
  local hosttype_filter="${2:-}"
  local mac hostname hosttype
  
  # Convert filter to lowercase for comparison
  if [[ -n "$hosttype_filter" ]]; then
    hosttype_filter=$(echo "$hosttype_filter" | tr '[:upper:]' '[:lower:]')
  fi
  
  # Get list of all MACs in cluster
  while IFS= read -r mac; do
    [[ -z "$mac" ]] && continue
    
    # Apply type filter if specified
    if [[ -n "$hosttype_filter" ]]; then
      hosttype=$(host_registry "$mac" get TYPE 2>/dev/null | tr '[:upper:]' '[:lower:]')
      [[ "$hosttype" != "$hosttype_filter" ]] && continue
    fi
    
    # Get hostname
    hostname=$(host_registry "$mac" get HOSTNAME 2>/dev/null)
    
    if [[ -n "$hostname" ]]; then
      echo "$hostname"
    fi
  done < <(list_cluster_hosts "$cluster_name")
  
  return 0
}

#===============================================================================
# set_active_cluster
# ------------------
# Set the active cluster by updating system registry.
#
# Arguments:
#   $1  - Cluster name (must correspond to a real cluster dir)
#
# Returns:
#   0 on success, non-zero on error.
#===============================================================================
set_active_cluster() {
  local cluster_name="$1"
  [[ -z "$cluster_name" ]] && {
    echo "[x] Usage: set_active_cluster <cluster-name>" >&2
    return 1
  }

  local cluster_dir
  cluster_dir="$(get_cluster_dir "$cluster_name")" || return 1

  # Ensure directory exists
  if [[ ! -d "$cluster_dir" ]]; then
    echo "[x] Cluster directory not found: $cluster_dir" >&2
    return 1
  fi

  # Ensure cluster registry exists
  if [[ ! -d "$cluster_dir/cluster.db" ]]; then
    echo "[x] Cluster registry not found: $cluster_dir/cluster.db" >&2
    return 2
  fi

  # Update system registry
  if ! system_registry set ACTIVE_CLUSTER "$cluster_name"; then
    echo "[x] Failed to update system registry" >&2
    return 3
  fi

  echo "[OK] Active cluster set to: $cluster_name"
}

#===============================================================================
# commit_changes
# --------------
# Commit all pending cluster configuration changes
#
# Behaviour:
#   - Processes all settings from CLUSTER_CONFIG_PENDING array
#   - Applies changes using cluster_config
#   - Clears the pending array
#
# Returns:
#   0 on success
#   1 on error
#===============================================================================
commit_changes() {
    local cluster="${CLUSTER_NAME:-}"
    
    if [[ -z "$cluster" ]]; then
        hps_log "error" "No cluster name available for commit"
        return 1
    fi
    
    # Check if array exists and has elements
    if [[ ! -v CLUSTER_CONFIG_PENDING ]] || [[ ${#CLUSTER_CONFIG_PENDING[@]} -eq 0 ]]; then
        cli_note "No configuration changes to commit"
        return 0
    fi
    
    cli_info "Committing configuration changes for cluster: $cluster"
    
    # Process all pending configuration
    local config_item
    for config_item in "${CLUSTER_CONFIG_PENDING[@]}"; do
        local key="${config_item%%:*}"
        local value="${config_item#*:}"
        
        if ! cluster_registry "set" "$key" "$value" "$cluster"; then
            hps_log "error" "Failed to set: $key=$value"
            return 1
        fi
        
        hps_log "info" "Set: $key=$value"
    done
    
    # Clear pending array
    CLUSTER_CONFIG_PENDING=()
    update_dns_dhcp_files
    hps_log "info" "Configuration changes committed for cluster: $cluster"
    return 0
}

#===============================================================================
# cluster_config
# --------------
# Alias to cluster_registry for backward compatibility
#===============================================================================
cluster_config() {
  cluster_registry "$@"
}

#===============================================================================
# initialise_cluster
# ------------------
# Initialize a new cluster with registry storage.
#
# Arguments:
#   $1 - cluster_name: Name of the cluster to create
#
# Returns:
#   0 on success
#   1 if cluster name not provided
#   2 if cluster already exists
#   3 if path export fails
#===============================================================================
initialise_cluster() {
  local cluster_name="$1"
  local base_dir="${HPS_CLUSTER_CONFIG_BASE_DIR}"
  local cluster_dir="${base_dir}/${cluster_name}"

  if [[ -z "$cluster_name" ]]; then
    hps_log ERROR "[x] Cluster name must be provided."
    return 1
  fi

  if [[ -d "$cluster_dir" ]]; then
    hps_log ERROR "[!] Cluster directory already exists: $cluster_dir"
    return 2
  fi

  mkdir -p "${cluster_dir}/hosts"
  mkdir -p "${cluster_dir}/services"
  mkdir -p "${cluster_dir}/keysafe"
  mkdir -p "${cluster_dir}/cluster.db"

  hps_log info "[OK] Cluster initialised at: $cluster_dir"
  hps_log info "[OK] Created registry: ${cluster_dir}/cluster.db"

  cluster_registry "set" "CLUSTER_NAME" "${cluster_name}"

  export_dynamic_paths "$cluster_name" || {
    hps_log ERROR "[x] Failed to export cluster paths for $cluster_name"
    return 3
  }
}

#===============================================================================
# print_cluster_variables
# -----------------------
# Print all cluster configuration variables.
#
# Returns:
#   0 on success
#   1 if cluster registry cannot be read
#===============================================================================
print_cluster_variables() {
  # Use cluster_registry view to get all variables as JSON
  local view_output
  view_output="$(cluster_registry view 2>/dev/null)" || {
    echo "[x] Cannot read cluster registry" >&2
    return 1
  }
  
  # Convert JSON to key=value format
  echo "$view_output" | jq -r 'to_entries[] | "\(.key)=\(.value)"'
}

#===============================================================================
# cluster_has_installed_sch
# -------------------------
# Check if cluster has any SCH hosts with STATE=INSTALLED.
#
# Returns:
#   0 if at least one installed SCH host exists
#   1 if no installed SCH hosts found
#===============================================================================
cluster_has_installed_sch() {
  # Search for hosts with TYPE=SCH
  local sch_hosts
  sch_hosts=$(registry_search host TYPE SCH 2>/dev/null)
  
  if [[ -z "$sch_hosts" ]]; then
    return 1
  fi
  
  # Check if any have STATE=INSTALLED
  local mac
  while IFS= read -r mac; do
    [[ -z "$mac" ]] && continue
    
    local state
    state=$(host_registry "$mac" get STATE 2>/dev/null)
    if [[ "$state" == "INSTALLED" ]]; then
      return 0
    fi
  done <<< "$sch_hosts"
  
  return 1
}

## Interactive functions

#===============================================================================
# cli_set_active_cluster
# ----------------------
# Prompt to set a cluster as active and apply changes
#
# Parameters:
#   $1 - Cluster name to potentially set as active
#
# Behaviour:
#   - Checks if cluster is already active (skips if so)
#   - Prompts user to set as active and apply changes
#   - Sets active cluster, exports paths, and commits changes if confirmed
#
# Returns:
#   0 on success or if already active
#   1 on error
#   2 if user declines
#===============================================================================
cli_set_active_cluster() {
    local cluster_name="$1"
    
    if [[ -z "$cluster_name" ]]; then
        hps_log "error" "No cluster name provided"
        return 1
    fi
    
    # Get current active cluster
    local current_active=$(get_active_cluster_name 2>/dev/null || echo "")
    
    # Skip if this cluster is already active
    if [[ "$cluster_name" == "$current_active" ]]; then
        cli_note "Cluster '$cluster_name' is already active"
        return 0
    fi
    
    # Ask if user wants to set as active
    if [[ $(cli_prompt_yesno "Set $cluster_name as active cluster and apply changes?" "n") == "y" ]]; then
        cli_info "Setting $cluster_name as active cluster..."
        
        # Set as active
        if set_active_cluster "$cluster_name"; then
            export_dynamic_paths
            
            # Commit changes
            if commit_changes; then
                cli_info "Cluster $cluster_name is now active and changes are applied"
                return 0
            else
                hps_log "error" "Failed to commit changes"
                return 1
            fi
        else
            hps_log "error" "Failed to set active cluster"
            return 1
        fi
    else
        # User declined
        return 2
    fi
}

#===============================================================================
# select_network_interface
# ------------------------
# Present menu to select a network interface
#
# Parameters:
#   $1 - Prompt text (optional, default: "Select network interface")
#   $2 - Include "None" option (optional, "true"/"false", default: "false")
#   $3 - None option text (optional, default: "None")
#
# Behaviour:
#   - Shows numbered list of interfaces with IP/gateway info
#   - Returns selected interface name via echo
#   - Returns "NONE" if None option selected
#
# Returns:
#   0 on valid selection
#   1 on cancel/error
#===============================================================================
select_network_interface() {
  local prompt="${1:-Select network interface}"
  local include_none="${2:-false}"
  local none_text="${3:-None}"
  
  local interfaces=()
  local labels=()
  local iface ip_cidr gateway
  
  # Build interface list
  while IFS='|' read -r iface ip_cidr gateway; do
    local label="$iface"
    [[ -n "$ip_cidr" ]] && label+=" - $ip_cidr"
    [[ -n "$gateway" ]] && label+=" (gateway: $gateway)"
    
    interfaces+=("$iface")
    labels+=("$label")
  done < <(get_network_interfaces)
  
  # Add None option if requested
  [[ "$include_none" == "true" ]] && labels+=("$none_text")
  
  # Show selection menu - send prompt to stderr so it's not captured
  echo "$prompt:" >&2
  local PS3="#? "  # Set the prompt for select
  select label in "${labels[@]}"; do
    if [[ -z "$label" ]]; then
      hps_log "error" "Invalid selection"
      continue
    fi
    
    # Check if None was selected
    if [[ "$include_none" == "true" ]] && [[ "$REPLY" == "${#labels[@]}" ]]; then
      echo "NONE"
      return 0
    fi
    
    # Return the selected interface NAME, not the label
    local index=$((REPLY - 1))
    if [[ $index -ge 0 ]] && [[ $index -lt ${#interfaces[@]} ]]; then
      echo "${interfaces[$index]}"
      return 0
    fi
    
    break
  done
  
  return 1
}

#===============================================================================
# config_get_value
# ----------------
# Get configuration value with precedence: pending > existing > default
#
# Parameters:
#   $1 - Configuration key
#   $2 - Default value (optional)
#   $3 - Cluster name (optional, defaults to $CLUSTER_NAME)
#
# Behaviour:
#   - First checks CLUSTER_CONFIG_PENDING array
#   - Then checks existing cluster config for specified cluster
#   - Finally uses provided default (or empty string)
#   - Uses $CLUSTER_NAME if no cluster specified
#
# Returns:
#   Echoes the found value
#   Exit code 0 always
#===============================================================================
config_get_value() {
  local key="$1"
  local default="${2:-}"
  local cluster="${3:-$CLUSTER_NAME}"
  local value=""
  
  # Check pending config first
  local config_item
  for config_item in "${CLUSTER_CONFIG_PENDING[@]:-}"; do
    if [[ "$config_item" =~ ^${key}:(.*)$ ]]; then
      echo "${BASH_REMATCH[1]}"
      return 0
    fi
  done
  
  # Check existing config for the specified cluster
  if [[ -n "$cluster" ]]; then
    value=$(cluster_registry "get" "$key" "" "$cluster" 2>/dev/null || echo "")
    if [[ -n "$value" ]]; then
      echo "$value"
      return 0
    fi
  fi
  
  # Use default
  echo "$default"
  return 0
}

#===============================================================================
# select_cluster
# --------------
# Interactive selector for cluster directories using Bash `select`.
#
# Behaviour:
#   - Lists cluster names; appends " (Active)" to the current one.
#   - Echoes the selected cluster directory to stdout (default),
#     or just the name with --return=name.
#   - Non-interactive (no TTY): auto-selects active if available, else first.
#===============================================================================
select_cluster() {
  local return_mode="dir"  # "dir" or "name"
  if [[ "$1" == "--return=name" ]]; then
    return_mode="name"
    shift
  fi

  local dirs=()
  _collect_cluster_dirs dirs

  if (( ${#dirs[@]} == 0 )); then
    echo "[!] No clusters found in ${HPS_CLUSTER_CONFIG_BASE_DIR}" >&2
    return 1
  fi

  local active_name=""
  active_name="$(get_active_cluster_name 2>/dev/null)" || true

  # Build parallel arrays: names[] (raw), display[] (with Active mark)
  local names=() display=() d name
  for d in "${dirs[@]}"; do
    name="$(basename -- "$d")"
    names+=("$name")
    if [[ -n "$active_name" && "$name" == "$active_name" ]]; then
      display+=("${name} (Active)")
    else
      display+=("$name")
    fi
  done

  # Non-interactive: prefer active; else first
  if [[ ! -t 0 ]]; then
    local pick_idx=0
    if [[ -n "$active_name" ]]; then
      local i
      for i in "${!names[@]}"; do
        if [[ "${names[$i]}" == "$active_name" ]]; then
          pick_idx="$i"
          break
        fi
      done
    fi
    if [[ "$return_mode" == "name" ]]; then
      echo "${names[$pick_idx]}"
    else
      echo "${dirs[$pick_idx]}"
    fi
    return 0
  fi

  # Interactive select: use a separate variable for the chosen item
  local PS3="[?] Select a cluster: "
  local choice
  select choice in "${display[@]}"; do
    # $REPLY is the raw user input (number); validate it
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && (( REPLY >= 1 && REPLY <= ${#display[@]} )); then
      local idx=$((REPLY - 1))
      if [[ "$return_mode" == "name" ]]; then
        echo "${names[$idx]}"
      else
        echo "${dirs[$idx]}"
      fi
      return 0
    else
      echo "[!] Invalid selection. Enter a number 1..${#display[@]}." >&2
    fi
  done
}

#===============================================================================
# cluster_storage_init_network
# ----------------------------
# Initialize storage network configuration in cluster_config
#
# Behaviour:
#   - Prompts admin for storage network preferences
#   - Sets up storage VLAN range and configuration
#   - Creates DNS subdomain mapping for each storage network
#   - Stores configuration in cluster_config
#
# Returns:
#   0 on success
#   1 on error
#===============================================================================
cluster_storage_init_network() {
  local num_storage_networks
  local enable_jumbo_frames
  local storage_base_vlan
  local storage_subnet_base
  local storage_subnet_cidr
  local cluster_domain
  
  # Get cluster domain
  cluster_domain=$(cluster_registry "get" "DNS_DOMAIN")
  if [[ -z "$cluster_domain" ]]; then
    hps_log "error" "Cluster domain not set"
    return 1
  fi
  
  # Get number of storage networks
  num_storage_networks=$(cli_prompt \
    "Number of storage networks to configure (1-10)" \
    "2" \
    "^[1-9]$|^10$" \
    "Please enter a number between 1 and 10")
  
  # Get base VLAN ID
  storage_base_vlan=$(cli_prompt \
    "Storage network base VLAN ID (31-99)" \
    "31" \
    "^(3[1-9]|[4-9][0-9])$" \
    "VLAN ID must be between 31 and 99")
  
  # Get subnet base
  storage_subnet_base=$(cli_prompt \
    "Storage subnet base (e.g., 10.31 for 10.31.x.0/24)" \
    "10.${storage_base_vlan}" \
    "^[0-9]{1,3}\.[0-9]{1,3}$" \
    "Please enter subnet base as X.Y format (e.g., 10.31)")
  
  # Validate subnet base octets
  local octet1 octet2
  IFS='.' read -r octet1 octet2 <<< "$storage_subnet_base"
  if [[ "$octet1" -gt 255 ]] || [[ "$octet2" -gt 255 ]]; then
    hps_log "error" "Invalid subnet base: octets must be 0-255"
    return 1
  fi
  
  # Get CIDR
  storage_subnet_cidr=$(cli_prompt \
    "Storage subnet CIDR mask (16-28)" \
    "24" \
    "^(1[6-9]|2[0-8])$" \
    "CIDR must be between 16 and 28")
  
  # Ask about jumbo frames
  echo "Note: Jumbo frames require switch support with MTU 9000+ on all storage ports"
  enable_jumbo_frames=$(cli_prompt \
    "Enable jumbo frames (9000 MTU) on storage networks? [y/n]" \
    "y" \
    "^[yn]$" \
    "Please enter 'y' for yes or 'n' for no")
  
  local mtu=1500
  [[ "$enable_jumbo_frames" == "y" ]] && mtu=9000
  
  # Store base configuration
  cluster_registry "set" "network_storage_count" "$num_storage_networks"
  cluster_registry "set" "network_storage_mtu" "$mtu"
  cluster_registry "set" "network_storage_base_vlan" "$storage_base_vlan"
  cluster_registry "set" "network_storage_subnet_base" "$storage_subnet_base"
  cluster_registry "set" "network_storage_subnet_cidr" "$storage_subnet_cidr"
  
  # Configure each storage network
  local i
  for ((i=0; i<num_storage_networks; i++)); do
    local vlan=$((storage_base_vlan + i))
    
    # Calculate subnet using the shared function
    local subnet=$(network_calculate_subnet "$storage_subnet_base" "$i" "$storage_subnet_cidr")
    if [[ $? -ne 0 ]]; then
      hps_log "error" "Failed to calculate subnet for storage network $((i+1))"
      return 1
    fi
    
    # Extract network portion for gateway
    local network_addr="${subnet%/*}"
    local gateway="${network_addr%.*}.1"
    local netmask=$(cidr_to_netmask "${storage_subnet_cidr}")
    local domain="storage$((i+1)).${cluster_domain}"
    
    cluster_registry "set" "network_storage_vlan${vlan}_subnet" "$subnet"
    cluster_registry "set" "network_storage_vlan${vlan}_gateway" "$gateway"
    cluster_registry "set" "network_storage_vlan${vlan}_netmask" "$netmask"
    cluster_registry "set" "network_storage_vlan${vlan}_domain" "$domain"
    cluster_registry "set" "network_storage_vlan${vlan}_allocated" "false"
    
    hps_log "info" "Configured storage network $((i+1)): VLAN $vlan, subnet $subnet, domain $domain"
  done
  
  return 0
}
