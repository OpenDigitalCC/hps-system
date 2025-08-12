__guard_source || return
# Define your functions below

make_timestamp() {
  date -u '+%Y-%m-%d %H:%M:%S UTC'
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


export_dynamic_paths() {
  local cluster_name="${1:-}"
  local base_dir="${HPS_CLUSTER_CONFIG_BASE_DIR:-/srv/hps-config/clusters}"
  local active_link="${base_dir}/active-cluster"

  if [[ -z "$cluster_name" ]]; then
    [[ -L "$active_link" ]] || {
      echo "[x] No active cluster and none specified." >&2
      return 1
    }
    cluster_name=$(basename "$(readlink -f "$active_link")" .cluster)
  fi

  export CLUSTER_NAME="$cluster_name"
  export HPS_CLUSTER_CONFIG_DIR="${base_dir}/${CLUSTER_NAME}"
  export HPS_HOST_CONFIG_DIR="${HPS_CLUSTER_CONFIG_DIR}/hosts"

  return 0
}

# Returns one of: CGI | SCRIPT | SOURCED
detect_call_context() {
    # Sourced? (not the main entrypoint)
    if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
        echo "SOURCED"
        return
    fi

    # CGI? (must have both variables set)
    if [[ -n "$GATEWAY_INTERFACE" && -n "$REQUEST_METHOD" ]]; then
        echo "CGI"
        return
    fi

    # Explicit SCRIPT detection: running in a shell, directly executed
    # Must have a terminal OR be reading from stdin without CGI env
    if [[ -t 0 || -p /dev/stdin || -n "$PS1" ]]; then
        echo "SCRIPT"
        return
    fi

    # Fallback (should not hit this unless in a weird non-interactive, non-CGI case)
    echo "SCRIPT"
}



