#!/usr/bin/env bats
#
# CS-1.1 item 7: n_init_run runs "func arg..." lines, keeps bare names working
# and still reports a missing function.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-13.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export CALL_LOG="$TEST_DIR/calls.log"
  : > "$CALL_LOG"

  n_remote_log() { :; }
  t_bare() { echo "bare" >> "$CALL_LOG"; }
  t_args() { echo "args:$*" >> "$CALL_LOG"; }
  source "$ROOT/node-manager/base/n_init-functions.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "bare function names still run" {
  HPS_INIT_SEQUENCE=("t_bare")
  run n_init_run
  [ "$status" -eq 0 ]
  grep -q "^bare$" "$CALL_LOG"
  [[ "$output" == *"1 succeeded, 0 failed"* ]]
}

@test "lines with arguments run the function with those arguments" {
  HPS_INIT_SEQUENCE=("t_args jq curl")
  run n_init_run
  [ "$status" -eq 0 ]
  grep -q "^args:jq curl$" "$CALL_LOG"
  [[ "$output" == *"1 succeeded, 0 failed"* ]]
}

@test "an unknown first word is reported as not found" {
  HPS_INIT_SEQUENCE=("t_missing jq")
  run n_init_run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Function not found: t_missing jq"* ]]
  [[ "$output" == *"0 succeeded, 1 failed"* ]]
}
