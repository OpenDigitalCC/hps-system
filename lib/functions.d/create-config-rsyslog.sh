__guard_source || return



create_config_rsyslog () {

local RSYSLOG_CONF="$(get_path_cluster_services_dir)/rsyslog.conf"

RSYSLOG_LOG_DIR="${HPS_LOG_DIR}/rsyslog"

mkdir -p ${RSYSLOG_LOG_DIR}

hps_log info "Configuring rsyslog" 

cat > "${RSYSLOG_CONF}" <<EOF

#===============================================================================
# rsyslog.conf - Basic configuration for HPS centralized logging
#===============================================================================

# Global directives
global(
  workDirectory="${RSYSLOG_LOG_DIR}"
)

# Load required modules
module(load="imudp")    # UDP syslog reception
module(load="imtcp")    # TCP syslog reception
module(load="imuxsock") # Local system logging
module(load="imklog")   # Kernel logging support

# Provide UDP syslog reception
input(type="imudp" port="514")

# Provide TCP syslog reception
input(type="imtcp" port="514")

# Templates for remote host logging
# Separate logs by hostname and date

template(name="RemoteHostFile" type="string"
  string="/srv/hps-system/log/rsyslog/%fromhost-ip%/%\$YEAR%-%\$MONTH%-%\$DAY%.log"
)

# Template for log format - include both IP and hostname
template(name="RemoteHostFormat" type="string"
  string="%TIMESTAMP% %fromhost-ip% [%HOSTNAME%] %syslogtag% %msg%\n"
)


# Rules for remote hosts (not localhost)
#if \$fromhost-ip != "127.0.0.1" then {
  action(type="omfile" 
    dynaFile="RemoteHostFile"
    template="RemoteHostFormat"
    dirCreateMode="0755"
    fileCreateMode="0644"
#  )
#  stop
#}


# Local system logs
*.info;mail.none;authpriv.none;cron.none   ${RSYSLOG_LOG_DIR}/local/messages
authpriv.*                                 ${RSYSLOG_LOG_DIR}/local/secure
mail.*                                     ${RSYSLOG_LOG_DIR}/local/maillog
cron.*                                     ${RSYSLOG_LOG_DIR}/local/cron
*.emerg                                    :omusrmsg:*
local7.*                                   ${RSYSLOG_LOG_DIR}/local/boot.log

# HPS-specific logs
local0.*                                   ${RSYSLOG_LOG_DIR}/local/hps-system.log
local1.*                                   ${RSYSLOG_LOG_DIR}/local/hps-nodes.log

# Log rotation handled externally by logrotate


EOF
  hps_log info "[OK] rsyslog config generated at: ${RSYSLOG_CONF}"
  
}


