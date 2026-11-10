#!/usr/bin/env bats
#
# IPS-02 items 1 and 5: n_init_run reports its result to the IPS in one POST
# (cmd=host_init_result, JSON body, X-HPS-MAC header) and logs a failed step at
# err severity. Each step's message is its own stderr tail (3 lines, 300
# chars). The report never blocks boot. curl is a PATH shim; n_remote_log and
# n_get_provisioning_node are stubs.

# shellcheck disable=SC2034  # vars are read by the sourced functions
bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-91.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export CURL_ARGS="$TEST_DIR/curl.args"
  export CURL_BODY="$TEST_DIR/curl.body"
  export LOG_CALLS="$TEST_DIR/log.calls"
  : > "$LOG_CALLS"
  mkdir -p "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/curl" <<'SH'
#!/bin/bash
for a in "$@"; do printf '[%s]\n' "$a"; done > "$CURL_ARGS"
prev=""
for a in "$@"; do
  if [ "$prev" = "--data-binary" ]; then printf '%s' "$a" > "$CURL_BODY"; fi
  prev="$a"
done
if [ "${FAKE_CURL_RC:-0}" -ne 0 ]; then echo "curl: (28) Operation timed out" >&2; exit "$FAKE_CURL_RC"; fi
printf '%s' "${FAKE_HTTP:-200}"
SH
  chmod +x "$TEST_DIR/bin/curl"
  export PATH="$TEST_DIR/bin:$PATH"

  n_remote_log() { printf 'LOG|%s|%s|%s\n' "${1-}" "${2-}" "${3-}" >> "$LOG_CALLS"; }
  n_get_provisioning_node() { echo 192.0.2.1; }
  get_mac() { echo 52:54:00:aa:bb:01; }
  t_ok() { echo "fine"; }
  t_bad() { echo "line1" >&2; echo "line2" >&2; echo "line3" >&2; echo "line4" >&2; return 1; }
  t_long() { head -c 500 /dev/zero | tr '\0' 'z' >&2; return 2; }
  t_quiet_fail() { return 3; }
  # shellcheck disable=SC1091
  source "$ROOT/node-manager/base/n_init-functions.sh"
  unset HPS_PIN
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "the report body for a sequence with one failing step" {
  HPS_INIT_SEQUENCE=("t_ok" "t_bad" "t_ok")
  run n_init_run
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 succeeded, 1 failed"* ]]
  [ "$(jq -r '.steps | length' "$CURL_BODY")" -eq 3 ]
  [ "$(jq -r '.steps[0].name' "$CURL_BODY")" = "t_ok" ]
  [ "$(jq -r '.steps[0].rc' "$CURL_BODY")" -eq 0 ]
  [ "$(jq -r '.steps[1].name' "$CURL_BODY")" = "t_bad" ]
  [ "$(jq -r '.steps[1].rc' "$CURL_BODY")" -eq 1 ]
  [ "$(jq -r '.steps[2].rc' "$CURL_BODY")" -eq 0 ]
  [ "$(jq -r '.steps[1].seconds | type' "$CURL_BODY")" = "number" ]
  [[ "$(jq -r '.started_at' "$CURL_BODY")" =~ ^20[0-9-]+T[0-9:]+Z$ ]]
  [[ "$(jq -r '.finished_at' "$CURL_BODY")" =~ ^20[0-9-]+T[0-9:]+Z$ ]]
  jq -e 'has("boot_id") and has("pin")' "$CURL_BODY"
}

@test "the call is one POST to cmd=host_init_result with JSON content type and the MAC header" {
  HPS_INIT_SEQUENCE=("t_ok")
  run n_init_run
  [ "$status" -eq 0 ]
  grep -qx '\[http://192.0.2.1/cgi-bin/boot_manager.sh?cmd=host_init_result\]' "$CURL_ARGS"
  grep -qx '\[POST\]' "$CURL_ARGS"
  grep -qx '\[Content-Type: application/json\]' "$CURL_ARGS"
  grep -qx '\[X-HPS-MAC: 52:54:00:aa:bb:01\]' "$CURL_ARGS"
  grep -A1 -x '\[-m\]' "$CURL_ARGS" | grep -qx '\[10\]'
}

@test "a step's message is its own stderr, last 3 lines" {
  HPS_INIT_SEQUENCE=("t_bad")
  run n_init_run
  [ "$status" -eq 0 ]
  [ "$(jq -r '.steps[0].message' "$CURL_BODY")" = $'line2\nline3\nline4' ]
}

@test "a step's message is at most 300 characters" {
  HPS_INIT_SEQUENCE=("t_long")
  run n_init_run
  [ "$(jq -r '.steps[0].message | length' "$CURL_BODY")" -eq 300 ]
}

@test "a global left by an earlier failed call never becomes a step's message" {
  N_IPS_COMMAND_LAST_ERROR="HTTP 411 for command: log_message"
  HPS_INIT_SEQUENCE=("t_quiet_fail")
  run n_init_run
  [ "$(jq -r '.steps[0].rc' "$CURL_BODY")" -eq 3 ]
  [ "$(jq -r '.steps[0].message' "$CURL_BODY")" = "" ]
  run ! grep -q 411 "$CURL_BODY"
}

@test "a missing function is a step with rc 127" {
  HPS_INIT_SEQUENCE=("t_missing x" "t_ok")
  run n_init_run
  [ "$(jq -r '.steps[0].rc' "$CURL_BODY")" -eq 127 ]
  [ "$(jq -r '.steps[0].name' "$CURL_BODY")" = "t_missing x" ]
}

@test "the step's stderr still reaches the caller's output" {
  HPS_INIT_SEQUENCE=("t_bad")
  run n_init_run
  [[ "$output" == *"line1"* ]]
}

@test "a failed step logs at err severity; a good one at the default" {
  HPS_INIT_SEQUENCE=("t_ok" "t_bad")
  run n_init_run
  grep -q '^LOG|Init ERROR \[2/2\]: Failed (1): t_bad|auto|err$' "$LOG_CALLS"
  grep -q '^LOG|Init \[1/2\]: Success: t_ok||$' "$LOG_CALLS"
}

@test "the pin comes from HPS_PIN" {
  HPS_PIN=pin-9
  HPS_INIT_SEQUENCE=("t_ok")
  run n_init_run
  [ "$(jq -r '.pin' "$CURL_BODY")" = "pin-9" ]
}

@test "a failing report (curl times out) is logged and ignored; init still returns 0" {
  export FAKE_CURL_RC=28
  HPS_INIT_SEQUENCE=("t_ok")
  run n_init_run
  [ "$status" -eq 0 ]
  grep -q '^LOG|WARNING: init result not reported: curl-failed:.*|auto|warning$' "$LOG_CALLS"
}

@test "a non-2xx answer is logged and ignored" {
  export FAKE_HTTP=413
  HPS_INIT_SEQUENCE=("t_ok")
  run n_init_run
  [ "$status" -eq 0 ]
  grep -q 'init result not reported: 413' "$LOG_CALLS"
}

@test "no IPS address: nothing is sent, boot continues" {
  n_get_provisioning_node() { return 1; }
  HPS_INIT_SEQUENCE=("t_ok")
  run n_init_run
  [ "$status" -eq 0 ]
  [ ! -e "$CURL_ARGS" ]
  grep -q 'no IPS address' "$LOG_CALLS"
}
