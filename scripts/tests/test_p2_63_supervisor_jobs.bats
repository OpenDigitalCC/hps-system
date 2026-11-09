#!/usr/bin/env bats
#
# CS-2.4: the supervisor runs hps-jobs (root) and ctrl-exec-api, both to syslog,
# pre-start creates the job queue, and rsyslog files both programs.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p2-63.XXXXXX")"
  export TEST_DIR
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  mkdir -p "$TEST_DIR/services" "$TEST_DIR/log" "$TEST_DIR/clusters/lab"
  hps_log() { echo "$*" >> "$TEST_DIR/hps.log"; }
  hps_get_config() {
    case "$1" in
      cluster_services) echo "$TEST_DIR/services" ;;
      cluster_base)     echo "$TEST_DIR/clusters/lab" ;;
      active_cluster)   echo "lab" ;;
      log)              echo "$TEST_DIR/log" ;;
      supervisord_conf) echo "$TEST_DIR/supervisord.conf" ;;
      *) return 1 ;;
    esac
  }
  install_opensvc_foreground_wrapper() { :; }
  _get_hps_environment() { echo "HPS_X=1"; }
  export -f hps_log hps_get_config
  export HPS_LOG="$TEST_DIR/log"
  export HPS_SYSTEM_BASE="/opt/hps"
  export HPS_CONFIG_BASE="$TEST_DIR"
  unset HPS_JOBS_DIR

  source "$ROOT/lib/hps-state.sh"
  source "$ROOT/lib/functions.d/jobs-functions.sh"
  source "$ROOT/lib/functions.d/create-config-rsyslog.sh"
  source "$ROOT/lib/functions.d/configure-supervisor.sh"
  source "$ROOT/lib/functions.d/supervisor-functions.sh"
  hps_state_umask
  : > "$TEST_DIR/supervisord.conf"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# block <program>: the lines of its [program:...] stanza.
block() {
  awk -v p="[program:$1]" '$0 == p {f=1; next} /^\[/ {f=0} f' "$TEST_DIR/supervisord.conf"
}

@test "program:hps-jobs runs bin/hps-jobs as root, logging to syslog" {
  run supervisor_configure_core_services
  [ "$status" -eq 0 ]
  b="$(block hps-jobs)"
  [[ "$b" == *"command=/opt/hps/bin/hps-jobs"* ]]
  [[ "$b" == *"user=root"* ]]
  [[ "$b" == *"autorestart=true"* ]]
  [[ "$b" == *"stdout_logfile=syslog"* ]]
  [[ "$b" == *"stderr_logfile=syslog"* ]]
}

@test "program:ctrl-exec-api drops to the ctrl-exec user and logs to syslog" {
  run supervisor_configure_core_services
  [ "$status" -eq 0 ]
  b="$(block ctrl-exec-api)"
  [[ "$b" == *"ctrl-exec-api'"* ]]
  [[ "$b" == *"setpriv --reuid=ctrl-exec --regid=ctrl-exec --init-groups"* ]]
  [[ "$b" == *"/run/ctrl-exec-api"* ]]
  [[ "$b" == *"stdout_logfile=syslog"* ]]
  [[ "$b" == *"stderr_logfile=syslog"* ]]
}

@test "both blocks are added once" {
  supervisor_configure_core_services
  supervisor_configure_core_services
  [ "$(grep -c '^\[program:hps-jobs\]' "$TEST_DIR/supervisord.conf")" -eq 1 ]
  [ "$(grep -c '^\[program:ctrl-exec-api\]' "$TEST_DIR/supervisord.conf")" -eq 1 ]
}

@test "pre-start creates the job queue under the active cluster" {
  run supervisor_prepare_jobs
  [ "$status" -eq 0 ]
  for d in new run 'done' failed; do
    [ "$(stat -c %a "$TEST_DIR/clusters/lab/jobs/$d")" = "2775" ]
  done
}

@test "pre-start without an active cluster warns and carries on" {
  hps_get_config() { return 1; }
  run supervisor_prepare_jobs
  [ "$status" -eq 0 ]
}

@test "_supervisor_pre_start runs supervisor_prepare_jobs after the services are prepared" {
  body=$(declare -f _supervisor_pre_start)
  [[ "$body" == *supervisor_prepare_services*supervisor_prepare_jobs*supervisor_fix_state_permissions* ]]
}

@test "rsyslog files hps-jobs and ctrl-exec-api under ips/<programname>/" {
  get_path_cluster_services_dir() { echo "$TEST_DIR/services"; }
  run create_config_rsyslog
  [ "$status" -eq 0 ]
  rule="$(grep -E 'programname == \[' "$TEST_DIR/services/rsyslog.conf")"
  [[ "$rule" == *'"hps-jobs"'* ]]
  [[ "$rule" == *'"ctrl-exec-api"'* ]]
}
