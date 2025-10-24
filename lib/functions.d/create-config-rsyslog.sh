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

# Set default file permissions (a+r)
\$FileCreateMode 0644
\$DirCreateMode 0755

# Load required modules
module(load="imudp")    # UDP syslog reception
module(load="imtcp")    # TCP syslog reception
module(load="imuxsock") # Local system logging
module(load="imklog")   # Kernel logging support

# Provide UDP syslog reception
input(type="imudp" port="514")

# Provide TCP syslog reception
input(type="imtcp" port="514")


## # Template for log format

# Template for all log formatting - include both IP and hostname
template(name="HPSLogFormat" type="string"
  string="%TIMESTAMP% %fromhost-ip% [%HOSTNAME%] %syslogtag% %msg%\n"
)


## # Templates for file formats

# Template for local IPS logs
template(name="IPSLogFile" type="string"
  string="${RSYSLOG_LOG_DIR}/ips/%\$YEAR%-%\$MONTH%-%\$DAY%.log"
)

# Template for remote host logs
template(name="RemoteLogFile" type="string"
  string="${RSYSLOG_LOG_DIR}/%fromhost-ip%/%\$YEAR%-%\$MONTH%-%\$DAY%.log"
)

# Log by program name
template(name="IPSServiceLogFile" type="string"
  string="${RSYSLOG_LOG_DIR}/ips/%programname%-%\$YEAR%-%\$MONTH%-%\$DAY%.log"
)


## # Log message routing

# Route marked program logs to separate file
if \$programname == "nginx" then {
  *.* action(type="omfile" dynaFile="IPSServiceLogFile" template="HPSLogFormat")
  stop
}

# Route all local logs to ips/* with the same format
if \$fromhost-ip == "127.0.0.1" then {
  *.* action(type="omfile" dynaFile="IPSLogFile" template="HPSLogFormat")
  stop
}

# Route all remote logs to from-ip/* with the same format
if \$fromhost-ip != "127.0.0.1" then {
  *.* action(type="omfile" dynaFile="RemoteLogFile" template="HPSLogFormat")
  stop
}

EOF
  hps_log info "[OK] rsyslog config generated at: ${RSYSLOG_CONF}"

}


