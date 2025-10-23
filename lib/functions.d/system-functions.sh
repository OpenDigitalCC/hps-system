__guard_source || return
# Define your functions below

hps_services_stop() {
  supervisorctl -c "$(get_path_cluster_services_dir)/supervisord.conf" stop all
}

hps_services_start() {
  _supervisor_pre_start
  hps_log info "$(supervisorctl -c "$(get_path_cluster_services_dir)/supervisord.conf" start all)"
}

hps_services_restart() {
  _supervisor_pre_start
  hps_log info "$(supervisorctl -c "$(get_path_cluster_services_dir)/supervisord.conf" restart all)"
}


make_timestamp() {
  date -u '+%Y-%m-%d %H:%M:%S UTC'
}

# Treat as TTY if *any* of stdin/out/err is a terminal.
_is_tty() {
  [[ -t 0 || -t 1 || -t 2 ]]
}

#===============================================================================
# download_file
# -------------
# Generic file download function with resume capability and verification
#
# Usage: download_file <url> <destination_path> [expected_sha256]
# Example: download_file "https://example.com/file.iso" "/path/to/file.iso" "abc123..."
#
# Behaviour:
#   - Downloads file using curl or wget (with resume support)
#   - Creates destination directory if needed
#   - Verifies SHA256 checksum if provided
#   - Logs download progress and completion
#
# Returns:
#   0 on success
#   1 if parameters missing or tools unavailable
#   2 if download fails
#   3 if checksum verification fails
#===============================================================================
download_file() {
    local url="$1"
    local dest_path="$2"
    local expected_sha256="$3"
    
    if [[ -z "$url" || -z "$dest_path" ]]; then
        hps_log "ERROR" "download_file: url and destination_path required"
        return 1
    fi
    
    # Check for download tools
    local download_cmd=""
    if command -v curl >/dev/null 2>&1; then
        download_cmd="curl"
    elif command -v wget >/dev/null 2>&1; then
        download_cmd="wget"
    else
        hps_log "ERROR" "download_file: Neither curl nor wget available"
        return 1
    fi
    
    # Create destination directory
    local dest_dir
    dest_dir=$(dirname "$dest_path")
    if ! mkdir -p "$dest_dir"; then
        hps_log "ERROR" "download_file: Failed to create directory: $dest_dir"
        return 2
    fi
    
    hps_log "INFO" "Downloading: $url -> $dest_path"
    
    # Download file with resume support
    if [[ "$download_cmd" == "curl" ]]; then
        if ! curl -s -L -C - -o "$dest_path" "$url"; then
            hps_log "ERROR" "download_file: curl download failed"
            return 2
        fi
    else
        if ! wget -q -c -O "$dest_path" "$url"; then
            hps_log "ERROR" "download_file: wget download failed"
            return 2
        fi
    fi
    
    # Verify checksum if provided
    if [[ -n "$expected_sha256" ]]; then
        if command -v sha256sum >/dev/null 2>&1; then
            local actual_sha256
            actual_sha256=$(sha256sum "$dest_path" | cut -d' ' -f1)
            if [[ "$actual_sha256" != "$expected_sha256" ]]; then
                hps_log "ERROR" "download_file: Checksum mismatch. Expected: $expected_sha256, Got: $actual_sha256"
                return 3
            fi
            hps_log "INFO" "download_file: Checksum verified successfully"
        else
            hps_log "WARN" "download_file: sha256sum not available, skipping checksum verification"
        fi
    fi
    
    hps_log "INFO" "Download completed: $dest_path"
    return 0
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



get_path_cluster_services_dir () {
  echo "$(get_active_cluster_dir)/services"
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



