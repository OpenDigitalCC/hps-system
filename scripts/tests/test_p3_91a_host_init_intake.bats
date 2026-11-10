#!/usr/bin/env bats
#
# IPS-02 item 2: cmd=host_init_result intake (host_init_intake): stores
# init_result, rotates the previous one to init_result_prev, sets init_ok;
# refuses a body over the 8 KiB cap, a MAC that is not the caller's, a bad
# method, an unknown caller and a body that is not an init result.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-91a.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  load p1_50_helpers
  source "$ROOT/lib/functions.d/host-functions.sh"
  p1_50_stubs
  MAC=52:54:00:aa:bb:01
  p1_50_host "$MAC" STATE INSTALLED
  p1_50_host "$MAC" system_pin pin-7
  export REQUEST_METHOD=POST
  unset CONTENT_LENGTH HTTP_X_HPS_MAC
  H="$TEST_DIR/hosts/525400aabb01"
  FAIL1="$TEST_DIR/fail1.json"
  cat > "$FAIL1" <<'JSON'
{"boot_id":"b-1","pin":"pin-7","started_at":"2026-11-10T10:00:00Z","finished_at":"2026-11-10T10:00:09Z",
 "steps":[{"name":"n_a","rc":0,"seconds":1,"message":""},
          {"name":"n_set_hostname_and_hosts","rc":1,"seconds":2,"message":"Error: failed to get hostname"},
          {"name":"n_c","rc":0,"seconds":0,"message":""}],"extra":"dropped"}
JSON
  GOOD="$TEST_DIR/good.json"
  cat > "$GOOD" <<'JSON'
{"boot_id":"b-2","pin":"","started_at":"2026-11-10T11:00:00Z","finished_at":"2026-11-10T11:00:05Z",
 "steps":[{"name":"n_a","rc":0,"seconds":1,"message":""}]}
JSON
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "a result with a failing step is stored and init_ok is false" {
  run host_init_intake "$MAC" < "$FAIL1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok" ]]
  [ "$(jq -r '.steps | length' "$H/init_result")" -eq 3 ]
  [ "$(jq -r '.steps[1].name' "$H/init_result")" = "n_set_hostname_and_hosts" ]
  [ "$(jq -r '.steps[1].rc' "$H/init_result")" -eq 1 ]
  [ "$(jq -r '.boot_id' "$H/init_result")" = "b-1" ]
  [ "$(jq -r '.received_at' "$H/init_result")" = "2026-11-09 12:00:00 UTC" ]
  [ "$(jq -r 'has("extra")' "$H/init_result")" = "false" ]
  [ "$(cat "$H/init_ok")" = "false" ]
  [ ! -e "$H/init_result_prev" ]
  grep -q "\[$MAC\] host_init_result stored: 1 step(s) failed: n_set_hostname_and_hosts" "$TEST_DIR/hps.log"
}

@test "a second result moves the first to init_result_prev and sets init_ok true" {
  host_init_intake "$MAC" < "$FAIL1" > /dev/null
  run host_init_intake "$MAC" < "$GOOD"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.boot_id' "$H/init_result")" = "b-2" ]
  [ "$(jq -r '.boot_id' "$H/init_result_prev")" = "b-1" ]
  [ "$(jq -r '.steps | length' "$H/init_result_prev")" -eq 3 ]
  [ "$(cat "$H/init_ok")" = "true" ]
}

@test "an empty pin in the body is filled from the host's system_pin" {
  run host_init_intake "$MAC" < "$GOOD"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.pin' "$H/init_result")" = "pin-7" ]
}

@test "a body over the 8 KiB cap is refused with 413, even when Content-Length lies" {
  head -c 9000 /dev/zero | tr '\0' 'x' > "$TEST_DIR/big.json"
  run host_init_intake "$MAC" < "$TEST_DIR/big.json"
  [ "$status" -eq 1 ]
  [[ "$output" == "Status: 413"* ]]
  [ ! -e "$H/init_result" ]
  [ ! -e "$H/init_ok" ]
}

@test "a declared Content-Length over the cap is refused before reading" {
  export CONTENT_LENGTH=9000
  run host_init_intake "$MAC" < "$GOOD"
  [ "$status" -eq 1 ]
  [[ "$output" == "Status: 413"* ]]
  [ ! -e "$H/init_result" ]
}

@test "a valid body just under the cap is accepted" {
  jq -c '.steps[0].message = ("y" * 7000)' "$GOOD" > "$TEST_DIR/near.json"
  [ "$(wc -c < "$TEST_DIR/near.json")" -lt 8192 ]
  run host_init_intake "$MAC" < "$TEST_DIR/near.json"
  [ "$status" -eq 0 ]
}

@test "an X-HPS-MAC header naming another MAC is refused with 403" {
  export HTTP_X_HPS_MAC=52:54:00:00:00:99
  run host_init_intake "$MAC" < "$GOOD"
  [ "$status" -eq 1 ]
  [[ "$output" == "Status: 403"* ]]
  [[ "$output" == *"MAC is not the caller's"* ]]
  [ ! -e "$H/init_result" ]
  grep -q "X-HPS-MAC names 52:54:00:00:00:99" "$TEST_DIR/hps.log"
}

@test "an X-HPS-MAC header naming the caller (any case) is accepted" {
  export HTTP_X_HPS_MAC=52:54:00:AA:BB:01
  run host_init_intake "$MAC" < "$GOOD"
  [ "$status" -eq 0 ]
  [ -f "$H/init_result" ]
}

@test "an unknown caller is refused and not created" {
  run host_init_intake 52:54:00:00:00:99 < "$GOOD"
  [ "$status" -eq 1 ]
  [[ "$output" == "Status: 403"* ]]
  [ ! -e "$TEST_DIR/hosts/525400000099" ]
}

@test "GET is refused with 405" {
  REQUEST_METHOD=GET run host_init_intake "$MAC" < "$GOOD"
  [ "$status" -eq 1 ]
  [[ "$output" == "Status: 405"* ]]
}

@test "bodies that are not an init result are refused with 400" {
  echo 'not json at all' > "$TEST_DIR/bad1.json"
  echo '{"steps":"nope"}' > "$TEST_DIR/bad2.json"
  echo '{"steps":[{"name":"a","rc":"x"}]}' > "$TEST_DIR/bad3.json"
  echo '{"boot_id":"b"}' > "$TEST_DIR/bad4.json"
  for f in bad1 bad2 bad3 bad4; do
    run host_init_intake "$MAC" < "$TEST_DIR/$f.json"
    [ "$status" -eq 1 ]
    [[ "$output" == "Status: 400"* ]]
  done
  [ ! -e "$H/init_result" ]
}

@test "boot_manager dispatches host_init_result to host_init_intake and parses level= on log_message" {
  run bash -n "$ROOT/http/cgi-bin/boot_manager.sh"
  [ "$status" -eq 0 ]
  grep -q 'cmd" == "host_init_result"' "$ROOT/http/cgi-bin/boot_manager.sh"
  grep -q 'host_init_intake "\$mac"' "$ROOT/http/cgi-bin/boot_manager.sh"
  grep -q 'cgi_param exists level' "$ROOT/http/cgi-bin/boot_manager.sh"
}
