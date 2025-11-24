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
# _collect_init_files
# -------------------
# Collect init sequence files based on OS, architecture, type, and profile.
#
# Arguments:
#   $1 - init_dir : Init sequences directory
#   $2 - arch     : CPU architecture
#   $3 - osname   : OS name
#   $4 - type     : Host type (TCH, SCH, etc.)
#   $5 - profile  : Profile (optional)
#
# Output:
#   Array of init file paths (one per line)
#
# Search order:
#   1. {osname}.init                           (base OS)
#   2. {arch}-{osname}.init                    (arch-specific OS)
#   3. {osname}-{type}.init                    (type-specific)
#   4. {arch}-{osname}-{type}.init             (arch + type)
#   5. {osname}-{type}-{profile}.init          (type + profile)
#   6. {arch}-{osname}-{type}-{profile}.init   (arch + type + profile)
#   7. common-post.init                        (always last)
#===============================================================================
_collect_init_files() {
  local init_dir="$1" arch="$2" osname="$3" type="$4" profile="${5:-}"
  local -a init_files=()
  
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
# _build_init_sequence
# --------------------
# Build init sequence array from init files.
#
# Arguments:
#   $1 - init_files (newline-separated list of file paths)
#
# Output:
#   Bash array declaration to stdout
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
    
    if [[ ! -f "$init_file" ]]; then
      hps_log warn "Init file not found: $init_file"
      continue
    fi
    
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



