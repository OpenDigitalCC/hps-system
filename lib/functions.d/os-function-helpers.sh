__guard_source || return


#===============================================================================
# os_config_list
# --------------
# List all configured OS entries.
#
# Behaviour:
#   - Reads the OS config file and outputs all section names
#   - One OS per line
#
# Returns:
#   0 on success
#   1 if config file doesn't exist
#
# Example usage:
#   os_config_list
#   for os in $(os_config_list); do
#     echo "Found OS: $os"
#   done
#
#===============================================================================
os_config_list() {
  local os_conf=$(_get_os_conf_path)
  
  [[ ! -f "$os_conf" ]] && return 1
  
  grep -E '^\[.*\]$' "$os_conf" | sed 's/^\[\(.*\)\]$/\1/'
}

#===============================================================================
# os_config_by_type
# -----------------
# List all OS entries that support a specific host type.
#
# Behaviour:
#   - Searches for OS entries where hps_types contains the specified type
#   - Outputs matching OS identifiers
#
# Arguments:
#   $1: Host type (TCH, SCH, DRH)
#
# Returns:
#   0 if matches found
#   1 if no matches
#
# Example usage:
#   os_config_by_type "TCH"
#   os_config_by_type "SCH"
#
#===============================================================================
os_config_by_type() {
  local host_type="$1"
  local found=0
  
  for os_id in $(os_config_list); do
    local types=$(os_config "$os_id" "get" "hps_types" 2>/dev/null)
    if [[ "$types" =~ (^|,)${host_type}(,|$) ]]; then
      echo "$os_id"
      found=1
    fi
  done
  
  return $((found ? 0 : 1))
}

#===============================================================================
# os_config_get_all
# -----------------
# Get all key-value pairs for a specific OS.
#
# Behaviour:
#   - Outputs all keys and values for the specified OS section
#   - Format: key=value
#
# Arguments:
#   $1: OS identifier
#
# Returns:
#   0 if section found
#   1 if not found
#
# Example usage:
#   os_config_get_all "rocky-10"
#
#===============================================================================
os_config_get_all() {
  local os_id="$1"
  local os_conf=$(_get_os_conf_path)
  local in_section=0
  
  [[ ! -f "$os_conf" ]] && return 1
  
  while IFS= read -r line; do
    # Check for section header
    if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
      if [[ "${BASH_REMATCH[1]}" == "$os_id" ]]; then
        in_section=1
      elif [[ $in_section -eq 1 ]]; then
        # We've left our section
        break
      fi
      continue
    fi
    
    # If in correct section, output key=value pairs
    if [[ $in_section -eq 1 ]] && [[ "$line" =~ ^[[:space:]]*([^=]+)=(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"
      key="${key%%[[:space:]]}"  # Trim trailing spaces
      key="${key##[[:space:]]}"  # Trim leading spaces
      value="${value%%[[:space:]]}"  # Trim trailing spaces  
      value="${value##[[:space:]]}"  # Trim leading spaces
      echo "${key}=${value}"
    fi
  done < "$os_conf"
  
  return $((in_section ? 0 : 1))
}

#===============================================================================
# os_config_summary
# -----------------
# Display a formatted summary of all OS configurations.
#
# Behaviour:
#   - Shows each OS with its key attributes in a readable format
#   - Useful for user selection menus
#
# Returns:
#   0 on success
#
# Example usage:
#   os_config_summary
#
#===============================================================================
os_config_summary() {
  local os_conf=$(_get_os_conf_path)
  
  [[ ! -f "$os_conf" ]] && return 1
  
  echo "Available OS Configurations:"
  echo "============================"
  
  for os_id in $(os_config_list); do
    echo ""
    echo "[$os_id]"
    local hps_types=$(os_config "$os_id" "get" "hps_types" 2>/dev/null || echo "N/A")
    local arch=$(os_config "$os_id" "get" "arch" 2>/dev/null || echo "N/A")
    local name=$(os_config "$os_id" "get" "name" 2>/dev/null || echo "N/A")
    local version=$(os_config "$os_id" "get" "version" 2>/dev/null || echo "N/A")
    local status=$(os_config "$os_id" "get" "status" 2>/dev/null || echo "N/A")
    local updated=$(os_config "$os_id" "get" "updated" 2>/dev/null || echo "N/A")
    local notes=$(os_config "$os_id" "get" "notes" 2>/dev/null || echo "")
    
    echo "  Host Types: $hps_types"
    echo "  OS: $name $version ($arch)"
    echo "  Status: $status"
    echo "  Updated: $updated"
    [[ -n "$notes" ]] && echo "  Notes: $notes"
  done
  
  return 0
}

#===============================================================================
# os_config_validate
# ------------------
# Validate that an OS configuration has all required fields.
#
# Behaviour:
#   - Checks for required fields: hps_types, arch, name, version, status
#   - Outputs any missing fields
#
# Arguments:
#   $1: OS identifier
#
# Returns:
#   0 if valid
#   1 if missing required fields
#
# Example usage:
#   if os_config_validate "rocky-10"; then
#     echo "OS config is valid"
#   fi
#
#===============================================================================
os_config_validate() {
  local os_id="$1"
  local required_fields=("hps_types" "arch" "name" "version" "status")
  local missing_fields=()
  local valid=0
  
  if ! os_config "$os_id" "exists"; then
    echo "Error: OS '$os_id' does not exist" >&2
    return 1
  fi
  
  for field in "${required_fields[@]}"; do
    if ! os_config "$os_id" "get" "$field" >/dev/null 2>&1; then
      missing_fields+=("$field")
      valid=1
    fi
  done
  
  if [[ $valid -ne 0 ]]; then
    echo "Error: OS '$os_id' missing required fields: ${missing_fields[*]}" >&2
  fi
  
  return $valid
}

