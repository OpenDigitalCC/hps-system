#!/usr/bin/env bats
#
# CS-1.11: all IPS service logging through syslog. Generated rsyslog, dnsmasq,
# nginx and supervisord configs are inspected; nothing is started.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-110.XXXXXX")"
  export TEST_DIR
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  mkdir -p "$TEST_DIR/services" "$TEST_DIR/sys" "$TEST_DIR/res" "$TEST_DIR/config/tftp" "$TEST_DIR/log"

  hps_log() { :; }
  hps_get_config() {
    case "$1" in
      cluster_services) echo "$TEST_DIR/services" ;;
      active_cluster)   echo "lab" ;;
      system_base)      echo "$TEST_DIR/sys" ;;
      resources)        echo "$TEST_DIR/res" ;;
      tftp)             echo "$TEST_DIR/config/tftp" ;;
      log)              echo "$TEST_DIR/log" ;;
      supervisord_conf) echo "$TEST_DIR/supervisord.conf" ;;
      *) return 1 ;;
    esac
  }
  cluster_registry() {
    case "$3" in
      network_dhcp_ip)        echo "192.0.2.1" ;;
      network_dhcp_iface)     echo "ens9" ;;
      network_cidr)           echo "192.0.2.0/24" ;;
      network_dhcp_rangesize) echo "20" ;;
      network_dns_domain)     echo "lab.test" ;;
    esac
  }
  generate_dhcp_range_simple() { echo "192.0.2.100,192.0.2.119,12h"; }
  get_path_cluster_services_dir() { echo "$TEST_DIR/services"; }
  install_opensvc_foreground_wrapper() { :; }
  _get_hps_environment() { echo "HPS_X=1"; }
  export -f hps_log hps_get_config cluster_registry generate_dhcp_range_simple
  export HPS_LOG="$TEST_DIR/log"

  source "$ROOT/lib/functions.d/create-config-rsyslog.sh"
  source "$ROOT/lib/functions.d/create-config-dnsmasq.sh"
  source "$ROOT/lib/functions.d/create-config-nginx.sh"
  source "$ROOT/lib/functions.d/configure-supervisor.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "rsyslog takes local messages on /dev/log and does not load imklog" {
  run create_config_rsyslog
  [ "$status" -eq 0 ]
  conf="$TEST_DIR/services/rsyslog.conf"
  grep -q '^module(load="imuxsock" SysSock.Name="/dev/log")' "$conf"
  run grep -E '^[^#]*imklog' "$conf"
  [ "$status" -eq 1 ]
}

@test "rsyslog files each IPS service under ips/<programname>/<date>.log" {
  run create_config_rsyslog
  [ "$status" -eq 0 ]
  conf="$TEST_DIR/services/rsyslog.conf"
  grep -qF "string=\"$TEST_DIR/log/ips/%programname%/%\$YEAR%-%\$MONTH%-%\$DAY%.log\"" "$conf"
  rule="$(grep -E 'programname == \[' "$conf")"
  for p in dnsmasq dnsmasq-dhcp dnsmasq-tftp nginx fcgiwrap chronyd supervisord hps; do
    [[ "$rule" == *"\"$p\""* ]]
  done
  [[ "$rule" == *'$fromhost-ip == "127.0.0.1"'* ]]
}

@test "rsyslog keeps the HPSLogFormat template, the default IPS file and the remote path" {
  run create_config_rsyslog
  [ "$status" -eq 0 ]
  conf="$TEST_DIR/services/rsyslog.conf"
  grep -qF 'string="%TIMESTAMP% %fromhost-ip% [%HOSTNAME%] %syslogtag% %msg%\n"' "$conf"
  grep -qF "string=\"$TEST_DIR/log/ips/%\$YEAR%-%\$MONTH%-%\$DAY%.log\"" "$conf"
  grep -qF "string=\"$TEST_DIR/log/%fromhost-ip%/%\$YEAR%-%\$MONTH%-%\$DAY%.log\"" "$conf"
  grep -q 'if \$fromhost-ip != "127.0.0.1" then {' "$conf"
  grep -q 'dynaFile="RemoteLogFile" template="HPSLogFormat"' "$conf"
}

@test "dnsmasq logs to syslog with no log file, DHCP logging kept" {
  run create_config_dnsmasq
  [ "$status" -eq 0 ]
  conf="$TEST_DIR/services/dnsmasq.conf"
  grep -qx 'log-facility=DAEMON' "$conf"
  grep -qx 'log-dhcp' "$conf"
  grep -qx 'log-queries' "$conf"
  run grep -E '^log-facility=.*/' "$conf"
  [ "$status" -eq 1 ]
}

@test "nginx logs to syslog only: access and error, no file or stdio paths" {
  run create_config_nginx
  [ "$status" -eq 0 ]
  conf="$TEST_DIR/services/nginx.conf"
  grep -qF 'error_log syslog:server=unix:/dev/log,nohostname,tag=nginx warn;' "$conf"
  grep -qF 'access_log syslog:server=unix:/dev/log,nohostname,facility=local7,tag=nginx,severity=info combined;' "$conf"
  run grep -E '^\s*(access|error)_log / ' "$conf"
  [ "$status" -eq 1 ]
  run grep -E '\.log' "$conf"
  [ "$status" -eq 1 ]
}

@test "every supervisor program logs to syslog and dnsmasq has no --log-facility" {
  : > "$TEST_DIR/supervisord.conf"
  run supervisor_configure_core_services
  [ "$status" -eq 0 ]
  conf="$TEST_DIR/supervisord.conf"
  for p in dnsmasq nginx fcgiwrap rsyslogd chronyd opensvc; do
    grep -q "^\[program:$p\]" "$conf"
  done
  run grep -cE '^std(out|err)_logfile=' "$conf"
  total="$output"
  run grep -cE '^std(out|err)_logfile=syslog$' "$conf"
  [ "$output" -eq "$total" ]
  [ "$total" -ge 14 ]
  grep -qx "command=/usr/sbin/dnsmasq -k --conf-file=$TEST_DIR/services/dnsmasq.conf" "$conf"
  run grep -F -e '--log-facility' "$conf"
  [ "$status" -eq 1 ]
}

@test "supervisord's own log stays a file under the log directory" {
  run supervisor_configure_core_config
  [ "$status" -eq 0 ]
  grep -qx "logfile=$TEST_DIR/log/supervisord.log" "$TEST_DIR/supervisord.conf"
}

@test "no per-service out/err log file path remains in lib, scripts or http" {
  run grep -rIE '\.(out|err)\.log' "$ROOT/lib" "$ROOT/scripts" "$ROOT/http"
  [ "$status" -eq 1 ]
}
