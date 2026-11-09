#!/usr/bin/env bats
#
# CS-1.6 item 5: the API caller's identity is the connection's MAC only. A body
# .mac or X-HPS-MAC header is compared and logged, never used. Tests the
# extracted function, not the CGI end to end.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-62.XXXXXX")"
  export TEST_DIR
  hps_log() { echo "$*" >> "$TEST_DIR/hps.log"; }
  export -f hps_log
  source "${BATS_TEST_DIRNAME}/../../lib/functions.d/cgi-functions.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "connection MAC is returned when no claim is made" {
  run cgi_resolve_caller_mac "aa:bb:cc:dd:ee:01" "" ""
  [ "$status" -eq 0 ]
  [ "$output" = "aa:bb:cc:dd:ee:01" ]
  [ ! -f "$TEST_DIR/hps.log" ]
}

@test "a body mac that differs is ignored with a warning" {
  run cgi_resolve_caller_mac "aa:bb:cc:dd:ee:01" "aa:bb:cc:dd:ee:99" ""
  [ "$status" -eq 0 ]
  [ "$output" = "aa:bb:cc:dd:ee:01" ]
  grep -q "^warn caller aa:bb:cc:dd:ee:01 sent a different body MAC aa:bb:cc:dd:ee:99" "$TEST_DIR/hps.log"
}

@test "an X-HPS-MAC header that differs is ignored with a warning" {
  run cgi_resolve_caller_mac "aa:bb:cc:dd:ee:01" "" "aa:bb:cc:dd:ee:77"
  [ "$output" = "aa:bb:cc:dd:ee:01" ]
  grep -q "different header MAC aa:bb:cc:dd:ee:77" "$TEST_DIR/hps.log"
}

@test "claims that agree, in any case, raise no warning" {
  run cgi_resolve_caller_mac "aa:bb:cc:dd:ee:01" "AA:BB:CC:DD:EE:01" "aa:bb:cc:dd:ee:01"
  [ "$output" = "aa:bb:cc:dd:ee:01" ]
  [ ! -f "$TEST_DIR/hps.log" ]
}

@test "a loopback caller keeps the identity localhost whatever it claims" {
  run cgi_resolve_caller_mac "localhost" "aa:bb:cc:dd:ee:01" "aa:bb:cc:dd:ee:02"
  [ "$output" = "localhost" ]
}

@test "the warning does not reach stdout (the result is captured by command substitution)" {
  hps_log() { echo "WARN-ON-STDOUT"; }
  mac=$(cgi_resolve_caller_mac "aa:bb:cc:dd:ee:01" "aa:bb:cc:dd:ee:99" 2>/dev/null)
  [ "$mac" = "aa:bb:cc:dd:ee:01" ]
}

@test "api.sh resolves the identity through the function and no longer trusts X-HPS-MAC" {
  api="${BATS_TEST_DIRNAME}/../../http/api/api.sh"
  grep -q 'REQUEST_MAC=$(cgi_resolve_caller_mac' "$api"
  ! grep -q 'CLIENT_MAC="${HTTP_X_HPS_MAC' "$api"
  ! grep -q 'REQUEST_MAC="${REQUEST_MAC:-$CLIENT_MAC}"' "$api"
}
