__guard_source || return





#===============================================================================
# hps_get_remote_functions
# ------------------------
# Generate function bundle for the requesting remote node.
#
# Behaviour:
#   - Uses $mac from CGI context (already set by hps_origin_tag)
#   - Looks up os_id and HOST_PROFILE from host_config
#   - Converts os_id to distro format using os_id_to_distro
#   - Calls node_build_functions to generate bundle
#   - Outputs function bundle to stdout
#
# Returns:
#   0 on success
#   1 if os_id not found or empty
#   2 if os_id conversion fails
#
# Example:
#   # In CGI context where $mac is already set
#   hps_get_remote_functions
#
#===============================================================================
hps_get_remote_functions() {
  local os_id distro profile
  
  # Get os_id from host config (using $mac from CGI context)
  if ! os_id=$(host_config "$mac" get os_id 2>/dev/null); then
    hps_log error "Could not retrieve os_id for MAC $mac"
    return 1
  fi
  
  if [[ -z "$os_id" ]]; then
    hps_log error "os_id is empty for MAC $mac"
    return 1
  fi
  
  # Convert os_id to distro format
  if ! distro=$(os_id_to_distro "$os_id"); then
    hps_log error "Failed to convert os_id '$os_id' to distro format"
    return 2
  fi
  
  # Get profile (empty is valid)
  profile=$(host_config "$mac" get HOST_PROFILE 2>/dev/null || echo "")
  
  hps_log info "Building function bundle for MAC $mac (OS: $os_id, Profile: ${profile:-none})"
  
  # Generate and output function bundle
  node_build_functions "$distro"
  return 0
}



#===============================================================================
# node_build_functions - Refactored with helper functions
#===============================================================================



#===============================================================================
# _build_function_patterns
# ------------------------
# Build array of function file patterns to load.
#
# Arguments:
#   $1 - base      : Base directory
#   $2 - cpu       : CPU architecture
#   $3 - mfr       : Manufacturer
#   $4 - osname    : OS name
#   $5 - osver     : OS version
#   $6 - profile   : Profile (optional)
#
# Side Effects:
#   Sets global array FUNCTION_PATTERNS
#===============================================================================
_build_function_patterns() {
  local base="$1" cpu="$2" mfr="$3" osname="$4" osver="$5" profile="$6"
  
  # Build patterns array
  FUNCTION_PATTERNS=(
    "$base/common.d/*.sh"
    "$base/${cpu}.d/*.sh"
    "$base/${cpu}.sh"
    "$base/${mfr}.d/*.sh"
    "$base/${mfr}.sh"
    "$base/${osname}.d/*.sh"
    "$base/${osname}.sh"
    "$base/${osname}-${osver}.d/*.sh"
    "$base/${osname}-${osver}.sh"
  )
  
  # Add profile patterns
  if [[ -n "$profile" ]]; then
    FUNCTION_PATTERNS+=(
      "$base/common.d/${profile}/*.sh"
      "$base/${cpu}.d/${profile}/*.sh"
      "$base/${mfr}.d/${profile}/*.sh"
      "$base/${osname}.d/${profile}/*.sh"
      "$base/${osname}-${osver}.d/${profile}/*.sh"
    )
  fi
}

#===============================================================================
# _output_function_files
# ----------------------
# Process and output function files based on patterns array.
#
# Arguments:
#   $1 - profile (for marking profile files)
#
# Side Effects:
#   Reads global array FUNCTION_PATTERNS
#   Outputs file contents to stdout
#   Sets global _FILE_COUNT variable
#===============================================================================
_output_function_files() {
  local profile="$1"
  local files f
  
  _FILE_COUNT=0
  
  # Enable nullglob for glob expansion
  local had_nullglob=0
  if shopt -q nullglob; then had_nullglob=1; else shopt -s nullglob; fi
  
  for p in "${FUNCTION_PATTERNS[@]}"; do
    # Expand glob pattern
    files=( $p )
    
    if ((${#files[@]} == 0)); then
      hps_log debug "Pattern not found: $p"
      if [[ -n "$profile" && "$p" == *"/${profile}/"* ]]; then
        hps_log warn "Profile directory not found: ${p%/*}"
      fi
      continue
    fi
    
    for f in "${files[@]}"; do
      [[ -f $f ]] || continue
      
      hps_log debug "Including function file: $f"
      ((_FILE_COUNT++))
      
      if [[ "$f" == *"/${profile}/"* ]]; then
        echo "# === Profile: $profile - $(basename "$(dirname "$f")")/$(basename "$f") included ==="
      else
        echo "# === $(basename "$(dirname "$f")")/$(basename "$f") included ==="
      fi
      cat "$f"
      echo
    done
  done
  
  # Restore nullglob
  ((had_nullglob==1)) || shopt -u nullglob
}


#===============================================================================
# _collect_init_files - Modified to check STATE
# -------------------
# Collect init sequence files based on OS, architecture, type, and profile.
# Special handling: If STATE=INSTALLING, return n_installer_run only.
#
# Arguments:
#   $1 - init_dir : Init sequences directory
#   $2 - arch     : CPU architecture
#   $3 - osname   : OS name
#   $4 - type     : Host type (TCH, SCH, etc.)
#   $5 - profile  : Profile (optional)
#
# Output:
#   Array of init actions (one per line)
#   - Normal boot: init file paths
#   - INSTALLING: function name "n_installer_run"
#
# Search order (normal boot):
#   1. {osname}.init                           (base OS)
#   2. {arch}-{osname}.init                    (arch-specific OS)
#   3. {osname}-{type}.init                    (type-specific)
#   4. {arch}-{osname}-{type}.init             (arch + type)
#   5. {osname}-{type}-{profile}.init          (type + profile)
#   6. {arch}-{osname}-{type}-{profile}.init   (arch + type + profile)
#   7. common-post.init                        (always last)
#
# Special handling (STATE=INSTALLING):
#   Returns: "n_installer_run" (single function call, not file path)
#   Note: All functions are still loaded, but only installer runs
#===============================================================================
_collect_init_files() {
  local init_dir="$1" arch="$2" osname="$3" type="$4" profile="${5:-}"
  local -a init_files=()
  
  # Check STATE first - special handling for INSTALLING
  local state=""
  if [[ -n "${mac:-}" ]]; then
    state=$(host_config "$mac" get STATE 2>/dev/null || echo "")
  fi
  
  if [[ "$state" == "INSTALLING" ]]; then
    hps_log info "STATE=INSTALLING detected, init sequence will run installer only"
    # Return function name directly, not a file path
    # This will be processed by _build_init_sequence as a single action
    echo "n_installer_run"
    return 0
  fi
  
  # Normal boot - proceed with standard init file collection
  hps_log debug "Normal boot detected (STATE=${state:-<unset>}), using standard init sequence"
  
  # 1. Base OS init
  local base_init="${init_dir}/${osname}.init"
  if [[ -f "$base_init" ]]; then
    init_files+=("$base_init")
    hps_log debug "Found base init: $base_init"
  fi
  
  # 2. Architecture-specific OS init
  local arch_init="${init_dir}/${arch}-${osname}.init"
  if [[ -f "$arch_init" ]]; then
    init_files+=("$arch_init")
    hps_log debug "Found arch-specific init: $arch_init"
  fi
  
  # 3. Type-specific init
  if [[ -n "$type" ]]; then
    local type_init="${init_dir}/${osname}-${type}.init"
    if [[ -f "$type_init" ]]; then
      init_files+=("$type_init")
      hps_log debug "Found type init: $type_init"
    fi
    
    # 4. Architecture + type init
    local arch_type_init="${init_dir}/${arch}-${osname}-${type}.init"
    if [[ -f "$arch_type_init" ]]; then
      init_files+=("$arch_type_init")
      hps_log debug "Found arch-specific type init: $arch_type_init"
    fi
  fi
  
  # 5. Type + Profile init
  if [[ -n "$type" ]] && [[ -n "$profile" ]]; then
    local type_profile_init="${init_dir}/${osname}-${type}-${profile}.init"
    if [[ -f "$type_profile_init" ]]; then
      init_files+=("$type_profile_init")
      hps_log debug "Found type-profile init: $type_profile_init"
    fi
    
    # 6. Architecture + type + profile init
    local arch_type_profile_init="${init_dir}/${arch}-${osname}-${type}-${profile}.init"
    if [[ -f "$arch_type_profile_init" ]]; then
      init_files+=("$arch_type_profile_init")
      hps_log debug "Found arch-specific type-profile init: $arch_type_profile_init"
    fi
  fi
  
  # 7. Common post init (always last)
  local common_post="${init_dir}/common-post.init"
  if [[ -f "$common_post" ]]; then
    init_files+=("$common_post")
    hps_log debug "Found common-post init: $common_post"
  fi
  
  # Output file paths
  printf '%s\n' "${init_files[@]}"
}


#===============================================================================
# _build_init_sequence - Modified to handle function names
# --------------------
# Build init sequence array from init files OR direct function names.
#
# Arguments:
#   $1 - init_files (newline-separated list of file paths OR function names)
#
# Output:
#   Bash array declaration to stdout
#
# Behaviour:
#   - If input is a file path (exists as file): read and parse as before
#   - If input is not a file: treat as direct function name and add to sequence
#===============================================================================
_build_init_sequence() {
  local init_files="$1"
  local -a init_sequence=()
  local init_file line
  
  local file_count
  file_count=$(echo "$init_files" | grep -c .)
  hps_log debug "_build_init_sequence called with $file_count files"
  
  while IFS= read -r init_file; do
    [[ -z "$init_file" ]] && continue
    
    # Check if this is a file path or a direct function name
    if [[ -f "$init_file" ]]; then
      # It's a file - process as before
      hps_log debug "Processing init file: $init_file"
      
      local line_count=0
      while IFS= read -r line; do
        ((line_count++))
        
        # Skip empty lines and comments
        if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
          hps_log debug "  Line $line_count: skipped (empty or comment)"
          continue
        fi
        
        # Trim whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        
        # Add non-empty lines
        if [[ -n "$line" ]]; then
          init_sequence+=("$line")
          hps_log debug "  Line $line_count: added '$line'"
        fi
      done < "$init_file"
      
      hps_log debug "Processed $line_count lines from $init_file"
    else
      # Not a file - treat as direct function name
      hps_log debug "Adding direct function: $init_file"
      init_sequence+=("$init_file")
    fi
  done <<< "$init_files"
  
  # Output array declaration
  echo "HPS_INIT_SEQUENCE=("
  for action in "${init_sequence[@]}"; do
    echo "  \"$action\""
  done
  echo ")"
  
  hps_log info "Built init sequence with ${#init_sequence[@]} action(s)"
}


#===============================================================================
# node_build_functions - Add installer functions when STATE=INSTALLING
#===============================================================================

# Add this section after the "Function files" section and before 
# "Relay OpenSVC o_ functions" section

  #---------------------------------------------------------------------------
  # Installer functions (if STATE=INSTALLING)
  #---------------------------------------------------------------------------
  local state=""
  if [[ -n "${mac:-}" ]]; then
    state=$(host_config "$mac" get STATE 2>/dev/null || echo "")
  fi
  
  if [[ "$state" == "INSTALLING" ]]; then
    hps_log info "STATE=INSTALLING, loading installer functions"
    
    # Determine installer directory based on OS name and major version
    # osver format: "3.20" -> extract major version "3"
    local major_ver="${osver%%.*}"
    local installer_dir="${LIB_DIR}/host-installer/${osname}-${major_ver}"
    
    hps_log debug "Installer directory: $installer_dir"
    
    if [[ -d "$installer_dir" ]]; then
      echo "# === Installer Functions (STATE=INSTALLING) ==="
      
      # Load all .sh files from installer directory
      local installer_files
      shopt -s nullglob
      installer_files=("$installer_dir"/*.sh)
      shopt -u nullglob
      
      if ((${#installer_files[@]} > 0)); then
        for f in "${installer_files[@]}"; do
          hps_log debug "Including installer file: $f"
          echo "# === Installer: $(basename "$f") included ==="
          cat "$f"
          echo
          ((file_count++))
        done
        
        hps_log info "Loaded ${#installer_files[@]} installer function file(s)"
      else
        hps_log warn "No installer function files found in $installer_dir"
      fi
    else
      hps_log error "Installer directory not found: $installer_dir"
      hps_log error "Cannot proceed with installation"
    fi
  fi
  

#===============================================================================
# node_build_functions
# --------------------
# Main function: Build complete function bundle for a node.
#
# Arguments:
#   $1 - distro : Distro string (cpu-mfr-osname-osver)
#   $2 - base   : Base directory (optional)
#
# Returns:
#   0 on success
#   1 on error
#===============================================================================
node_build_functions() {
  local distro="${1:?Usage: node_build_functions <distro> [func_dir]}"
  local base="${2:-${LIB_DIR:+${LIB_DIR%/}/node-functions.d}}"
  
  # Get type and profile
  local type profile
  
  if ! type=$(host_config "$mac" get TYPE 2>/dev/null); then
    hps_log warn "No TYPE available"
    type=""
  fi
  
  if ! profile=$(host_config "$mac" get HOST_PROFILE 2>/dev/null); then
    hps_log warn "No HOST_PROFILE available"
    profile=""
  fi
  
  if [[ -z "$type" ]]; then
    hps_log info "No type set, using base functions only"
  else
    hps_log info "Using type: $type"
  fi
  
  if [[ -z "$profile" ]]; then
    hps_log info "No profile set"
  else
    hps_log info "Using profile: $profile"
  fi
  
  # Parse distro
  local cpu mfr osname osver
  IFS='-' read -r cpu mfr osname osver <<<"$distro"
  
  hps_log info "Building function bundle for distro: $distro"
  hps_log debug "Components: cpu=$cpu mfr=$mfr osname=$osname osver=$osver type=$type profile=$profile"
  hps_log debug "Searching in: $base"
  
  # Header
  echo "# Host function bundle for: $distro"
  echo "# Source directory: $base"
  [[ -n "$type" ]] && echo "# Type: $type"
  [[ -n "$profile" ]] && echo "# Profile: $profile"
  echo
  
  # Relay IPS utility functions
  declare -f urlencode
  declare -f netmask_to_cidr
  
  local file_count=0
  
  #---------------------------------------------------------------------------
  # Pre-load
  #---------------------------------------------------------------------------
  local pre_load="${base}/pre-load.sh"
  if [[ -f "$pre_load" ]]; then
    hps_log debug "Including pre-load file: $pre_load"
    echo "# === pre-load.sh included ==="
    cat "$pre_load"
    echo
    ((file_count++))
  fi
  
  #---------------------------------------------------------------------------
  # Function files
  #---------------------------------------------------------------------------
  _build_function_patterns "$base" "$cpu" "$mfr" "$osname" "$osver" "$profile"
  
  # Debug: log pattern count
  hps_log debug "Generated ${#FUNCTION_PATTERNS[@]} file patterns"
  
  # Must declare global before calling
  declare -g _FILE_COUNT=0
  _output_function_files "$profile"
  file_count=$((_FILE_COUNT + file_count))
  
  hps_log debug "Loaded $_FILE_COUNT function files"
  
  #---------------------------------------------------------------------------
  # Relay OpenSVC o_ functions
  #---------------------------------------------------------------------------
  echo "# === Relay OpenSVC o_ functions ==="
  declare -f | awk '/^o_[a-zA-Z_]+ \(\)/, /^}/'
  echo


  #---------------------------------------------------------------------------
  # Installer functions (if STATE=INSTALLING)
  #---------------------------------------------------------------------------
  local state=""
  if [[ -n "${mac:-}" ]]; then
    state=$(host_config "$mac" get STATE 2>/dev/null || echo "")
  fi
  
  if [[ "$state" == "INSTALLING" ]]; then
    hps_log info "STATE=INSTALLING, loading installer functions"
    
    # Determine installer directory based on OS name and major version
    # osver format: "3.20" -> extract major version "3"
    local major_ver="${osver%%.*}"
    local installer_dir="${LIB_DIR}/host-installer/${osname}-${major_ver}"
    
    hps_log debug "Installer directory: $installer_dir"
    
    if [[ -d "$installer_dir" ]]; then
      echo "# === Installer Functions (STATE=INSTALLING) ==="
      
      # Load all .sh files from installer directory
      local installer_files
      shopt -s nullglob
      installer_files=("$installer_dir"/*.sh)
      shopt -u nullglob
      
      if ((${#installer_files[@]} > 0)); then
        for f in "${installer_files[@]}"; do
          hps_log debug "Including installer file: $f"
          echo "# === Installer: $(basename "$f") included ==="
          cat "$f"
          echo
          ((file_count++))
        done
        
        hps_log info "Loaded ${#installer_files[@]} installer function file(s)"
      else
        hps_log warn "No installer function files found in $installer_dir"
      fi
    else
      hps_log error "Installer directory not found: $installer_dir"
      hps_log error "Cannot proceed with installation"
    fi
  fi


  #---------------------------------------------------------------------------
  # Post-load
  #---------------------------------------------------------------------------
  local post_load="${base}/post-load.sh"
  if [[ -f "$post_load" ]]; then
    hps_log debug "Including post-load file: $post_load"
    echo "# === post-load.sh included ==="
    cat "$post_load"
    echo
    ((file_count++))
  fi
  
  #---------------------------------------------------------------------------
  # Init sequence embedding
  #---------------------------------------------------------------------------
  echo "# === Init Sequence Embedding ==="
  echo
  
  local init_dir="${LIB_DIR}/node-init-sequences.d"
  local init_files
  init_files=$(_collect_init_files "$init_dir" "$cpu" "$osname" "$type" "$profile")
  
  local init_file_count
  init_file_count=$(echo "$init_files" | grep -c . || echo 0)
  
  echo "# Init sequence for: ${osname}${type:+-${type}}${profile:+-${profile}} [${cpu}]"
  echo "# Generated from: ${init_file_count} file(s)"
  _build_init_sequence "$init_files"
  echo
  
  #---------------------------------------------------------------------------
  # Finalize
  #---------------------------------------------------------------------------
  hps_log info "Function bundle complete: $file_count files included"
  return 0
}



