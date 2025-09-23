__guard_source || return

# node_get_functions
# -----------------------
# Concatenate host-side functions for a distro string and emit to stdout.
# Looks in ${LIB_DIR}/host-scripts.d (or /srv/hps-system/lib/host-scripts.d).
# Search order:
#   common.d/*.sh
#   <cpu>.d/*.sh        then <cpu>.sh
#   <mfr>.d/*.sh        then <mfr>.sh
#   <osname>.d/*.sh     then <osname>.sh
#   <osname>-<osver>.d/*.sh then <osname>-<osver>.sh
#
# Usage: initialise_host_scripts "x86_64-linux-rockylinux-10.0" [func_dir]
node_get_functions() {
  local distro="${1:?Usage: initialise_host_scripts <cpu-mfr-osname-osver> [func_dir]}"
  local base="${2:-${LIB_DIR:+${LIB_DIR%/}/host-scripts.d}}"
  base="${base:-/srv/hps-system/lib/host-scripts.d}"

  local cpu mfr osname osver
  IFS='-' read -r cpu mfr osname osver <<<"$distro"

  # Enable nullglob so unmatched globs expand to empty, not literal strings.
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

  local p files f
  for p in "${patterns[@]}"; do
    files=( $p )
    if ((${#files[@]} == 0)); then
      echo "# === $(basename "${p%/*}")/$(basename "${p##*/}") not found ==="
      continue
    fi
    for f in "${files[@]}"; do
      [[ -f $f ]] || continue
      echo "# === $(basename "$f") included ==="
      cat "$f"
      echo
    done
  done

  # Restore nullglob to previous state
  ((had_nullglob==1)) || shopt -u nullglob
}




# function to create a local script, that will detect what O/S we are, and then collect the functions
bootstrap_initialise_functions() {

# The following is sent literally
# the functions are only used in this script in order to ascertain the correct functions, this is distro agnostic.
  cat <<'EOF'
#!/bin/bash
# Offline bootstrap initialiser from provisioning server

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
  if ! curl -fsSL "$url" | source /dev/stdin; then
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




