__guard_source || return


#===============================================================================
# node_get_functions
# ------------------
# Concatenate host-side functions for a distro string and emit to stdout
#
# Arguments:
#   $1 - distro : Distro string format: cpu-mfr-osname-osver
#   $2 - base   : Base directory (optional, defaults to ${LIB_DIR}/host-scripts.d)
#
# Search Order:
#   common.d/*.sh
#   <cpu>.d/*.sh        then <cpu>.sh
#   <mfr>.d/*.sh        then <mfr>.sh
#   <osname>.d/*.sh     then <osname>.sh
#   <osname>-<osver>.d/*.sh then <osname>-<osver>.sh
#
# Behaviour:
#   - Parses distro string into components
#   - Searches for function files in priority order
#   - Logs which files are found and included
#   - Concatenates all matching files to stdout
#   - Adds comments showing which files were included
#
# Returns:
#   0 on success
#   1 if distro parameter missing
#===============================================================================
node_get_functions() {
  local distro="${1:?Usage: node_get_functions <cpu-mfr-osname-osver> [func_dir]}"
  local base="${2:-${LIB_DIR:+${LIB_DIR%/}/host-scripts.d}}"
  base="${base:-/srv/hps-system/lib/host-scripts.d}"
  
  local cpu mfr osname osver
  IFS='-' read -r cpu mfr osname osver <<<"$distro"
  
  hps_log info "Building function bundle for distro: $distro"
  hps_log debug "Components: cpu=$cpu mfr=$mfr osname=$osname osver=$osver"
  hps_log debug "Searching in: $base"
  
  # Enable nullglob so unmatched globs expand to empty, not literal strings
  local had_nullglob=0
  if shopt -q nullglob; then had_nullglob=1; else shopt -s nullglob; fi
  
  echo "# Host function bundle for: $distro"
  echo "# Source directory: $base"
  echo
  
  local patterns=(
    "$base/common.d/"*.sh
    "$base/${cpu}.d/"*.sh     "$base/${cpu}.sh"
    "$base/${mfr}.d/"*.sh     "$base/${mfr}.sh"
    "$base/${osname}.d/"*.sh  "$base/${osname}.sh"
    "$base/${osname}-${osver}.d/"*.sh "$base/${osname}-${osver}.sh"
  )
  
  local file_count=0
  local p files f
  
  for p in "${patterns[@]}"; do
    files=( $p )
    if ((${#files[@]} == 0)); then
      hps_log debug "Pattern not found: $p"
      echo "# === $(basename "${p%/*}")/$(basename "${p##*/}") not found ==="
      continue
    fi
    
    for f in "${files[@]}"; do
      [[ -f $f ]] || continue
      
      hps_log info "Including function file: $f"
      file_count=$((file_count + 1))
      
      echo "# === $(basename "$f") included ==="
      cat "$f"
      echo
    done
  done
  
  # Restore nullglob to previous state
  ((had_nullglob==1)) || shopt -u nullglob
  
  hps_log info "Function bundle complete: $file_count files included"
}




# function to create a local script, that will detect what O/S we are, and then collect the functions
bootstrap_initialise_functions() {

# The following is sent literally
# the functions are only used in this script in order to ascertain the correct functions, this is distro agnostic.
  cat <<'EOF'
#!/bin/sh
# Offline bootstrap initialiser from provisioning server

# NOTE: Keep this 'sh' / 'ash' friendly as not evrythig will have bash at this point

bootstrap_initialise_distro_string() {
  local cpu osname osver mfr

  cpu="$(uname -m)"
  mfr="linux"

  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    osname="${ID,,}"            # lowercase
    osver="${VERSION_ID,,}"     # lowercase
  else
    osname="unknown"
    osver="unknown"
  fi

  echo "${cpu}-${mfr}-${osname}-${osver}"
}

bootstrap_get_provisioning_node() {
  # Returns the default gateway IP (provisioning node)
  ip route | awk '/^default/ { print $3; exit }'
}

bootstrap_get_functions () {
  local gateway
  gateway="$(bootstrap_get_provisioning_node)"

  local distro
  distro="$(bootstrap_initialise_distro_string)"

  # Quote the URL to prevent shell or curl from misinterpreting '&'
  local url="http://${gateway}/cgi-bin/boot_manager.sh?cmd=node_get_functions&distro=$(urlencode "$distro")"

  # Fetch and source
  if ! eval "$(curl -fsSL "$url")"; then
    echo "[-] Failed to fetch or source functions from $url"
    return 2
  else
    echo "[+] Loaded bootstrap functions from $url"
  fi

}
EOF

# Include functions here from the internal lib as required, to expand and send
  declare -f urlencode

# Start the bootstrapping
  echo "bootstrap_get_functions"

}




