__guard_source || return


get_active_cluster_file() {
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
    # Now returns path to cluster.conf in active cluster dir
    local link="${HPS_CLUSTER_CONFIG_DIR}/active-cluster"
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
  shopt -s nullglob
  local clusters=("${HPS_CLUSTER_CONFIG_BASE_DIR}"/*/)
  shopt -u nullglob
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
    echo "[✗] Cannot write empty cluster config to $target_file" >&2
    return 1
  fi

  echo "Writing: ${values[*]}"
  printf "%s\n" "${values[@]}" > "$target_file"
  echo "[✓] Cluster configuration written to $target_file"
}

set_active_cluster() {
  local cluster_name="$1"
  local cluster_dir="${HPS_CLUSTER_CONFIG_BASE_DIR}/${cluster_name}"
  local active_link="${HPS_CLUSTER_CONFIG_BASE_DIR}/active-cluster"

  if [[ ! -d "$cluster_dir" ]]; then
    echo "[✗] Cluster directory not found: $cluster_dir" >&2
    return 1
  fi

  if [[ ! -f "$cluster_dir/cluster.conf" ]]; then
    echo "[✗] cluster.conf not found in: $cluster_dir" >&2
    return 2
  fi

  ln -sfn "$cluster_dir" "$active_link"
  echo "[✓] Active cluster set to: $cluster_name"
}


cluster_config() {
  local op="$1"
  local key="$2"
  local value="${3:-}"

  local cluster_file
  cluster_file=$(get_active_cluster_filename) || {
    echo "[✗] No active cluster config found." >&2
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
      echo "[✗] Unknown cluster_config operation: $op" >&2
      return 2
      ;;
  esac
}



