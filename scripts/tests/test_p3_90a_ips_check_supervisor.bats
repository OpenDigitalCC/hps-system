#!/usr/bin/env bats
#
# IPS-01: supervisord runs hps-ips-check once after the services start. The
# generated supervisord.conf is inspected; nothing is started.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-90a.XXXXXX")"
  export TEST_DIR
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  mkdir -p "$TEST_DIR/services" "$TEST_DIR/log"
  hps_log() { :; }
  hps_get_config() {
    case "$1" in
      cluster_services) echo "$TEST_DIR/services" ;;
      active_cluster)   echo "lab" ;;
      supervisord_conf) echo "$TEST_DIR/supervisord.conf" ;;
      *) return 1 ;;
    esac
  }
  install_opensvc_foreground_wrapper() { :; }
  _get_hps_environment() { echo "HPS_X=1"; }
  export -f hps_log hps_get_config
  export HPS_LOG="$TEST_DIR/log" HPS_SYSTEM_BASE="/srv/hps-system"
  source "$ROOT/lib/functions.d/configure-supervisor.sh"
  : > "$TEST_DIR/supervisord.conf"
  supervisor_configure_core_services
}

teardown() {
  rm -rf "$TEST_DIR"
}

# the lines of one [program:...] stanza
stanza() {
  sed -n "/^\[program:$1\]/,/^\[/p" "$TEST_DIR/supervisord.conf"
}

@test "hps-ips-check is a one-shot supervisor program that waits for the services" {
  run stanza hps-ips-check
  [[ "$output" == *"command=/srv/hps-system/bin/hps-ips-check --wait 60 --no-logger"* ]]
  [[ "$output" == *"autostart=true"* ]]
  [[ "$output" == *"autorestart=false"* ]]
  [[ "$output" == *"startsecs=0"* ]]
}

@test "hps-ips-check logs through stdout to syslog like every program, with --no-logger so each line appears once" {
  run stanza hps-ips-check
  [[ "$output" == *"stdout_logfile=syslog"* ]]
  [[ "$output" == *"stderr_logfile=syslog"* ]]
  [[ "$output" == *"--no-logger"* ]]
}

@test "the program block is added once however often the services are configured" {
  supervisor_configure_core_services
  n="$(grep -c '^\[program:hps-ips-check\]' "$TEST_DIR/supervisord.conf")"
  [ "$n" -eq 1 ]
}

@test "the program starts after the services it checks" {
  run stanza hps-ips-check
  prio="$(sed -n 's/^priority=//p' <<< "$output")"
  [ "$prio" -gt 1 ]
}
