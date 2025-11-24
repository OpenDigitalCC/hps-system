#!/bin/bash
#===============================================================================
# OS Configuration Helper Functions with Architecture Support
# -----------------------------------------------------------
# Helper functions for managing OS versions with architecture and minor version
# support using colon delimiter format: <arch>:<name>:<version>
#===============================================================================




_get_distro_dir () {
  echo "${HPS_DISTROS_DIR}"
}


#===============================================================================
# os_get_latest
# -------------
# Get the latest version of an OS from the registry.
#
# Behaviour:
#   - Scans all OS entries for the given OS name
#   - Finds the highest version number
#   - Returns the full OS ID (arch:name:version) of the latest version
#   - Assumes versions are numeric/sortable (e.g., 3.20, 10.0)
#
# Arguments:
#   $1: OS name (e.g., "alpine", "rocky", "rockylinux")
#
# Returns:
#   Latest OS ID on stdout, or nothing if not found
#   Exit code: 0 if found, 1 if not found
#
# Example usage:
#   latest=$(os_get_latest "alpine")           # x86_64:alpine:3.20
#   latest=$(os_get_latest "rockylinux")       # x86_64:rockylinux:10.0
#
#===============================================================================
os_get_latest() {
  local os_name="$1"
  local os_conf=$(_get_os_conf_path)
  local latest_version=""
  local latest_os_id=""
  
  [[ ! -f "$os_conf" ]] && return 1
  
  # Extract all section headers and find matching OS entries
  while IFS= read -r line; do
    if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
      local os_id="${BASH_REMATCH[1]}"
      
      # Parse the OS ID (arch:name:version)
      local IFS=':'
      read -r arch name version <<< "$os_id"
      
      # Check if this matches our OS name
      if [[ "$name" == "$os_name" ]]; then
        # Compare versions - using sort -V for version comparison
        if [[ -z "$latest_version" ]]; then
          latest_version="$version"
          latest_os_id="$os_id"
        else
          # Check if this version is newer
          local higher_version
          higher_version=$(printf '%s\n%s\n' "$version" "$latest_version" | sort -V | tail -1)
          
          if [[ "$higher_version" == "$version" && "$version" != "$latest_version" ]]; then
            latest_version="$version"
            latest_os_id="$os_id"
          fi
        fi
      fi
    fi
  done < "$os_conf"
  
  if [[ -n "$latest_os_id" ]]; then
    echo "$latest_os_id"
    return 0
  else
    return 1
  fi
}


#===============================================================================
# os_id_to_distro
# ---------------
# Convert OS_ID format to distro string format for node_build_functions.
#
# Arguments:
#   $1: OS_ID (e.g., "x86_64:alpine:3.20")
#
# Returns:
#   Distro string (e.g., "x86_64-linux-alpine-3.20")
#
# Example:
#   distro=$(os_id_to_distro "x86_64:alpine:3.20")
#   # Returns: x86_64-linux-alpine-3.20
#
#===============================================================================
os_id_to_distro() {
  local os_id="$1"
  
  if [[ -z "$os_id" ]]; then
    hps_log error "os_id_to_distro: OS_ID required"
    return 1
  fi
  
  # Parse components: x86_64:alpine:3.20 -> arch:name:version
  IFS=':' read -r arch osname version <<< "$os_id"
  
  # Build distro string: arch-mfr-osname-version
  echo "${arch}-linux-${osname}-${version}"
}



#===============================================================================
# get_os_name_version
# -------------------
# Extract name and version from OS ID, without architecture.
#
# Arguments:
#   $1: OS ID (e.g., "x86_64:alpine:3.20")
#   $2: Format (optional): "colon" (default) or "underscore"
#
# Returns:
#   Name and version (e.g., "alpine:3.20" or "alpine_3.20")
#
# Example usage:
#   name_ver=$(get_os_name_version "x86_64:alpine:3.20")           # alpine:3.20
#   name_ver=$(get_os_name_version "x86_64:alpine:3.20" underscore) # alpine_3.20
#
#===============================================================================
get_os_name_version() {
  local os_id="$1"
  local format="${2:-colon}"
  
  # Strip architecture prefix (everything before first colon)
  local name_version="${os_id#*:}"
  
  # Apply format if requested
  if [[ "$format" == "underscore" ]]; then
    name_version="${name_version//:/_}"
  fi
  
  echo "$name_version"
}

#===============================================================================
# get_os_name
# -----------
# Extract OS name from OS ID, without architecture or version.
#
# Arguments:
#   $1: OS ID (e.g., "x86_64:alpine:3.20")
#
# Returns:
#   OS name only (e.g., "alpine")
#
# Example usage:
#   os_name=$(get_os_name "x86_64:alpine:3.20")           # alpine
#   os_name=$(get_os_name "x86_64:rockylinux:9.3")        # rockylinux
#
#===============================================================================
get_os_name() {
  local os_id="$1"
  
  # Strip architecture prefix (everything before first colon)
  local name_version="${os_id#*:}"
  
  # Extract just the name (everything before the second colon)
  local name="${name_version%%:*}"
  
  echo "$name"
}



#===============================================================================
# get_distro_base_path
# --------------------
# Get the base path for a distribution, using configured repo_path.
#
# Behaviour:
#   - Uses repo_path from os_config if available
#   - Falls back to converting OS ID if repo_path not set
#   - Returns consistent paths for mounting, HTTP, and filesystem access
#
# Arguments:
#   $1: OS identifier (e.g., "x86_64:rocky:10")
#   $2: Path type (optional): "mount", "http", "relative" (default: "mount")
#
# Returns:
#   Path string appropriate for the requested type
#
#===============================================================================
get_distro_base_path() {
  local os_id="$1"
  local path_type="${2:-mount}"
  local repo_path=""
  
  if [ -z "$os_id" ] ; then
    hps_log error "no O/S ID specified"
    return 1
  fi

  # Try to get configured repo path
  if os_config "$os_id" "exists"; then
    repo_path=$(os_config "$os_id" "get" "repo_path" 2>/dev/null)
   else
    hps_log error "O/S $os_id does not have a repo_path set"
    return 1
  fi

  case "$path_type" in
    mount)
      echo "$(_get_distro_dir)/${repo_path}"
      ;;
    http)
      echo "/distros/${repo_path}"
      ;;
    relative)
      echo "${repo_path}"
      ;;
    *)
      hps_log error "Unknown path type: $path_type"
      return 1
      ;;
  esac
}


#===============================================================================
# get_distro_url
# --------------
# Get the HTTP URL for a distribution.
#
# Arguments:
#   $1: OS identifier
#   $2: Server address (optional, defaults to current server)
#
# Returns:
#   Full HTTP URL to distribution
#
# Example:
#   url=$(get_distro_url "x86_64:rocky:10.0" "${dhcp-server}")
#
#===============================================================================
get_distro_url() {
  local os_id="$1"
  local server="${2:-${SERVER_ADDR}}"
  local http_path=$(get_distro_base_path "$os_id" "http")
  
  echo "http://${server}${http_path}"
}



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
  
  # More robust pattern that handles whitespace and colons
  grep -E '^\[[^]]+\]' "$os_conf" | sed 's/^\[\([^]]*\)\]/\1/'
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
# os_config_by_arch_and_type
# ---------------------------
# Find OS options for a specific architecture and host type.
#
# Arguments:
#   $1: Architecture (x86_64, aarch64, etc.)
#   $2: Host type (TCH, SCH, DRH)
#
# Returns:
#   List of matching OS identifiers
#
# Example:
#   os_config_by_arch_and_type "x86_64" "TCH"
#   os_config_by_arch_and_type "aarch64" "SCH"
#
#===============================================================================
os_config_by_arch_and_type() {
  local req_arch="$1"
  local host_type="$2"
  local found=0
  
  for os_id in $(os_config_list); do
    # Extract architecture from OS ID (first component)
    local id_arch="${os_id%%:*}"
    
    # Also check the arch field for verification
    local conf_arch=$(os_config "$os_id" "get" "arch" 2>/dev/null)
    local types=$(os_config "$os_id" "get" "hps_types" 2>/dev/null)
    
    if [[ "$id_arch" == "$req_arch" || "$conf_arch" == "$req_arch" ]] && \
       [[ "$types" =~ (^|,)${host_type}(,|$) ]]; then
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
#   os_config_get_all "x86_64:rocky:10.0"
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
#   - Groups by architecture
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
  
  echo "Available OS Configurations"
  echo "==========================="
  
  # Group by architecture
  local architectures=()
  for os_id in $(os_config_list); do
    local arch="${os_id%%:*}"
    if [[ ! " ${architectures[@]} " =~ " ${arch} " ]]; then
      architectures+=("$arch")
    fi
  done
  
  # Display each architecture group
  for arch in "${architectures[@]}"; do
    echo ""
    echo "Architecture: $arch"
    echo "-------------------"
    
    for os_id in $(os_config_list | grep "^${arch}:"); do
      local hps_types=$(os_config "$os_id" "get" "hps_types" 2>/dev/null || echo "N/A")
      local name=$(os_config "$os_id" "get" "name" 2>/dev/null || echo "N/A")
      local version=$(os_config "$os_id" "get" "version_full" 2>/dev/null || echo "N/A")
      local status=$(os_config "$os_id" "get" "status" 2>/dev/null || echo "N/A")
      local updated=$(os_config "$os_id" "get" "updated" 2>/dev/null || echo "N/A")
      local notes=$(os_config "$os_id" "get" "notes" 2>/dev/null || echo "")
      
      echo "  [$os_id]"
      echo "    Host Types: $hps_types"
      echo "    OS: $name $version"
      echo "    Status: $status"
      echo "    Updated: $updated"
      [[ -n "$notes" ]] && echo "    Notes: $notes"
    done
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
#   if os_config_validate "x86_64:rocky:10.0"; then
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

#===============================================================================
# parse_os_id
# -----------
# Parse OS ID components from colon-delimited identifier.
#
# Arguments:
#   $1: OS identifier (e.g., "x86_64:rocky:10.0")
#
# Outputs:
#   Sets global variables: OS_ID_ARCH, OS_ID_NAME, OS_ID_VERSION
#
# Example:
#   parse_os_id "x86_64:rocky:10.0"
#   echo "arch=$OS_ID_ARCH name=$OS_ID_NAME version=$OS_ID_VERSION"
#
#===============================================================================
parse_os_id() {
  local os_id="$1"
  IFS=':' read -r OS_ID_ARCH OS_ID_NAME OS_ID_VERSION <<< "$os_id"
}

#===============================================================================
# os_config_latest_minor
# ----------------------
# Find the latest minor version for a given architecture and major version.
#
# Arguments:
#   $1: Pattern to match (e.g., "x86_64:rocky:10", "x86_64:alpine:3.20")
#   $2: Status filter (optional, default: any)
#
# Returns:
#   Latest minor version identifier, empty if none found
#
# Example:
#   latest=$(os_config_latest_minor "x86_64:rocky:10")
#   latest_prod=$(os_config_latest_minor "x86_64:rocky:10" "prod")
#
#===============================================================================
os_config_latest_minor() {
  local pattern="$1"
  local status_filter="${2:-}"
  local latest=""
  local highest_version=""
  
  for os_id in $(os_config_list | grep "^${pattern}"); do
    # Check status if filter provided
    if [[ -n "$status_filter" ]]; then
      local status=$(os_config "$os_id" "get" "status" 2>/dev/null)
      [[ "$status" != "$status_filter" ]] && continue
    fi
    
    local version_full=$(os_config "$os_id" "get" "version_full" 2>/dev/null)
    if [[ -n "$version_full" ]]; then
      if [[ -z "$highest_version" ]] || version_compare "$version_full" ">" "$highest_version"; then
        highest_version="$version_full"
        latest="$os_id"
      fi
    fi
  done
  
  echo "$latest"
}

#===============================================================================
# version_compare
# ---------------
# Compare two version strings.
#
# Arguments:
#   $1: Version 1
#   $2: Operator (>, <, =, >=, <=)
#   $3: Version 2
#
# Returns:
#   0 if comparison is true, 1 if false
#
# Example:
#   version_compare "10.1" ">" "10.0" && echo "10.1 is newer"
#
#===============================================================================
version_compare() {
  local v1="$1"
  local op="$2"
  local v2="$3"
  
  # Convert versions to comparable format (pad with zeros)
  local v1_parts=(${v1//./ })
  local v2_parts=(${v2//./ })
  
  # Pad to same length
  local max_parts=$((${#v1_parts[@]} > ${#v2_parts[@]} ? ${#v1_parts[@]} : ${#v2_parts[@]}))
  
  for ((i=${#v1_parts[@]}; i<max_parts; i++)); do
    v1_parts+=("0")
  done
  
  for ((i=${#v2_parts[@]}; i<max_parts; i++)); do
    v2_parts+=("0")
  done
  
  # Compare each part
  for ((i=0; i<max_parts; i++)); do
    local p1="${v1_parts[i]}"
    local p2="${v2_parts[i]}"
    
    if [[ "$p1" -gt "$p2" ]]; then
      case "$op" in
        ">"|">=") return 0 ;;
        *) return 1 ;;
      esac
    elif [[ "$p1" -lt "$p2" ]]; then
      case "$op" in
        "<"|"<=") return 0 ;;
        *) return 1 ;;
      esac
    fi
  done
  
  # Versions are equal
  case "$op" in
    "="|">="|"<=") return 0 ;;
    *) return 1 ;;
  esac
}

#===============================================================================
# os_config_select
# ----------------
# Select the appropriate OS based on architecture, host type, and version.
#
# Arguments:
#   $1: Architecture
#   $2: Host type  
#   $3: Preferred name and version pattern (optional, e.g., "rocky:10")
#
# Returns:
#   Best matching OS identifier
#
# Example:
#   os_id=$(os_config_select "x86_64" "SCH")
#   os_id=$(os_config_select "aarch64" "TCH" "alpine:3.20")
#
#===============================================================================
os_config_select() {
  local arch="$1"
  local host_type="$2"
  local version_pref="${3:-}"
  
  # First try exact match with preference
  if [[ -n "$version_pref" ]]; then
    local exact="${arch}:${version_pref}"
    if os_config "$exact" "exists"; then
      local types=$(os_config "$exact" "get" "hps_types")
      if [[ "$types" =~ (^|,)${host_type}(,|$) ]]; then
        echo "$exact"
        return 0
      fi
    fi
    
    # Try latest minor of preferred version
    local latest=$(os_config_latest_minor "${arch}:${version_pref}" "prod")
    if [[ -n "$latest" ]]; then
      echo "$latest"
      return 0
    fi
  fi
  
  # Fall back to any prod OS for this arch/type
  for os_id in $(os_config_by_arch_and_type "$arch" "$host_type"); do
    local status=$(os_config "$os_id" "get" "status")
    if [[ "$status" == "prod" ]]; then
      echo "$os_id"
      return 0
    fi
  done
  
  return 1
}
