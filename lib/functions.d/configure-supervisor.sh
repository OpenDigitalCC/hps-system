__guard_source || return


#:name: configure_supervisor_core
#:group: supervisor
#:synopsis: Write the base supervisord.conf using ${HPS_LOG_DIR} for all logs.
#:usage: configure_supervisor_core
#:description:
#  Generates ${HPS_SERVICE_CONFIG_DIR}/supervisord.conf core sections and sets:
#    - logfile=${HPS_LOG_DIR}/supervisord.log
#    - childlogdir=${HPS_LOG_DIR}/supervisor
#  Ensures ${HPS_LOG_DIR} and ${HPS_LOG_DIR}/supervisor exist.
configure_supervisor_core () {
  local SUPERVISORD_CONF="${HPS_SERVICE_CONFIG_DIR}/supervisord.conf"

  # Ensure base log dirs exist
  mkdir -p "${HPS_LOG_DIR}" "${HPS_LOG_DIR}/supervisor"

  hps_log info "Creating Supervisor core config ${SUPERVISORD_CONF}"

  cat > "${SUPERVISORD_CONF}" <<EOF
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
childlogdir=${HPS_LOG_DIR}/supervisor
loglevel=info
identifier=supervisor
minfds=1024
minprocs=200
user=root
strip_ansi=false

EOF

  hps_log info "[OK] Supervisor core config generated at: ${SUPERVISORD_CONF}"
  echo "${SUPERVISORD_CONF}"
}



#:name: configure_supervisor_services
#:group: supervisor
#:synopsis: Generate supervisord.conf with dnsmasq, nginx, fcgiwrap, and OpenSVC agent.
#:usage: configure_supervisor_services
#:description:
#  Writes ${HPS_SERVICE_CONFIG_DIR}/supervisord.conf with dnsmasq, nginx,
#  fcgiwrap, and OpenSVC agent programs. Logs are written to ${HPS_LOG_DIR}.
#  The function is idempotent: each program block is only added once.
configure_supervisor_services () {
  # Ensure the core header and defaults exist
  local SUPERVISORD_CONF="$(configure_supervisor_core)"
#  local SUPERVISORD_CONF="${HPS_SERVICE_CONFIG_DIR}/supervisord.conf"

  # -- helper: append a block once, keyed by program stanza name
  _supervisor_append_once() {
    local stanza="$1"    # e.g. program:nginx
    local block="$2"
    if ! grep -qE "^\[${stanza}\]\s*$" "${SUPERVISORD_CONF}" 2>/dev/null; then
      printf '\n%s\n\n' "${block}" >> "${SUPERVISORD_CONF}"
    fi
  }

  hps_log info "[*] Creating Supervisor services config ${SUPERVISORD_CONF}"
  mkdir -p "$(dirname "${SUPERVISORD_CONF}")" "${HPS_LOG_DIR}"

  # --- dnsmasq ---
  _supervisor_append_once "program:dnsmasq" "$(cat <<EOF
[program:dnsmasq]
command=/usr/sbin/dnsmasq -k --conf-file=${HPS_SERVICE_CONFIG_DIR}/dnsmasq.conf
autostart=true
autorestart=true
stderr_logfile=${HPS_LOG_DIR}/dnsmasq.err.log
stdout_logfile=${HPS_LOG_DIR}/dnsmasq.out.log
EOF
)"

  # --- nginx ---
  _supervisor_append_once "program:nginx" "$(cat <<EOF
[program:nginx]
command=/usr/sbin/nginx -g 'daemon off;' -c "${HPS_SERVICE_CONFIG_DIR}/nginx.conf"
autostart=true
autorestart=true
stderr_logfile=${HPS_LOG_DIR}/nginx.err.log
stdout_logfile=${HPS_LOG_DIR}/nginx.out.log
EOF
)"

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
)"


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
)"


  hps_log info "Supervisor services config generated at: ${SUPERVISORD_CONF}"
}


create_supervisor_services_config () {
  create_config_nginx
  create_config_dnsmasq
  create_config_opensvc IPS # specify that this is an IPS node

}


reload_supervisor_config () {
  SUPERVISORD_CONF="${HPS_SERVICE_CONFIG_DIR}/supervisord.conf"
  hps_log info "Reread: $(supervisorctl -c "$SUPERVISORD_CONF" reread)"
  hps_log info "Update: $(supervisorctl -c "$SUPERVISORD_CONF" update)"
}



