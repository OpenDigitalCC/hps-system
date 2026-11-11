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
# Generate supervisord.conf with dnsmasq, lighttpd, rsyslog, chronyd, hps-jobs,
# hps-monitor, ctrl-exec-api, OpenSVC and the one-shot hps-ips-check.
#
# Usage:
#   supervisor_configure_core_services
#
# Description:
#   Appends service blocks to /srv/hps-config/services/supervisord.conf.
#   Every program logs to syslog (stdout_logfile/stderr_logfile=syslog, tagged
#   with the program name); rsyslog files it under ${HPS_LOG}/ips/<program>/.
#   supervisord's own log stays a file: ${HPS_LOG}/supervisord.log.
#   The function is idempotent: each program block is only added once.
#   Service configs use cluster-specific paths for dnsmasq, lighttpd, rsyslog.
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

  _supervisor_append_once "program:dnsmasq" "$(cat <<EOF
[program:dnsmasq]
command=/usr/sbin/dnsmasq -k --conf-file=${dnsmasq_conf}
autostart=true
autorestart=true
stdout_logfile=syslog
stderr_logfile=syslog
environment=$(_get_hps_environment)
EOF
)" || return 3

  # --- lighttpd (static files, ranges and CGI in one process) ---
  local lighttpd_conf="${cluster_services_dir}/lighttpd.conf"

  _supervisor_append_once "program:lighttpd" "$(cat <<EOF
[program:lighttpd]
command=/usr/sbin/lighttpd -D -f ${lighttpd_conf}
autostart=true
autorestart=true
stdout_logfile=syslog
stderr_logfile=syslog
environment=$(_get_hps_environment)
EOF
)" || return 3

  # --- rsyslogd ---
  local rsyslog_conf="${cluster_services_dir}/rsyslog.conf"
  
  _supervisor_append_once "program:rsyslogd" "$(cat <<EOF
[program:rsyslogd]
command=/usr/sbin/rsyslogd -n -f ${rsyslog_conf}
priority=1
autostart=true
autorestart=true
stderr_logfile=syslog
stdout_logfile=syslog
stdout_events_enabled=true
stderr_events_enabled=true
environment=$(_get_hps_environment)
EOF
)" || return 3

  # --- chronyd (time server for the cluster network) ---
  # -d foreground; -x never adjust the system clock (the container shares the
  # host's kernel clock); -u root so the drift file in the services dir is
  # writable.
  local chrony_conf="${cluster_services_dir}/chrony.conf"

  _supervisor_append_once "program:chronyd" "$(cat <<EOF
[program:chronyd]
command=/usr/sbin/chronyd -d -x -u root -f ${chrony_conf}
autostart=true
autorestart=true
stderr_logfile=syslog
stdout_logfile=syslog
environment=$(_get_hps_environment)
EOF
)" || return 3

  # --- hps-jobs (root runner of the privileged-action queue, ADR 0006) ---
  _supervisor_append_once "program:hps-jobs" "$(cat <<EOF
[program:hps-jobs]
command=${HPS_SYSTEM_BASE}/bin/hps-jobs
autostart=true
autorestart=true
startsecs=2
stopsignal=TERM
user=root
stdout_logfile=syslog
stderr_logfile=syslog
environment=$(_get_hps_environment)
EOF
)" || return 3

  # --- hps-monitor (resource checks of the paired nodes, logged to syslog; docs/MONITORING.md) ---
  # Needs root: it lists the dispatcher's agents. Idles when monitor_interval_seconds is 0.
  _supervisor_append_once "program:hps-monitor" "$(cat <<EOF
[program:hps-monitor]
command=${HPS_SYSTEM_BASE}/bin/hps-monitor loop
autostart=true
autorestart=true
startsecs=2
stopsignal=TERM
user=root
stdout_logfile=syslog
stderr_logfile=syslog
environment=$(_get_hps_environment)
EOF
)" || return 3

  # --- ctrl-exec-api (unix socket for ctrl-exec-cli: hps-run.sh --input) ---
  # Starts as root only to create /run/ctrl-exec-api, then drops to the
  # ctrl-exec service user with its groups (hps, so the socket can be group
  # hps; see ce_api_bring_up). The socket path and group are in ctrl-exec.conf.
  _supervisor_append_once "program:ctrl-exec-api" "$(cat <<EOF
[program:ctrl-exec-api]
command=/bin/bash -c 'install -d -o ctrl-exec -g ctrl-exec -m 0755 /run/ctrl-exec-api && exec setpriv --reuid=ctrl-exec --regid=ctrl-exec --init-groups ctrl-exec-api'
autostart=true
autorestart=true
startsecs=2
startretries=10
stopsignal=TERM
user=root
stdout_logfile=syslog
stderr_logfile=syslog
environment=$(_get_hps_environment)
EOF
)" || return 3

  # --- ctrl-exec-agent (the IPS's own agent ips.<domain>: ips-admin) ---
  # Root: the ips-admin tools act on the IPS's state as root, and the image
  # has no executor to raise a profile (docs/OPERATOR.md). Reached only from
  # 127.0.0.1 (allowed_ips). A renewed certificate the agent staged is
  # promoted first, as the node OpenRC service does.
  _supervisor_append_once "program:ctrl-exec-agent" "$(cat <<EOF
[program:ctrl-exec-agent]
command=/bin/bash -c 'ctrl-exec-agent promote-cert > /dev/null 2>&1 || true; exec ctrl-exec-agent serve'
autostart=true
autorestart=true
startsecs=2
startretries=3
stopsignal=TERM
user=root
stdout_logfile=syslog
stderr_logfile=syslog
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

  # --- hps-ips-check (one-shot self-check after the services start) ---
  # autorestart=false: it runs once per supervisord start and exits (0 all
  # pass, 1 a FAIL; supervisord logs a FAIL exit as unexpected). --wait lets the
  # HTTP port and the ctrl-exec API socket come up first. startsecs=0: a
  # program that exits at once is not a failed start. Result: syslog lines
  # tagged hps-ips-check (its stdout, like every program's; --no-logger stops
  # the tool logging each line a second time) and
  # <cluster>/services/ips-check.json.
  _supervisor_append_once "program:hps-ips-check" "$(cat <<EOF
[program:hps-ips-check]
command=${HPS_SYSTEM_BASE}/bin/hps-ips-check --wait 60 --no-logger
priority=900
autostart=true
autorestart=false
startsecs=0
startretries=0
user=root
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
