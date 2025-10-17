__guard_source || return



#===============================================================================
# get_active_cluster_name
# -----------------------
# Convenience: returns the basename of the active cluster directory.
#
# Returns:
#   Cluster name via stdout, or non-zero on error.
#===============================================================================
get_active_cluster_name() {
  local dir
  dir="$(get_active_cluster_dir)" || return 1
  basename -- "$dir"
}

#===============================================================================
# get_active_cluster_link
# -----------------------
# Return the path to the "active-cluster" symlink under the cluster config base.
# Verifies that the symlink exists. This avoids hardcoding the path elsewhere.
#
# Returns:
#   Symlink path via stdout, or non-zero with error to stderr if not found.
#===============================================================================
get_active_cluster_link() {
  local link="$(get_active_cluster_link_path)"

  if [[ ! -L "$link" ]]; then
    echo "[ERROR] No active cluster symlink at: $link" >&2
    return 1
  fi

  echo "$link"
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
# Resolve the absolute path to the *active* cluster directory, via the symlink
# returned by get_active_cluster_link.
#
# Reuses:
#   - get_active_cluster_link
#   - get_cluster_dir
#
# Returns:
#   Path via stdout, or non-zero with error message on stderr.
#===============================================================================
get_active_cluster_dir() {
  local link
  link="$(get_active_cluster_link)" || return 1

  local target
  if ! target="$(readlink -f -- "$link")"; then
    echo "[ERROR] Failed to resolve active cluster symlink: $link" >&2
    return 1
  fi

  # Derive the name (last path component) and recompose with get_cluster_dir
  local name
  name="$(basename -- "$target")"
  local dir
  dir="$(get_cluster_dir "$name")" || return 1

  if [[ ! -d "$dir" ]]; then
    echo "[ERROR] Active cluster target is not a directory: $dir" >&2
    return 1
  fi

  echo "$dir"
}

#===============================================================================
# get_active_cluster_link_path
# ----------------------------
# Return the absolute path to where the active-cluster symlink should live.
# (No validation is done here.)
#
# Returns:
#   Path via stdout.
#===============================================================================
get_active_cluster_link_path() {
  echo "${HPS_CLUSTER_CONFIG_BASE_DIR}/active-cluster"
}


#===============================================================================
# get_cluster_conf_file
# ---------------------
# Return the absolute path to the cluster.conf file for a given cluster.
#
# Arguments:
#   $1 - Cluster name
#
# Reuses:
#   - get_cluster_dir
#
# Returns:
#   Path via stdout, or non-zero on error.
#===============================================================================
get_cluster_conf_file() {
  local cluster_name="$1"
  [[ -z "$cluster_name" ]] && {
    echo "[ERROR] Usage: get_cluster_conf_file <cluster-name>" >&2
    return 1
  }

  local cluster_dir
  cluster_dir="$(get_cluster_dir "$cluster_name")" || return 1
  echo "${cluster_dir}/cluster.conf"
}


#===============================================================================
# get_active_cluster_filename
# ---------------------------
# Return the absolute path to the active cluster.conf file.
#
# Dependencies:
#   - get_active_cluster_dir
#   - get_cluster_conf_file
#
# Returns:
#   Path via stdout, or non-zero with error to stderr.
#===============================================================================
get_active_cluster_filename() {
  local cluster_dir
  cluster_dir="$(get_active_cluster_dir)" || return 1

  local cluster_name
  cluster_name="$(basename -- "$cluster_dir")"

  local file
  file="$(get_cluster_conf_file "$cluster_name")" || return 1

  if [[ ! -f "$file" ]]; then
    echo "[ERROR] Active cluster missing cluster.conf: $file" >&2
    return 1
  fi

  echo "$file"
}


#===============================================================================
# get_active_cluster_file
# -----------------------
# Output the contents of the active cluster.conf file to stdout.
#
# Dependencies:
#   - get_active_cluster_filename
#
# Returns:
#   File content via stdout, or non-zero with error to stderr.
#===============================================================================
get_active_cluster_file() {
  local file
  file="$(get_active_cluster_filename)" || return 1
  cat -- "$file"
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
# Metadata fields (queried via helper, not by reading files):
#   DESCRIPTION, NETWORK_CIDR, DNS_DOMAIN
#
# Reuses:
#   - _collect_cluster_dirs
#   - get_active_cluster_dir
#   - get_active_cluster_name
#   - cluster_config get <KEY>        # must resolve against active cluster
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

  # Helper: print a key via cluster_config get (skip silently if empty)
  _print_meta() {
    local key="$1" label="$2" val=""
    if val="$(cluster_config get "$key" 2>/dev/null)"; then
      [[ -n "$val" ]] && echo "${label}: ${val}"
    fi
  }

  # Case 1: Active cluster exists
  local active_dir active_name
  if active_dir="$(get_active_cluster_dir 2>/dev/null)"; then
    active_name="$(basename -- "$active_dir")"
    echo "Cluster: ${active_name} (Active)"
    echo "Directory: ${active_dir}"
    _print_meta "DESCRIPTION"   "Description"
    _print_meta "NETWORK_CIDR"  "Network CIDR"
    _print_meta "DNS_DOMAIN"    "DNS Domain"
    return 0
  fi

  # Case 2: No active; if exactly one cluster, show it (metadata unavailable
  # without temporarily switching active; we only show name/dir here).
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
# under ${HPS_CLUSTER_CONFIG_BASE_DIR}, excluding symlinks (e.g. active-cluster).
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
# List all *real* cluster directories (no symlinks) under
# ${HPS_CLUSTER_CONFIG_BASE_DIR}. Appends " (Active)" to the active one.
#
# Dependencies:
#   - _collect_cluster_dirs (gathers non-symlink dirs)
#   - get_active_cluster_name (resolves active via symlink)
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

#:name: list_cluster_hosts
#:group: cluster
#:synopsis: List all host MAC addresses in a cluster.
#:usage: list_cluster_hosts [cluster_name]
#:description:
#  Lists all host MAC addresses configured in the specified cluster.
#  If no cluster_name is provided, uses the active cluster.
#  Outputs one MAC address per line by examining host config files.
#  Uses get_active_cluster_hosts_dir or get_cluster_dir to locate hosts.
#:parameters:
#  cluster_name - (optional) Name of the cluster. If empty, uses active cluster.
#:returns:
#  0 on success (outputs MAC addresses to stdout, one per line)
#  1 if cluster directory doesn't exist or cannot be determined
list_cluster_hosts() {
  local cluster_name="${1:-}"
  local hosts_dir
  
  # Determine hosts directory
  if [[ -z "$cluster_name" ]]; then
    # Use active cluster hosts directory
    hosts_dir=$(get_active_cluster_hosts_dir 2>/dev/null)
    if [[ -z "$hosts_dir" ]]; then
      hps_log error "list_cluster_hosts: Cannot determine active cluster hosts directory"
      return 1
    fi
  else
    # Get specific cluster directory and append /hosts
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
  
  # List all .conf files and extract MAC addresses from filenames
  if compgen -G "${hosts_dir}/*.conf" > /dev/null 2>&1; then
    for conf_file in "${hosts_dir}"/*.conf; do
      [[ ! -f "$conf_file" ]] && continue
      
      # Extract MAC address from filename
      local mac
      mac=$(get_mac_from_conffile "$conf_file" 2>/dev/null)
      
      if [[ -n "$mac" ]]; then
        echo "$mac"
      fi
    done
  fi
  
  return 0
}

#:name: get_cluster_host_ips
#:group: cluster
#:synopsis: Get IP addresses of all hosts in a cluster.
#:usage: get_cluster_host_ips [cluster_name]
#:description:
#  Returns IP addresses for all configured hosts in the specified cluster.
#  If no cluster_name is provided, uses the active cluster.
#  Outputs one IP address per line.
#:parameters:
#  cluster_name - (optional) Name of the cluster. If empty, uses active cluster.
#:returns:
#  0 on success (outputs IP addresses to stdout, one per line)
#  1 if cluster cannot be determined
get_cluster_host_ips() {
  local cluster_name="${1:-}"
  local mac ip
  local hosts_dir
  
  # Determine hosts directory
  if [[ -z "$cluster_name" ]]; then
    hosts_dir=$(get_active_cluster_hosts_dir 2>/dev/null)
  else
    local cluster_dir
    cluster_dir=$(get_cluster_dir "$cluster_name" 2>/dev/null)
    hosts_dir="${cluster_dir}/hosts"
  fi
  
  if [[ -z "$hosts_dir" ]] || [[ ! -d "$hosts_dir" ]]; then
    hps_log error "get_cluster_host_ips: Cannot determine hosts directory"
    return 1
  fi
  
  # Get list of all MACs in cluster
  while IFS= read -r mac; do
    [[ -z "$mac" ]] && continue
    
    # Get IP directly from the config file
    local conf_file="${hosts_dir}/${mac}.conf"
    if [[ -f "$conf_file" ]]; then
      ip=$(grep -E "^IP=" "$conf_file" 2>/dev/null | cut -d= -f2 | tr -d '"')
      if [[ -n "$ip" ]]; then
        echo "$ip"
      fi
    fi
  done < <(list_cluster_hosts "$cluster_name")
  
  return 0
}

#:name: get_cluster_host_hostnames
#:group: cluster
#:synopsis: Get hostnames of all hosts in a cluster.
#:usage: get_cluster_host_hostnames [cluster_name] [hosttype_filter]
#:description:
#  Returns hostnames for all configured hosts in the specified cluster.
#  If no cluster_name is provided, uses the active cluster.
#  Optionally filter by host type (case-insensitive).
#  Outputs one hostname per line.
#:parameters:
#  cluster_name     - (optional) Name of the cluster. If empty, uses active cluster.
#  hosttype_filter  - (optional) Filter by host type (e.g., TCH, ROCKY)
#:returns:
#  0 on success (outputs hostnames to stdout, one per line)
#  1 if cluster cannot be determined
get_cluster_host_hostnames() {
  local cluster_name="${1:-}"
  local hosttype_filter="${2:-}"
  local mac hostname hosttype
  local hosts_dir
  
  # Convert filter to lowercase for comparison
  if [[ -n "$hosttype_filter" ]]; then
    hosttype_filter=$(echo "$hosttype_filter" | tr '[:upper:]' '[:lower:]')
  fi
  
  # Determine hosts directory
  if [[ -z "$cluster_name" ]]; then
    hosts_dir=$(get_active_cluster_hosts_dir 2>/dev/null)
  else
    local cluster_dir
    cluster_dir=$(get_cluster_dir "$cluster_name" 2>/dev/null)
    hosts_dir="${cluster_dir}/hosts"
  fi
  
  if [[ -z "$hosts_dir" ]] || [[ ! -d "$hosts_dir" ]]; then
    hps_log error "get_cluster_host_hostnames: Cannot determine hosts directory"
    return 1
  fi
  
  # Get list of all MACs in cluster
  while IFS= read -r mac; do
    [[ -z "$mac" ]] && continue
    
    local conf_file="${hosts_dir}/${mac}.conf"
    [[ ! -f "$conf_file" ]] && continue
    
    # Apply type filter if specified
    if [[ -n "$hosttype_filter" ]]; then
      hosttype=$(grep -E "^TYPE=" "$conf_file" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
      [[ "$hosttype" != "$hosttype_filter" ]] && continue
    fi
    
    # Get hostname
    hostname=$(grep -E "^HOSTNAME=" "$conf_file" 2>/dev/null | cut -d= -f2 | tr -d '"')
    
    if [[ -n "$hostname" ]]; then
      echo "$hostname"
    fi
  done < <(list_cluster_hosts "$cluster_name")
  
  return 0
}

#===============================================================================
# set_active_cluster
# ------------------
# Set the active cluster by updating the active-cluster symlink.
#
# Arguments:
#   $1  - Cluster name (must correspond to a real cluster dir with cluster.conf)
#
# Reuses:
#   - get_cluster_dir
#   - get_cluster_conf_file
#   - get_active_cluster_link_path
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

  local cluster_dir conf_file
  cluster_dir="$(get_cluster_dir "$cluster_name")" || return 1
  conf_file="$(get_cluster_conf_file "$cluster_name")" || return 1

  # Ensure directory exists
  if [[ ! -d "$cluster_dir" ]]; then
    echo "[x] Cluster directory not found: $cluster_dir" >&2
    return 1
  fi

  # Ensure cluster.conf exists
  if [[ ! -f "$conf_file" ]]; then
    echo "[x] cluster.conf not found: $conf_file" >&2
    return 2
  fi

  # Ensure symlink is updated
  local link
  link="$(get_active_cluster_link_path)"
  ln -sfn "$cluster_dir" "$link"

  echo "[OK] Active cluster set to: $cluster_name"
}






write_cluster_config() {
  local target_file="$1"
  shift
  local values=("$@")

  if [[ ${#values[@]} -eq 0 ]]; then
    echo "[x] Cannot write empty cluster config to $target_file" >&2
    return 1
  fi

  echo "Writing: ${values[*]}"
  printf "%s\n" "${values[@]}" > "$target_file"
  echo "[OK] Cluster configuration written to $target_file"
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
        
        if ! cluster_config "set" "$key" "$value" "$cluster"; then
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
# Get/set/check cluster configuration values
#
# Parameters:
#   $1 - Operation (get/set/exists)
#   $2 - Configuration key
#   $3 - Value (for set operation)
#   $4 - Cluster name (optional, defaults to active cluster)
#
# Behaviour:
#   - set: Quotes values when writing if they contain spaces/special chars
#   - get: Returns values without quotes
#   - Handles both quoted and unquoted values when reading
#
# Returns:
#   0 on success
#   1 on error
#   2 on invalid operation
#===============================================================================
cluster_config() {
  local op="$1"
  local key="$2"
  local value="${3:-}"
  local cluster="${4:-}"
  local cluster_file
  
  # If cluster name provided, use that cluster's config
  if [[ -n "$cluster" ]]; then
    cluster_file="$(get_active_cluster_filename)"
    if [[ ! -f "$cluster_file" ]]; then
      # Create if doesn't exist for set operations
      if [[ "$op" == "set" ]]; then
        mkdir -p "$(dirname "$cluster_file")"
        touch "$cluster_file"
      else
        return 1
      fi
    fi
  else
    # Use active cluster
    cluster_file=$(get_active_cluster_filename) || {
      echo "[x] No active cluster config found." >&2
      return 1
    }
  fi
  
  case "$op" in
    get)
      local raw_value=$(grep -E "^${key}=" "$cluster_file" 2>/dev/null | cut -d= -f2-)
      # Strip surrounding quotes if present (handles both single and double quotes)
      if [[ "$raw_value" =~ ^\"(.*)\"$ ]]; then
        echo "${BASH_REMATCH[1]}"
      elif [[ "$raw_value" =~ ^\'(.*)\'$ ]]; then
        echo "${BASH_REMATCH[1]}"
      else
        echo "$raw_value"
      fi
      ;;
    set)
      # Determine if value needs quoting
      local quoted_value="$value"
      
      # Quote if contains: spaces, $, `, \, ", ', newlines, tabs
      if [[ "$value" =~ [[:space:]\$\`\\\"\'] ]] || [[ -z "$value" ]]; then
        # Escape any existing double quotes in the value
        quoted_value="${value//\"/\\\"}"
        quoted_value="\"${quoted_value}\""
      fi
      
      # Update or add the key=value pair
      if grep -qE "^${key}=" "$cluster_file" 2>/dev/null; then
        # Use a different delimiter to avoid issues with / in values
        sed -i "s|^${key}=.*|${key}=${quoted_value}|" "$cluster_file"
      else
        echo "${key}=${quoted_value}" >> "$cluster_file"
      fi
      ;;
    exists)
      grep -qE "^${key}=" "$cluster_file" 2>/dev/null
      ;;
    *)
      echo "[x] Unknown cluster_config operation: $op" >&2
      return 2
      ;;
  esac
}



initialise_cluster() {
  local cluster_name="$1"
  local base_dir="${HPS_CLUSTER_CONFIG_BASE_DIR}"
  local cluster_dir="${base_dir}/${cluster_name}"
  local cluster_file="${cluster_dir}/cluster.conf"

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

  touch "$cluster_file"

  hps_log info "[OK] Cluster initialised at: $cluster_dir"
  hps_log info "[OK] Created config: $cluster_file"

  cluster_config "set" "CLUSTER_NAME" "${cluster_name}"

  export_dynamic_paths "$cluster_name" || {
    hps_log ERROR "[x] Failed to export cluster paths for $cluster_name"
    return 3
  }
}

print_cluster_variables() {
  local config_file="$(get_active_cluster_filename)"
  local k v

  if [[ ! -f "$config_file" ]]; then
    echo "[x] Cluster config not found: $config_file" >&2
    return 1
  fi

  while IFS='=' read -r k v; do
    # Skip blank lines and comments
    [[ "$k" =~ ^#.*$ || -z "$k" ]] && continue
    v="${v%\"}"; v="${v#\"}"  # strip surrounding quotes
    echo "$k=$v"
  done < "$config_file"
}

get_host_type_param() {
  local type="$1"
  local key="$2"
  declare -n ref="$type"

  echo "${ref[$key]}"
}

#:name: cluster_has_installed_sch
#:group: cluster
#:synopsis: Check if cluster has any SCH hosts with STATE=INSTALLED.
#:usage: cluster_has_installed_sch
#:description:
#  Checks if at least one SCH (Storage/Compute Host) in the active cluster
#  has STATE set to INSTALLED. Uses cluster helper functions for enumeration.
#:returns:
#  0 if at least one installed SCH host exists
#  1 if no installed SCH hosts found
cluster_has_installed_sch() {
  local mac
  
  # Get all hosts in cluster
  while IFS= read -r mac; do
    [[ -z "$mac" ]] && continue
    
    # Check if this host is TYPE=SCH
    local host_type
    host_type=$(host_config "$mac" get TYPE 2>/dev/null)
    [[ "$host_type" != "SCH" ]] && continue
    
    # Check if STATE=INSTALLED
    local host_state
    host_state=$(host_config "$mac" get STATE 2>/dev/null)
    if [[ "$host_state" == "INSTALLED" ]]; then
      return 0  # Found at least one installed SCH
    fi
  done < <(list_cluster_hosts)
  
  return 1  # No installed SCH hosts found
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
    local current_active=$(get_active_cluster 2>/dev/null || echo "")
    
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
    value=$(cluster_config "get" "$key" "" "$cluster" 2>/dev/null || echo "")
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
# Reuses:
#   - _collect_cluster_dirs
#   - get_active_cluster_name
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


#!/bin/bash

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
  cluster_domain=$(cluster_config "get" "DNS_DOMAIN")
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
  cluster_config "set" "network_storage_count" "$num_storage_networks"
  cluster_config "set" "network_storage_mtu" "$mtu"
  cluster_config "set" "network_storage_base_vlan" "$storage_base_vlan"
  cluster_config "set" "network_storage_subnet_base" "$storage_subnet_base"
  cluster_config "set" "network_storage_subnet_cidr" "$storage_subnet_cidr"
  
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
    
    cluster_config "set" "network_storage_vlan${vlan}_subnet" "$subnet"
    cluster_config "set" "network_storage_vlan${vlan}_gateway" "$gateway"
    cluster_config "set" "network_storage_vlan${vlan}_netmask" "$netmask"
    cluster_config "set" "network_storage_vlan${vlan}_domain" "$domain"
    cluster_config "set" "network_storage_vlan${vlan}_allocated" "false"
    
    hps_log "info" "Configured storage network $((i+1)): VLAN $vlan, subnet $subnet, domain $domain"
  done
  
  return 0
}



