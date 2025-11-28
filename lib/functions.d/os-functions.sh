__guard_source || return

#===============================================================================
# OS Configuration Registry Core Functions
# ----------------------------------------
# Manages OS configurations for HPS system using JSON registry.
# Supports architecture-specific OS entries using colon delimiter.
#
# Format: <arch>:<name>:<version>
# Example: x86_64:rocky:10.0
#
# Storage: /srv/hps-config/os.db/<arch>_<name>_<version>.os/
#===============================================================================

#===============================================================================
# os_config
# ---------
# Manage OS registry configuration.
#
# Behaviour:
#   - get: retrieves a value for a given OS and key
#   - set: sets a value for a given OS and key
#   - exists: checks if an OS section exists
#   - undefine: removes an entire OS section or a specific key
#
# Arguments:
#   $1: OS identifier (e.g., "x86_64:rocky:10.0")
#   $2: Operation (get, set, exists, undefine)
#   $3: Key name (for get/set/undefine operations)
#   $4: Value (for set operation only)
#
# Returns:
#   0 on success
#   1 on error or not found
#
# Example usage:
#   os_config "x86_64:rocky:10.0" "get" "status"
#   os_config "x86_64:rocky:10.0" "set" "status" "prod"
#   os_config "x86_64:rocky:10.0" "exists"
#   os_config "x86_64:rocky:10.0" "undefine" "status"
#   os_config "x86_64:rocky:10.0" "undefine"
#
#===============================================================================
os_config() {
  local os_id="$1"
  local operation="$2"
  local key="${3:-}"
  local value="${4:-}"
  
  case "$operation" in
    get)
      os_config_get "$os_id" "$key"
      ;;
    set)
      os_config_set "$os_id" "$key" "$value"
      ;;
    exists)
      os_config_exists "$os_id"
      ;;
    undefine)
      if [[ -n "$key" ]]; then
        os_config_undefine_key "$os_id" "$key"
      else
        os_config_undefine_section "$os_id"
      fi
      ;;
    *)
      echo "Error: Unknown operation '$operation'" >&2
      return 1
      ;;
  esac
}

#===============================================================================
# os_config_get
# -------------
# Get a value from the OS registry for a specific OS and key.
#
# Behaviour:
#   - Uses os_registry to retrieve value
#   - Returns raw value (quotes stripped automatically)
#
# Arguments:
#   $1: OS identifier (e.g., "x86_64:rocky:10.0")
#   $2: Key name
#
# Returns:
#   0 if found, 1 if not found
#
# Example usage:
#   status=$(os_config_get "x86_64:rocky:10.0" "status")
#
#===============================================================================
os_config_get() {
  local os_id="$1"
  local key="$2"
  
  os_registry "$os_id" get "$key"
}

#===============================================================================
# os_config_set
# -------------
# Set a value in the OS registry for a specific OS and key.
#
# Behaviour:
#   - Uses os_registry to store value
#   - Auto-wraps non-JSON values in quotes
#   - Creates OS directory if it doesn't exist
#
# Arguments:
#   $1: OS identifier (e.g., "x86_64:rocky:10.0")
#   $2: Key name
#   $3: Value
#
# Returns:
#   0 on success, 1 on error
#
# Example usage:
#   os_config_set "x86_64:rocky:10.0" "status" "prod"
#
#===============================================================================
os_config_set() {
  local os_id="$1"
  local key="$2"
  local value="$3"
  
  os_registry "$os_id" set "$key" "$value"
}

#===============================================================================
# os_config_exists
# ----------------
# Check if an OS section exists in the registry.
#
# Behaviour:
#   - Checks if OS directory exists in registry
#
# Arguments:
#   $1: OS identifier (e.g., "x86_64:rocky:10.0")
#
# Returns:
#   0 if exists, 1 if not found
#
# Example usage:
#   if os_config_exists "x86_64:rocky:10.0"; then
#     echo "Rocky 10 for x86_64 is configured"
#   fi
#
#===============================================================================
os_config_exists() {
  local os_id="$1"
  
  os_registry "$os_id" exists
}

#===============================================================================
# os_config_undefine_key
# ----------------------
# Remove a specific key from an OS section.
#
# Behaviour:
#   - Removes the key's JSON file from the OS directory
#   - Preserves the OS section and other keys
#
# Arguments:
#   $1: OS identifier (e.g., "x86_64:rocky:10.0")
#   $2: Key name to remove
#
# Returns:
#   0 on success, 1 on error
#
# Example usage:
#   os_config_undefine_key "x86_64:rocky:10.0" "min_ram_gb"
#
#===============================================================================
os_config_undefine_key() {
  local os_id="$1"
  local key="$2"
  
  os_registry "$os_id" delete "$key"
}

#===============================================================================
# os_config_undefine_section
# --------------------------
# Remove an entire OS section from the registry.
#
# Behaviour:
#   - Removes the entire OS directory and all keys within it
#   - Logs details of what was removed
#
# Arguments:
#   $1: OS identifier (e.g., "x86_64:rocky:10.0")
#
# Returns:
#   0 on success, 1 if not found
#
# Example usage:
#   os_config_undefine_section "x86_64:rocky:9.3"
#
#===============================================================================
os_config_undefine_section() {
  local os_id="$1"
  
  # Convert OS ID to filesystem-safe name
  local os_safe
  os_safe=$(echo "$os_id" | tr ':' '_')
  local db_path="/srv/hps-config/os.db/${os_safe}.os"
  
  if [[ ! -d "$db_path" ]]; then
    hps_log error "OS configuration not found: $os_id"
    return 1
  fi
  
  # Count keys before removal for logging
  local key_count=0
  if [[ -d "$db_path" ]]; then
    key_count=$(find "$db_path" -maxdepth 1 -name "*.json" -type f 2>/dev/null | wc -l)
  fi
  
  # List keys for detailed logging
  local keys=""
  if [[ $key_count -gt 0 ]]; then
    keys=$(find "$db_path" -maxdepth 1 -name "*.json" -type f 2>/dev/null | \
           xargs -r basename -s .json 2>/dev/null | \
           tr '\n' ',' | sed 's/,$//')
  fi
  
  # Remove the directory
  rm -rf "$db_path"
  
  if [[ $? -eq 0 ]]; then
    hps_log info "Removed OS configuration: $os_id (${key_count} keys: ${keys:-none})"
    return 0
  else
    hps_log error "Failed to remove OS configuration: $os_id"
    return 1
  fi
}
