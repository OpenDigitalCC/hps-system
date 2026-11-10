#!/usr/bin/env bats
#
# n_ips_command (node-manager/base/pre-load.sh): the boot_manager POST carries
# an explicit empty body, so lighttpd gets Content-Length: 0 and does not answer
# 411 Length Required. curl is a PATH shim that records its arguments.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-72.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export CURL_LOG="$TEST_DIR/curl.args"
  mkdir -p "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/curl" <<'SH'
#!/bin/bash
for a in "$@"; do printf '[%s]\n' "$a"; done > "$CURL_LOG"
printf 'value-okHTTPCODE:%s' "${FAKE_HTTP:-200}"
SH
  chmod +x "$TEST_DIR/bin/curl"
  export PATH="$TEST_DIR/bin:$PATH"
  local f start end
  f="$ROOT/node-manager/base/pre-load.sh"
  for fn in n_ips_command n_url_encode; do
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

@test "n_ips_command POSTs with an explicit empty body (Content-Length: 0)" {
  run n_ips_command host_variable name=HOSTNAME
  [ "$status" -eq 0 ]
  [ "$output" = "value-ok" ]
  grep -qx '\[-X\]' "$CURL_LOG"
  grep -qx '\[POST\]' "$CURL_LOG"
  grep -A1 -x '\[--data-binary\]' "$CURL_LOG" | grep -qx '\[\]'
  grep -qx '\[http://192.0.2.1/cgi-bin/boot_manager.sh?cmd=host_variable&name=HOSTNAME\]' "$CURL_LOG"
}

@test "n_ips_command: a 411 or other 4xx is an error (3), not a value" {
  FAKE_HTTP=411 run n_ips_command host_variable name=HOSTNAME
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}
