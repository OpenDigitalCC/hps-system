

#===============================================================================
# hps_get_remote_functions
# ------------------------
# Generate function bundle for the requesting remote node.
#
# Behaviour:
#   - Uses $mac from CGI context (already set by hps_origin_tag)
#   - Looks up os_id, TYPE, PROFILE, STATE, RESCUE from host_config
#   - Converts os_id to node-manager format (os-majorver)
#   - Calls node_build_functions to generate bundle
#   - Outputs function bundle to stdout
#
# Returns:
#   0 on success
#   1 if os_id not found or empty
#
# Example:
#   # In CGI context where $mac is already set
#   hps_get_remote_functions
#
#===============================================================================
hps_get_remote_functions() {
  local os_id type profile state rescue
  
  # Get os_id from host config (using $mac from CGI context)
  if ! os_id=$(host_registry "$mac" get os_id 2>/dev/null); then
    hps_log error "Could not retrieve os_id for MAC $mac"
    return 1
  fi
  
  if [[ -z "$os_id" ]]; then
    hps_log error "os_id is empty for MAC $mac"
    return 1
  fi
  
  # Get type, profile, state, rescue
  type=$(host_registry "$mac" get TYPE 2>/dev/null || echo "")
  profile=$(host_registry "$mac" get PROFILE 2>/dev/null || echo "DEFAULT")
  state=$(host_registry "$mac" get STATE 2>/dev/null || echo "RUNNING")
  rescue=$(host_registry "$mac" get RESCUE 2>/dev/null || echo "false")
  
  hps_log info "Building function bundle for MAC $mac"
  hps_log info "  OS: $os_id, Type: ${type:-<unset>}, Profile: $profile, State: $state, Rescue: $rescue"
  
  # Generate and output function bundle
  node_build_functions "$os_id" "$type" "$profile" "$state" "$rescue"
  return 0
}


#===============================================================================
# node_build_functions
# --------------------
# Build complete function bundle for a node using hierarchical loading.
#
# Behaviour:
#   - Loads libraries in hierarchical cascade: base → OS → TYPE → PROFILE
#   - Adds STATE overlay if applicable (+INSTALLING)
#   - Adds RESCUE overlay if rescue=true
#   - Selects and concatenates init files based on metadata
#   - Later files override earlier functions
#
# Arguments:
#   $1 - os_id   : Full OS identifier (e.g., "alpine-3.20.2")
#   $2 - type    : Node type (SCH, TCH, DRH, or empty)
#   $3 - profile : Profile (DEFAULT, KVM, or empty)
#   $4 - state   : State (RUNNING, INSTALLING, etc.)
#   $5 - rescue  : Rescue flag (true/false)
#
# Returns:
#   Function bundle to stdout
#   0 on success, 1 on error
#
# Example usage:
#   node_build_functions "alpine-3.20.2" "SCH" "DEFAULT" "RUNNING" "false"
#
#===============================================================================
node_build_functions() {
  local os_id="$1"
  local type="$2"
  local profile="${3:-DEFAULT}"
  local state="${4:-RUNNING}"
  local rescue="${5:-false}"
  
  # Parse os_id using standard format: x86_64:alpine:3.20.2
  # Extract components using IFS
  local os_arch os_name os_full_version os_major_version os_dir
  IFS=':' read -r os_arch os_name os_full_version <<< "$os_id"
  
  # Extract major version: 3.20.2 → 3
  os_major_version="${os_full_version%%.*}"
  
  # Build os_dir for directory lookup: alpine-3
  os_dir="${os_name}-${os_major_version}"
  
  local node_manager_base="${HPS_SYSTEM_BASE}/node-manager"
  
  hps_log info "Building function bundle for: $os_dir"
  hps_log debug "  Full os_id: $os_id"
  hps_log debug "  Architecture: $os_arch"
  hps_log debug "  OS name: $os_name"
  hps_log debug "  OS version: $os_full_version (major: $os_major_version)"
  hps_log debug "  Type: ${type:-<none>}"
  hps_log debug "  Profile: $profile"
  hps_log debug "  State: $state"
  hps_log debug "  Rescue: $rescue"
  hps_log debug "  Base directory: $node_manager_base"
  
  # Validate node-manager directory exists
  if [[ ! -d "$node_manager_base" ]]; then
    hps_log error "node-manager directory not found: $node_manager_base"
    return 1
  fi
  
  # Header
  echo "# Node Function Bundle"
  echo "# Generated: $(date -Iseconds)"
  echo "# OS ID: $os_id"
  echo "# OS: $os_dir ($os_name $os_full_version)"
  echo "# Architecture: $os_arch"
  echo "# Type: ${type:-<none>}"
  echo "# Profile: $profile"
  echo "# State: $state"
  [[ "$rescue" == "true" ]] && echo "# RESCUE: true"
  echo ""
  
  # Relay IPS utility functions
  echo "# === IPS Utility Functions ==="
  declare -f urlencode
  declare -f netmask_to_cidr
  echo ""
  
  local file_count=0
  
  #---------------------------------------------------------------------------
  # Load libraries in hierarchical order
  #---------------------------------------------------------------------------
  
  # 1. Base libraries (always loaded)
  if [[ -d "$node_manager_base/base" ]]; then
    hps_log debug "Loading base libraries"
    _load_library_dir "$node_manager_base/base" "Base Libraries"
    file_count=$((file_count + _LOADED_COUNT))
  fi
  
  # 2. OS base libraries
  if [[ -d "$node_manager_base/$os_dir" ]]; then
    hps_log debug "Loading OS base: $os_dir"
    _load_library_dir "$node_manager_base/$os_dir" "OS Base: $os_dir"
    file_count=$((file_count + _LOADED_COUNT))
  else
    hps_log warn "OS directory not found: $node_manager_base/$os_dir"
  fi
  
  # 3. TYPE libraries
  if [[ -n "$type" ]] && [[ -d "$node_manager_base/$os_dir/$type" ]]; then
    hps_log debug "Loading TYPE: $type"
    _load_library_dir "$node_manager_base/$os_dir/$type" "Type: $type"
    file_count=$((file_count + _LOADED_COUNT))
  fi
  
  # 4. PROFILE libraries
  if [[ -n "$type" ]] && [[ -n "$profile" ]] && [[ -d "$node_manager_base/$os_dir/$type/$profile" ]]; then
    hps_log debug "Loading PROFILE: $profile"
    _load_library_dir "$node_manager_base/$os_dir/$type/$profile" "Profile: $profile"
    file_count=$((file_count + _LOADED_COUNT))
  fi
  
  # 5. STATE overlay (if not RUNNING/INSTALLED)
  if [[ "$state" != "RUNNING" ]] && [[ "$state" != "INSTALLED" ]]; then
    local state_dir="$node_manager_base/$os_dir/+${state}"
    if [[ -d "$state_dir" ]]; then
      hps_log info "Loading STATE overlay: +$state"
      _load_library_dir "$state_dir" "State Overlay: +$state"
      file_count=$((file_count + _LOADED_COUNT))
    else
      hps_log warn "State overlay not found: $state_dir"
    fi
  fi
  
  # 6. RESCUE overlay (special override)
  if [[ "$rescue" == "true" ]]; then
    local rescue_dir="$node_manager_base/$os_dir/RESCUE"
    if [[ -d "$rescue_dir" ]]; then
      hps_log info "Loading RESCUE overlay"
      _load_library_dir "$rescue_dir" "RESCUE Mode"
      file_count=$((file_count + _LOADED_COUNT))
    else
      hps_log error "RESCUE mode requested but directory not found: $rescue_dir"
    fi
  fi
  
  #---------------------------------------------------------------------------
  # Relay OpenSVC o_ functions
  #---------------------------------------------------------------------------
  echo "# === Relay OpenSVC o_ functions ==="
  declare -f | awk '/^o_[a-zA-Z_]+ \(\)/, /^}/'
  echo ""
  
  hps_log info "Library loading complete: $file_count files loaded"
  
  #---------------------------------------------------------------------------
  # Build and embed init sequence
  #---------------------------------------------------------------------------
  echo "# === Init Sequence Embedding ==="
  echo ""
  
  local init_sequence
  init_sequence=$(_build_init_sequence "$node_manager_base" "$os_dir" "$type" "$profile" "$state" "$rescue")
  
  echo "$init_sequence"
  echo ""
  
  hps_log info "Function bundle complete"
  return 0
}


#===============================================================================
# _load_library_dir
# -----------------
# Load all .sh files from a directory in alphabetical order.
#
# Behaviour:
#   - Loads all *.sh files in directory (not recursive)
#   - Sorts files alphabetically
#   - Outputs file contents to stdout
#   - Sets _LOADED_COUNT to number of files loaded
#
# Arguments:
#   $1 - directory path
#   $2 - label for output header
#
# Side Effects:
#   Sets global _LOADED_COUNT variable
#
# Internal helper function
#===============================================================================
_load_library_dir() {
  local dir="$1"
  local label="$2"
  
  _LOADED_COUNT=0
  
  if [[ ! -d "$dir" ]]; then
    return 0
  fi
  
  local files
  shopt -s nullglob
  files=("$dir"/*.sh)
  shopt -u nullglob
  
  if ((${#files[@]} == 0)); then
    return 0
  fi
  
  echo "# === $label ==="
  
  # Sort files alphabetically using a simpler approach
  local f
  for f in $(printf '%s\n' "${files[@]}" | sort); do
    hps_log debug "  Loading: $(basename "$f")"
    echo "# Loading: $(basename "$f")"
    cat "$f"
    echo ""
    ((_LOADED_COUNT++))
  done
}


#===============================================================================
# _build_init_sequence
# --------------------
# Build init sequence by selecting and concatenating init files.
#
# Behaviour:
#   - If RESCUE=true: Returns ONLY RESCUE inits
#   - Otherwise: Scans tree for *.init files, matches metadata
#   - Concatenates matching inits into executable sequence
#   - Returns bash array declaration
#
# Arguments:
#   $1 - base_dir : node-manager base directory
#   $2 - os_ver   : OS version (e.g., "alpine-3")
#   $3 - type     : Node type
#   $4 - profile  : Profile
#   $5 - state    : State
#   $6 - rescue   : Rescue flag (true/false)
#
# Returns:
#   Init sequence as bash array declaration to stdout
#
# Internal helper function
#===============================================================================
_build_init_sequence() {
  local base_dir="$1"
  local os_ver="$2"
  local type="$3"
  local profile="$4"
  local state="$5"
  local rescue="$6"
  
  local -a init_files=()
  
  # Special handling for RESCUE mode
  if [[ "$rescue" == "true" ]]; then
    hps_log info "RESCUE mode: loading only RESCUE inits"
    
    local rescue_dir="$base_dir/$os_ver/RESCUE"
    if [[ -d "$rescue_dir" ]]; then
      shopt -s nullglob
      init_files=("$rescue_dir"/*.init)
      shopt -u nullglob
      
      hps_log debug "Found ${#init_files[@]} RESCUE init file(s)"
    else
      hps_log warn "RESCUE directory not found: $rescue_dir"
    fi
  else
    # Normal mode: scan and match metadata
    hps_log debug "Building init sequence for: os=$os_ver type=$type profile=$profile state=$state"
    
    # Scan for all init files in base and os_ver trees
    local all_inits
    all_inits=$(_find_all_inits "$base_dir" "$os_ver")
    
    # Match each init against metadata
    while IFS= read -r init_file; do
      [[ -z "$init_file" ]] && continue
      
      if _init_matches_metadata "$init_file" "$os_ver" "$type" "$profile" "$state" "$rescue"; then
        init_files+=("$init_file")
        hps_log debug "  Matched: $(basename "$init_file")"
      fi
    done <<< "$all_inits"
    
    hps_log info "Selected ${#init_files[@]} init file(s) based on metadata"
  fi
  
  # Build init sequence array
  local -a init_actions=()
  
  for init_file in "${init_files[@]}"; do
    hps_log debug "Processing init: $init_file"
    
    # Read init file, skip empty lines and comments (except metadata)
    while IFS= read -r line; do
      # Skip metadata line
      [[ "$line" =~ ^#@METADATA ]] && continue
      
      # Skip comments and empty lines
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      
      # Trim whitespace
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      
      # Add non-empty lines
      if [[ -n "$line" ]]; then
        init_actions+=("$line")
      fi
    done < "$init_file"
  done
  
  # Output array declaration
  echo "# Init sequence from ${#init_files[@]} file(s), ${#init_actions[@]} action(s)"
  echo "HPS_INIT_SEQUENCE=("
  for action in "${init_actions[@]}"; do
    echo "  \"$action\""
  done
  echo ")"
  
  hps_log info "Init sequence built with ${#init_actions[@]} action(s)"
}


#===============================================================================
# _find_all_inits
# ---------------
# Find all *.init files in base and OS directories.
#
# Arguments:
#   $1 - base_dir : node-manager base directory
#   $2 - os_ver   : OS version (e.g., "alpine-3")
#
# Returns:
#   Newline-separated list of init file paths (sorted)
#
# Internal helper function
#===============================================================================
_find_all_inits() {
  local base_dir="$1"
  local os_ver="$2"
  
  local search_paths=(
    "$base_dir/base"
    "$base_dir/$os_ver"
  )
  
  for path in "${search_paths[@]}"; do
    if [[ -d "$path" ]]; then
      find "$path" -name "*.init" -type f 2>/dev/null
    fi
  done | sort
}


#===============================================================================
# _init_matches_metadata
# ----------------------
# Check if init file metadata matches current host config.
#
# Behaviour:
#   - Reads first line of init file
#   - Parses #@METADATA key=value pairs
#   - Special handling for RESCUE=true (only matches when rescue param is true)
#   - Matches each field against provided values
#   - Missing fields default to "*" (match all)
#   - "*" in field matches any value
#   - Comma-separated values = OR (e.g., "type=SCH,DRH")
#
# Arguments:
#   $1 - init_file : Path to init file
#   $2 - os_ver    : OS version to match
#   $3 - type      : Type to match
#   $4 - profile   : Profile to match
#   $5 - state     : State to match
#   $6 - rescue    : Rescue flag (true/false)
#
# Returns:
#   0 if matches, 1 if no match
#
# Internal helper function
#===============================================================================
_init_matches_metadata() {
  local init_file="$1"
  local check_os="$2"
  local check_type="$3"
  local check_profile="$4"
  local check_state="$5"
  local check_rescue="${6:-false}"
  
  # Read first line
  local first_line
  first_line=$(head -n1 "$init_file" 2>/dev/null)
  
  # Check if it has metadata
  if [[ ! "$first_line" =~ ^#@METADATA ]]; then
    # No metadata = match all (include by default)
    hps_log debug "  No metadata in $(basename "$init_file"), including by default"
    return 0
  fi
  
  # Parse metadata
  local metadata="${first_line#*@METADATA}"
  
  # Check for RESCUE flag first (special handling)
  if [[ "$metadata" =~ RESCUE=true ]]; then
    # This init is ONLY for RESCUE mode
    hps_log debug "  Init requires RESCUE=true"
    if [[ "$check_rescue" != "true" ]]; then
      return 1
    fi
    # If we're in RESCUE mode and this is a RESCUE init, it matches
    return 0
  fi
  
  # Extract fields
  local meta_os meta_type meta_profile meta_state
  meta_os=$(_extract_metadata_field "$metadata" "os")
  meta_type=$(_extract_metadata_field "$metadata" "type")
  meta_profile=$(_extract_metadata_field "$metadata" "profile")
  meta_state=$(_extract_metadata_field "$metadata" "state")
  
  # Default missing fields to "*"
  meta_os="${meta_os:-*}"
  meta_type="${meta_type:-*}"
  meta_profile="${meta_profile:-*}"
  meta_state="${meta_state:-*}"
  
  # Match each field
  _matches_field "$meta_os" "$check_os" || return 1
  _matches_field "$meta_type" "$check_type" || return 1
  _matches_field "$meta_profile" "$check_profile" || return 1
  _matches_field "$meta_state" "$check_state" || return 1
  
  return 0
}


#===============================================================================
# _extract_metadata_field
# -----------------------
# Extract a field value from metadata string.
#
# Arguments:
#   $1 - metadata string
#   $2 - field name
#
# Returns:
#   Field value or empty string
#
# Internal helper function
#===============================================================================
_extract_metadata_field() {
  local metadata="$1"
  local field="$2"
  
  # Extract field=value
  local pattern="${field}=([^ ]+)"
  if [[ "$metadata" =~ $pattern ]]; then
    echo "${BASH_REMATCH[1]}"
  fi
}


#===============================================================================
# _matches_field
# --------------
# Check if a metadata field matches a check value.
#
# Behaviour:
#   - "*" matches anything
#   - Exact match
#   - Comma-separated = OR (e.g., "SCH,DRH" matches "SCH" or "DRH")
#
# Arguments:
#   $1 - pattern (from metadata)
#   $2 - value (to check)
#
# Returns:
#   0 if matches, 1 if no match
#
# Internal helper function
#===============================================================================
_matches_field() {
  local pattern="$1"
  local value="$2"
  
  # Wildcard matches all
  if [[ "$pattern" == "*" ]]; then
    return 0
  fi
  
  # Exact match
  if [[ "$pattern" == "$value" ]]; then
    return 0
  fi
  
  # Comma-separated OR
  if [[ "$pattern" =~ , ]]; then
    local opt
    local IFS=','
    for opt in $pattern; do
      if [[ "$opt" == "$value" ]]; then
        return 0
      fi
    done
  fi
  
  return 1
}
