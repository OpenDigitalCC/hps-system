__guard_source || return

create_supervisor_services_config () {
  create_config_nginx
  create_config_dnsmasq
  create_config_rsyslog
  create_config_opensvc IPS # specify that this is an IPS node
}

reload_supervisor_config () {
  local SUPERVISORD_CONF="$(get_path_supervisord_conf)"
  hps_log info "Reread: $(supervisorctl -c "$SUPERVISORD_CONF" reread) $?"
  hps_log info "Update: $(supervisorctl -c "$SUPERVISORD_CONF" update) $?"
}


#:name: reload_supervisor_services
#:group: supervisor
#:synopsis: Send HUP signal to supervisor services (all or specific service).
#:usage: reload_supervisor_services [service_name]
#:description:
#  Sends HUP signal to reload supervisor-managed services.
#  If no argument provided, signals all services.
#  If service_name provided, signals only that specific service.
#  Validates that supervisorctl command succeeds and logs results.
#:parameters:
#  service_name - (optional) Name of specific service to reload (e.g., nginx, dnsmasq)
#:returns:
#  0 on success
#  1 if SUPERVISORD_CONF is not set or file doesn't exist
#  2 if supervisorctl command fails
reload_supervisor_services() {
  local SUPERVISORD_CONF="$(get_path_supervisord_conf)"
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



