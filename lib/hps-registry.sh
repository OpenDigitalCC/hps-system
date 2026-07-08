# Disable patsub_replacement to ensure consistent string substitution
shopt -u patsub_replacement 2>/dev/null || true

#===============================================================================
# HPS Registry Functions - JSON-based Configuration Storage
#===============================================================================
# This library provides JSON-based registry storage for HPS configuration.
#
# Features:
# - File-per-key storage (.db directories)
# - Atomic updates with file locking
# - Returns raw values by default (strips quotes)
# - Pure JSON storage - no legacy .conf file support
#===============================================================================

#===============================================================================
# Configuration
#===============================================================================
# Return raw values (strip quotes) for backward compatibility
export HPS_REGISTRY_RAW_MODE="${HPS_REGISTRY_RAW_MODE:-true}"

# System registry location
export HPS_SYSTEM_REGISTRY="${HPS_SYSTEM_REGISTRY:-/srv/hps-config/system.db}"

#===============================================================================
# json_registry
# ------------
# Core JSON registry function for managing JSON documents.
#
# Usage:
#   json_registry <db_path> <command> <key> [value]
#
# Commands:
#   get       - Retrieve JSON document (raw by default)
#   set       - Store JSON document (validates JSON)
#   delete    - Remove JSON document
#   exists    - Check if key exists
#   list      - List all keys in this registry
#   list_all  - List all registries of this type
#   count     - Count all keys in this registry
#   view      - Aggregate all documents into single JSON object
#   destroy   - Remove entire registry directory
#
# Storage:
#   <db_path>/
#     ├── <key>.json      # Individual JSON documents
#     └── .lock/          # Lock files for atomic operations
#
# Returns:
#   0 on success
#   1 if key not found (get/exists) or directory not found (destroy)
#   2 if invalid JSON (set)
#   3 if lock timeout
#===============================================================================
json_registry() {
  local db_path="${1:?Usage: json_registry <db_path> <command> <key> [value]}"
  local cmd="${2:?}"
  local key="${3:-}"
  local value="${4:-}"
  
  # Validate key format (alphanumeric, underscore, dash) - not needed for destroy
  if [[ -n "$key" ]] && [[ ! "$key" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "ERROR: Invalid key format: $key" >&2
    return 2
  fi
  
  # Ensure directories exist (except for destroy)
  if [[ "$cmd" != "destroy" ]]; then
    mkdir -p "$db_path/.lock"
  fi
  
  local file="$db_path/${key}.json"
  local lock="$db_path/.lock/${key}.lock"
  
  case "$cmd" in
    get)
      if [[ -f "$file" ]]; then
        # Validate JSON before returning
        if jq . "$file" >/dev/null 2>&1; then
          # Use -r flag to strip quotes for backward compatibility
          if [[ "${HPS_REGISTRY_RAW_MODE:-true}" == "true" ]]; then
            jq -r . "$file"
          else
            cat "$file"
          fi
          return 0
        else
          echo "ERROR: Corrupted JSON in $file" >&2
          return 2
        fi
      else
        return 1
      fi
      ;;
      
    set)
      # Validate JSON
      if ! echo "$value" | jq . >/dev/null 2>&1; then
        echo "ERROR: Invalid JSON" >&2
        return 2
      fi
      
      # Acquire lock
      if ! acquire_lock "$lock" "write"; then
        echo "ERROR: Cannot acquire lock for $key" >&2
        return 3
      fi
      
      # Write atomically
      local tmp_file="$file.$$.tmp"
      if echo "$value" | jq . > "$tmp_file"; then
        mv "$tmp_file" "$file"
        local result=$?
      else
        rm -f "$tmp_file"
        local result=2
      fi
      
      release_lock "$lock"
      return $result
      ;;
      
    delete)
      if [[ -f "$file" ]]; then
        if ! acquire_lock "$lock" "write"; then
          echo "ERROR: Cannot acquire lock for $key" >&2
          return 3
        fi
        rm -f "$file"
        local result=$?
        release_lock "$lock"
        return $result
      else
        return 0  # Already gone
      fi
      ;;
      
    exists)
      [[ -f "$file" ]]
      return $?
      ;;
      
    list)
      find "$db_path" -maxdepth 1 -name "*.json" -type f 2>/dev/null | \
        xargs -r basename -s .json 2>/dev/null | sort
      return 0
      ;;
      
    count)
      find "$db_path" -maxdepth 1 -name "*.json" -type f 2>/dev/null | wc -l
      return 0
      ;;
      
    list_all)
      # This command is handled by wrapper functions
      # It lists all registries of this type, not keys within a registry
      echo "ERROR: list_all must be called via wrapper (host_registry, cluster_registry, etc.)" >&2
      return 2
      ;;
      
    view)
      # Aggregate all JSON files into single object
      echo "{"
      local first=true
      for f in "$db_path"/*.json; do
        [[ -f "$f" ]] || continue
        local k=$(basename "$f" .json)
        $first || echo ","
        echo -n "  \"$k\": "
        cat "$f" | jq -c .
        first=false
      done
      echo "}"
      return 0
      ;;
      
    destroy)
      # Check if registry directory exists
      if [[ ! -d "$db_path" ]]; then
        return 1
      fi
      
      # Acquire lock for destroy operation
      local destroy_lock="$db_path/.lock/.destroy.lock"
      mkdir -p "$db_path/.lock"
      
      if ! acquire_lock "$destroy_lock" "destroy"; then
        echo "ERROR: Cannot acquire lock for destroy operation" >&2
        return 3
      fi
      
      # Remove entire registry directory
      if rm -rf "$db_path" 2>/dev/null; then
        return 0
      else
        release_lock "$destroy_lock" 2>/dev/null
        echo "ERROR: Failed to remove registry directory: $db_path" >&2
        return 3
      fi
      ;;
      
    *)
      echo "ERROR: Unknown registry command: $cmd" >&2
      return 2
      ;;
  esac
}

#===============================================================================
# acquire_lock / release_lock
# ---------------------------
# Simple file-based locking mechanism with stale lock detection.
#===============================================================================
acquire_lock() {
  local lock_file="${1:?}"
  local op_type="${2:-exclusive}"
  local timeout=50  # 5 seconds (50 * 0.1s)
  local waited=0
  
  while [[ -f "$lock_file" ]] && [[ $waited -lt $timeout ]]; do
    # Check if lock holder still exists
    if [[ -f "$lock_file" ]]; then
      local lock_info
      lock_info=$(<"$lock_file")
      local lock_pid
      lock_pid=$(echo "$lock_info" | grep -oP 'pid:\K\d+' || echo "")
      
      # Remove stale lock if process is gone
      if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
        rm -f "$lock_file"
        break
      fi
    fi
    
    sleep 0.1
    ((waited++))
  done
  
  if [[ $waited -eq $timeout ]]; then
    return 1
  fi
  
  # Create lock with metadata
  cat > "$lock_file" <<EOF
ts:$(date +%s)
pid:$$
op:$op_type
host:$(hostname)
EOF
  return 0
}

release_lock() {
  local lock_file="${1:?}"
  rm -f "$lock_file"
  return 0
}

#===============================================================================
# host_registry
# ------------
# JSON registry for host configurations.
# Provides compatibility layer for existing host_config interface.
#
# Pure registry mode - no .conf file fallback.
#
# Usage:
#   host_registry list_all                    # List all hosts
#   host_registry <mac> <command> [key] [value]
#===============================================================================
host_registry() {
  # Handle list_all specially - no MAC required
  if [[ "${1:-}" == "list_all" ]]; then
    local hosts_dir
    hosts_dir=$(hps_get_config cluster_hosts) || {
      echo "ERROR: Cannot determine cluster hosts directory" >&2
      return 1
    }
    
    find "$hosts_dir" -maxdepth 1 -type d -name "*.db" ! -name ".db" 2>/dev/null | \
      while IFS= read -r db_path; do
        basename "$db_path" .db
      done | sort
    return 0
  fi
  
  # All other commands require MAC as first parameter
  local mac="${1:?Usage: host_registry <mac> <command> [key] [value]}"
  local cmd="${2:?}"
  local key="${3:-}"
  local value="${4:-}"
  
  # Normalize MAC
  local mac_normalized
  mac_normalized=$(normalise_mac "$mac") || {
    echo "ERROR: Failed to normalize MAC address: $mac" >&2
    return 1
  }
  
  # Get hosts directory
  local hosts_dir
  hosts_dir=$(hps_get_config cluster_hosts) || {
    echo "ERROR: Cannot determine cluster hosts directory" >&2
    return 1
  }
  
  local db_path="${hosts_dir}/${mac_normalized}.db"
  
  case "$cmd" in
    exists)
      # If no key specified, check if host exists
      if [[ -z "$key" ]]; then
        [[ -d "$db_path" ]]
        return $?
      fi
      
      # Check if specific key exists
      json_registry "$db_path" exists "$key" >/dev/null 2>&1
      return $?
      ;;
      
    get)
      json_registry "$db_path" get "$key"
      return $?
      ;;
      
    equals)
      local stored
      stored=$(json_registry "$db_path" get "$key" 2>/dev/null)
      [[ "$stored" == "$value" ]]
      return $?
      ;;
      
    set)
      # Wrap non-JSON values in quotes
      if ! echo "$value" | jq . >/dev/null 2>&1; then
        value="\"$value\""
      fi
      
      json_registry "$db_path" set "$key" "$value"
      
      # Update timestamp
      local ts="\"$(make_timestamp)\""
      json_registry "$db_path" set "UPDATED" "$ts" >/dev/null 2>&1
      
      hps_log info "[$mac] registry updated: $key"
      return $?
      ;;
      
    delete|unset)
      json_registry "$db_path" delete "$key"
      return $?
      ;;
      
    list)
      json_registry "$db_path" list
      return $?
      ;;
      
    count)
      json_registry "$db_path" count
      return $?
      ;;
      
    view)
      json_registry "$db_path" view
      return $?
      ;;
      
    destroy)
      json_registry "$db_path" destroy
      return $?
      ;;
      
    *)
      echo "ERROR: Unknown command: $cmd" >&2
      return 2
      ;;
  esac
}

#===============================================================================
# cluster_registry
# ---------------
# JSON registry for cluster configurations.
# Pure registry mode - no .conf file fallback.
#
# Usage:
#   cluster_registry <cluster_name> <command> <key> [value]
#   cluster_registry list_all                              # Special command
#   cluster_registry exists <cluster_name>                 # Special command
#
# Parameters:
#   cluster_name - Name of cluster to operate on (e.g., "test-1", "prod")
#   command      - Operation to perform (get, set, delete, exists, list, view, destroy)
#   key          - Configuration key
#   value        - Value to set (optional, only for set command)
#
# Special Commands (no cluster_name parameter):
#   list_all     - List all cluster names
#   exists       - Check if cluster exists (cluster_name becomes second parameter)
#
# Examples:
#   # Get active cluster first
#   CLUSTER=$(hps_get_config active_cluster) || return 1
#   
#   # Then use it explicitly
#   cluster_registry "$CLUSTER" get network_dhcp_ip
#   cluster_registry "$CLUSTER" set dns_domain "cluster.local"
#   cluster_registry "$CLUSTER" list
#   
#   # List all clusters
#   cluster_registry list_all
#   
#   # Check if specific cluster exists
#   cluster_registry exists test-2
#
# Returns:
#   0 on success
#   1 if cluster not found or key not found
#   2 if invalid parameters or JSON
#   3 if lock timeout
#
#===============================================================================
cluster_registry() {
  local first_arg="${1:-}"
  
  # Handle special commands that don't follow cluster_name pattern
  case "$first_arg" in
    list_all)
      # List all clusters (all cluster.db directories)
      local config_base
      config_base=$(hps_get_config config_base) || {
        hps_log error "Cannot determine config base directory"
        return 1
      }
      
      local clusters_dir="${config_base}/clusters"
      
      find "$clusters_dir" -mindepth 2 -maxdepth 2 -type d -name "cluster.db" 2>/dev/null | \
        while IFS= read -r db_path; do
          basename "$(dirname "$db_path")"
        done | sort
      return 0
      ;;
      
    exists)
      # Check if cluster exists: cluster_registry exists <cluster_name>
      local cluster_name="${2:-}"
      if [[ -z "$cluster_name" ]]; then
        hps_log error "Usage: cluster_registry exists <cluster_name>"
        return 2
      fi
      
      local config_base
      config_base=$(hps_get_config config_base) || {
        hps_log error "Cannot determine config base directory"
        return 1
      }
      
      local cluster_dir="${config_base}/clusters/${cluster_name}"
      [[ -d "$cluster_dir/cluster.db" ]]
      return $?
      ;;
      
    "")
      hps_log error "Usage: cluster_registry <cluster_name> <command> [key] [value]"
      return 2
      ;;
      
    *)
      # Normal operation: cluster_registry <cluster_name> <command> <key> [value]
      local cluster_name="$first_arg"
      local cmd="${2:-}"
      local key="${3:-}"
      local value="${4:-}"
      
      if [[ -z "$cmd" ]]; then
        hps_log error "Usage: cluster_registry <cluster_name> <command> [key] [value]"
        return 2
      fi
      
      # Validate cluster name (alphanumeric, underscore, dash)
      if [[ ! "$cluster_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        hps_log error "Invalid cluster name format: $cluster_name"
        return 2
      fi
      
      # Get config base
      local config_base
      config_base=$(hps_get_config config_base) || {
        hps_log error "Cannot determine config base directory"
        return 1
      }
      
      # Build cluster directory path
      local cluster_dir="${config_base}/clusters/${cluster_name}"
      local db_path="${cluster_dir}/cluster.db"
      
      # Validate cluster exists (except for destroy which handles non-existent)
      if [[ "$cmd" != "destroy" ]] && [[ ! -d "$cluster_dir" ]]; then
        hps_log error "Cluster not found: $cluster_name"
        return 1
      fi
      
      # Execute command
      case "$cmd" in
        get|exists)
          json_registry "$db_path" "$cmd" "$key"
          return $?
          ;;
          
        set)
          # Wrap non-JSON values in quotes
          if ! echo "$value" | jq . >/dev/null 2>&1; then
            value="\"$value\""
          fi
          json_registry "$db_path" set "$key" "$value"
          return $?
          ;;
          
        delete|unset)
          json_registry "$db_path" delete "$key"
          return $?
          ;;
          
        list)
          json_registry "$db_path" list
          return $?
          ;;
          
        count)
          json_registry "$db_path" count
          return $?
          ;;
          
        view)
          json_registry "$db_path" view
          return $?
          ;;
          
        destroy)
          json_registry "$db_path" destroy
          return $?
          ;;
          
        *)
          hps_log error "Unknown command: $cmd"
          return 2
          ;;
      esac
      ;;
  esac
}



#===============================================================================
# system_registry
# --------------
# System-level registry for global HPS configuration.
# Replaces hps.conf and active-cluster symlink.
#
# Usage:
#   system_registry get <key>
#   system_registry set <key> <value>
#   system_registry exists <key>
#   system_registry destroy
#===============================================================================
system_registry() {
  local cmd="${1:?Usage: system_registry <command> <key> [value]}"
  local key="${2:-}"
  local value="${3:-}"
  
  local db_path="${HPS_SYSTEM_REGISTRY}"
  
  case "$cmd" in
    set)
      # Wrap non-JSON values in quotes
      if ! echo "$value" | jq . >/dev/null 2>&1; then
        value="\"$value\""
      fi
      json_registry "$db_path" set "$key" "$value"
      ;;
    get|delete|exists|list|count|view|destroy)
      json_registry "$db_path" "$cmd" "$key" "$value"
      ;;
    list_all)
      # Not applicable for system registry (only one system registry exists)
      echo "ERROR: list_all not applicable for system_registry" >&2
      return 2
      ;;
    *)
      echo "ERROR: Unknown command: $cmd" >&2
      return 2
      ;;
  esac
}

#===============================================================================
# os_registry 
# ----------
# Operating system registry for OS configurations.
# Replaces os.conf INI-style format.
#
# Usage:
#   os_registry <os_id> get <key>
#   os_registry <os_id> set <key> <value>
#   os_registry <os_id> exists <key>
#   os_registry <os_id> destroy
#   os_registry list
#===============================================================================
os_registry() {
  local os_id="${1:-}"
  
  # Handle list command (no os_id required)
  if [[ "$os_id" == "list" ]]; then
    local os_db="/srv/hps-config/os.db"
    
    # Find all .os directories and read the stored os_id
    find "$os_db" -maxdepth 1 -type d -name "*.os" 2>/dev/null | \
      while IFS= read -r os_dir; do
        local id_file="${os_dir}/.os_id"
        
        # If .os_id file exists, use it (new format)
        if [[ -f "$id_file" ]]; then
          cat "$id_file"
        else
          # Fallback: try to reconstruct from directory name (legacy)
          local dir_name=$(basename "$os_dir" .os)
          
          # Simple heuristic: arch is always first component (x86_64, aarch64, etc)
          # Version is always last component (numeric with dots)
          # Everything in between is the name
          
          # Get version (last underscore-separated component that starts with a digit)
          local version="${dir_name##*_}"
          
          # If version doesn't start with digit, reconstruction failed
          if [[ ! "$version" =~ ^[0-9] ]]; then
            echo "WARNING: Cannot parse OS directory: $dir_name" >&2
            continue
          fi
          
          # Remove version from end
          local without_version="${dir_name%_${version}}"
          
          # Arch is first component
          local arch="${without_version%%_*}"
          
          # Name is everything between arch and version
          local name="${without_version#${arch}_}"
          
          echo "${arch}:${name}:${version}"
        fi
      done | sort
    
    return 0
  fi
  
  local cmd="${2:?Usage: os_registry <os_id> <command> [key] [value]}"
  local key="${3:-}"
  local value="${4:-}"
  
  # Convert os_id to filesystem-safe name using tr (more reliable than ${var//://_})
  local os_safe
  os_safe=$(echo "$os_id" | tr ':' '_')
  local db_path="/srv/hps-config/os.db/${os_safe}.os"
  
  case "$cmd" in
    exists)
      # If no key specified, check if OS exists
      if [[ -z "$key" ]]; then
        [[ -d "$db_path" ]]
        return $?
      else
        # Check if specific key exists
        json_registry "$db_path" exists "$key"
        return $?
      fi
      ;;
    set)
      # Wrap non-JSON values in quotes
      if ! echo "$value" | jq . >/dev/null 2>&1; then
        value="\"$value\""
      fi
      
      # Store the OS ID for reliable listing
      local id_file="$db_path/.os_id"
      if [[ ! -f "$id_file" ]]; then
        mkdir -p "$db_path"
        echo "$os_id" > "$id_file"
      fi
      
      json_registry "$db_path" set "$key" "$value"
      ;;
    get|delete|list|count|view|destroy)
      json_registry "$db_path" "$cmd" "$key" "$value"
      ;;
    *)
      echo "ERROR: Unknown command: $cmd" >&2
      return 2
      ;;
  esac
}

#===============================================================================
# Compatibility Aliases
#===============================================================================
host_config() {
  host_registry "$@"
}

cluster_config() {
  cluster_registry "$@"
}

#===============================================================================
# Registry Search Functions
#===============================================================================
registry_search() {
  local registry_type="${1:?Usage: registry_search <type> <field> <value>}"
  local field="${2:?}"
  local value="${3:?}"
  
  case "$registry_type" in
    host)
      local hosts_dir
      hosts_dir=$(hps_get_config cluster_hosts)
      
      for db in "$hosts_dir"/*.db; do
        [[ -d "$db" ]] || continue
        
        local json_file="$db/${field}.json"
        if [[ -f "$json_file" ]]; then
          # Compare with raw value (quotes stripped)
          local stored_value
          stored_value=$(jq -r . "$json_file" 2>/dev/null)
          if [[ "$stored_value" == "$value" ]]; then
            basename "$db" .db
          fi
        fi
      done
      ;;
      
    cluster)
      local cluster_dir
      cluster_dir=$(hps_get_config cluster_base) || return 1
      local db_path="${cluster_dir}/cluster.db"
      
      local json_file="$db_path/${field}.json"
      if [[ -f "$json_file" ]]; then
        local stored_value
        stored_value=$(jq -r . "$json_file" 2>/dev/null)
        if [[ "$stored_value" == "$value" ]]; then
          echo "cluster"
        fi
      fi
      ;;
  esac
}

#===============================================================================
# Helper: Get active cluster name from system registry
#===============================================================================
get_active_cluster_from_registry() {
  system_registry get "ACTIVE_CLUSTER" 2>/dev/null
}

#===============================================================================
# Helper: Set active cluster in system registry
#===============================================================================
set_active_cluster_in_registry() {
  local cluster_name="${1:?}"
  system_registry set "ACTIVE_CLUSTER" "$cluster_name"
}
