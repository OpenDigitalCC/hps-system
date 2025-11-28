__guard_source || return
# Define your functions below


# TODO: This is likely deptrecated
#:name: install_opensvc_foreground_wrapper
#:group: opensvc
#:synopsis: Install /usr/local/sbin/opensvc-foreground to run the OpenSVC v3 daemon in foreground with clean logs.
#:usage: install_opensvc_foreground_wrapper
#:description:
#  Writes an exec wrapper that:
#    - ensures runtime dirs (/run/opensvc, /var/log/opensvc, /var/lib/opensvc, ${HPS_LOG_DIR}) exist
#    - verifies /etc/opensvc/agent.key exists and is non-empty (fails fast otherwise)
#    - execs 'om daemon run' (OpenSVC v3) in the foreground
#    - funnels agent stdout/stderr to ${HPS_LOG_DIR}/opensvc.{out,err}.log
#    - filters the noisy "zerolog … journal/socket" lines from stderr (no journald in container)
#  Notes:
#    - Idempotent: only rewrites the file if content changed.
#    - No supervisorctl calls; service control is handled elsewhere.
install_opensvc_foreground_wrapper() {
  local target="/usr/local/sbin/opensvc-foreground"
  local logdir="${HPS_LOG_DIR:-/srv/hps-system/log}"

  mkdir -p "$(dirname "$target")" "$logdir"

  # Desired wrapper content
  local tmp
  tmp="$(mktemp "${target}.XXXXXX")" || { hps_log error "[opensvc] mktemp failed"; return 1; }
  cat >"$tmp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Use HPS log dir if provided, fallback otherwise.
LOGDIR="${HPS_LOG_DIR:-/srv/hps-system/log}"

# Preflight: required directories (ok if already exist)
mkdir -p /run/opensvc /var/log/opensvc /var/lib/opensvc "${LOGDIR}"

# Preflight: agent key must exist and be non-empty
if [[ ! -s /etc/opensvc/agent.key ]]; then
  echo "[opensvc] FATAL: /etc/opensvc/agent.key missing or empty" >&2
  exit 2
fi

# Run the v3 daemon in foreground so a supervisor can manage it if desired.
# Filter the noisy journald error lines from stderr; keep everything else.
# Agent also writes its own file log as configured in /etc/opensvc/opensvc.conf.
exec /usr/bin/om daemon run \
  1>>"${LOGDIR}/opensvc.out.log" \
  2> >(stdbuf -o0 awk '!/zerolog: could not write event: write unixgram .*journal\/socket/' >> "${LOGDIR}/opensvc.err.log")
EOF

  chmod 0755 "$tmp"

  # Idempotent install: only replace if content differs
  if [[ -f "$target" ]]; then
    if cmp -s "$tmp" "$target"; then
      rm -f "$tmp"
      hps_log info "[opensvc] Wrapper already current: ${target}"
      return 0
    fi
  fi

  mv -f "$tmp" "$target"
  hps_log info "[opensvc] Installed wrapper: ${target}"
}

_osvc_setup_directories

_opensvc_foreground_wrapper () {
  # Use HPS log dir if provided, fallback otherwise.
  LOGDIR="${HPS_LOG_DIR:-/srv/hps-system/log}"


  # Run the v3 daemon in foreground so a supervisor can manage it if desired.
  exec /usr/bin/om daemon run | logger -t om -p local0.info
  #\

}




#===============================================================================
# _osvc_setup_directories
# ------------------------
# Creates OpenSVC directory structure.
#
# Behaviour:
#   - Creates /etc/opensvc for configuration files
#   - Creates /var/log/opensvc for log files
#   - Creates /var/lib/opensvc for state/data files
#   - Sets appropriate permissions
#
# Returns:
#   0 on success
#   1 on failure to create directories
#
# Example usage:
#   _osvc_setup_directories
#
#===============================================================================
_osvc_setup_directories() {
  local conf_dir="/etc/opensvc"
  local log_dir="/var/log/opensvc"
  local var_dir="/var/lib/opensvc"
  
  if ! mkdir -p "${conf_dir}" "${log_dir}" "${var_dir}"; then
    hps_log error "Failed to create OpenSVC directories"
    return 1
  fi
  
  hps_log debug "Created OpenSVC directory structure"
  return 0
}

#===============================================================================
# _osvc_create_conf
# -----------------
# Creates minimal opensvc.conf configuration file.
#
# Behaviour:
#   - Generates opensvc.conf with agent nodename
#   - Nodename format: ips
#   - Creates atomic replacement with backup
#   - Sets proper permissions (644, root:root)
#
# Returns:
#   0 on success
#   1 on failure
#
# Example usage:
#   _osvc_create_conf
#
#===============================================================================
_osvc_create_conf() {
  local conf_file="/etc/opensvc/opensvc.conf"
  
  hps_log debug "Generating opensvc.conf"
  
  # Get DNS domain
  local dns_domain
  dns_domain="$(cluster_registry get DNS_DOMAIN 2>/dev/null)" || dns_domain=""
  
  if [[ -z "${dns_domain}" ]]; then
    hps_log error "DNS_DOMAIN not set in cluster_config"
    return 1
  fi
  
  # Create temp file
  local tmp
  tmp="$(mktemp "${conf_file}.XXXXXX")" || {
    hps_log error "Failed to create temp file"
    return 1
  }
  
  # Write minimal config
  cat > "${tmp}" <<EOF
[agent]
nodename = ips
EOF

  # Atomic move
  mv -f "${tmp}" "${conf_file}"
  chmod 0644 "${conf_file}"
  chown root:root "${conf_file}"
  
  hps_log info "Generated ${conf_file}"
  return 0
}


#===============================================================================
# _osvc_cluster_agent_key
# -----------------------
# Manages OpenSVC agent key with single cluster key policy.
#
# Behaviour:
#   - Reads cluster key from cluster_registry (OPENSVC_AGENT_KEY)
#   - Reads existing on-disk key from /etc/opensvc/agent.key
#   - If cluster has canonical key, disk must match or function fails
#   - If no cluster key exists, adopts existing disk key or generates new
#   - Ensures proper permissions on agent.key file
#
# Returns:
#   0 on success
#   2 on agent key conflict
#   1 on other errors
#
# Example usage:
#   _osvc_cluster_agent_key
#
#===============================================================================
_osvc_cluster_agent_key() {
  local key_file="/etc/opensvc/agent.key"
  
  hps_log debug "Enforcing agent key policy"
  
  # Read cluster key (if any)
  local cluster_key
  cluster_key="$(cluster_registry get OPENSVC_AGENT_KEY 2>/dev/null)" || cluster_key=""
  cluster_key="${cluster_key//$'\r'/}"  # Strip CR
  cluster_key="${cluster_key## }"       # Trim leading spaces
  cluster_key="${cluster_key%% }"       # Trim trailing spaces
  
  # Read existing on-disk key (if any)
  local disk_key=""
  if [[ -s "${key_file}" ]]; then
    disk_key="$(head -n1 "${key_file}" 2>/dev/null)" || disk_key=""
    disk_key="${disk_key//$'\r'/}"
    disk_key="${disk_key## }"
    disk_key="${disk_key%% }"
  fi
  
  if [[ -n "${cluster_key}" ]]; then
    # Cluster has canonical key → disk must match or refuse
    if [[ -n "${disk_key}" ]] && [[ "${disk_key}" != "${cluster_key}" ]]; then
      hps_log error "Agent key mismatch detected"
      hps_log error "  Disk key: ${disk_key:0:8}..."
      hps_log error "  Cluster key: ${cluster_key:0:8}..."
      hps_log error "Refusing to overwrite ${key_file}"
      hps_log error "Resolution: update cluster_registry or replace ${key_file} manually"
      return 2
    fi
    
    # Write/normalize the disk key to cluster value
    printf '%s\n' "${cluster_key}" > "${key_file}"
    chmod 0600 "${key_file}"
    chown root:root "${key_file}"
    hps_log info "Applied cluster OPENSVC_AGENT_KEY to ${key_file}"
    
  else
    # No cluster key yet → adopt existing or generate new
    if [[ -n "${disk_key}" ]]; then
      # Adopt existing disk key into cluster config
      cluster_registry set OPENSVC_AGENT_KEY "${disk_key}"
      hps_log info "Adopted existing agent key into cluster config"
    else
      # Generate new key
      local new_key
      if command -v openssl >/dev/null 2>&1; then
        new_key="$(openssl rand -hex 32)"
      else
        new_key="$(tr -dc 'A-Fa-f0-9' </dev/urandom | head -c 64 || true)"
        [[ -z "${new_key}" ]] && new_key="generated-fallback-key"
      fi
      
      cluster_registry set OPENSVC_AGENT_KEY "${new_key}"
      printf '%s\n' "${new_key}" > "${key_file}"
      chmod 0600 "${key_file}"
      chown root:root "${key_file}"
      hps_log info "Generated and stored new OPENSVC_AGENT_KEY"
    fi
  fi
  
  return 0
}

#===============================================================================
# _osvc_cluster_secrets
# ---------------------
# Manages OpenSVC cluster secret for IPS.
#
# Behaviour:
#   - Reads cluster secret from cluster_registry (OPENSVC_CLUSTER_SECRET)
#   - If no secret exists, generates new one using openssl or urandom
#   - Stores generated secret in cluster_config
#   - Returns the secret value via stdout
#
# Returns:
#   0 on success (outputs secret to stdout)
#   1 on error
#
# Example usage:
#   local secret
#   secret="$(_osvc_cluster_secrets)" || return 1
#
#===============================================================================
_osvc_cluster_secrets() {
  local cluster_secret
  cluster_secret="$(cluster_registry get OPENSVC_CLUSTER_SECRET 2>/dev/null)" || cluster_secret=""
  
  # IPS: Generate secret if not exists
  if [[ -z "${cluster_secret}" ]]; then
    if command -v openssl >/dev/null 2>&1; then
      cluster_secret="$(openssl rand -hex 16)"
    else
      cluster_secret="$(tr -dc 'a-f0-9' </dev/urandom | head -c 32 || true)"
      [[ -z "${cluster_secret}" ]] && {
        hps_log error "Failed to generate cluster secret"
        return 1
      }
    fi
    
    cluster_registry set OPENSVC_CLUSTER_SECRET "${cluster_secret}"
    hps_log info "Generated and stored OPENSVC_CLUSTER_SECRET"
  fi
  
  printf '%s' "${cluster_secret}"
  return 0
}



#===============================================================================
# _osvc_create_hb_secrets
# -----------------------
# Creates OpenSVC heartbeat secrets if not already configured.
#
# Behaviour:
#   - Checks if system/sec/hb object exists
#   - Checks if secret key exists within the object
#   - Only creates if both object and secret are missing
#   - Generates 32-byte hex secret for heartbeat authentication
#   - Verifies creation by listing keys
#
# Returns:
#   0 on success (created or already exists)
#   1 on creation failure
#
# Example usage:
#   _osvc_create_hb_secrets
#
#===============================================================================
_osvc_create_hb_secrets() {
  hps_log debug "Checking heartbeat secrets"
  
  # Check if heartbeat secret object exists
  if om system/sec/hb print >/dev/null 2>&1; then
    # Object exists, check if secret key exists
    if om system/sec/hb key ls 2>/dev/null | grep -q "^secret"; then
      hps_log debug "Heartbeat secrets already configured"
      return 0
    fi
    hps_log debug "Heartbeat object exists but secret key missing"
  else
    # Create heartbeat secret object
    hps_log info "Creating heartbeat secret object"
    if ! om system/sec/hb create 2>/dev/null; then
      hps_log error "Failed to create heartbeat secret object"
      return 1
    fi
  fi
  
  # Generate a random secret for heartbeat authentication
  local hb_secret
  if command -v openssl >/dev/null 2>&1; then
    hb_secret="$(openssl rand -hex 32)"
  else
    hb_secret="$(tr -dc 'a-f0-9' </dev/urandom | head -c 64 || true)"
    if [[ -z "${hb_secret}" ]]; then
      hps_log error "Failed to generate heartbeat secret"
      return 1
    fi
  fi
  
  # Add the secret to the object
  hps_log info "Adding heartbeat secret key"
  if ! om system/sec/hb key add --name secret --value "${hb_secret}" 2>/dev/null; then
    hps_log error "Failed to add heartbeat secret key"
    return 1
  fi
  
  # Verify it was created
  if om system/sec/hb key ls 2>/dev/null | grep -q "^secret"; then
    hps_log info "Heartbeat secrets configured successfully"
    return 0
  else
    hps_log error "Heartbeat secret verification failed"
    return 1
  fi
}

#===============================================================================
# _osvc_wait_for_sock
# --------------------
# Wait for OpenSVC daemon socket to be ready.
# Helper function for osvc_prepare_cluster_identity.
#
# Behaviour:
#   - Checks for socket file existence up to 10 times
#   - Sleeps 1 second between checks
#   - Exits with code 1 on timeout
#
# Returns:
#   Does not return on failure (exits 1)
#   Returns 0 when socket is ready
#===============================================================================
_osvc_wait_for_sock() {
  hps_log debug "Waiting for OpenSVC daemon socket"
  
  local i
  for i in {1..10}; do
    if [[ -S /var/lib/opensvc/lsnr/http.sock ]]; then
      hps_log debug "OpenSVC daemon socket ready"
      return 0
    fi
    sleep 1
  done
  
  hps_log error "OpenSVC daemon socket not ready after 10 seconds"
  return 1
}

#===============================================================================
# _osvc_verify_daemon_responsive
# -----------------------------
# Verify OpenSVC daemon is responsive to commands.
# Helper function for osvc_prepare_cluster_identity.
#
# Behaviour:
#   - Tests daemon responsiveness using om cluster status
#   - Exits with code 1 if daemon is not responsive
#
# Returns:
#   Does not return on failure (exits 1)
#   Returns 0 if daemon is responsive
#===============================================================================
_osvc_verify_daemon_responsive() {
  hps_log debug "Verifying OpenSVC daemon responsiveness"
  
  if om cluster status >/dev/null 2>&1; then
    hps_log debug "OpenSVC daemon is responsive"
    return 0
  else
    hps_log error "OpenSVC daemon not responsive"
    exit 1
  fi
}



#:name: _osvc_config_update
#:group: opensvc
#:synopsis: Set OpenSVC configuration using the correct v3 API.
#:usage: _osvc_config_update <key=value> [key=value] ...
#:description:
#  Sets OpenSVC cluster configuration using om cluster config update.
#  This is the ONLY function that should be used to modify OpenSVC settings.
#  Handles logging and error reporting internally.
#:parameters:
#  key=value - One or more configuration key-value pairs
#:returns:
#  0 on success
#  1 on failure
_osvc_config_update() {
  if [[ $# -eq 0 ]]; then
    hps_log error "_osvc_config_update: at least one key=value pair required"
    return 1
  fi
  
  local set_args=()
  for kv in "$@"; do
    set_args+=(--set "$kv")
  done
  
  hps_log debug "Updating OpenSVC cluster config: $*"
  
  if om cluster config update "${set_args[@]}" 2>&1 | grep -v "^$"; then
    hps_log debug "Successfully updated cluster config"
    return 0
  else
    hps_log error "Failed to update cluster config: $*"
    return 1
  fi
}


# Deprecated in favour of _osvc_config_update?
#:name: _osvc_kv_set
#:group: opensvc
#:synopsis: Set an OpenSVC v3 key using om config set --kw key=value
#:usage: _osvc_kv_set key value
_osvc_kv_set() {
  local k="${1:?key}" v="${2:?value}"
  om config set --kw "${k}=${v}"
}


osvc_process_commands() {
  local cmd="$1"
  
  # Validate command parameter
  if [[ -z "$cmd" ]]; then
    hps_log error "No command specified"
    return 1
  fi
  
  case "$cmd" in 
    get_auth_token)
      _osvc_get_auth_token
      ;;
    *)
      hps_log error "Unknown command: $cmd"
      return 1
      ;;
  esac
}



# Get an auth token from OpenSVC. Short-lived 
# so that it is only used in this atomic operation
# the joining client must use it straight away.
_osvc_get_auth_token () {
# TODO: add --subject calling hostname
  echo $(om daemon auth --duration 15s --role join)
}




#:name: ensure_opensvc_installed
#:group: opensvc
#:synopsis: Ensure OpenSVC (om) is installed and functional.
#:usage: ensure_opensvc_installed
#:description:
#  Checks if 'om' command exists and is executable.
#  If not found or not working, calls ips_install_opensvc to install it.
#  Verifies installation was successful before returning.
#  Loop-safe: only attempts installation once.
#:returns:
#  0 if om is available and working
#  1 if installation fails or om still not working after install
ensure_opensvc_installed() {
  local installed=0
  
  # Check if om exists and is executable
  if command -v om >/dev/null 2>&1; then
    # Test that om actually runs
    if om version >/dev/null 2>&1; then
      hps_log debug "OpenSVC already installed and working"
      return 0
    else
      hps_log warning "om command found but not functional"
    fi
  else
    hps_log info "OpenSVC not found, installing..."
  fi
  
  # Install OpenSVC
  if ! ips_install_opensvc; then
    hps_log error "Failed to install OpenSVC"
    return 1
  fi
  
  # Verify installation succeeded
  if ! command -v om >/dev/null 2>&1; then
    hps_log error "OpenSVC installation completed but om command still not found"
    return 1
  fi
  
  # Test that it actually works
  if ! om version >/dev/null 2>&1; then
    hps_log error "OpenSVC installed but om command not functional"
    return 1
  fi
  
  hps_log info "OpenSVC installed and verified successfully"
  return 0
}


ips_install_opensvc () {
  # Verify presence, install, fix deps, and sanity-check 'om'
  # Check the .deb exists and is non-empty
  OSVC_DEB="$(ls -t $HPS_PACKAGES_DIR/opensvc/*.deb | head -n 1)"

  hps_log debug "Installing OSVC_DEB: $OSVC_DEB"
  test -s $OSVC_DEB || { 
    hps_log error "ERROR: $OSVC_DEB missing or empty"
    return 1 
    }
  # Install; resolve any missing deps from Debian repos
  apt-get update
  apt-get install -y --no-install-recommends $OSVC_DEB || apt-get -f install -y
  rm -rf /var/lib/apt/lists/*
  # Sanity check: ensure 'om' is available and prints a version
  if ! command -v om >/dev/null 2>&1; then 
    hps_log error "ERROR: 'om' command not found after installing OpenSVC"
  return 1
  fi
}


