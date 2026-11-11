#!/usr/bin/env bats
#
# The optional syslog forward (operator action ips-syslog-forward): kept in
# the cluster keys syslog_forward_host / syslog_forward_prefix, written into
# the generated rsyslog.conf before the routing rules, rsyslogd restarted.
# The registry is a directory of files; supervisorctl is a shim.

bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-194.XXXXXX")"
  export TEST_DIR
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  mkdir -p "$TEST_DIR/services" "$TEST_DIR/log" "$TEST_DIR/reg" "$TEST_DIR/bin"
  hps_log() { echo "$*" >> "$TEST_DIR/hps.log"; }
  hps_get_config() {
    case "$1" in
      active_cluster) echo lab ;;
      log) echo "$TEST_DIR/log" ;;
      supervisord_conf) echo "$TEST_DIR/supervisord.conf" ;;
      *) return 1 ;;
    esac
  }
  cluster_registry() {
    case "$2" in
      get) [[ -f "$TEST_DIR/reg/$3" ]] && printf '"%s"\n' "$(cat "$TEST_DIR/reg/$3")" ;;
      set) printf '%s' "$4" > "$TEST_DIR/reg/$3" ;;
      delete) rm -f "$TEST_DIR/reg/$3" ;;
    esac
    return 0
  }
  get_path_cluster_services_dir() { echo "$TEST_DIR/services"; }
  export -f hps_log hps_get_config cluster_registry get_path_cluster_services_dir
  cat > "$TEST_DIR/bin/supervisorctl" <<'EOT'
#!/bin/bash
echo "supervisorctl $*" >> "$TEST_DIR/calls"
EOT
  chmod +x "$TEST_DIR/bin/supervisorctl"
  export PATH="$TEST_DIR/bin:$PATH"
  source "$ROOT/lib/functions.d/create-config-rsyslog.sh"
  source "$ROOT/lib/functions.d/ips-admin-functions.sh"
  CONF="$TEST_DIR/services/rsyslog.conf"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "by default nothing is forwarded" {
  run create_config_rsyslog
  [ "$status" -eq 0 ]
  run ! grep -q 'omfwd' "$CONF"
}

@test "with the keys set, everything goes to the collector over TCP 514 as <prefix>.<host>, before the routing rules" {
  printf '192.0.2.10' > "$TEST_DIR/reg/syslog_forward_host"
  printf 's1' > "$TEST_DIR/reg/syslog_forward_prefix"
  run create_config_rsyslog
  [ "$status" -eq 0 ]
  grep -qF '*.* action(type="omfwd" target="192.0.2.10" port="514" protocol="tcp" template="HPSForward"' "$CONF"
  grep -qF 'string="<%PRI%>%TIMESTAMP:::date-rfc3339% s1.%HOSTNAME% %syslogtag:1:32%%msg:::sp-if-no-1st-sp%%msg%\n"' "$CONF"
  f=$(grep -n 'omfwd' "$CONF" | cut -d: -f1)
  r=$(grep -n '^## # Log message routing' "$CONF" | cut -d: -f1)
  [ "$f" -lt "$r" ]
}

@test "invalid stored values are not written, and are logged" {
  printf '127.0.0.1' > "$TEST_DIR/reg/syslog_forward_host"
  printf 's1' > "$TEST_DIR/reg/syslog_forward_prefix"
  create_config_rsyslog
  run ! grep -q 'omfwd' "$CONF"
  printf '192.0.2.10' > "$TEST_DIR/reg/syslog_forward_host"
  printf 'S1;x' > "$TEST_DIR/reg/syslog_forward_prefix"
  create_config_rsyslog
  run ! grep -q 'omfwd' "$CONF"
  grep -q 'not valid; not forwarding' "$TEST_DIR/hps.log"
}

@test "ips_syslog_forward <ip> <prefix> stores the keys, regenerates rsyslog.conf and restarts rsyslogd" {
  run ips_syslog_forward 192.0.2.10 s1
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_DIR/reg/syslog_forward_host")" = 192.0.2.10 ]
  [ "$(cat "$TEST_DIR/reg/syslog_forward_prefix")" = s1 ]
  grep -q 'target="192.0.2.10"' "$CONF"
  grep -qx "supervisorctl -c $TEST_DIR/supervisord.conf restart rsyslogd" "$TEST_DIR/calls"
  [[ "$output" == *"syslog forward: 192.0.2.10 (tcp 514) as s1.<host>"* ]]
}

@test "ips_syslog_forward refuses a bad address, loopback or prefix, and changes nothing" {
  for a in "300.1.1.1 s1" "127.0.0.1 s1" "192.0.2.10 S1" "192.0.2.10 -x" "192.0.2.10" "192.0.2.10 s1 extra"; do
    # shellcheck disable=SC2086
    run ips_syslog_forward $a
    [ "$status" -eq 2 ] || { echo "accepted: $a"; false; }
  done
  [ ! -e "$TEST_DIR/reg/syslog_forward_host" ]
  [ ! -e "$TEST_DIR/calls" ]
}

@test "ips_syslog_forward off removes the keys and the forward" {
  ips_syslog_forward 192.0.2.10 s1
  run ips_syslog_forward off
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_DIR/reg/syslog_forward_host" ]
  [ ! -e "$TEST_DIR/reg/syslog_forward_prefix" ]
  run ! grep -q 'omfwd' "$CONF"
  run ips_syslog_forward show
  [ "$output" = "syslog forward: off" ]
}

@test "bin/hps-syslog-forward without arguments is a usage error" {
  run "$ROOT/bin/hps-syslog-forward"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: hps-syslog-forward <ipv4> <prefix> | off | show"* ]]
}
