__guard_source || return
# Define your functions below


host_initialise_config() {
  local mac="$1"
  local config_file="${HPS_HOST_CONFIG_DIR}/${mac}.conf"

  mkdir -p "${HPS_HOST_CONFIG_DIR}"

  local created_ts
  created_ts=$(make_timestamp)

  cat > "$config_file" <<EOF
# Host config generated automatically
# MAC: $mac
STATE=UNCONFIGURED
CREATED="$created_ts"
EOF

  hps_log info "Initialised new host config: $config_file"
  echo "$config_file"
}


declare -gA HOST_CONFIG
declare -g __HOST_CONFIG_PARSED=0
declare -g __HOST_CONFIG_FILE=""

host_config() {
  local mac=$1
  local cmd="$2"
  local key="$3"
  local value="${4:-}"

  # Load config file into HOST_CONFIG map
  if [[ $__HOST_CONFIG_PARSED -eq 0 ]]; then
    __HOST_CONFIG_FILE="${HOST_CONFIG_FILE:-${HPS_HOST_CONFIG_DIR}/${mac}.conf}"

    if [[ -f "$__HOST_CONFIG_FILE" ]]; then
      while IFS='=' read -r k v; do
        [[ "$k" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        v="${v%\"}"; v="${v#\"}"  # strip surrounding quotes
        HOST_CONFIG["$k"]="$v"
      done < "$__HOST_CONFIG_FILE"
    fi

    __HOST_CONFIG_PARSED=1
  fi

  case "$cmd" in
    get)
      [[ ${HOST_CONFIG[$key]+_} ]] && printf '%s\n' "${HOST_CONFIG[$key]}"
      return
      ;;

    exists)
      [[ ${HOST_CONFIG[$key]+_} ]]
      return
      ;;

    equals)
      [[ ${HOST_CONFIG[$key]+_} && "${HOST_CONFIG[$key]}" == "$value" ]]
      return
      ;;

    set)
      HOST_CONFIG["$key"]="$value"
      HOST_CONFIG["UPDATED"]="$(make_timestamp)"

      {
        echo "# Auto-generated host config"
        echo "# MAC: $mac"
        for k in "${!HOST_CONFIG[@]}"; do
          printf '%s="%s"\n' "$k" "${HOST_CONFIG[$k]}"
        done
      } > "$__HOST_CONFIG_FILE"

      return
      ;;

    *)
      echo "[✗] Invalid host_config command: $cmd" >&2
      return 2
      ;;
  esac
}




has_sch_host() {
  local host_dir="${HPS_HOST_CONFIG_DIR}"

  [[ ! -d "$host_dir" ]] && {
    echo "[✗] Host config directory not found: $host_dir" >&2
    return 1
  }

  if grep -q '^TYPE=SCH' "$host_dir"/*.conf 2>/dev/null; then
    return 0  # Found at least one
  else
    return 1  # None found
  fi
}


host_network_configure() {
  local macid="$1"
  local hosttype="$2"

  local dhcp_ip dhcp_cidr netmask network_base
  dhcp_ip=$(cluster_config get DHCP_IP)
  dhcp_cidr=$(cluster_config get DHCP_CIDR)

  [[ -z "$dhcp_ip" || -z "$dhcp_cidr" ]] && {
    hps_log debug "[✗] Missing DHCP_IP or DHCP_CIDR in cluster config"
    return 1
  }

  if ! command -v ipcalc &>/dev/null; then
    hps_log debug "[✗] ipcalc is required."
    return 1
  fi

  netmask=$(ipcalc "$dhcp_cidr" | awk '/Netmask:/ {print $2}')
  network_base=$(ipcalc "$dhcp_cidr" | awk '/Network:/ {print $2}' | cut -d/ -f1)

  ip_to_int() {
    IFS=. read -r o1 o2 o3 o4 <<< "$1"
    echo $(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
  }

  int_to_ip() {
    local ip=$1
    echo "$(( (ip >> 24) & 255 )).$(( (ip >> 16) & 255 )).$(( (ip >> 8) & 255 )).$(( ip & 255 ))"
  }

  local start_ip end_ip try_ip
  local base_int=$(ip_to_int "$network_base")
  local max=254

  for ((i=2; i<max; i++)); do
    try_ip=$(int_to_ip $((base_int + i)))
    if ! grep -q "^IP=$try_ip" "${HPS_HOST_CONFIG_DIR}"/*.conf 2>/dev/null; then
      break
    fi
  done

  if [[ -z "$try_ip" ]]; then
    hps_log debug "[✗] No available IPs in range."
    return 1
  fi

  for n in $(seq -w 1 999); do
    hostname="${hosttype}-${n}"
    if ! grep -q "^HOSTNAME=$hostname" "${HPS_HOST_CONFIG_DIR}"/*.conf 2>/dev/null; then
      break
    fi
  done

  [[ -z "$hostname" ]] && {
    hps_log debug "[✗] Failed to generate unique hostname"
    return 1
  }

  host_config "$macid" set IP "$try_ip"
  host_config "$macid" set NETMASK "$netmask"
  host_config "$macid" set HOSTNAME "$hostname"
  host_config "$macid" set TYPE "$hosttype"
  host_config "$macid" set STATE "CONFIGURED"

  hps_log debug "[✓] Assigned IP: $try_ip"
  hps_log debug "[✓] Assigned Hostname: $hostname"
}


