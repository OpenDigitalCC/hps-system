__guard_source || return
# Define your functions below


host_initialise_config() {
  local mac="$1"
  local config_file="${HPS_HOST_CONFIG_DIR}/${mac}.conf"

  mkdir -p "${HPS_HOST_CONFIG_DIR}"

  local created_ts
  created_ts=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

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
  local cmd="$1"
  local key="$2"
  local value="${3:-}"

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

      # Auto-save immediately
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

