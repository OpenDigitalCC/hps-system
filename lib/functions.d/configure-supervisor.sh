__guard_source || return


#:name: configure_supervisor_services
#:group: supervisor
#:synopsis: Generate supervisord.conf with dnsmasq, nginx, fcgiwrap, and OpenSVC agent.
#:usage: configure_supervisor_services
#:description:
#  Writes $(get_path_cluster_services_dir)/supervisord.conf with dnsmasq, nginx,
#  fcgiwrap, and OpenSVC agent programs. Logs are written to ${HPS_LOG_DIR}.
#  The function is idempotent: each program block is only added once.
#  Validates that the configuration file and required directories are created successfully.
#:returns:
#  0 on success
#  1 if core configuration creation fails
#  2 if directory creation fails
#  3 if configuration file write fails
configure_supervisor_services() {
  # Ensure the core header and defaults exist
  local SUPERVISORD_CONF
  SUPERVISORD_CONF="$(configure_supervisor_core)" || {
    hps_log error "Failed to create supervisor core configuration"
    return 1
  }

  # Verify core config file was actually created
  if [[ ! -f "${SUPERVISORD_CONF}" ]]; then
    hps_log error "Supervisor core configuration file not found: ${SUPERVISORD_CONF}"
    return 1
  fi

  
  hps_log info "Creating Supervisor services config ${SUPERVISORD_CONF}"

  # Ensure required directories exist
  local config_dir log_dir
  config_dir="$(dirname "${SUPERVISORD_CONF}")"
  log_dir="${HPS_LOG_DIR}"

  for dir in "${config_dir}" "${log_dir}"; do
    if [[ ! -d "${dir}" ]]; then
      mkdir -p "${dir}" || {
        hps_log error "Failed to create directory: ${dir}"
        return 2
      }
      hps_log debug "Created directory: ${dir}"
    fi
  done

  # Helper: append a block once, keyed by program stanza name
  _supervisor_append_once() {
    local stanza="$1"    # e.g. program:nginx
    local block="$2"
    
    # Check if stanza already exists
    if ! grep -qE "^\[${stanza}\]\s*$" "${SUPERVISORD_CONF}" 2>/dev/null; then
      # Attempt to append the block
      if printf '\n%s\n\n' "${block}" >> "${SUPERVISORD_CONF}" 2>/dev/null; then
        hps_log debug "Added supervisor service: ${stanza}"
      else
        hps_log error "Failed to write service block: ${stanza}"
        return 3
      fi
    else
      hps_log debug "Supervisor service already exists: ${stanza}"
    fi
  }

  # --- dnsmasq ---


  local DNSMASQ_CONF="$(get_path_cluster_services_dir)/dnsmasq.conf"
  local DNSMASQ_LOG_STDERR="${HPS_LOG_DIR}/dnsmasq.err.log"
  local DNSMASQ_LOG_STDOUT="${HPS_LOG_DIR}/dnsmasq.out.log"
  
  touch ${DNSMASQ_LOG_STDERR} ${DNSMASQ_LOG_STDOUT}
  chown nobody:nogroup ${DNSMASQ_LOG_STDERR} ${DNSMASQ_LOG_STDOUT}

  _supervisor_append_once "program:dnsmasq" "$(cat <<EOF
[program:dnsmasq]
command=/usr/sbin/dnsmasq -k --conf-file=${DNSMASQ_CONF} --log-facility=${DNSMASQ_LOG_STDOUT}
autostart=true
autorestart=true
stderr_logfile=${DNSMASQ_LOG_STDERR}
stdout_logfile=${DNSMASQ_LOG_STDOUT}
EOF
)" || return 3

  # --- nginx ---
  _supervisor_append_once "program:nginx" "$(cat <<EOF
[program:nginx]
command=/usr/sbin/nginx -g 'daemon off;' -c "$(get_path_cluster_services_dir)/nginx.conf"
autostart=true
autorestart=true
stderr_logfile=${HPS_LOG_DIR}/nginx.err.log
stdout_logfile=${HPS_LOG_DIR}/nginx.out.log
EOF
)" || return 3

  # --- fcgiwrap ---
  _supervisor_append_once "program:fcgiwrap" "$(cat <<EOF
[program:fcgiwrap]
command=bash -c 'rm -f /var/run/fcgiwrap.socket && exec /usr/bin/spawn-fcgi -n -s /var/run/fcgiwrap.socket -U www-data -G www-data /usr/sbin/fcgiwrap'
umask=002
autostart=true
autorestart=true
stdout_logfile=${HPS_LOG_DIR}/fcgiwrap.out.log
stderr_logfile=${HPS_LOG_DIR}/fcgiwrap.err.log
EOF
)" || return 3

  # --- rsyslogd ---
  _supervisor_append_once "program:rsyslogd" "$(cat <<EOF
[program:rsyslogd]
command=/usr/sbin/rsyslogd -n -f $(get_path_cluster_services_dir)/rsyslog.conf
autostart=true
autorestart=true
stderr_logfile=${HPS_LOG_DIR}/rsyslog.err.log
stdout_logfile=${HPS_LOG_DIR}/rsyslog.out.log
EOF
)" || return 3


  # --- OpenSVC agent ---
  _supervisor_append_once "program:opensvc" "$(cat <<EOF
[program:opensvc]
command=/usr/local/sbin/opensvc-foreground
autostart=true
autorestart=true
startsecs=2
startretries=3
stopsignal=TERM
user=root
environment=HOME="/root"
directory=/
stdout_logfile=${HPS_LOG_DIR}/opensvc.supervisor-stdout.log
stderr_logfile=${HPS_LOG_DIR}/opensvc.supervisor-stderr.log
EOF
)" || return 3

  # Final validation: verify the file exists and is readable
  if [[ ! -f "${SUPERVISORD_CONF}" ]] || [[ ! -r "${SUPERVISORD_CONF}" ]]; then
    hps_log error "Supervisor configuration file validation failed: ${SUPERVISORD_CONF}"
    return 3
  fi

  hps_log info "Supervisor services config generated successfully at: ${SUPERVISORD_CONF}"
  return 0
}

get_path_supervisord_conf () {
  echo "$(get_path_cluster_services_dir)/supervisord.conf"
}


#:name: configure_supervisor_core
#:group: supervisor
#:synopsis: Write the base supervisord.conf using ${HPS_LOG_DIR} for all logs.
#:usage: configure_supervisor_core
#:description:
#  Generates $(get_path_cluster_services_dir)/supervisord.conf core sections and sets:
#    - logfile=${HPS_LOG_DIR}/supervisord.log
#    - childlogdir=${HPS_LOG_DIR}/supervisor
#  Ensures ${HPS_LOG_DIR} and ${HPS_LOG_DIR}/supervisor exist.
#  Validates that all directories and the configuration file are created successfully.
#:returns:
#  0 on success (outputs config file path to stdout)
#  1 if required variables are not set
#  2 if directory creation fails
#  3 if configuration file write fails
#  4 if configuration file validation fails
configure_supervisor_core() {
  # Validate required environment variables
  if [[ -z "$(get_path_cluster_services_dir)" ]]; then
    hps_log error "Cannot locate cluster services dir"
    return 1
  fi
  
  if [[ -z "${HPS_LOG_DIR}" ]]; then
    hps_log error "HPS_LOG_DIR is not set"
    return 1
  fi

  local SUPERVISORD_CONF="$(get_path_supervisord_conf)"
  local SUPERVISOR_CHILD_LOG_DIR="${HPS_LOG_DIR}/supervisor"
  
  hps_log info "Creating Supervisor core config ${SUPERVISORD_CONF}"

  # Ensure parent directory for config exists
  local config_dir
  config_dir="$(dirname "${SUPERVISORD_CONF}")"
  if [[ ! -d "${config_dir}" ]]; then
    if ! mkdir -p "${config_dir}"; then
      hps_log error "Failed to create configuration directory: ${config_dir}"
      return 2
    fi
    hps_log debug "Created configuration directory: ${config_dir}"
  fi

  # Ensure base log directories exist
  local dir
  for dir in "${HPS_LOG_DIR}" "${SUPERVISOR_CHILD_LOG_DIR}"; do
    if [[ ! -d "${dir}" ]]; then
      if ! mkdir -p "${dir}"; then
        hps_log error "Failed to create log directory: ${dir}"
        return 2
      fi
      hps_log debug "Created log directory: ${dir}"
    fi
  done

  # Write the configuration file
  if ! cat > "${SUPERVISORD_CONF}" <<EOF
[unix_http_server]
file=/var/run/supervisor.sock
chmod=0700
username=admin
password=ignored-but-needed

[supervisorctl]
serverurl=unix:///var/run/supervisor.sock
username=admin
password=ignored-but-needed

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisord]
nodaemon=true
logfile=${HPS_LOG_DIR}/supervisord.log
pidfile=/var/run/supervisord.pid
childlogdir=${SUPERVISOR_CHILD_LOG_DIR}
loglevel=info
identifier=supervisor
minfds=1024
minprocs=200
user=root
strip_ansi=false
EOF
  then
    hps_log error "Failed to write supervisor core configuration to: ${SUPERVISORD_CONF}"
    return 3
  fi

  # Validate the configuration file was created and is readable
  if [[ ! -f "${SUPERVISORD_CONF}" ]]; then
    hps_log error "Configuration file does not exist after write: ${SUPERVISORD_CONF}"
    return 4
  fi

  if [[ ! -r "${SUPERVISORD_CONF}" ]]; then
    hps_log error "Configuration file is not readable: ${SUPERVISORD_CONF}"
    return 4
  fi

  # Validate file has content (should be at least 100 bytes for this config)
  local file_size
  file_size=$(stat -c%s "${SUPERVISORD_CONF}" 2>/dev/null || stat -f%z "${SUPERVISORD_CONF}" 2>/dev/null)
  if [[ -z "${file_size}" ]] || [[ "${file_size}" -lt 100 ]]; then
    hps_log error "Configuration file appears to be empty or truncated: ${SUPERVISORD_CONF}"
    return 4
  fi

  # Validate critical sections are present
  local required_sections=("[unix_http_server]" "[supervisorctl]" "[supervisord]")
  local section
  for section in "${required_sections[@]}"; do
    if ! grep -qF "${section}" "${SUPERVISORD_CONF}"; then
      hps_log error "Configuration file missing required section: ${section}"
      return 4
    fi
  done

  hps_log info "Supervisor core config generated successfully at: ${SUPERVISORD_CONF}"
  
  # Output the config path to stdout for capturing by callers
  echo "${SUPERVISORD_CONF}"
  return 0
}





