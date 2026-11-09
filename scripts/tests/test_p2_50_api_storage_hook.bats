#!/usr/bin/env bats
#
# CS-2.3 hook, as changed by CS-2.4 (ADR 0006): after ce_approve_pair_request
# succeeds, http/api/api.sh queues a `storage-up <mac>` job for SCH hosts whose
# registry has storage_state, and does nothing (with a log line) otherwise. The
# CGI never runs hps-storage itself (it cannot read the keysafe); it submits and
# answers at once. The real api.sh runs as a CGI against a fake function library
# that loads the real job helpers.

bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p2-50.XXXXXX")"
  export TEST_DIR
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  mkdir -p "$TEST_DIR/tree/http/api" "$TEST_DIR/tree/lib" "$TEST_DIR/hosts"
  cp "$ROOT/http/api/api.sh" "$TEST_DIR/tree/http/api/api.sh"
  export HPS_JOBS_DIR="$TEST_DIR/jobs"
  cat > "$TEST_DIR/tree/lib/functions.sh" <<EOT
hps_log() { echo "\$*" >> "$TEST_DIR/hps.log"; }
source "$ROOT/lib/hps-state.sh"
source "$ROOT/lib/functions.d/jobs-functions.sh"
hps_origin_tag() { echo "\$FAKE_MAC"; }
host_config_exists() { return 0; }
cgi_resolve_caller_mac() { echo "\$1"; }
ce_approve_pair_request() { echo "\$*" >> "$TEST_DIR/approve.log"; return "\${FAKE_APPROVE_RC:-0}"; }
host_registry() {
  local f="$TEST_DIR/hosts/\$1/\$3"
  [[ "\$2" == get && -f "\$f" ]] && cat "\$f"
}
EOT
  export FAKE_MAC="aa:bb:cc:dd:ee:01"
  mkdir -p "$TEST_DIR/hosts/$FAKE_MAC"
  export BODY='{"action":"ctrl_exec_pair_request","reqid":"R1"}'
}

teardown() {
  rm -rf "$TEST_DIR"
}

# call_api: the CGI, POST of $BODY from a node (not loopback).
call_api() {
  REQUEST_METHOD=POST CONTENT_TYPE=application/json CONTENT_LENGTH="${#BODY}" \
    REMOTE_ADDR=10.0.0.9 bash "$TEST_DIR/tree/http/api/api.sh" <<< "$BODY"
}

jobs_queued() {
  find "$HPS_JOBS_DIR/new" -name '*.json' 2> /dev/null | wc -l
}

@test "an SCH host with storage_state gets a storage-up job and the call returns at once" {
  echo -n SCH > "$TEST_DIR/hosts/$FAKE_MAC/TYPE"
  echo -n up > "$TEST_DIR/hosts/$FAKE_MAC/storage_state"
  start=$SECONDS
  run call_api
  [ "$status" -eq 0 ]
  [ $((SECONDS - start)) -lt 3 ]
  [[ "$output" == *'"paired": true'* ]]
  [ "$(jobs_queued)" -eq 1 ]
  f=("$HPS_JOBS_DIR"/new/*.json)
  [ "$(jq -r .kind "${f[0]}")" = "storage-up" ]
  [ "$(jq -c .args "${f[0]}")" = '["aabbccddee01"]' ]
  grep -q "storage hook: queued storage-up for aabbccddee01" "$TEST_DIR/hps.log"
}

@test "TYPE SCH,TCH counts as an SCH host" {
  echo -n 'SCH,TCH' > "$TEST_DIR/hosts/$FAKE_MAC/TYPE"
  echo -n up > "$TEST_DIR/hosts/$FAKE_MAC/storage_state"
  run call_api
  [ "$status" -eq 0 ]
  [ "$(jobs_queued)" -eq 1 ]
}

@test "an SCH host without storage_state: no job, a log line" {
  echo -n SCH > "$TEST_DIR/hosts/$FAKE_MAC/TYPE"
  run call_api
  [ "$status" -eq 0 ]
  [[ "$output" == *'"paired": true'* ]]
  [ "$(jobs_queued)" -eq 0 ]
  grep -q "has no storage_state; nothing to do" "$TEST_DIR/hps.log"
}

@test "a non-SCH host with storage_state: no job, a log line" {
  echo -n TCH > "$TEST_DIR/hosts/$FAKE_MAC/TYPE"
  echo -n up > "$TEST_DIR/hosts/$FAKE_MAC/storage_state"
  run call_api
  [ "$status" -eq 0 ]
  [ "$(jobs_queued)" -eq 0 ]
  grep -q "is not an SCH host; nothing to do" "$TEST_DIR/hps.log"
}

@test "a host with no TYPE at all: no job" {
  echo -n up > "$TEST_DIR/hosts/$FAKE_MAC/storage_state"
  run call_api
  [ "$status" -eq 0 ]
  [ "$(jobs_queued)" -eq 0 ]
}

@test "a denied pairing queues nothing and answers 403" {
  echo -n SCH > "$TEST_DIR/hosts/$FAKE_MAC/TYPE"
  echo -n up > "$TEST_DIR/hosts/$FAKE_MAC/storage_state"
  FAKE_APPROVE_RC=1 run call_api
  [[ "$output" == *"403"* ]]
  [ "$(jobs_queued)" -eq 0 ]
  run ! grep -q "storage hook" "$TEST_DIR/hps.log"
}

@test "an unwritable queue does not break the pairing response" {
  echo -n SCH > "$TEST_DIR/hosts/$FAKE_MAC/TYPE"
  echo -n up > "$TEST_DIR/hosts/$FAKE_MAC/storage_state"
  mkdir -p "$HPS_JOBS_DIR/new"
  chmod 555 "$HPS_JOBS_DIR/new"
  run call_api
  chmod 755 "$HPS_JOBS_DIR/new"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"paired": true'* ]]
  grep -q "could not queue storage-up" "$TEST_DIR/hps.log"
}

@test "api.sh no longer starts hps-storage itself" {
  run grep -nE 'setsid|bin/hps-storage|HPS_STORAGE_CMD' "$ROOT/http/api/api.sh"
  [ "$status" -eq 1 ]
}
