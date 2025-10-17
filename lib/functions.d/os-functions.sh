__guard_source || return


#===============================================================================
# _get_os_conf_path
# -----------------
# Internal helper function to get the OS config file path.
#
# Behaviour:
#   - Returns the test file path if OS_CONFIG_TEST_FILE is set
#
# Returns:
#   Path to the OS config file
#
# Example usage:
#   local os_conf=$(_get_os_conf_path)
#
#===============================================================================
_get_os_conf_path() {
  echo "${HPS_CONFIG_BASE}/os.conf"
}


#!/bin/bash
#===============================================================================
# OS Configuration Registry Core Functions
# ----------------------------------------
# Manages OS configurations for HPS system in INI format.
# Supports architecture-specific OS entries using colon delimiter.
#
# Format: <arch>:<name>:<version>
# Example: x86_64:rocky:10.0
#
# File location: /srv/hps-config/os.conf
#===============================================================================


#===============================================================================
# os_config
# ---------
# Manage OS registry configuration in INI format.
#
# Behaviour:
#   - get: retrieves a value for a given OS and key
#   - set: sets a value for a given OS and key
#   - exists: checks if an OS section exists
#   - undefine: removes an entire OS section or a specific key
#
# Arguments:
#   $1: OS identifier (section name, e.g., "x86_64:rocky:10.0")
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
  local key="${3:-}"      # Use default empty string if not provided
  local value="${4:-}"    # Use default empty string if not provided
  
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
#   - Reads the INI file and extracts the value for the given section and key
#   - Outputs the value to stdout
#   - Handles OS IDs with colon delimiters (arch:name:version)
#
# Arguments:
#   $1: OS identifier (section name)
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
  local os_conf=$(_get_os_conf_path)
  local in_section=0
  local value=""
  
  [[ ! -f "$os_conf" ]] && return 1
  
  while IFS= read -r line; do
    # Skip empty lines and comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    
    # Check for section header
    if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
      if [[ "${BASH_REMATCH[1]}" == "$os_id" ]]; then
        in_section=1
      else
        in_section=0
      fi
      continue
    fi
    
    # If in correct section, look for key
    if [[ $in_section -eq 1 ]] && [[ "$line" =~ ^[[:space:]]*([^=]+)=(.*)$ ]]; then
      local found_key="${BASH_REMATCH[1]}"
      found_key="${found_key%%[[:space:]]}"  # Trim trailing spaces
      found_key="${found_key##[[:space:]]}"  # Trim leading spaces
      
      if [[ "$found_key" == "$key" ]]; then
        value="${BASH_REMATCH[2]}"
        value="${value%%[[:space:]]}"  # Trim trailing spaces
        value="${value##[[:space:]]}"  # Trim leading spaces
        echo "$value"
        return 0
      fi
    fi
  done < "$os_conf"
  
  return 1
}

#===============================================================================
# os_config_set
# -------------
# Set a value in the OS registry for a specific OS and key.
#
# Behaviour:
#   - Updates existing key or adds new key in the section
#   - Creates section if it doesn't exist
#   - Preserves comments and formatting
#   - Handles OS IDs with colon delimiters (arch:name:version)
#
# Arguments:
#   $1: OS identifier (section name)
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
  local os_conf=$(_get_os_conf_path)
  local temp_file=$(mktemp)
  local in_section=0
  local section_exists=0
  local key_updated=0
  
  [[ ! -f "$os_conf" ]] && touch "$os_conf"
  
  # Process the file (or handle empty file)
  if [[ -s "$os_conf" ]]; then
    while IFS= read -r line; do
      # Check for section header
      if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
        # If we were in the target section and key wasn't found, add it
        if [[ $in_section -eq 1 && $key_updated -eq 0 ]]; then
          echo "${key}=${value}" >> "$temp_file"
          key_updated=1
        fi
        
        if [[ "${BASH_REMATCH[1]}" == "$os_id" ]]; then
          in_section=1
          section_exists=1
        else
          in_section=0
        fi
        echo "$line" >> "$temp_file"
        continue
      fi
      
      # If in correct section, check for key
      if [[ $in_section -eq 1 ]] && [[ "$line" =~ ^[[:space:]]*([^=]+)=(.*)$ ]]; then
        local found_key="${BASH_REMATCH[1]}"
        found_key="${found_key%%[[:space:]]}"  # Trim trailing spaces
        found_key="${found_key##[[:space:]]}"  # Trim leading spaces
        
        if [[ "$found_key" == "$key" ]]; then
          echo "${key}=${value}" >> "$temp_file"
          key_updated=1
          continue
        fi
      fi
      
      echo "$line" >> "$temp_file"
    done < "$os_conf"
    
    # Handle end of file cases
    if [[ $section_exists -eq 1 && $key_updated -eq 0 ]]; then
      # Section exists but key wasn't found, add it
      echo "${key}=${value}" >> "$temp_file"
    elif [[ $section_exists -eq 0 ]]; then
      # Section doesn't exist, create it
      [[ -s "$temp_file" ]] && echo "" >> "$temp_file"  # Add blank line if file not empty
      echo "[${os_id}]" >> "$temp_file"
      echo "${key}=${value}" >> "$temp_file"
    fi
  else
    # File is empty, create first section
    echo "[${os_id}]" >> "$temp_file"
    echo "${key}=${value}" >> "$temp_file"
  fi
  
  # Replace original file
  mv "$temp_file" "$os_conf"
  return 0
}

#===============================================================================
# os_config_exists
# ----------------
# Check if an OS section exists in the registry.
#
# Behaviour:
#   - Searches for the section header in the INI file
#   - Handles OS IDs with colon delimiters (arch:name:version)
#
# Arguments:
#   $1: OS identifier (section name)
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
  local os_conf=$(_get_os_conf_path)
  
  [[ ! -f "$os_conf" ]] && return 1
  
  # Use grep with fixed string to avoid regex issues with colons
  grep -qF "[${os_id}]" "$os_conf"
  return $?
}

#===============================================================================
# os_config_undefine_key
# ----------------------
# Remove a specific key from an OS section.
#
# Behaviour:
#   - Removes the key=value line from the specified section
#   - Preserves the section and other keys
#
# Arguments:
#   $1: OS identifier (section name)
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
  local os_conf=$(_get_os_conf_path)
  local temp_file=$(mktemp)
  local in_section=0
  
  [[ ! -f "$os_conf" ]] && return 1
  
  while IFS= read -r line; do
    # Check for section header
    if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
      if [[ "${BASH_REMATCH[1]}" == "$os_id" ]]; then
        in_section=1
      else
        in_section=0
      fi
      echo "$line" >> "$temp_file"
      continue
    fi
    
    # If in correct section, check for key to skip
    if [[ $in_section -eq 1 ]] && [[ "$line" =~ ^[[:space:]]*([^=]+)=(.*)$ ]]; then
      local found_key="${BASH_REMATCH[1]}"
      found_key="${found_key%%[[:space:]]}"  # Trim trailing spaces
      found_key="${found_key##[[:space:]]}"  # Trim leading spaces
      
      if [[ "$found_key" == "$key" ]]; then
        continue  # Skip this line
      fi
    fi
    
    echo "$line" >> "$temp_file"
  done < "$os_conf"
  
  mv "$temp_file" "$os_conf"
  return 0
}

#===============================================================================
# os_config_undefine_section
# --------------------------
# Remove an entire OS section from the registry.
#
# Behaviour:
#   - Removes the section header and all keys within it
#   - Preserves other sections and comments
#
# Arguments:
#   $1: OS identifier (section name)
#
# Returns:
#   0 on success, 1 on error
#
# Example usage:
#   os_config_undefine_section "x86_64:rocky:9.3"
#
#===============================================================================
os_config_undefine_section() {
  local os_id="$1"
  local os_conf=$(_get_os_conf_path)
  local temp_file=$(mktemp)
  local in_section=0
  
  [[ ! -f "$os_conf" ]] && return 1
  
  while IFS= read -r line; do
    # Check for section header
    if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
      if [[ "${BASH_REMATCH[1]}" == "$os_id" ]]; then
        in_section=1
        continue  # Skip this section header
      else
        in_section=0
      fi
    fi
    
    # Skip all lines in the target section
    if [[ $in_section -eq 1 ]]; then
      # Skip empty lines and content in target section
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# || "$line" =~ ^[[:space:]]*[^=]+=.*$ ]] && continue
    fi
    
    echo "$line" >> "$temp_file"
  done < "$os_conf"
  
  mv "$temp_file" "$os_conf"
  return 0
}
