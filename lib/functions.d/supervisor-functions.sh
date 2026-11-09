# shellcheck shell=bash

# at initial containwer start, subsequent supervisor starts or restarts, prepare the services
_supervisor_pre_start () {
  supervisor_configure_core_config
  supervisor_configure_core_services
  supervisor_prepare_services
  supervisor_prepare_jobs
  supervisor_fix_state_permissions
  supervisor_reload_core_config
}

# Hand IPS state to group hps before services start (the CGI runs as www-data,
# a member of hps; root writers are covered by umask 002 and setgid dirs).
# Covers HPS_CONFIG_BASE and HPS_LOG; never touches a path named keysafe
# (root-only); resources are served read-only and are left alone.
# Idempotent; logs a count; refuses an empty variable or /.
supervisor_fix_state_permissions () {
  local target total=0
  for target in "${HPS_CONFIG_BASE:-}" "${HPS_LOG:-}"; do
    if [[ -z "$target" || "$target" == "/" ]]; then
      hps_log error "supervisor_fix_state_permissions: refusing to run against '${target}'"
      return 1
    fi
  done
  for target in "$HPS_CONFIG_BASE" "$HPS_LOG"; do
    hps_state_fix_tree "$target" || return 1
    total=$((total + HPS_STATE_FIX_COUNT))
  done
  hps_log info "supervisor_fix_state_permissions: ${total} path(s) checked under ${HPS_CONFIG_BASE} and ${HPS_LOG}"
  return 0
}

# The privileged-action queue (jobs/{new,run,done,failed} of the active
# cluster), created group hps / setgid / group-writable so the CGI can write
# new/. hps-jobs creates the same on start; this makes them exist before the
# first CGI request. No active cluster yet: logged, not an error.
supervisor_prepare_jobs () {
  if ! hps_jobs_ensure_dirs 2>/dev/null; then
    hps_log warn "supervisor_prepare_jobs: no job queue yet (no active cluster?); hps-jobs creates it on start"
    return 0
  fi
  hps_log info "supervisor_prepare_jobs: job queue ready at $(hps_jobs_dir)"
  return 0
}

# Get all services ready to start
supervisor_prepare_services () {
#  _set_ips_hostname
  supervisor_populate_tftp
  os_seed_nixos || hps_log warn "supervisor_prepare_services: os_seed_nixos failed (continuing)"
  create_config_lighttpd
  create_config_dnsmasq
  update_dns_dhcp_files
  create_config_rsyslog
  create_config_chrony
  # No OpenSVC package (lab IPS): log and continue, the services above do not need it.
  osvc_prepare_cluster || hps_log warn "supervisor_prepare_services: OpenSVC not prepared (continuing without it)"
}


# Copy the boot loaders shipped in ${HPS_SYSTEM_BASE}/tftp into the TFTP root
# (hps_get_config tftp). Copies only files that are missing or differ.
supervisor_populate_tftp () {
  local src dest f name copied=0
  src="$(hps_get_config system_base)/tftp"
  dest="$(hps_get_config tftp)" || {
    hps_log error "supervisor_populate_tftp: cannot determine TFTP root"
    return 1
  }
  if [[ ! -d "$src" ]]; then
    hps_log error "supervisor_populate_tftp: source directory missing: $src"
    return 1
  fi
  mkdir -p "$dest" || {
    hps_log error "supervisor_populate_tftp: cannot create $dest"
    return 1
  }
  for f in "$src"/*; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    if [[ -f "$dest/$name" ]] && cmp -s "$f" "$dest/$name"; then
      continue
    fi
    cp -f -- "$f" "$dest/$name" || {
      hps_log error "supervisor_populate_tftp: copy failed: $name"
      return 1
    }
    hps_log info "supervisor_populate_tftp: installed $name into $dest"
    copied=$((copied + 1))
  done
  hps_log info "supervisor_populate_tftp: $copied file(s) copied to $dest"
  return 0
}

# Functions to run straight after supervisor has started
_supervisor_post_start () {
  if ! command -v om >/dev/null 2>&1; then
    hps_log warn "_supervisor_post_start: OpenSVC (om) not installed, skipping osvc_configure_cluster"
    return 0
  fi
  osvc_configure_cluster
}


supervisor_reload_core_config () {
  local SUPERVISORD_CONF
  SUPERVISORD_CONF="$(hps_get_config supervisord_conf)"
  hps_log info "Reread: $(supervisorctl -c "$SUPERVISORD_CONF" reread) $?"
  hps_log info "Update: $(supervisorctl -c "$SUPERVISORD_CONF" update) $?"
}


#:name: supervisor_reload_services
#:group: supervisor
#:synopsis: Send HUP signal to supervisor services (all or specific service).
#:usage: supervisor_reload_services [service_name]
#:description:
#  Sends HUP signal to reload supervisor-managed services.
#  If no argument provided, signals all services.
#  If service_name provided, signals only that specific service.
#  Validates that supervisorctl command succeeds and logs results.
#:parameters:
#  service_name - (optional) Name of specific service to reload (e.g., lighttpd, dnsmasq)
#:returns:
#  0 on success
#  1 if SUPERVISORD_CONF is not set or file doesn't exist
#  2 if supervisorctl command fails
supervisor_reload_services() {
  local SUPERVISORD_CONF
  SUPERVISORD_CONF="$(hps_get_config supervisord_conf)"
  local service_name="${1:-}"
  
  # Validate SUPERVISORD_CONF is set
  if [[ -z "${SUPERVISORD_CONF}" ]]; then
    hps_log error "SUPERVISORD_CONF is not set"
    return 1
  fi
  
  # Validate configuration file exists
  if [[ ! -f "${SUPERVISORD_CONF}" ]]; then
    hps_log error "Supervisor configuration file not found: ${SUPERVISORD_CONF}"
    return 1
  fi
  
  # Determine target for HUP signal
  local target="all"
  if [[ -n "${service_name}" ]]; then
    target="${service_name}"
    hps_log info "Sending HUP signal to supervisor service: ${service_name}"
  else
    hps_log info "Sending HUP signal to all supervisor services"
  fi
  
  # Execute HUP signal and capture output
  local result
  local exit_code
  result=$(supervisorctl -c "${SUPERVISORD_CONF}" signal HUP "${target}" 2>&1 | tr '\n' ' ' | sed 's/  */ /g' | sed 's/ $//')
  exit_code=$?
  
  # Log results
  if [[ ${exit_code} -eq 0 ]]; then
    hps_log info "HUP signal sent successfully to ${target}: ${result}"
    return 0
  else
    hps_log error "Failed to send HUP signal to ${target} (exit code: ${exit_code}): ${result}"
    return 2
  fi
}


