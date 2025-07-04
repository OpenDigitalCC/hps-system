__guard_source || return


get_active_cluster_file() {
    # Return contents of active cluster config
    local link="${HPS_CLUSTER_CONFIG_DIR}/active-cluster"

    if [[ ! -L "$link" ]]; then
        echo "[ERROR] No active cluster symlink at: $link" >&2
        return 1
    fi
    local target
    target=$(readlink -f "$link") || {
        echo "[ERROR] Failed to resolve active cluster symlink: $link" >&2
        return 1
    }
    if [[ ! -f "$target/cluster.conf" ]]; then
        echo "[ERROR] Resolved target is not a file: $target" >&2
        return 1
    fi
    cat "$target/cluster.conf"
}


get_active_cluster_filename() {
    # returns path to cluster.conf in active cluster dir
    local link="${HPS_CLUSTER_CONFIG_BASE_DIR}/active-cluster"
    if [[ ! -L "$link" ]]; then
        echo "[ERROR] No active cluster symlink at: $link" >&2
        return 1
    fi
    # Resolve full path to the symlink target
    local target
    target=$(readlink -f "$link") || {
        echo "[ERROR] Failed to resolve active cluster symlink: $link" >&2
        return 1
    }
    echo "$target/cluster.conf"
}

get_active_cluster_info() {
  local base_dir="${HPS_CLUSTER_CONFIG_BASE_DIR:-/srv/hps-config/clusters}"
  local active_link="${base_dir}/active-cluster"

  shopt -s nullglob
  local clusters=("$base_dir"/*/)
  shopt -u nullglob

  if [[ ${#clusters[@]} -eq 0 ]]; then
    echo "[!] No cluster directories found in $base_dir" >&2
    return 1
  elif [[ ${#clusters[@]} -eq 1 ]]; then
    echo "[*] Using only cluster: $(basename "${clusters[0]}")"
    echo "${clusters[0]%/}/cluster.conf"
  elif [[ -L "$active_link" ]]; then
    local target
    target=$(readlink -f "$active_link")
    if [[ -f "$target/cluster.conf" ]]; then
      echo "[*] Using active cluster: $(basename "$target")"
      echo "$target/cluster.conf"
    else
      echo "[!] Active cluster config not found in: $target" >&2
      return 1
    fi
  else
    echo "[?] Multiple clusters found:"
    select cluster_dir in "${clusters[@]}"; do
      [[ -n "$cluster_dir" ]] && echo "${cluster_dir%/}/cluster.conf" && return
    done
  fi
}

count_clusters() {
  local base_dir="${HPS_CLUSTER_CONFIG_BASE_DIR}"
  [[ ! -d "$base_dir" ]] && {
    echo "[!] Cluster config base directory not found: $base_dir" >&2
    echo 0
    return 0
  }

  shopt -s nullglob
  local clusters=("$base_dir"/*/)
  shopt -u nullglob

  if [[ ${#clusters[@]} -eq 0 ]]; then
    echo "[!] No clusters found in $base_dir" >&2
    echo 0
    return 0
  fi

  echo "${#clusters[@]}"
}



list_clusters() {
  shopt -s nullglob
  local clusters=("${HPS_CLUSTER_CONFIG_BASE_DIR}"/*/)
  shopt -u nullglob
  for c in "${clusters[@]}"; do
    echo "$(basename "${c}")"
  done
}

select_cluster() {
  local base_dir="${HPS_CLUSTER_CONFIG_BASE_DIR}"
  shopt -s nullglob
  local clusters=("${base_dir}"/*/)
  shopt -u nullglob

  if [[ ${#clusters[@]} -eq 0 ]]; then
    echo "[!] No clusters found in $base_dir" >&2
    return 1
  fi

  echo "[?] Select a cluster:"
  select cluster_dir in "${clusters[@]}"; do
    [[ -n "$cluster_dir" ]] && echo "${cluster_dir%/}" && return
  done
}



write_cluster_config() {
  local target_file="$1"
  shift
  local values=("$@")

  if [[ ${#values[@]} -eq 0 ]]; then
    echo "[x] Cannot write empty cluster config to $target_file" >&2
    return 1
  fi

  echo "Writing: ${values[*]}"
  printf "%s\n" "${values[@]}" > "$target_file"
  echo "[OK] Cluster configuration written to $target_file"
}

set_active_cluster() {
  local cluster_name="$1"
  local cluster_dir="${HPS_CLUSTER_CONFIG_BASE_DIR}/${cluster_name}"
  local active_link="${HPS_CLUSTER_CONFIG_BASE_DIR}/active-cluster"

  if [[ ! -d "$cluster_dir" ]]; then
    echo "[x] Cluster directory not found: $cluster_dir" >&2
    return 1
  fi

  if [[ ! -f "$cluster_dir/cluster.conf" ]]; then
    echo "[x] cluster.conf not found in: $cluster_dir" >&2
    return 2
  fi

  ln -sfn "$cluster_dir" "$active_link"
  echo "[OK] Active cluster set to: $cluster_name"
}


cluster_config() {
  local op="$1"
  local key="$2"
  local value="${3:-}"

  local cluster_file
  cluster_file=$(get_active_cluster_filename) || {
    echo "[x] No active cluster config found." >&2
    return 1
  }

  case "$op" in
    get)
      grep -E "^${key}=" "$cluster_file" | cut -d= -f2-
      ;;

    set)
      if grep -qE "^${key}=" "$cluster_file"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$cluster_file"
      else
        echo "${key}=${value}" >> "$cluster_file"
      fi
      ;;

    exists)
      grep -qE "^${key}=" "$cluster_file"
      ;;

    *)
      echo "[x] Unknown cluster_config operation: $op" >&2
      return 2
      ;;
  esac
}

initialise_cluster() {
  local cluster_name="$1"
  local base_dir="${HPS_CLUSTER_CONFIG_BASE_DIR:-/srv/hps-config/clusters}"
  local cluster_dir="${base_dir}/${cluster_name}"
  local cluster_file="${cluster_dir}/cluster.conf"

  if [[ -z "$cluster_name" ]]; then
    echo "[x] Cluster name must be provided." >&2
    return 1
  fi

  if [[ -d "$cluster_dir" ]]; then
    echo "[!] Cluster directory already exists: $cluster_dir" >&2
    return 2
  fi

  mkdir -p "${cluster_dir}/hosts"

  cat > "$cluster_file" <<EOF
# Cluster configuration
CLUSTER_NAME=${cluster_name}
EOF

  echo "[OK] Cluster initialised at: $cluster_dir"
  echo "[OK] Created config: $cluster_file"

  export_dynamic_paths "$cluster_name" || {
    echo "[x] Failed to export cluster paths for $cluster_name" >&2
    return 3
  }
}

print_cluster_variables() {
  local config_file="$(get_active_cluster_filename)"
  local k v

  if [[ ! -f "$config_file" ]]; then
    echo "[x] Cluster config not found: $config_file" >&2
    return 1
  fi

  while IFS='=' read -r k v; do
    # Skip blank lines and comments
    [[ "$k" =~ ^#.*$ || -z "$k" ]] && continue
    v="${v%\"}"; v="${v#\"}"  # strip surrounding quotes
    echo "$k=$v"
  done < "$config_file"
}

get_host_type_param() {
  local type="$1"
  local key="$2"
  declare -n ref="$type"

  echo "${ref[$key]}"
}


load_cluster_host_type_profiles() {
  
  local config_file="$(get_active_cluster_filename)"
  [[ -f "$config_file" ]] || return 1

  # Set of declared host types
  declare -gA __declared_types=()

  while IFS='=' read -r k v; do
    [[ "$k" =~ ^#.*$ || -z "$k" ]] && continue
    k="${k%% }"
    v="${v%\"}"; v="${v#\"}"

    if [[ "$k" =~ ^([A-Z]+)_([A-Z0-9_]+)$ ]]; then
      local host="${BASH_REMATCH[1]}"
      local key="${BASH_REMATCH[2]}"

      # Declare the associative array once
      if [[ -z "${__declared_types[$host]+_}" ]]; then
        declare -g -A "$host"
        __declared_types[$host]=1
      fi

      # Now bind and populate
      declare -n arr="$host"
      arr["$key"]="$v"
    fi
  done < "$config_file"
}


cluster_has_installed_sch() {
  local config_dir="${HPS_HOST_CONFIG_DIR}"
  local config_file
  local type state

  for config_file in "$config_dir"/*.conf; do
    [[ -f "$config_file" ]] || continue

    type=""
    state=""

    while IFS='=' read -r key val; do
      key="${key//[$'\r\n']}"
      val="${val%\"}"; val="${val#\"}"
      case "$key" in
        TYPE) type="$val" ;;
        STATE) state="$val" ;;
      esac
    done < "$config_file"

    if [[ "$type" == "SCH" && "$state" == "INSTALLED" ]]; then
      return 0
    fi
  done

  return 1
}


