#!/usr/bin/env bats
#
# IPS-02 items 4 and 5: n_remote_host_variable / n_remote_cluster_variable
# report their own failure (the HTTP status of their own call), not the stale
# N_IPS_COMMAND_LAST_ERROR of an earlier failed call; n_remote_log carries an
# optional severity (logger -p / level=).

bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-91b.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export LOG_CALLS="$TEST_DIR/log.calls"
  export CURL_ARGS="$TEST_DIR/curl.args"
  : > "$LOG_CALLS"
  export HPS_LOG_STDIN_TIMEOUT=2
  mkdir -p "$TEST_DIR/bin"
  # curl: HTTP code by cmd= in the URL: FAKE_HTTP_<cmd>, default 200.
  cat > "$TEST_DIR/bin/curl" <<'SH'
#!/bin/bash
url="${*: -1}"
echo "$url" >> "$CURL_ARGS"
case "$url" in
  *cmd=host_variable*)    code="${FAKE_HTTP_HOST:-200}" ;;
  *cmd=cluster_variable*) code="${FAKE_HTTP_CLUSTER:-200}" ;;
  *cmd=log_message*)      code="${FAKE_HTTP_LOG:-200}" ;;
  *) code=200 ;;
esac
printf 'valueHTTPCODE:%s' "$code"
SH
  cat > "$TEST_DIR/bin/pgrep" <<'SH'
#!/bin/bash
[ "${FAKE_SYSLOGD:-0}" = 1 ]
SH
  cat > "$TEST_DIR/bin/logger" <<'SH'
#!/bin/bash
echo "logger: $*" >> "$LOG_CALLS"
SH
  chmod +x "$TEST_DIR/bin/curl" "$TEST_DIR/bin/pgrep" "$TEST_DIR/bin/logger"
  export PATH="$TEST_DIR/bin:$PATH"
  local f start end fn
  f="$ROOT/node-manager/base/pre-load.sh"
  for fn in n_ips_command n_url_encode n_ips_command_report n_remote_log n_remote_host_variable n_remote_cluster_variable; do
    start=$(grep -n "^${fn}() {" "$f" | cut -d: -f1)
    end=$(awk -v s="$start" 'NR>s && /^}/ {print NR; exit}' "$f")
    sed -n "${start},${end}p" "$f" >> "$TEST_DIR/fn.sh"
  done
  # shellcheck disable=SC1091
  source "$TEST_DIR/fn.sh"
  n_get_provisioning_node() { echo 192.0.2.1; }
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "n_remote_host_variable failing reports its own HTTP status" {
  export FAKE_HTTP_HOST=403
  export FAKE_SYSLOGD=1
  run n_remote_host_variable HOSTNAME
  [ "$status" -eq 3 ]
  grep -q "Failed to get host variable 'HOSTNAME': HTTP 403 for command: host_variable" "$LOG_CALLS"
  [[ "$output" == *"HTTP 403 for command: host_variable"* ]]
}

@test "a stale global from an earlier failed log call is not what is reported" {
  export FAKE_HTTP_HOST=404
  export FAKE_SYSLOGD=1
  N_IPS_COMMAND_LAST_ERROR="HTTP 411 for command: log_message"
  run n_remote_host_variable HOSTNAME
  [ "$status" -eq 3 ]
  run ! grep -q "411" "$LOG_CALLS"
  grep -q "HTTP 404 for command: host_variable" "$LOG_CALLS"
  [[ "$output" != *"411"* ]]
}

@test "the failing log call itself (411) does not change the reason reported" {
  export FAKE_HTTP_HOST=403
  export FAKE_HTTP_LOG=411
  unset FAKE_SYSLOGD
  run n_remote_host_variable HOSTNAME
  [ "$status" -eq 3 ]
  [[ "$output" == *"HTTP 403 for command: host_variable"* ]]
  [[ "$output" != *"HTTP 411"* ]]
}

@test "in the caller's own shell the global carries the real reason after a failure" {
  export FAKE_HTTP_HOST=403
  export FAKE_SYSLOGD=1
  rc=0
  n_remote_host_variable HOSTNAME >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 3 ]
  [[ "$N_IPS_COMMAND_LAST_ERROR" == "HTTP 403 for command: host_variable"* ]]
}

@test "n_remote_host_variable success still prints the value" {
  run n_remote_host_variable HOSTNAME
  [ "$status" -eq 0 ]
  [ "$output" = "value" ]
}

@test "n_remote_cluster_variable failing reports its own HTTP status" {
  export FAKE_HTTP_CLUSTER=500
  export FAKE_SYSLOGD=1
  N_IPS_COMMAND_LAST_ERROR="HTTP 411 for command: log_message"
  run n_remote_cluster_variable network_dns_domain
  [ "$status" -eq 3 ]
  grep -q "Failed to get cluster variable 'network_dns_domain': HTTP 500 for command: cluster_variable" "$LOG_CALLS"
  run ! grep -q "411" "$LOG_CALLS"
}

@test "n_remote_log: default severity adds no priority and no level parameter" {
  FAKE_SYSLOGD=1 run n_remote_log "hello"
  grep -qx 'logger: -t hps\[run\] hello' "$LOG_CALLS" || grep -q '^logger: -t hps\[.*\] hello$' "$LOG_CALLS"
  run n_remote_log "hello" ips
  grep -q 'cmd=log_message&message=hello&function=' "$CURL_ARGS"
  run ! grep -q 'level=' "$CURL_ARGS"
}

@test "n_remote_log: severity err goes to logger -p user.err" {
  FAKE_SYSLOGD=1 run n_remote_log "boom" auto err
  grep -q '^logger: -p user.err -t hps\[.*\] boom$' "$LOG_CALLS"
}

@test "n_remote_log: severity err over the IPS carries level=err" {
  run n_remote_log "boom" ips err
  grep -q 'cmd=log_message&message=boom&function=.*&level=err' "$CURL_ARGS"
}
