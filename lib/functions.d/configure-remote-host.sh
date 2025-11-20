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
# node_build_functions
# ------------------
# Concatenate host-side functions for a distro string and emit to stdout
# with support for profile-specific functions.
#
# Arguments:
#   $1 - distro : Distro string format: cpu-mfr-osname-osver
#   $2 - base   : Base directory (optional, defaults to ${LIB_DIR}/node-functions.d)
#
# Search Order:
#   pre-load.sh (if exists in base directory)
#   common.d/*.sh
#   common.d/${PROFILE}/*.sh
#   <cpu>.d/*.sh        then <cpu>.sh
#   <cpu>.d/${PROFILE}/*.sh
#   <mfr>.d/*.sh        then <mfr>.sh
#   <mfr>.d/${PROFILE}/*.sh
#   <osname>.d/*.sh        then <osname>.sh
#   <osname>.d/${PROFILE}/*.sh
#   <osname>-<osver>.d/*.sh then <osname>-<osver>.sh
#   <osname>-<osver>.d/${PROFILE}/*.sh
#   post-load.sh (if exists in base directory)
#
# Behaviour:
#   - Gets current profile via 'host-config get PROFILE'
#   - Parses distro string into components
#   - Loads pre-load.sh first if it exists
#   - Searches for function files in priority order
#   - Profile-specific functions are loaded after base functions
#   - Loads post-load.sh last if it exists (for function execution)
#   - Logs warnings when profile directories don't exist
#   - Logs which files are found and included
#   - Concatenates all matching files to stdout
#   - Adds comments showing which files were included
#
# Returns:
#   0 on success
#   1 if distro parameter missing
#   2 if host-config command fails
#===============================================================================
node_build_functions() {
  local distro="${1:?Usage: node_build_functions <distro> [func_dir]}"
  local base="${2:-${LIB_DIR:+${LIB_DIR%/}/node-functions.d}}"
  
  # Get the current profile if available
  local profile
  if ! profile=$(host_config $mac get HOST_PROFILE 2>/dev/null); then
    hps_log warn "No HOST_PROFILE available"
  fi
  
  # Profile might be empty, which is valid
  if [[ -z "$profile" ]]; then
    hps_log info "No profile set, using base functions only"
  else
    hps_log info "Using profile: $profile"
  fi
  
  local cpu mfr osname osver
  IFS='-' read -r cpu mfr osname osver <<<"$distro"
  
  hps_log info "Building function bundle for distro: $distro"

  declare -f urlencode
  declare -f netmask_to_cidr
 
  
  hps_log debug "Components: cpu=$cpu mfr=$mfr osname=$osname osver=$osver"
  hps_log debug "Searching in: $base"
  
  # Enable nullglob so unmatched globs expand to empty, not literal strings
  local had_nullglob=0
  if shopt -q nullglob; then had_nullglob=1; else shopt -s nullglob; fi
  
  echo "# Host function bundle for: $distro"
  echo "# Source directory: $base"
  [[ -n "$profile" ]] && echo "# Profile: $profile"
  echo
  
  local file_count=0
  
  # Load pre-load.sh first if it exists
  local pre_load="${base}/pre-load.sh"
  if [[ -f "$pre_load" ]]; then
    hps_log debug "Including pre-load file: $pre_load"
    echo "# === pre-load.sh included ==="
    cat "$pre_load"
    echo
    file_count=$((file_count + 1))
  else
    hps_log debug "No pre-load.sh found in $base"
  fi
  
  # Build patterns for regular function files
  local patterns=(
    "$base/common.d/"*.sh
    "$base/${cpu}.d/"*.sh     "$base/${cpu}.sh"
    "$base/${mfr}.d/"*.sh     "$base/${mfr}.sh"
    "$base/${osname}.d/"*.sh  "$base/${osname}.sh"
    "$base/${osname}-${osver}.d/"*.sh "$base/${osname}-${osver}.sh"
  )
  
  # Add profile-specific patterns if profile is set
  if [[ -n "$profile" ]]; then
    patterns+=(
      "$base/common.d/${profile}/"*.sh
      "$base/${cpu}.d/${profile}/"*.sh
      "$base/${mfr}.d/${profile}/"*.sh
      "$base/${osname}.d/${profile}/"*.sh
      "$base/${osname}-${osver}.d/${profile}/"*.sh
    )
  fi
  
  local p files f
  
  for p in "${patterns[@]}"; do
    files=( $p )
    if ((${#files[@]} == 0)); then
      hps_log debug "Pattern not found: $p"
      # Only warn about missing profile directories if profile is set
      if [[ -n "$profile" && "$p" == *"/${profile}/"* ]]; then
        hps_log warn "Profile directory not found: ${p%/*}"
      fi
      continue
    fi
    
    for f in "${files[@]}"; do
      [[ -f $f ]] || continue
      
      hps_log debug "Including function file: $f"
      file_count=$((file_count + 1))
      
      # If it's a profile file, indicate that in the comment
      if [[ "$f" == *"/${profile}/"* ]]; then
        echo "# === Profile: $profile - $(basename "$(dirname "$f")")/$(basename "$f") included ==="
      else
        echo "# === $(basename "$(dirname "$f")")/$(basename "$f") included ==="
      fi
      cat "$f"
      echo
    done
  done

# relay functions  # Relay OpenSVC task functions prefixed with o_
  echo # === Relay OpenSVC o_ functions ===
  declare -f | awk '/^o_[a-zA-Z_]+ \(\)/, /^}/'
  
  # Load post-load.sh last if it exists (for executing collected functions)
  local post_load="${base}/post-load.sh"
  if [[ -f "$post_load" ]]; then
    hps_log debug "Including post-load file: $post_load"
    echo "# === post-load.sh included (execution script) ==="
    cat "$post_load"
    echo
    file_count=$((file_count + 1))
  else
    hps_log debug "No post-load.sh found in $base"
  fi
  
  # Restore nullglob to previous state
  ((had_nullglob==1)) || shopt -u nullglob
  
  hps_log info "Function bundle complete: $file_count files included"
}




