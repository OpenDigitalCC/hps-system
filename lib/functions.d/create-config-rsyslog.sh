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

# _rsyslog_own_condition: the rsyslog condition for "this line belongs to this cluster",
# which gates audit.log, metrics.log and events.log (docs/LOGGING.md "Whose lines"). A
# line is this cluster's when it comes from this IPS itself (the loopback sender) or from
# a host named as this cluster names its hosts: a single label, or <label>.<the cluster's
# network_dns_domain> (docs/NAMING.md). A line forwarded here by the IPS of another cluster
# (the lab's arrangement, ips-syslog-forward) carries <prefix>.<hostname> as its host name
# (_rsyslog_forward_block), so it matches neither form. The sender address cannot tell
# them apart: a nested cluster's IPS sits on the same network as the hosts. Lines that do
# not match still go to the day files, which hold everything received.
_rsyslog_own_condition() {
  local cluster domain="" re
  cluster=$(hps_get_config active_cluster 2> /dev/null) || cluster=""
  if [[ -n "$cluster" ]]; then
    domain=$(cluster_registry "$cluster" get network_dns_domain 2> /dev/null) || domain=""
  fi
  domain="${domain//\"/}"
  domain="${domain,,}"
  [[ "$domain" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || domain=""
  re='^[a-z0-9_-]+'
  if [[ -n "$domain" ]]; then
    re+="(\\\\.${domain//./\\\\.})?"
  fi
  # rsyslog refuses a bare $ inside a double-quoted string: the end anchor is written \$
  re+='\$'
  printf '($fromhost-ip == "127.0.0.1" or re_match($hostname, "%s"))' "$re"
}

# The programs whose lines are the audit trail (docs/LOGGING.md): every
# ctrl-exec call and every operator call. They go to audit.log, from any
# sender, and are not filed in the per-host or per-service day files.
RSYSLOG_AUDIT_PROGRAMS=(ctrl-exec-api ctrl-exec-agent ctrl-exec-dispatcher hps-auth-hook ips-admin)

# Lines that cannot carry a marker yet (docs/LOGGING.md "Derived lines"):
# "<name>|<rsyslog condition>|<priority>|<kind>|<state>". rsyslog writes each
# match to events.log as an event line of that priority, kind and state, subject
# "-" and the original text after it. The first match wins. A tool that grows
# its own marker leaves this table: its line then carries HPS-EVENT already and
# is never derived.
RSYSLOG_DERIVED_EVENTS=(
  'ipxe-init|$msg contains "iPXE Initialisation requested"|info|boot|requested'
  'boot|$msg contains "NixOS network boot:" or $msg contains "held: booting audit image"|info|boot|started'
  'init|$msg contains "host_init_result stored"|info|boot|done'
  'up|$msg contains "Reached target Multi-User System"|info|node|up'
  'off|$msg contains "reboot: Power down" or $msg contains "Reached target System Power Off"|info|node|off'
  'down|$msg contains "Stopping HPS: stop guests"|info|node|down'
  'held|$msg contains " is HELD " or ($programname startswith "console-" and $msg contains "held for onboarding")|notice|pairing|held'
  'bmc|$msg contains "hps-bmc: action=" and not ($msg contains "action=status")|notice|power|done'
  'node-fault|$msg contains "hps-node:" and $msg contains "FAULT"|warning|node|error'
  'node|$msg contains "hps-node:"|notice|node|done'
  'storage|$msg contains "hps-storage:" and $msg contains " exit "|notice|storage|done'
  'ips-check|$programname == "hps-ips-check" and ($msg contains "FAIL " or $msg contains "summary:")|warning|service|failed'
  'error|$syslogseverity <= 3 and not ($msg contains "hps-monitor: ") and ($programname startswith "hps" or $programname startswith "ctrl-exec" or $programname == ["om", "dnsmasq", "dnsmasq-dhcp", "dnsmasq-tftp", "lighttpd", "chronyd", "supervisord", "rsyslogd"])|warning|log|error'
  'error-other|$syslogseverity <= 3 and not ($msg contains "hps-monitor: ")|info|log|error'
)

# _rsyslog_log_views_block <log dir>: the three views beside the day tree:
#   audit.log    the audit programs (routing, in the block below, stops them)
#   metrics.log  hps-monitor's per-check and tick lines, "<rfc3339> metric <host> <tag> <msg>"
#   events.log   a marker line (HPS-EVENT / HPS-ALERT) of a local program, or else
#                the first matching derived line
# Written before the routing rules, which stop each message.
_rsyslog_log_views_block() {
  local dir="$1" row name cond pri kind state progs="" p own
  own=$(_rsyslog_own_condition)
  for p in "${RSYSLOG_AUDIT_PROGRAMS[@]}"; do
    progs+="${progs:+, }\"$p\""
  done
  printf '## # Whose lines: the three views take this cluster'"'"'s lines only (this IPS and its hosts).\n'
  printf '## # A line forwarded from another cluster falls through to the day files below.\n'
  printf '## # Audit: the ctrl-exec and operator-call records, in audit.log only\n'
  printf 'template(name="HPSAuditFormat" type="string" string="%%timegenerated:::date-rfc3339%% %%fromhost-ip%% [%%HOSTNAME%%] %%syslogtag%% %%msg%%\\n")\n'
  printf 'if (%s) then {\n' "$own"
  printf 'if ($programname == [%s]) then {\n' "$progs"
  printf '  action(type="omfile" file="%s/audit.log" template="HPSAuditFormat")\n' "$dir"
  printf '  stop\n}\n}\n\n'
  printf '## # Metrics: hps-monitor results, in the form hps-metrics reads\n'
  printf 'template(name="HPSMetricFormat" type="string" string="%%timegenerated:::date-rfc3339%% metric %%hostname%% %%syslogtag%%%%msg:::sp-if-no-1st-sp%%%%msg%%\\n")\n'
  printf 'if (%s) then {\n' "$own"
  printf 'if ($msg contains "hps-monitor: host=" or $msg contains "hps-monitor: tick ") then {\n'
  printf '  action(type="omfile" file="%s/metrics.log" template="HPSMetricFormat")\n}\n}\n\n' "$dir"
  printf '## # Events: marker lines of the IPS'"'"'s own programs, and the derived lines\n'
  printf 'template(name="HPSEventFormat" type="string" string="%%timegenerated:::date-rfc3339%% %%hostname%%%%msg:::sp-if-no-1st-sp%%%%msg%%\\n")\n'
  for row in "${RSYSLOG_DERIVED_EVENTS[@]}"; do
    IFS='|' read -r name cond pri kind state <<< "$row"
    local marker=HPS-EVENT
    [[ "$pri" == warning || "$pri" == urgent ]] && marker=HPS-ALERT
    printf 'template(name="HPSDerived_%s" type="string" string="%%timegenerated:::date-rfc3339%% %%hostname%% %s pri=%s kind=%s subject=- state=%s %%syslogtag%%%%msg:::sp-if-no-1st-sp%%%%msg%%\\n")\n' \
      "${name//-/_}" "$marker" "$pri" "$kind" "$state"
  done
  printf 'if (%s) then {\n' "$own"
  printf 'if ($fromhost-ip == "127.0.0.1" and ($msg contains "HPS-EVENT pri=" or $msg contains "HPS-ALERT pri=")) then {\n'
  printf '  action(type="omfile" file="%s/events.log" template="HPSEventFormat")\n}' "$dir"
  for row in "${RSYSLOG_DERIVED_EVENTS[@]}"; do
    IFS='|' read -r name cond pri kind state <<< "$row"
    printf ' else if (%s) then {\n  action(type="omfile" file="%s/events.log" template="HPSDerived_%s")\n}' "$cond" "$dir" "${name//-/_}"
  done
  printf '\n}\n'
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
local VIEWS_BLOCK
VIEWS_BLOCK=$(_rsyslog_log_views_block "${RSYSLOG_LOG_DIR}")
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

${VIEWS_BLOCK}


## # Log message routing

# Route local IPS service logs to one file per program. The program names are a
# fixed list (they become directory names); only local senders match, so a
# node cannot write into the service tree.
if (\$fromhost-ip == "127.0.0.1") and (\$programname == ["dnsmasq", "dnsmasq-dhcp", "dnsmasq-tftp", "lighttpd", "chronyd", "supervisord", "hps", "hps-jobs", "hps-monitor", "hps-issue-watch", "hps-log-rotate"]) then {
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


