__guard_source || return
# Define your functions below

make_timestamp() {
  date -u '+%Y-%m-%d %H:%M:%S UTC'
}

# Treat as TTY if *any* of stdin/out/err is a terminal.
_is_tty() {
  [[ -t 0 || -t 1 || -t 2 ]]
}

# Build 'origin' (MAC for CGI, otherwise pid/user/host). Safe under `set -u`.
hps_origin_tag() {
  # Optional: caller may pass an explicit origin override (e.g. for tests)
  local override="${1-}"

  if [[ -n "$override" ]]; then
    printf '%s' "$override"
    return 0
  fi

  if _is_tty; then
    # Interactive CLI (or at least one TTY fd): lightweight tag
    # ${VAR-} is safe under `set -u` (yields empty if unset)
    # nest defaults so we never reference a bare unset var

local user="$(id -un 2>/dev/null || echo unknown)"
local host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
printf 'pid:%s user:%s host:%s' "$$" "$user" "$host"

#    printf 'pid:%s user:%s host:%s' "$$" "${LOGNAME:-$USER}" "$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
#    printf 'pid:%s' "$$"
    return 0
  fi

  # Non-TTY path: try to use client IP/MAC if available (e.g. CGI)
  local rip="${REMOTE_ADDR-}" mac=""
  if [[ -n "$rip" ]]; then
    # Only call get_client_mac if it exists
    if declare -F get_client_mac >/dev/null 2>&1; then
      mac="$(get_client_mac "$rip" 2>/dev/null || true)"
    fi
    if [[ -n "$mac" ]]; then
      printf '%s' "$mac"
    else
      # Fall back to IP tag if MAC cannot be resolved
      printf '%s' "$rip"
    fi
    return 0
  fi

  # Non-TTY and no REMOTE_ADDR: likely batch/cron → fall back to pid tag
  printf 'pid:%s' "$$"
}


hps_services_start() {
  configure_supervisor_services
  reload_supervisor_config
  supervisorctl -c "${HPS_SERVICE_CONFIG_DIR}/supervisord.conf" start all
  hps_services_post_start
}

hps_services_stop() {
  supervisorctl -c "${HPS_SERVICE_CONFIG_DIR}/supervisord.conf" stop all
}

hps_services_restart() {
  configure_supervisor_services
  create_supervisor_services_config
  reload_supervisor_config
  supervisorctl -c "${HPS_SERVICE_CONFIG_DIR}/supervisord.conf" restart all
  hps_services_post_start
}

hps_services_post_start () {
  # Configure OpenSVC cluster if applicable
  hps_configure_opensvc_cluster
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



