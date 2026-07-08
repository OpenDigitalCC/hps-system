#!/bin/bash

#===============================================================================
# Supervisor Configuration Functions
#===============================================================================
# Functions for generating and managing supervisord configuration.
# Uses centralized paths via hps_get_config for consistency.
#===============================================================================

_get_hps_environment() {
  # Return standard HPS environment for supervisor programs
  echo "HPS_SYSTEM_BASE=\"${HPS_SYSTEM_BASE}\",HPS_CONFIG_BASE=\"${HPS_CONFIG_BASE}\",HOME=\"/root\""
}

#===============================================================================
# supervisor_configure_core_config
# --------------------------------
# Write the base supervisord.conf using ${HPS_LOG} for all logs.
#
# Usage:
#   supervisor_configure_core_config
#
# Description:
#   Generates /srv/hps-config/services/supervisord.conf core sections:
#     - logfile=${HPS_LOG}/supervisord.log
#     - childlogdir=${HPS_LOG}/supervisor
#   Ensures ${HPS_LOG} and ${HPS_LOG}/supervisor exist.
#   Validates that all directories and the configuration file are created.
#
# Returns:
#   0 on success
#   1 if required variables are not set
#   2 if directory creation fails
#   3 if configuration file write fails
#   4 if configuration file validation fails
#
# Note:
#   Config location is fixed at /srv/hps-config/services/supervisord.conf
#   Logs are centralized (not cluster-specific)
#
#===============================================================================
supervisor_configure_core_config() {
  # Get supervisor config path
  local supervisord_conf
  supervisord_conf=$(hps_get_config supervisord_conf) || {
    hps_log error "Cannot determine supervisord configuration path"
    return 1
  }
  
  # Validate HPS_LOG is set
  if [[ -z "${HPS_LOG}" ]]; then
    hps_log error "HPS_LOG is not set"
    return 1
  fi

  local supervisor_child_log_dir="${HPS_LOG}/supervisor"
  
  hps_log info "Creating Supervisor core config ${supervisord_conf}"

  # Ensure parent directory for config exists
  local config_dir
  config_dir="$(dirname "${supervisord_conf}")"
  if [[ ! -d "${config_dir}" ]]; then
    if ! mkdir -p "${config_dir}"; then
      hps_log error "Failed to create configuration directory: ${config_dir}"
      return 2
    fi
    hps_log debug "Created configuration directory: ${config_dir}"
  fi

  # Ensure base log directories exist
  local dir
  for dir in "${HPS_LOG}" "${supervisor_child_log_dir}"; do
    if [[ ! -d "${dir}" ]]; then
      if ! mkdir -p "${dir}"; then
        hps_log error "Failed to create log directory: ${dir}"
        return 2
      fi
      hps_log debug "Created log directory: ${dir}"
    fi
  done

  # Write the configuration file
  if ! cat > "${supervisord_conf}" <<EOF
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
logfile=${HPS_LOG}/supervisord.log
pidfile=/var/run/supervisord.pid
childlogdir=${supervisor_child_log_dir}
logfile_maxbytes=10000
loglevel=info
identifier=supervisor
minfds=1024
minprocs=200
user=root
strip_ansi=false
syslog=true
EOF
  then
    hps_log error "Failed to write supervisor core configuration to: ${supervisord_conf}"
    return 3
  fi

  # Validate the configuration file was created and is readable
  if [[ ! -f "${supervisord_conf}" ]]; then
    hps_log error "Configuration file does not exist after write: ${supervisord_conf}"
    return 4
  fi

  if [[ ! -r "${supervisord_conf}" ]]; then
    hps_log error "Configuration file is not readable: ${supervisord_conf}"
    return 4
  fi

  # Validate file has content (should be at least 100 bytes for this config)
  local file_size
  file_size=$(stat -c%s "${supervisord_conf}" 2>/dev/null || stat -f%z "${supervisord_conf}" 2>/dev/null)
  if [[ -z "${file_size}" ]] || [[ "${file_size}" -lt 100 ]]; then
    hps_log error "Configuration file appears to be empty or truncated: ${supervisord_conf}"
    return 4
  fi

  # Validate critical sections are present
  local required_sections=("[unix_http_server]" "[supervisorctl]" "[supervisord]")
  local section
  for section in "${required_sections[@]}"; do
    if ! grep -qF "${section}" "${supervisord_conf}"; then
      hps_log error "Configuration file missing required section: ${section}"
      return 4
    fi
  done

  hps_log info "Supervisor core config generated successfully at: ${supervisord_conf}"
  return 0
}

#===============================================================================
# supervisor_configure_core_services
# ----------------------------------
# Generate supervisord.conf with dnsmasq, nginx, fcgiwrap, rsyslog, and OpenSVC.
#
# Usage:
#   supervisor_configure_core_services
#
# Description:
#   Appends service blocks to /srv/hps-config/services/supervisord.conf.
#   Logs are written to ${HPS_LOG}.
#   The function is idempotent: each program block is only added once.
#   Service configs use cluster-specific paths for dnsmasq, nginx, rsyslog.
#
# Returns:
#   0 on success
#   1 if core configuration not found
#   2 if directory creation fails
#   3 if service block write fails
#
#===============================================================================
supervisor_configure_core_services() {
  # Get supervisor config path
  local supervisord_conf
  supervisord_conf=$(hps_get_config supervisord_conf) || {
    hps_log error "Failed to get supervisor configuration path"
    return 1
  }

  # Verify core config file exists
  if [[ ! -f "${supervisord_conf}" ]]; then
    hps_log error "Supervisor core configuration file not found: ${supervisord_conf}"
    return 1
  fi
  
  hps_log info "Adding service blocks to Supervisor config: ${supervisord_conf}"

  # Get active cluster for log directory
  local cluster
  cluster=$(hps_get_config active_cluster) || {
    hps_log error "Cannot determine active cluster"
    return 1
  }

  # Get cluster-specific directories
  local cluster_services_dir
  cluster_services_dir=$(hps_get_config cluster_services) || {
    hps_log error "Cannot determine cluster services directory"
    return 1
  }

  local cluster_log_dir="${HPS_LOG}/clusters/${cluster}"

  # Ensure required directories exist
  local config_dir
  config_dir="$(dirname "${supervisord_conf}")"

  for dir in "${config_dir}" "${HPS_LOG}" "${cluster_log_dir}"; do
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
    local stanza="$1"
    local block="$2"
    
    # Check if stanza already exists
    if ! grep -qE "^\[${stanza}\]\s*$" "${supervisord_conf}" 2>/dev/null; then
      # Attempt to append the block
      if printf '\n%s\n\n' "${block}" >> "${supervisord_conf}" 2>/dev/null; then
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
  local dnsmasq_conf="${cluster_services_dir}/dnsmasq.conf"
  local dnsmasq_log_stderr="${cluster_services_dir}/dnsmasq.err.log"
  local dnsmasq_log_stdout="${cluster_services_dir}/dnsmasq.out.log"
  
  touch "${dnsmasq_log_stderr}" "${dnsmasq_log_stdout}"
  chown nobody:nogroup "${dnsmasq_log_stderr}" "${dnsmasq_log_stdout}" 2>/dev/null || true

  _supervisor_append_once "program:dnsmasq" "$(cat <<EOF
[program:dnsmasq]
command=/usr/sbin/dnsmasq -k --conf-file=${dnsmasq_conf} --log-facility=${dnsmasq_log_stdout}
autostart=true
autorestart=true
stdout_logfile=${dnsmasq_log_stdout}
stderr_logfile=${dnsmasq_log_stderr}
environment=$(_get_hps_environment)
EOF
)" || return 3

  # --- nginx ---
  local nginx_conf="${cluster_services_dir}/nginx.conf"
  local nginx_log_stderr="${cluster_services_dir}/nginx.err.log"
  local nginx_log_stdout="${cluster_services_dir}/nginx.out.log"
  
  _supervisor_append_once "program:nginx" "$(cat <<EOF
[program:nginx]
command=/usr/sbin/nginx -g 'daemon off;' -c ${nginx_conf}
autostart=true
autorestart=true
stdout_logfile=${nginx_log_stdout}
stderr_logfile=${nginx_log_stderr}
environment=$(_get_hps_environment)
EOF
)" || return 3

  # --- fcgiwrap ---
  local fcgiwrap_log_stderr="${cluster_services_dir}/fcgiwrap.err.log"
  local fcgiwrap_log_stdout="${cluster_services_dir}/fcgiwrap.out.log"
  
  _supervisor_append_once "program:fcgiwrap" "$(cat <<EOF
[program:fcgiwrap]
command=bash -c 'rm -f /var/run/fcgiwrap.socket && exec /usr/bin/spawn-fcgi -F 4 -s /var/run/fcgiwrap.socket -U www-data -G www-data /usr/sbin/fcgiwrap'
umask=002
autostart=true
autorestart=true
stdout_logfile=${fcgiwrap_log_stdout}
stderr_logfile=${fcgiwrap_log_stderr}
environment=$(_get_hps_environment)
EOF
)" || return 3

  # --- rsyslogd ---
  local rsyslog_conf="${cluster_services_dir}/rsyslog.conf"
  local rsyslog_log_stderr="${cluster_services_dir}/rsyslog.err.log"
  local rsyslog_log_stdout="${cluster_services_dir}/rsyslog.out.log"
  
  _supervisor_append_once "program:rsyslogd" "$(cat <<EOF
[program:rsyslogd]
command=/usr/sbin/rsyslogd -n -f ${rsyslog_conf}
autostart=true
autorestart=true
stderr_logfile=${rsyslog_log_stderr}
stdout_logfile=${rsyslog_log_stdout}
stdout_events_enabled=true
stderr_events_enabled=true
environment=$(_get_hps_environment)
EOF
)" || return 3

  # --- OpenSVC agent ---
  install_opensvc_foreground_wrapper

  _supervisor_append_once "program:opensvc" "$(cat <<EOF
[program:opensvc]
command=/bin/bash -c 'source ${HPS_SYSTEM_BASE}/lib/functions.sh && _opensvc_foreground_wrapper'
autostart=true
autorestart=true
startsecs=2
startretries=3
stopsignal=TERM
user=root
directory=/
stdout_logfile=syslog
stderr_logfile=syslog
environment=$(_get_hps_environment)
EOF
)" || return 3

  # --- Event listener to run post_start ---
  _supervisor_append_once "eventlistener:post_start_config" "$(cat <<EOF
[eventlistener:post_start_config]
command=/bin/bash -c 'source ${HPS_SYSTEM_BASE}/lib/functions.sh && _supervisor_post_start'
events=PROCESS_STATE_RUNNING
buffer_size=100
autostart=true
autorestart=unexpected
stdout_logfile=syslog
stderr_logfile=syslog
environment=$(_get_hps_environment)
EOF
)" || return 3

  # Final validation
  if [[ ! -f "${supervisord_conf}" ]] || [[ ! -r "${supervisord_conf}" ]]; then
    hps_log error "Supervisor configuration file validation failed: ${supervisord_conf}"
    return 3
  fi

  hps_log info "Supervisor services config generated successfully"
  return 0
}
