#!/usr/bin/env bats
#
# CS-3.6: the Bash job allowlist (lib/functions.d/jobs-functions.sh) accepts and
# refuses the same workload-* kinds and arguments as HPS::Jobs (t/73).

bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-50.XXXXXX")"
  export TEST_DIR
  export HPS_JOBS_DIR="$TEST_DIR/clusters/lab/jobs"
  hps_log() { echo "$*" >> "$TEST_DIR/hps.log"; }
  export -f hps_log
  source "${BATS_TEST_DIRNAME}/../../lib/hps-state.sh"
  source "${BATS_TEST_DIRNAME}/../../lib/functions.d/jobs-functions.sh"
  hps_state_umask
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "workload kinds with valid arguments are allowed" {
  run hps_job_validate workload-create t0
  [ "$status" -eq 0 ]
  run hps_job_validate workload-create t0 --resume
  [ "$status" -eq 0 ]
  run hps_job_validate workload-start t0 --vm t0-app
  [ "$status" -eq 0 ]
  run hps_job_validate workload-stop t0
  [ "$status" -eq 0 ]
  run hps_job_validate workload-status t0 --vm t0-app
  [ "$status" -eq 0 ]
  run hps_job_validate workload-destroy t0
  [ "$status" -eq 0 ]
}

@test "workload kinds with bad arguments are refused" {
  run -1 hps_job_validate workload-create
  run -1 hps_job_validate workload-create T0
  run -1 hps_job_validate workload-create t0 --vm x
  run -1 hps_job_validate workload-create t0 --force
  run -1 hps_job_validate workload-start t0 --vm
  run -1 hps_job_validate workload-start t0 --resume
  run -1 hps_job_validate workload-start t0 --vm 'a;b'
  run -1 hps_job_validate workload-stop t0 --vm x y
  run -1 hps_job_validate workload-destroy
  run -1 hps_job_validate workload-destroy t0 --vm x
  run -1 hps_job_validate workload-destroy 'a;b'
  [ "$status" -eq 1 ]
}

@test "a workload job is queued by hps_job_submit" {
  mkdir -p "$HPS_JOBS_DIR/new"
  run hps_job_submit workload-create t0 --resume
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-f]{8}$ ]]
  run grep -l '"kind":"workload-create"' "$HPS_JOBS_DIR"/new/*.json
  [ "$status" -eq 0 ]
}
