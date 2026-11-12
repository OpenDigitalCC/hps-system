#!/usr/bin/env bats
#
# CS-1.12: a CGI failure answers with a non-2xx HTTP status for non-iPXE
# callers, so `curl -f` fails on the node (the DL360 got HTTP 200 with the
# body "Key 'HOSTNAME' not found" and set it as the hostname). iPXE callers keep
# the iPXE-script body. One helper, cgi_status, prints every Status: line.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/cgi-functions.sh"
  hps_log() { :; }
  ipxe_cgi_fail() { printf '#!ipxe\necho Error: %s\n' "$1"; }
  detect_client_type() { echo "${FAKE_CLIENT:-cli}"; }
}

@test "cgi_status prints one Status line" {
  run cgi_status 404 "Not Found"
  [ "$status" -eq 0 ]
  [ "$output" = "Status: 404 Not Found" ]
}

@test "cgi_status needs both arguments" {
  run cgi_status 404
  [ "$status" -ne 0 ]
}

@test "cgi_fail answers 500 before the Content-Type header by default" {
  run cgi_fail "boom"
  [ "${lines[0]}" = "Status: 500 Internal Server Error" ]
  [ "${lines[1]}" = "Content-Type: text/plain" ]
  [[ "$output" == *boom ]]
}

@test "cgi_fail takes a code and text" {
  run cgi_fail "gone" 404 "Not Found"
  [ "${lines[0]}" = "Status: 404 Not Found" ]
  [ "${lines[1]}" = "Content-Type: text/plain" ]
}

@test "cgi_auto_fail passes a 404 through for a cli caller" {
  FAKE_CLIENT=cli run cgi_auto_fail "Key 'HOSTNAME' not found" 404 "Not Found"
  [ "${lines[0]}" = "Status: 404 Not Found" ]
  [[ "$output" == *"Key 'HOSTNAME' not found" ]]
}

@test "cgi_auto_fail without a code is a 500 for browser, script and unknown callers" {
  for c in browser script unknown cli; do
    FAKE_CLIENT=$c run cgi_auto_fail "nope"
    [ "${lines[0]}" = "Status: 500 Internal Server Error" ]
  done
}

@test "cgi_auto_fail keeps the iPXE-script body, with no Status line, for an iPXE caller" {
  FAKE_CLIENT=ipxe run cgi_auto_fail "Key 'HOSTNAME' not found" 404 "Not Found"
  [ "${lines[0]}" = "#!ipxe" ]
  [[ "$output" != *"Status:"* ]]
}

@test "cgi_success stays a plain 200 (no Status line)" {
  run cgi_success "held01"
  [ "${lines[0]}" = "Content-Type: text/plain" ]
  [[ "$output" != *"Status:"* ]]
}

@test "host_audit_refuse still prints exactly one Status line (CS-1.5 contract)" {
  host_audit_refuse() { echo "Status: $1"; cgi_fail "node_audit refused: $2"; }
  run host_audit_refuse "403 Forbidden" "no"
  [ "${lines[0]}" = "Status: 403 Forbidden" ]
  [ "${lines[1]}" = "Content-Type: text/plain" ]
}

@test "the real host_audit_refuse prints one Status line through the real cgi_fail" {
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/host-functions.sh"
  run host_audit_refuse "403 Forbidden" "no"
  [ "${lines[0]}" = "Status: 403 Forbidden" ]
  [ "${lines[1]}" = "Content-Type: text/plain" ]
}

@test "boot_manager answers a missing host or cluster key with 404 Not Found" {
  grep -q "cgi_auto_fail \"Key '\$var_name' not found\" 404 \"Not Found\"" "$ROOT/http/cgi-bin/boot_manager.sh"
  grep -q "cgi_auto_fail \"Cluster key '\$name' not found\" 404 \"Not Found\"" "$ROOT/http/cgi-bin/boot_manager.sh"
}

@test "an unset cluster key is an expected absence: logged at info, not error" {
  grep -q "cgi_auto_fail \"Cluster key '\$name' not found\" 404 \"Not Found\" info" "$ROOT/http/cgi-bin/boot_manager.sh"
}
