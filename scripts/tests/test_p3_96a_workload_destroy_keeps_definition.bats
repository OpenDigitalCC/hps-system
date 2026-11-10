#!/usr/bin/env bats
#
# IPS-07: workload destroy keeps workloads/<name>.json; destroy --forget removes
# it. The driver, CLI and job allowlist (Perl and Bash) agree.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-96a.XXXXXX")"
  export TEST_DIR
  export HPS_JOBS_DIR="$TEST_DIR/clusters/lab/jobs"
  hps_log() { echo "$*" >> "$TEST_DIR/hps.log"; }
  export -f hps_log
  source "$ROOT/lib/hps-state.sh"
  source "$ROOT/lib/functions.d/jobs-functions.sh"
  hps_state_umask
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "the job allowlist accepts workload-destroy with --forget only" {
  run hps_job_validate workload-destroy t0
  [ "$status" -eq 0 ]
  run hps_job_validate workload-destroy t0 --forget
  [ "$status" -eq 0 ]
  run -1 hps_job_validate workload-destroy t0 --vm x
  run -1 hps_job_validate workload-destroy t0 --forget x
  run -1 hps_job_validate workload-destroy --forget
  run -1 hps_job_validate workload-destroy 'a;b' --forget
}

@test "the CLI help says destroy keeps the definition and --forget removes it" {
  run "$ROOT/bin/hps-workload"
  [ "$status" -eq 2 ]
  [[ "$output" == *"destroy <name> [--forget]"* ]]
  [[ "$output" == *"keeps workloads/<name>.json"* ]]
}

@test "--forget is refused on every other operation" {
  run "$ROOT/bin/hps-workload" create t0 --forget
  [ "$status" -eq 2 ]
  run "$ROOT/bin/hps-workload" start t0 --forget
  [ "$status" -eq 2 ]
}

@test "driver and CLI: destroy keeps the definition, create after destroy works, --forget removes it" {
  run perl -I"$ROOT/lib/perl" "$ROOT/t/72-hps-workload-cli.t"
  [ "$status" -eq 0 ]
  [[ "$output" != *"not ok"* ]]
  run perl -I"$ROOT/lib/perl" "$ROOT/t/71-workload-driver.t"
  [ "$status" -eq 0 ]
  [[ "$output" != *"not ok"* ]]
  run perl -I"$ROOT/lib/perl" "$ROOT/t/73-jobs-workload-kinds.t"
  [ "$status" -eq 0 ]
}
