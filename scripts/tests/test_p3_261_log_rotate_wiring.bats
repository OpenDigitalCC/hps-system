#!/usr/bin/env bats
#
# Wiring of hps-log-rotate (docs/LOGGING.md "Rotation"): the supervisor
# program, the retention keys in every catalogue, the file modes and the CLI's
# smoke paths. The rotation logic itself is t/253-log-rotate.t.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-261.XXXXXX")"
  export TEST_DIR
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  mkdir -p "$TEST_DIR/services" "$TEST_DIR/sys" "$TEST_DIR/res" "$TEST_DIR/log"
  hps_log() { :; }
  hps_get_config() {
    case "$1" in
      cluster_services) echo "$TEST_DIR/services" ;;
      system_base)      echo "$TEST_DIR/sys" ;;
      log)              echo "$TEST_DIR/log" ;;
      supervisord_conf) echo "$TEST_DIR/supervisord.conf" ;;
      active_cluster)   echo "lab" ;;
      *) return 1 ;;
    esac
  }
  get_path_cluster_services_dir() { echo "$TEST_DIR/services"; }
  install_opensvc_foreground_wrapper() { :; }
  _get_hps_environment() { echo "HPS_X=1"; }
  export -f hps_log hps_get_config get_path_cluster_services_dir
  export HPS_LOG="$TEST_DIR/log"
  export HPS_SYSTEM_BASE="$TEST_DIR/sys"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "supervisor runs hps-log-rotate loop as root, logging to syslog, once" {
  source "$ROOT/lib/functions.d/configure-supervisor.sh"
  : > "$TEST_DIR/supervisord.conf"
  run supervisor_configure_core_services
  [ "$status" -eq 0 ]
  run supervisor_configure_core_services
  [ "$status" -eq 0 ]
  f="$TEST_DIR/supervisord.conf"
  run grep -c '^\[program:hps-log-rotate\]' "$f"
  [ "$output" -eq 1 ]
  run awk '/^\[program:hps-log-rotate\]/ {f=1} f {print} f && /^environment=/ {exit}' "$f"
  [[ "$output" == *"command=$TEST_DIR/sys/bin/hps-log-rotate loop"* ]]
  [[ "$output" == *"user=root"* ]]
  [[ "$output" == *"autorestart=true"* ]]
  [[ "$output" == *"stdout_logfile=syslog"* ]]
  [[ "$output" == *"stderr_logfile=syslog"* ]]
}

@test "the retention keys are in the catalogue, the registry keys and both documents, with their defaults" {
  for pair in log_retention_days:7 log_events_retention_days:365 log_metrics_retention_days:30 log_audit_retention_days:14; do
    k="${pair%%:*}"
    d="${pair##*:}"
    grep -q "^| \`$k\` | monitoring | .* | \`int:1..3650\` | \`$d\` | no |$" "$ROOT/docs/CLUSTER-CONFIG.md"
    grep -q "^| \`$k\` | \`int\` | hps-cluster-config; read by hps-log-rotate |" "$ROOT/docs/REGISTRY-KEYS.md"
    grep -q "key => '$k'.*" "$ROOT/lib/perl/HPS/ClusterConfig.pm"
    run perl -I"$ROOT/lib/perl" -MHPS::ClusterConfig -e 'my $q = HPS::ClusterConfig::question($ARGV[0]); print $q->{default}' "$k"
    [ "$output" = "$d" ]
  done
}

@test "hps-log-rotate: an executable tool; usage is exit 2; documented in LOGGING.md" {
  [ -x "$ROOT/bin/hps-log-rotate" ]
  run perl "$ROOT/bin/hps-log-rotate"
  [ "$status" -eq 2 ]
  [[ "$output" == *"hps-log-rotate run [--dry-run] [--force]"* ]]
  run perl "$ROOT/bin/hps-log-rotate" purge
  [ "$status" -eq 2 ]
  grep -q 'hps-log-rotate' "$ROOT/docs/LOGGING.md"
  grep -q 'log_audit_retention_days' "$ROOT/docs/LOGGING.md"
}

@test "hps-log-rotate run --dry-run over an empty tree does nothing and exits 0" {
  run env HPS_LOG="$TEST_DIR/log" HPS_CONFIG_BASE="$TEST_DIR" perl "$ROOT/bin/hps-log-rotate" run --dry-run
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
