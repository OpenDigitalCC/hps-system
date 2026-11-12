#!/usr/bin/env bats
#
# Scale test phase 2: after a pairing is approved, http/api/api.sh queues a
# `net-up <mac>` job (hps-node net-up) for NixOS hosts whose TYPE contains SCH
# or TCH, before the storage hook's storage-up; anything else is a no-op with a
# log line. Same CGI rig as test_p2_50 (fake function library, real job helpers).

bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-199.XXXXXX")"
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
ce_approve_pair_request() { return "\${FAKE_APPROVE_RC:-0}"; }
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

call_api() {
  REQUEST_METHOD=POST CONTENT_TYPE=application/json CONTENT_LENGTH="${#BODY}" \
    REMOTE_ADDR=10.0.0.9 bash "$TEST_DIR/tree/http/api/api.sh" <<< "$BODY"
}

host() {
  printf '%s' "$2" > "$TEST_DIR/hosts/$FAKE_MAC/$1"
}

# kinds: the kinds of the queued jobs, sorted, space separated.
kinds() {
  local f
  for f in "$HPS_JOBS_DIR"/new/*.json; do
    [[ -e "$f" ]] && jq -r .kind "$f"
  done | sort | paste -sd' ' -
}

@test "1: a NixOS SCH host with a pool gets net-up, queued before storage-up" {
  host TYPE SCH
  host os_id x86_64:nixos:26.05
  host storage_state up
  run call_api
  [ "$status" -eq 0 ]
  [[ "$output" == *'"paired": true'* ]]
  [ "$(kinds)" = "net-up storage-up" ]
  run grep -n -e "net hook: queued net-up for aabbccddee01" -e "storage hook: queued storage-up" "$TEST_DIR/hps.log"
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == *"net hook"* ]]
}

@test "2: a NixOS TCH host gets net-up with its MAC as the one argument" {
  host TYPE TCH
  host os_id x86_64:nixos:26.05
  run call_api
  [ "$status" -eq 0 ]
  [ "$(kinds)" = "net-up" ]
  f=("$HPS_JOBS_DIR"/new/*.json)
  [ "$(jq -c .args "${f[0]}")" = '["aabbccddee01"]' ]
}

@test "3: converged (SCH,TCH) counts" {
  host TYPE SCH,TCH
  host os_id x86_64:nixos:26.05
  run call_api
  [ "$(kinds)" = "net-up" ]
}

@test "4: a host that is not NixOS, or not SCH/TCH, gets no net-up" {
  host TYPE SCH
  host os_id x86_64:rocky:10
  run call_api
  [ "$status" -eq 0 ]
  [ -z "$(kinds)" ]
  grep -q "net hook: $FAKE_MAC is not a NixOS host" "$TEST_DIR/hps.log"
  host TYPE CNH
  host os_id x86_64:nixos:26.05
  run call_api
  [ -z "$(kinds)" ]
  grep -q "net hook: $FAKE_MAC is not an SCH or TCH host" "$TEST_DIR/hps.log"
  host TYPE XSCHX
  run call_api
  [ -z "$(kinds)" ]
}

@test "5: a denied pairing queues nothing" {
  host TYPE TCH
  host os_id x86_64:nixos:26.05
  FAKE_APPROVE_RC=1 run call_api
  [[ "$output" == *"403"* ]]
  [ -z "$(kinds)" ]
  run ! grep -q "net hook" "$TEST_DIR/hps.log"
}

@test "6: the bash job validator takes net-up <mac> only" {
  # shellcheck source=/dev/null
  source "$ROOT/lib/functions.d/jobs-functions.sh"
  hps_job_validate net-up aabbccddee01
  run hps_job_validate net-up
  [ "$status" -eq 1 ]
  run hps_job_validate net-up sch-001
  [ "$status" -eq 1 ]
  run hps_job_validate net-up aabbccddee01 --dry-run
  [ "$status" -eq 1 ]
}

# IPS-34 item 2: om3 back after a reboot. A host with osvc_delivered_at (an om3
# cluster member) also gets osvc-deliver <mac>, queued after net-up and
# storage-up; one without gets nothing, and pairing succeeds either way.

# queued: the kinds in the order the runner takes them (the file names sort by
# epoch; same second: modification time, as HPS::Jobs::pending).
queued() {
  local f
  for f in $(ls -tr "$HPS_JOBS_DIR"/new/*.json 2>/dev/null); do
    jq -r .kind "$f"
  done | paste -sd' ' -
}

@test "7: an om3 member gets osvc-deliver <mac> after net-up and storage-up" {
  host TYPE SCH,TCH
  host os_id x86_64:nixos:26.05
  host storage_state up
  host osvc_delivered_at 1800000000
  run call_api
  [ "$status" -eq 0 ]
  [[ "$output" == *'"paired": true'* ]]
  [ "$(queued)" = "net-up storage-up osvc-deliver" ]
  f=$(grep -l '"osvc-deliver"' "$HPS_JOBS_DIR"/new/*.json)
  [ "$(jq -c .args "$f")" = '["aabbccddee01"]' ]
  grep -q "osvc hook: queued osvc-deliver for aabbccddee01" "$TEST_DIR/hps.log"
}

@test "8: a host never delivered to is not an om3 member: no osvc-deliver, pairing still succeeds" {
  host TYPE TCH
  host os_id x86_64:nixos:26.05
  run call_api
  [ "$status" -eq 0 ]
  [[ "$output" == *'"paired": true'* ]]
  [ "$(kinds)" = "net-up" ]
  grep -q "osvc hook: $FAKE_MAC is not an om3 cluster member" "$TEST_DIR/hps.log"
}

@test "9: a queue that cannot take the job is logged and the pairing still succeeds" {
  host TYPE TCH
  host os_id x86_64:nixos:26.05
  host osvc_delivered_at 1800000000
  export HPS_JOBS_DIR="$TEST_DIR/no-such-queue/x"
  : > "$TEST_DIR/no-such-queue"
  run call_api
  [ "$status" -eq 0 ]
  [[ "$output" == *'"paired": true'* ]]
  grep -q "osvc hook: could not queue osvc-deliver" "$TEST_DIR/hps.log"
}

@test "10: the bash job validator takes osvc-deliver <mac> only" {
  # shellcheck source=/dev/null
  source "$ROOT/lib/functions.d/jobs-functions.sh"
  hps_job_validate osvc-deliver aabbccddee01
  run hps_job_validate osvc-deliver
  [ "$status" -eq 1 ]
  run hps_job_validate osvc-deliver tch-001
  [ "$status" -eq 1 ]
}
