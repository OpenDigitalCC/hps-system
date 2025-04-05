

__guard_source || return
# Define your functions below

configure_supervisor_core () {

SUPERVISORD_CONF="${HPS_SERVICE_CONFIG_DIR}/supervisord.conf"

# Optionally generate supervisor conf dynamically
mkdir -p /var/log/supervisor

echo "[*] Creating Supervisor core config ${SUPERVISORD_CONF}"

cat > "${SUPERVISORD_CONF}" <<EOF

[unix_http_server]
file=/var/run/supervisor.sock
chmod=0700

[supervisorctl]
serverurl=unix:///var/run/supervisor.sock

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisord]
nodaemon=true
logfile=/var/log/supervisord.log
pidfile=/var/run/supervisord.pid
childlogdir=/var/log/supervisor
loglevel=info
identifier=supervisor
minfds=1024
minprocs=200
user=root
strip_ansi=false

EOF

echo "[OK] Supervisor core config generated at: ${SUPERVISORD_CONF}"
}


configure_supervisor_services () {

SUPERVISORD_CONF="${HPS_SERVICE_CONFIG_DIR}/supervisord.conf"


echo "[*] Creating Supervisor services config ${SUPERVISORD_CONF}"

configure_supervisor_core

cat >> "${SUPERVISORD_CONF}" <<EOF

[program:dnsmasq]
command=/usr/sbin/dnsmasq -k --conf-file=${HPS_SERVICE_CONFIG_DIR}/dnsmasq.conf
autostart=true
autorestart=true
stderr_logfile=/var/log/dnsmasq.err.log
stdout_logfile=/var/log/dnsmasq.out.log

[program:nginx]
command=/usr/sbin/nginx -g 'daemon off;' -c "${HPS_SERVICE_CONFIG_DIR}/nginx.conf"
autostart=true
autorestart=true
stderr_logfile=/var/log/nginx.err.log
stdout_logfile=/var/log/nginx.out.log

[program:fcgiwrap]
command=bash -c 'rm -f /var/run/fcgiwrap.socket && exec /usr/bin/spawn-fcgi -n -s /var/run/fcgiwrap.socket -U www-data -G www-data /usr/sbin/fcgiwrap'
autostart=true
autorestart=true
stdout_logfile=/var/log/fcgiwrap.out.log
stderr_logfile=/var/log/fcgiwrap.err.log


EOF

echo "[OK] Supervisor services config generated at: ${SUPERVISORD_CONF}"
}


reload_supervisor_config () {
  SUPERVISORD_CONF="${HPS_SERVICE_CONFIG_DIR}/supervisord.conf"
  supervisorctl -c "$SUPERVISORD_CONF" reread
  supervisorctl -c "$SUPERVISORD_CONF" update
}



