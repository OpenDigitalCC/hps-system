__guard_source || return
# Define your functions below


host_initialise_config() {
  local mac="$1"
  local config_file="${HPS_HOST_CONFIG_DIR}/${mac}.conf"

  mkdir -p "${HPS_HOST_CONFIG_DIR}"

  host_config "$mac" set STATE "UNCONFIGURED"

#  local created_ts
#  created_ts=$(make_timestamp)

#  cat > "$config_file" <<EOF
## Host config generated automatically
## MAC: $mac
#STATE=UNCONFIGURED
#CREATED="$created_ts"
#EOF

  hps_log info "[$mac] Initialised host config: $config_file"
# commented out as this creates error on first boot when called from boot manager which needs no output 
#  echo "$config_file"

}


host_config_delete() {
  local mac="$1"
  local config_file="${HPS_HOST_CONFIG_DIR}/${mac}.conf"

  if [[ -f "$config_file" ]]; then
    rm -f "$config_file"
    hps_log info "[$mac] Deleted host config"
    return 0
  else
    hps_log warn "[$mac] Host config not found"
    return 1
  fi
}

host_config_show() {
  local mac="$1"
  local config_file="${HPS_HOST_CONFIG_DIR}/${mac}.conf"

  if [[ ! -f "$config_file" ]]; then
    hps_log info "No host config found for MAC: $mac"
    return 0
  fi

  while IFS='=' read -r k v; do
    [[ "$k" =~ ^#.*$ || -z "$k" ]] && continue
    # Strip quotes
    v="${v%\"}"; v="${v#\"}"
    # Escape embedded quotes and backslashes
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    echo "${k}=\"${v}\""
  done < "$config_file"
}



host_config_exists() {
  local mac="$1"
  local config_file="${HPS_HOST_CONFIG_DIR}/${mac}.conf"

  [[ -f "$config_file" ]]
}

declare -gA HOST_CONFIG
declare -g __HOST_CONFIG_PARSED=0
declare -g __HOST_CONFIG_FILE=""

#:name: host_config
#:group: host-management
#:synopsis: Manage host configuration key-value storage per MAC address.
#:usage: host_config <mac> <command> [key] [value]
#:description:
#  Parses and manages host configuration from ${HPS_HOST_CONFIG_DIR}/<mac>.conf
#  Supports get, exists, equals, and set operations on host configuration keys.
#  Configuration is cached per MAC address to avoid repeated file parsing.
#:parameters:
#  mac     - MAC address of the host (e.g., 52:54:00:9c:4c:24)
#  command - Operation: get, exists, equals, set
#  key     - Configuration key name (alphanumeric and underscore)
#  value   - Value to set (only for 'set' and 'equals' commands)
#:returns:
#  get:    0 if key exists (prints value), 1 if key not found
#  exists: 0 if key exists, 1 if not
#  equals: 0 if key exists and matches value, 1 otherwise
#  set:    0 on success
#  other:  2 for invalid command
host_config() {
  local mac=$1
  local cmd="$2"
  local key="$3"
  local value="${4:-}"
  
  # Track which MAC was parsed to avoid cross-host reuse
  if [[ "${__HOST_CONFIG_PARSED:-0}" -eq 0 || "${__HOST_CONFIG_MAC:-}" != "$mac" ]]; then
    declare -gA HOST_CONFIG=()            # reset map
    __HOST_CONFIG_FILE="${HOST_CONFIG_FILE:-${HPS_HOST_CONFIG_DIR}/${mac}.conf}"
    __HOST_CONFIG_MAC="$mac"
    
    if [[ -f "$__HOST_CONFIG_FILE" ]]; then
      # Accept keys: [A-Za-z_][A-Za-z0-9_]*  (was: uppercase-only)
      # Strip surrounding double quotes if present.
      while IFS='=' read -r k v; do
        [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        # Trim leading/trailing spaces around value
        v="${v#"${v%%[![:space:]]*}"}"
        v="${v%"${v##*[![:space:]]}"}"
        # Strip surrounding "" if present
        [[ "$v" == \"*\" ]] && v="${v%\"}" && v="${v#\"}"
        HOST_CONFIG["$k"]="$v"
      done < "$__HOST_CONFIG_FILE"
    fi
    __HOST_CONFIG_PARSED=1
  fi
  
  case "$cmd" in
    get)
      # prints value if present; rc=0 if found, 1 if missing
      if [[ ${HOST_CONFIG[$key]+_} ]]; then
        printf '%s\n' "${HOST_CONFIG[$key]}"
        return 0
      else
        return 1
      fi
      ;;
    exists)
      [[ ${HOST_CONFIG[$key]+_} ]]
      return $?
      ;;
    equals)
      [[ ${HOST_CONFIG[$key]+_} && "${HOST_CONFIG[$key]}" == "$value" ]]
      return $?
      ;;
    set)
      # Validate key format
      if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        hps_log error "[$mac] Invalid key format: $key"
        return 2
      fi
      
      HOST_CONFIG["$key"]="$value"
      hps_log info "[$mac] host_config update: $key = $value"
      
      local timestamp
      timestamp="$(make_timestamp)"
      HOST_CONFIG["UPDATED"]="$timestamp"
      hps_log info "[$mac] host_config UPDATED = $timestamp"
      
      # Ensure config directory exists
      local config_dir
      config_dir="$(dirname "$__HOST_CONFIG_FILE")"
      if [[ ! -d "$config_dir" ]]; then
        if ! mkdir -p "$config_dir"; then
          hps_log error "[$mac] Failed to create config directory: $config_dir"
          return 3
        fi
      fi
      
      # Write configuration file
      {
        echo "# Auto-generated host config"
        echo "# MAC: $mac"
        # Stable output: sort keys to avoid churn in diffs
        for k in $(printf '%s\n' "${!HOST_CONFIG[@]}" | LC_ALL=C sort); do
          # Escape any embedded double quotes in values
          local v="${HOST_CONFIG[$k]//\"/\\\"}"
          printf '%s="%s"\n' "$k" "$v"
        done
      } > "$__HOST_CONFIG_FILE" || {
        hps_log error "[$mac] Failed to write config file: $__HOST_CONFIG_FILE"
        return 3
      }
      
      return 0
      ;;
    *)
      hps_log error "Invalid host_config command: $cmd"
      return 2
      ;;
  esac
}



has_sch_host() {
  local host_dir="${HPS_HOST_CONFIG_DIR}"

  [[ ! -d "$host_dir" ]] && {
    echo "[x] Host config directory not found: $host_dir" >&2
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
    hps_log debug "[x] Missing DHCP_IP or DHCP_CIDR in cluster config"
    return 1
  }

  if ! command -v ipcalc &>/dev/null; then
    hps_log debug "[x] ipcalc is required."
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
    hps_log debug "[x] No available IPs in range."
    return 1
  fi

  for n in $(seq -w 1 999); do
    hostname="${hosttype}-${n}"
    if ! grep -q "^HOSTNAME=$hostname" "${HPS_HOST_CONFIG_DIR}"/*.conf 2>/dev/null; then
      break
    fi
  done

  [[ -z "$hostname" ]] && {
    hps_log debug "[x] Failed to generate unique hostname"
    return 1
  }

  host_config "$macid" set IP "$try_ip"
  host_config "$macid" set NETMASK "$netmask"
  host_config "$macid" set HOSTNAME "$hostname"
  host_config "$macid" set TYPE "$hosttype"
  host_config "$macid" set STATE "CONFIGURED"

  hps_log debug "[OK] Assigned IP: $try_ip"
  hps_log debug "[OK] Assigned Hostname: $hostname"
}


