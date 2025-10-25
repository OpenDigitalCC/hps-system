__guard_source || return

#:name: create_bootstrap_core_lib
#:group: bootstrap
#:synopsis: Generate the core HPS bootstrap library content.
#:usage: create_bootstrap_core_lib
#:description:
#  Outputs the core HPS bootstrap library shell script to stdout.
#  This library provides essential functions for node bootstrap and initialization.
#  Distribution-agnostic - can be used for Alpine, Rocky, or other distros.
#:returns:
#  0 on success (outputs library content to stdout)
create_bootstrap_core_lib() {

  # relay IPS core functions

  echo "# HPS Bootstrap Library"
  echo "# Relaying HPS functions"

  declare -f hps_check_bash_syntax
  declare -f hps_debug_function_load
  declare -f hps_safe_eval
  declare -f hps_source_with_debug
  
  echo "# Relay complete"

  cat <<'LIBEOF'

# Core functions for HPS node bootstrap and initialisation

# URL encoding function
hps_url_encode() {
  local s="$1"
  local out=""
  local i c
  for ((i=0; i<${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-])
        out+="$c"
        ;;
      *)
        printf -v hex '%%%02X' "'$c"
        out+="$hex"
        ;;
    esac
  done
  printf '%s\n' "$out"
}

# Get distribution string
hps_get_distro_string() {
  local cpu osname osver mfr
  cpu="$(uname -m)"
  mfr="linux"
  
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    osname="${ID,,}"
    osver="${VERSION_ID,,}"
  else
    osname="unknown"
    osver="unknown"
  fi
  
  echo "${cpu}-${mfr}-${osname}-${osver}"
}

# Get provisioning node IP
hps_get_provisioning_node() {
  ip route | awk '/^default/ { print $3; exit }'
}

hps_fetch_node_functions() {
  local ips_address distro url
  
  ips_address="$(hps_get_provisioning_node)" || {
    echo "[HPS] ERROR: Could not determine provisioning node" >&2
    return 1
  }
  
  distro="$(hps_get_distro_string)"
  url="http://${ips_address}/cgi-bin/boot_manager.sh?cmd=node_get_functions&distro=$(hps_url_encode "$distro")"
  
  # Fetch functions without evaluating
  local response
  response=$(curl -fsSL "$url") || {
    echo "[HPS] ERROR: Failed to fetch functions from $url" >&2
    return 2
  }
  
  # Output the functions
  echo "$response"
  return 0
}

hps_load_node_functions() {
  echo "[HPS] Loading functions from IPS..." >&2
  
  local functions
  functions=$(hps_fetch_node_functions) || return $?
  
  if ! eval "$functions"; then
    echo "[HPS] ERROR: Failed to evaluate functions, diagnosing:" >&2
    hps_fetch_node_functions | hps_check_bash_syntax  >&2
    return 1
  fi
  
  echo "[HPS] Functions loaded successfully" >&2
  return 0
}



# Initialize node (load functions and run queue)
hps_node_init() {
  # Load functions first
  hps_load_node_functions || return $?
  
  # Run initialization queue if available
  if type n_queue_run >/dev/null 2>&1; then
    echo "[HPS] Running initialization queue..." >&2
    n_queue_run
  else
    echo "[HPS] WARNING: n_queue_run not found" >&2
  fi
}

# Reload functions (alias for convenience)
hps_reload() {
  hps_load_node_functions
}

# Quick status function
hps_status() {
  echo "HPS Bootstrap Library Status:"
  echo "  Provisioning node: $(hps_get_provisioning_node)"
  echo "  Distribution: $(hps_get_distro_string)"
  echo "  Library version: 1.0"
  
  # Check if node functions are loaded
  if type n_ips_command >/dev/null 2>&1; then
    echo "  Node functions: Loaded"
  else
    echo "  Node functions: Not loaded"
  fi
}


LIBEOF

  return 0
}
