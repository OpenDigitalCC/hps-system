#!/usr/bin/env bats
#
# CS-1.7 item 2: n_remote_log. An explicit message argument is always the
# message (even when stdin is not a tty); stdin is read only when no message is
# given; it never hangs on closed or empty stdin. n_ips_command and logger are
# stubs that record calls.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-70.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export CALL_LOG="$TEST_DIR/calls.log"
  : > "$CALL_LOG"
  export HPS_LOG_STDIN_TIMEOUT=2
  # Load only n_remote_log out of pre-load.sh.
  local start end
  start=$(grep -n '^n_remote_log() {' "$ROOT/node-manager/base/pre-load.sh" | cut -d: -f1)
  end=$(awk -v s="$start" 'NR>s && /^}/ {print NR; exit}' "$ROOT/node-manager/base/pre-load.sh")
  sed -n "${start},${end}p" "$ROOT/node-manager/base/pre-load.sh" > "$TEST_DIR/fn.sh"
  # shellcheck disable=SC1091
  source "$TEST_DIR/fn.sh"
  n_ips_command() { echo "ips: $*" >> "$CALL_LOG"; }
  export -f n_ips_command
  caller() { n_remote_log "$@"; }
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "message argument with stdin from /dev/null is logged, not dropped" {
  run timeout 10 bash -c 'source "$1"; n_ips_command() { echo "ips: $*" >> "$CALL_LOG"; }; w() { n_remote_log "hello world"; }; w </dev/null' _ "$TEST_DIR/fn.sh"
  [ "$status" -eq 0 ]
  grep -q '^ips: log_message message=hello world function=w$' "$CALL_LOG"
}

@test "message argument with a pipe on stdin: the argument wins, stdin is ignored" {
  run timeout 10 bash -c 'source "$1"; n_ips_command() { echo "ips: $*" >> "$CALL_LOG"; }; w() { n_remote_log "from arg"; }; echo "from pipe" | w' _ "$TEST_DIR/fn.sh"
  [ "$status" -eq 0 ]
  grep -q 'message=from arg ' "$CALL_LOG"
  ! grep -q 'from pipe' "$CALL_LOG"
}

@test "no argument: piped lines are logged one by one" {
  run timeout 10 bash -c 'source "$1"; n_ips_command() { echo "ips: $*" >> "$CALL_LOG"; }; w() { n_remote_log; }; printf "one\ntwo\n" | w' _ "$TEST_DIR/fn.sh"
  [ "$status" -eq 0 ]
  grep -q 'message=one ' "$CALL_LOG"
  grep -q 'message=two ' "$CALL_LOG"
}

@test "empty first argument plus a method reads stdin with that method" {
  run timeout 10 bash -c 'source "$1"; n_ips_command() { echo "ips: $*" >> "$CALL_LOG"; }; w() { n_remote_log "" ips; }; echo piped | w' _ "$TEST_DIR/fn.sh"
  [ "$status" -eq 0 ]
  grep -q 'message=piped ' "$CALL_LOG"
}

@test "no argument and closed stdin returns at once without logging" {
  run timeout 10 bash -c 'source "$1"; n_ips_command() { echo "ips: $*" >> "$CALL_LOG"; }; w() { n_remote_log; }; w </dev/null' _ "$TEST_DIR/fn.sh"
  [ "$status" -eq 0 ]
  [ ! -s "$CALL_LOG" ]
}

@test "no argument and an idle open pipe times out instead of hanging" {
  run timeout 10 bash -c 'source "$1"; n_ips_command() { :; }; w() { n_remote_log; }; sleep 6 | w' _ "$TEST_DIR/fn.sh"
  [ "$status" -eq 0 ]
}

@test "message argument and method: syslog falls back to ips without a syslogd" {
  run timeout 10 bash -c 'source "$1"; n_ips_command() { echo "ips: $*" >> "$CALL_LOG"; }; w() { n_remote_log "m1" syslog; }; w </dev/null' _ "$TEST_DIR/fn.sh"
  [ "$status" -eq 0 ]
  grep -q 'message=m1 ' "$CALL_LOG"
}
