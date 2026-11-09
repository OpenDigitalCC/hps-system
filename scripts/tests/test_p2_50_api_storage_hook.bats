#!/usr/bin/env bats
#
# CS-2.3: after ce_approve_pair_request succeeds, http/api/api.sh starts
# `hps-storage <mac> up` DETACHED for SCH hosts whose registry has
# storage_state, and does nothing (with a log line) otherwise. The real api.sh
# runs as a CGI against a fake function library; hps-storage is a shim that
# records its arguments and then outlives the API call.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p2-50.XXXXXX")"
  export TEST_DIR
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  mkdir -p "$TEST_DIR/tree/http/api" "$TEST_DIR/tree/lib" "$TEST_DIR/hosts"
  cp "$ROOT/http/api/api.sh" "$TEST_DIR/tree/http/api/api.sh"
  cat > "$TEST_DIR/tree/lib/functions.sh" <<EOT
hps_log() { echo "\$*" >> "$TEST_DIR/hps.log"; }
hps_origin_tag() { echo "\$FAKE_MAC"; }
host_config_exists() { return 0; }
cgi_resolve_caller_mac() { echo "\$1"; }
ce_approve_pair_request() { echo "\$*" >> "$TEST_DIR/approve.log"; return "\${FAKE_APPROVE_RC:-0}"; }
host_registry() {
  local f="$TEST_DIR/hosts/\$1/\$3"
  [[ "\$2" == get && -f "\$f" ]] && cat "\$f"
}
EOT
  cat > "$TEST_DIR/hps-storage" <<'EOT'
#!/usr/bin/env bash
echo "$*" > "$TEST_DIR/storage.args"
sleep 4
echo finished > "$TEST_DIR/storage.done"
EOT
  chmod +x "$TEST_DIR/hps-storage"
  export HPS_STORAGE_CMD="$TEST_DIR/hps-storage"
  export FAKE_MAC="aa:bb:cc:dd:ee:01"
  mkdir -p "$TEST_DIR/hosts/$FAKE_MAC"
  export BODY='{"action":"ctrl_exec_pair_request","reqid":"R1"}'
}

teardown() {
  pkill -f "$TEST_DIR/hps-storage" 2> /dev/null || true
  rm -rf "$TEST_DIR"
}

# call_api: the CGI, POST of $BODY from a node (not loopback).
call_api() {
  REQUEST_METHOD=POST CONTENT_TYPE=application/json CONTENT_LENGTH="${#BODY}" \
    REMOTE_ADDR=10.0.0.9 bash "$TEST_DIR/tree/http/api/api.sh" <<< "$BODY"
}

wait_for_file() {
  local n
  for _ in {1..20}; do
    [[ -f "$1" ]] && return 0
    sleep 0.1
  done
  return 1
}

@test "an SCH host with storage_state gets 'hps-storage <mac> up', detached" {
  echo -n SCH > "$TEST_DIR/hosts/$FAKE_MAC/TYPE"
  echo -n up > "$TEST_DIR/hosts/$FAKE_MAC/storage_state"
  start=$SECONDS
  run call_api
  [ "$status" -eq 0 ]
  # the shim sleeps 4 s holding nothing of ours: the call must not wait for it
  [ $((SECONDS - start)) -lt 3 ]
  [[ "$output" == *'"paired": true'* ]]
  wait_for_file "$TEST_DIR/storage.args"
  [ "$(cat "$TEST_DIR/storage.args")" = "aa:bb:cc:dd:ee:01 up --wait 120" ]
  [ ! -f "$TEST_DIR/storage.done" ]
  grep -q "storage hook: starting 'hps-storage aa:bb:cc:dd:ee:01 up" "$TEST_DIR/hps.log"
}

@test "the job has no stdout, stderr or stdin of the CGI (the response can end)" {
  echo -n SCH > "$TEST_DIR/hosts/$FAKE_MAC/TYPE"
  echo -n down > "$TEST_DIR/hosts/$FAKE_MAC/storage_state"
  cat > "$TEST_DIR/hps-storage" <<'EOT'
#!/usr/bin/env bash
f0=$(readlink /proc/$$/fd/0)
f1=$(readlink /proc/$$/fd/1)
f2=$(readlink /proc/$$/fd/2)
sid=$(ps -o sid= -p $$)
printf '%s\n' "$f0" "$f1" "$f2" "$sid" "$$" > "$TEST_DIR/storage.fds"
sleep 3
EOT
  run call_api
  [ "$status" -eq 0 ]
  wait_for_file "$TEST_DIR/storage.fds"
  sleep 0.3
  [ "$(sed -n 1p "$TEST_DIR/storage.fds")" = "/dev/null" ]
  [ "$(sed -n 2p "$TEST_DIR/storage.fds")" = "/dev/null" ]
  [ "$(sed -n 3p "$TEST_DIR/storage.fds")" = "/dev/null" ]
  # own session: the session id is the job's own pid
  [ "$(sed -n 4p "$TEST_DIR/storage.fds" | tr -d ' ')" = "$(sed -n 5p "$TEST_DIR/storage.fds")" ]
}

@test "TYPE SCH,TCH counts as an SCH host" {
  echo -n 'SCH,TCH' > "$TEST_DIR/hosts/$FAKE_MAC/TYPE"
  echo -n up > "$TEST_DIR/hosts/$FAKE_MAC/storage_state"
  run call_api
  [ "$status" -eq 0 ]
  wait_for_file "$TEST_DIR/storage.args"
}

@test "an SCH host without storage_state: no job, a log line" {
  echo -n SCH > "$TEST_DIR/hosts/$FAKE_MAC/TYPE"
  run call_api
  [ "$status" -eq 0 ]
  [[ "$output" == *'"paired": true'* ]]
  sleep 0.5
  [ ! -f "$TEST_DIR/storage.args" ]
  grep -q "has no storage_state; nothing to do" "$TEST_DIR/hps.log"
}

@test "a non-SCH host with storage_state: no job, a log line" {
  echo -n TCH > "$TEST_DIR/hosts/$FAKE_MAC/TYPE"
  echo -n up > "$TEST_DIR/hosts/$FAKE_MAC/storage_state"
  run call_api
  [ "$status" -eq 0 ]
  sleep 0.5
  [ ! -f "$TEST_DIR/storage.args" ]
  grep -q "is not an SCH host; nothing to do" "$TEST_DIR/hps.log"
}

@test "a host with no TYPE at all: no job" {
  echo -n up > "$TEST_DIR/hosts/$FAKE_MAC/storage_state"
  run call_api
  [ "$status" -eq 0 ]
  sleep 0.5
  [ ! -f "$TEST_DIR/storage.args" ]
}

@test "a denied pairing runs no hook and answers 403" {
  echo -n SCH > "$TEST_DIR/hosts/$FAKE_MAC/TYPE"
  echo -n up > "$TEST_DIR/hosts/$FAKE_MAC/storage_state"
  FAKE_APPROVE_RC=1 run call_api
  [[ "$output" == *"403"* ]]
  sleep 0.5
  [ ! -f "$TEST_DIR/storage.args" ]
  ! grep -q "storage hook" "$TEST_DIR/hps.log"
}

@test "a missing hps-storage command does not break the pairing response" {
  echo -n SCH > "$TEST_DIR/hosts/$FAKE_MAC/TYPE"
  echo -n up > "$TEST_DIR/hosts/$FAKE_MAC/storage_state"
  HPS_STORAGE_CMD="$TEST_DIR/does-not-exist" run call_api
  [ "$status" -eq 0 ]
  [[ "$output" == *'"paired": true'* ]]
}

