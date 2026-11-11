#!/usr/bin/env bats
#
# ce_operator_api_configure (from ce_api_bring_up): the ctrl-exec API's TCP
# listener is off unless the cluster key operator_api_listen names an address
# of this IPS; then it listens there with TLS, on a self-signed certificate
# for that address. openssl is real; the local addresses are a stub.

bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-193.XXXXXX")"
  export TEST_DIR
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  mkdir -p "$TEST_DIR/etc"
  hps_log() { echo "$*" >> "$TEST_DIR/hps.log"; }
  hps_get_config() { [[ "$1" == active_cluster ]] && echo lab; }
  cluster_registry() { [[ "$3" == operator_api_listen ]] && printf '%s\n' "${FAKE_LISTEN:-}"; return 0; }
  export -f hps_log hps_get_config cluster_registry
  export CTRL_EXEC_DISPATCHER_CONF_DIR="$TEST_DIR/etc"
  CONF="$TEST_DIR/etc/ctrl-exec.conf"
  export CTRL_EXEC_DISPATCHER_CONF="$CONF"
  printf 'cert = /x/dispatcher.crt\napi_socket = /run/ctrl-exec-api/api.sock\napi_port = off\n' > "$CONF"
  # The dispatcher shim reports FAKE_VERSION (default: the required release).
  mkdir -p "$TEST_DIR/bin"
  printf '#!/bin/bash\n[[ "$1" == --version ]] && echo "ctrl-exec-dispatcher ${FAKE_VERSION:-0.14.7}"\n' > "$TEST_DIR/bin/ced"
  chmod +x "$TEST_DIR/bin/ced"
  export CTRL_EXEC_DISPATCHER="$TEST_DIR/bin/ced"
  source "$ROOT/lib/functions.d/ctrl-exec-functions.sh"
  source "$ROOT/lib/functions.d/ips-admin-functions.sh"
  _ce_local_ipv4s() { printf '127.0.0.1\n10.99.1.1\n192.0.2.5\n'; }
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "no operator_api_listen: api_port = off and no TCP keys" {
  run ce_operator_api_configure "$CONF"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^api_port' "$CONF")" -eq 1 ]
  grep -qx 'api_port = off' "$CONF"
  run ! grep -qE '^(api_bind|api_tls_cert|api_tls_key)' "$CONF"
  grep -qx 'api_socket = /run/ctrl-exec-api/api.sock' "$CONF"
}

@test "operator_api_listen on this IPS: TLS on that address, port 7445" {
  FAKE_LISTEN=10.99.1.1 run ce_operator_api_configure "$CONF"
  [ "$status" -eq 0 ]
  grep -qx 'api_port = 7445' "$CONF"
  grep -qx 'api_bind = 10.99.1.1' "$CONF"
  grep -qx "api_tls_cert = $TEST_DIR/etc/hps-api-tls.crt" "$CONF"
  grep -qx "api_tls_key = $TEST_DIR/etc/hps-api-tls.key" "$CONF"
  [ "$(grep -c '^api_port' "$CONF")" -eq 1 ]
  grep -qx 'cert = /x/dispatcher.crt' "$CONF"
}

@test "the certificate is its own trust anchor for that IP, and the key is 0640" {
  FAKE_LISTEN=10.99.1.1 ce_operator_api_configure "$CONF"
  crt="$TEST_DIR/etc/hps-api-tls.crt"
  run openssl verify -CAfile "$crt" -verify_ip 10.99.1.1 "$crt"
  [ "$status" -eq 0 ]
  run openssl verify -CAfile "$crt" -verify_ip 10.99.1.2 "$crt"
  [ "$status" -ne 0 ]
  [ "$(stat -c %a "$TEST_DIR/etc/hps-api-tls.key")" = "640" ]
}

@test "the certificate is kept across starts, and made anew for a new address" {
  FAKE_LISTEN=10.99.1.1 ce_operator_api_configure "$CONF"
  a=$(openssl x509 -in "$TEST_DIR/etc/hps-api-tls.crt" -noout -fingerprint -sha256)
  FAKE_LISTEN=10.99.1.1 ce_operator_api_configure "$CONF"
  b=$(openssl x509 -in "$TEST_DIR/etc/hps-api-tls.crt" -noout -fingerprint -sha256)
  [ "$a" = "$b" ]
  [ "$(grep -c '^api_bind' "$CONF")" -eq 1 ]
  FAKE_LISTEN=192.0.2.5 ce_operator_api_configure "$CONF"
  grep -qx 'api_bind = 192.0.2.5' "$CONF"
  run openssl verify -CAfile "$TEST_DIR/etc/hps-api-tls.crt" -verify_ip 192.0.2.5 "$TEST_DIR/etc/hps-api-tls.crt"
  [ "$status" -eq 0 ]
}

@test "a loopback, wildcard, foreign or malformed address keeps the listener off" {
  for ip in 127.0.0.1 0.0.0.0 203.0.113.9 10.99.1.300 not-an-ip; do
    FAKE_LISTEN="$ip" run ce_operator_api_configure "$CONF"
    [ "$status" -eq 0 ]
    grep -qx 'api_port = off' "$CONF" || { echo "listened on $ip"; false; }
    run ! grep -q '^api_bind' "$CONF"
  done
  grep -q 'loopback or wildcard' "$TEST_DIR/hps.log"
  grep -q 'not an address of this host' "$TEST_DIR/hps.log"
}

@test "clearing operator_api_listen turns the listener off again" {
  FAKE_LISTEN=10.99.1.1 ce_operator_api_configure "$CONF"
  run ce_operator_api_configure "$CONF"
  [ "$status" -eq 0 ]
  grep -qx 'api_port = off' "$CONF"
  run ! grep -qE '^(api_bind|api_tls_cert|api_tls_key)' "$CONF"
}

@test "ce_api_bring_up applies it" {
  export CTRL_EXEC_API_PLUGINS_DEB="$TEST_DIR/none.deb"
  export HPS_SYSTEM_PATH="$TEST_DIR/no-system"
  FAKE_LISTEN=10.99.1.1 run ce_api_bring_up
  [ "$status" -eq 0 ]
  grep -qx 'api_bind = 10.99.1.1' "$CONF"
}

@test "api_forward_token = no: the operator's token never reaches the agents" {
  export CTRL_EXEC_API_PLUGINS_DEB="$TEST_DIR/none.deb"
  export HPS_SYSTEM_PATH="$TEST_DIR/no-system"
  FAKE_LISTEN=10.99.1.1 run ce_api_bring_up
  [ "$status" -eq 0 ]
  grep -qx 'api_forward_token = no' "$CONF"
  [ "$(grep -c '^api_forward_token' "$CONF")" -eq 1 ]
  run ce_api_bring_up
  [ "$(grep -c '^api_forward_token' "$CONF")" -eq 1 ]
}

@test "api_forward_token = no also holds with the listener off (the hook still gets the token)" {
  export CTRL_EXEC_API_PLUGINS_DEB="$TEST_DIR/none.deb"
  export HPS_SYSTEM_PATH="$TEST_DIR/no-system"
  run ce_api_bring_up
  grep -qx 'api_forward_token = no' "$CONF"
}

@test "ctrl-exec older than 0.14.7: the error names the requirement and the operator API stays off" {
  export CTRL_EXEC_API_PLUGINS_DEB="$TEST_DIR/none.deb"
  export HPS_SYSTEM_PATH="$TEST_DIR/no-system"
  FAKE_VERSION=0.14.6 FAKE_LISTEN=10.99.1.1 run ce_api_bring_up
  [ "$status" -eq 0 ]
  grep -q 'ctrl-exec >= 0.14.7 is required for operator access (installed: 0.14.6)' "$TEST_DIR/hps.log"
  grep -qx 'api_port = off' "$CONF"
  run ! grep -qE '^(api_bind|api_tls_cert|api_tls_key|api_forward_token)' "$CONF"
}

@test "an unreadable dispatcher version also keeps the operator API off" {
  export CTRL_EXEC_API_PLUGINS_DEB="$TEST_DIR/none.deb"
  export HPS_SYSTEM_PATH="$TEST_DIR/no-system"
  FAKE_VERSION=weird FAKE_LISTEN=10.99.1.1 run ce_api_bring_up
  grep -q 'installed: unknown' "$TEST_DIR/hps.log"
  grep -qx 'api_port = off' "$CONF"
}

@test "the local addresses come from the kernel and include loopback" {
  source "$ROOT/lib/functions.d/ips-admin-functions.sh"
  [ -r /proc/net/fib_trie ] || skip "no /proc/net/fib_trie"
  run _ce_local_ipv4s
  [ "$status" -eq 0 ]
  [[ "$output" == *127.0.0.1* ]]
}
