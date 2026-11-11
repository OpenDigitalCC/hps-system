# shellcheck shell=bash

# _rsyslog_forward_valid <ipv4> <prefix>: a forward target and host prefix
# (ips_syslog_forward, the generator below): an IPv4 address that is not
# loopback, and 1-32 of a-z 0-9 - starting with a letter or digit.
_rsyslog_forward_valid() {
  local ip="$1" prefix="$2" o
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do
    ((10#$o <= 255)) || return 1
  done
  case "$ip" in
    127.* | 0.0.0.0 | 255.255.255.255) return 1 ;;
  esac
  [[ "$prefix" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]
}

# _rsyslog_forward_block: the optional forward of everything to a collector,
# from the cluster keys syslog_forward_host and syslog_forward_prefix (set by
# the operator action ips-syslog-forward; docs/OPERATOR.md). Prints nothing
# when they are unset; logs and prints nothing when they are not valid. Host
# names go upstream as <prefix>.<hostname>, so one collector can hold several
# clusters (the format lab/syslog-lab.pl --upstream used).
_rsyslog_forward_block() {
  local cluster ip prefix
  cluster=$(hps_get_config active_cluster 2> /dev/null) || return 0
  [[ -n "$cluster" ]] || return 0
  ip=$(cluster_registry "$cluster" get syslog_forward_host 2> /dev/null) || ip=""
  prefix=$(cluster_registry "$cluster" get syslog_forward_prefix 2> /dev/null) || prefix=""
  ip="${ip//\"/}"
  prefix="${prefix//\"/}"
  [[ -n "$ip" ]] || return 0
  if ! _rsyslog_forward_valid "$ip" "$prefix"; then
    hps_log warn "create_config_rsyslog: syslog_forward_host '${ip}' / syslog_forward_prefix '${prefix}' not valid; not forwarding"
    return 0
  fi
  printf '## # Forward everything to a collector (operator action ips-syslog-forward)\n'
  printf 'template(name="HPSForward" type="string" string="<%%PRI%%>%%TIMESTAMP:::date-rfc3339%% %s.%%HOSTNAME%% %%syslogtag:1:32%%%%msg:::sp-if-no-1st-sp%%%%msg%%\\n")\n' "$prefix"
  printf '*.* action(type="omfwd" target="%s" port="514" protocol="tcp" template="HPSForward" action.resumeRetryCount="-1" queue.type="LinkedList" queue.size="10000")\n' "$ip"
}

create_config_rsyslog () {

local RSYSLOG_CONF
RSYSLOG_CONF="$(get_path_cluster_services_dir)/rsyslog.conf"

local RSYSLOG_LOG_DIR
RSYSLOG_LOG_DIR=$(hps_get_config log) || {
  hps_log error "Cannot determine log directory"
  return 1
}


mkdir -p ${RSYSLOG_LOG_DIR}

hps_log info "Configuring rsyslog"

# Before the routing rules, which stop each message.
local FORWARD_BLOCK
FORWARD_BLOCK=$(_rsyslog_forward_block)
if [[ -n "$FORWARD_BLOCK" ]]; then
  hps_log info "rsyslog: forwarding everything ($(printf '%s' "$FORWARD_BLOCK" | grep -o 'target="[^"]*"'))"
fi

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
module(load="imuxsock" SysSock.Name="/dev/log") # Local system logging (services, hps_log)
# imklog is not loaded: a container has no kernel log of its own

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

# One file per IPS service: ips/<programname>/<date>.log
template(name="IPSServiceLogFile" type="string"
  string="${RSYSLOG_LOG_DIR}/ips/%programname%/%\$YEAR%-%\$MONTH%-%\$DAY%.log"
)

${FORWARD_BLOCK}


## # Log message routing

# Route local IPS service logs to one file per program. The program names are a
# fixed list (they become directory names); only local senders match, so a
# node cannot write into the service tree.
if (\$fromhost-ip == "127.0.0.1") and (\$programname == ["dnsmasq", "dnsmasq-dhcp", "dnsmasq-tftp", "lighttpd", "chronyd", "supervisord", "hps", "hps-jobs", "hps-monitor", "ctrl-exec-api", "ctrl-exec-agent", "ips-admin"]) then {
  *.* action(type="omfile" dynaFile="IPSServiceLogFile" template="HPSLogFormat")
  stop
}

# Route all other local logs to ips/<date>.log with the same format
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


