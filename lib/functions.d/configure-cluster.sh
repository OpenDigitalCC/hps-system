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
    if [[ ! -f "$target" ]]; then
        echo "[ERROR] Resolved target is not a file: $target" >&2
        return 1
    fi
    cat "$target"
}


get_active_cluster_filename() {
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
    echo "$target"
}


get_active_cluster_info() {
  source /srv/hps-config/hps.conf
  local config_dir="$HPS_CLUSTER_CONFIG_DIR"
  local active="$config_dir/active"

  shopt -s nullglob
  local clusters=("$config_dir"/*.cluster)
  shopt -u nullglob

  if [[ ${#clusters[@]} -eq 0 ]]; then
    echo "[!] No cluster configurations found in $config_dir" >&2
    return 1
  elif [[ ${#clusters[@]} -eq 1 ]]; then
    echo "[*] Using only cluster: $(basename "${clusters[0]}")"
    echo "${clusters[0]}"
  elif [[ -f "$active" ]]; then
    local file="$config_dir/$(cat "$active")"
    if [[ -f "$file" ]]; then
      echo "[*] Using active cluster: $(basename "$file")"
      echo "$file"
    else
      echo "[!] Active cluster file not found: $file" >&2
      return 1
    fi
  else
    echo "[?] Multiple clusters found:"
    select cluster in "${clusters[@]}"; do
      [[ -n "$cluster" ]] && echo "$cluster" && return
    done
  fi
}



count_clusters() {
  source /srv/hps-config/hps.conf
  shopt -s nullglob
  local clusters=("${HPS_CLUSTER_CONFIG_DIR}"/*.cluster)
  shopt -u nullglob
  echo "${#clusters[@]}"
}


list_clusters() {
  source /srv/hps-config/hps.conf
  shopt -s nullglob
  local clusters=("${HPS_CLUSTER_CONFIG_DIR}"/*.cluster)
  shopt -u nullglob
  for c in "${clusters[@]}"; do
    echo "$(basename "$c")"
  done
}

select_cluster() {
  source /srv/hps-config/hps.conf
  local config_dir="$HPS_CLUSTER_CONFIG_DIR"
  shopt -s nullglob
  local clusters=("$config_dir"/*.cluster)
  shopt -u nullglob

  if [[ ${#clusters[@]} -eq 0 ]]; then
    echo "[!] No clusters found in $config_dir" >&2
    return 1
  fi

  echo "[?] Select a cluster:"
  select cluster in "${clusters[@]}"; do
    [[ -n "$cluster" ]] && echo "$cluster" && return
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
  local target="$1"
  ln -sf "$target" "${HPS_CLUSTER_CONFIG_DIR}/active-cluster"
  echo "[✓] Active cluster set to: $(basename "$target")"
}

hps_services_start() {
  configure_supervisor_services
  reload_supervisor_config
  supervisorctl -c "${HPS_SERVICE_CONFIG_DIR}/supervisord.conf" start all
}

hps_services_stop() {
  supervisorctl -c "${HPS_SERVICE_CONFIG_DIR}/supervisord.conf" stop all
}

hps_services_restart() {
  configure_supervisor_services
  reload_supervisor_config
  supervisorctl -c "${HPS_SERVICE_CONFIG_DIR}/supervisord.conf" restart all
}


