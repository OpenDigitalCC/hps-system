__guard_source || return


initialise_host_scripts() {
  local distro="${1:?Usage: initialise_host_scripts <distro-string>}"

  # Required: LIB_DIR must be set
  local func_dir="${LIB_DIR}/host-scripts.d"

  # Break down distro string
  IFS='-' read -r cpu mfr osname osver <<< "$distro"

  local files=(
    "${func_dir}/common.sh"
    "${func_dir}/${cpu}.sh"
    "${func_dir}/${mfr}.sh"
    "${func_dir}/${osname}.sh"
    "${func_dir}/${osname}-${osver}.sh"
  )

  echo "# Host function bundle for: $distro"
  echo "# Source directory: $func_dir"
  echo

  for file in "${files[@]}"; do
    if [[ -f "$file" ]]; then
      echo "# === $(basename "$file") included ==="
      cat "$file"
      echo
    else
      echo "# === $(basename "$file") not found ==="
    fi
  done
}



bootstrap_initialise_distro() {
  local mac="$1"

# The following is sent literally
  cat <<'EOF'
#!/bin/bash
# Offline bootstrap initialiser from provisioning server

initialise_distro_string() {
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



get_provisioning_node() {
  # Returns the default gateway IP (provisioning node)
  ip route | awk '/^default/ { print $3; exit }'
}

initialise_host_scripts() {
  local gateway
  gateway="$(get_provisioning_node)"

  local distro
  distro="$(initialise_distro_string)"

  # Quote the URL to prevent shell or curl from misinterpreting '&'
  local url="http://${gateway}/cgi-bin/boot_manager.sh?cmd=initialise_host_scripts&distro=$(urlencode "$distro")"
#  local url="http://${gateway}/cgi-bin/boot_manager.sh?cmd=initialise_host_scripts&distro=${distro}"
  local dest="/tmp/host-functions.sh"

  echo "[+] Fetching function bundle from: $url"
  if curl -fsSL "$url" -o "$dest"; then
    echo "[=] Sourced: $dest"
    source "$dest"
  else
    echo "[!] Failed to fetch host functions from $url" >&2
    return 1
  fi
}
EOF

# Include functions here from the internal lib as required, to expand and send
  declare -f urlencode

# Start the bootstrapping
  echo "initialise_host_scripts"

}




