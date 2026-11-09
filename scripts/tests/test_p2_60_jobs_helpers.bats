#!/usr/bin/env bats
#
# CS-2.4: the job queue, caller side (lib/functions.d/jobs-functions.sh):
# directories made with hps_state_mkdir, the file shape hps_job_submit writes,
# the kind/argument allowlist, and hps_job_wait / hps_job_result reading what
# the runner leaves in done/ and failed/.

bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p2-60.XXXXXX")"
  export TEST_DIR
  export HPS_JOBS_DIR="$TEST_DIR/clusters/lab/jobs"
  hps_log() { echo "$*" >> "$TEST_DIR/hps.log"; }
  export -f hps_log
  source "${BATS_TEST_DIRNAME}/../../lib/hps-state.sh"
  source "${BATS_TEST_DIRNAME}/../../lib/functions.d/jobs-functions.sh"
  hps_state_umask
}

teardown() {
  rm -rf "$TEST_DIR"
}

# result_file <dest> <id> <json>: what the runner would leave.
result_file() {
  mkdir -p "$HPS_JOBS_DIR/$1"
  printf '%s\n' "$3" > "$HPS_JOBS_DIR/$1/$2.result.json"
}

@test "the queue directories are created setgid and group-writable" {
  run hps_jobs_ensure_dirs
  [ "$status" -eq 0 ]
  for d in new run 'done' failed; do
    [ -d "$HPS_JOBS_DIR/$d" ]
    mode=$(stat -c %a "$HPS_JOBS_DIR/$d")
    [ "$mode" = "2775" ]
  done
}

@test "hps_jobs_dir defaults to <cluster_base>/jobs" {
  unset HPS_JOBS_DIR
  hps_get_config() { [[ "$1" == cluster_base ]] && echo "$TEST_DIR/clusters/lab"; }
  run hps_jobs_dir
  [ "$output" = "$TEST_DIR/clusters/lab/jobs" ]
}

@test "submit writes new/<epoch>-<pid>-<id>.json and prints the id" {
  run hps_job_submit pairing-approve abc123 --replace
  [ "$status" -eq 0 ]
  id="$output"
  [[ "$id" =~ ^[0-9a-f]{8}$ ]]
  files=("$HPS_JOBS_DIR"/new/*.json)
  [ "${#files[@]}" -eq 1 ]
  [[ "${files[0]##*/}" =~ ^[0-9]+-[0-9]+-${id}\.json$ ]]
  [ "$(jq -r .id "${files[0]}")" = "$id" ]
  [ "$(jq -r .kind "${files[0]}")" = "pairing-approve" ]
  [ "$(jq -c .args "${files[0]}")" = '["abc123","--replace"]' ]
  [[ "$(jq -r .requested_by "${files[0]}")" =~ ^[0-9]+/.+ ]]
  [[ "$(jq -r .requested_at "${files[0]}")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$ ]]
}

@test "a submitted job is group-writable and leaves no temp file" {
  run hps_job_submit pairing-window-close
  [ "$status" -eq 0 ]
  files=("$HPS_JOBS_DIR"/new/*)
  [ "${#files[@]}" -eq 1 ]
  [ "$(stat -c %a "${files[0]}")" = "664" ]
  run find "$HPS_JOBS_DIR/new" -name '.tmp-*'
  [ -z "$output" ]
}

@test "submit creates a missing queue" {
  rm -rf "$HPS_JOBS_DIR"
  run hps_job_submit pairing-window-close
  [ "$status" -eq 0 ]
  [ -d "$HPS_JOBS_DIR/new" ]
}

@test "submit returns 2 when the queue cannot be written" {
  mkdir -p "$HPS_JOBS_DIR/new"
  chmod 555 "$HPS_JOBS_DIR/new"
  run hps_job_submit pairing-window-close
  chmod 755 "$HPS_JOBS_DIR/new"
  [ "$status" -eq 2 ]
}

@test "every allowed kind with valid arguments is accepted" {
  hps_job_validate pairing-window-open
  hps_job_validate pairing-window-open 300
  hps_job_validate pairing-window-open 1
  hps_job_validate pairing-window-open 600
  hps_job_validate pairing-window-close
  hps_job_validate pairing-list
  hps_job_validate pairing-approve deadbeef
  hps_job_validate pairing-approve deadbeef --replace
  hps_job_validate storage-up 525400000001
  hps_job_validate storage-down 525400000001
  hps_job_validate storage-trim-check 525400000001
  hps_job_validate storage-status 525400000001
}

@test "an unknown kind is refused and nothing is queued" {
  run hps_job_submit rm-rf /
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown job kind"* ]]
  run hps_job_submit ""
  [ "$status" -eq 1 ]
  [ ! -d "$HPS_JOBS_DIR/new" ] || [ -z "$(ls -A "$HPS_JOBS_DIR/new")" ]
}

@test "arguments that do not match the kind's pattern are refused" {
  bad=(
    "pairing-window-open 0"
    "pairing-window-open 601"
    "pairing-window-open abc"
    "pairing-window-open 1 2"
    "pairing-window-close now"
    "pairing-list x"
    "pairing-approve"
    "pairing-approve DEADBEEF"
    "pairing-approve dead;beef"
    "pairing-approve deadbeef --force"
    "pairing-approve deadbeef --replace x"
    "storage-up"
    "storage-up 52:54:00:00:00:01"
    "storage-up 52540000000"
    "storage-up 5254000000011"
    "storage-up 52540000000G"
    "storage-up 525400000001 extra"
    "storage-status \$(id)"
  )
  for line in "${bad[@]}"; do
    # shellcheck disable=SC2086  # word splitting of the line is the point
    run hps_job_submit $line
    [ "$status" -eq 1 ] || { echo "accepted: $line"; return 1; }
  done
  [ -z "$(ls -A "$HPS_JOBS_DIR/new" 2>/dev/null)" ]
}

@test "a 65-character reqid is refused" {
  long=$(printf 'a%.0s' {1..65})
  run hps_job_submit pairing-approve "$long"
  [ "$status" -eq 1 ]
}

@test "wait returns the job's stdout and its exit status" {
  result_file 'done' abcd0001 '{"id":"abcd0001","exit":0,"stdout":"approved ok","stderr":""}'
  run hps_job_wait abcd0001 2
  [ "$status" -eq 0 ]
  [ "$output" = "approved ok" ]
}

@test "wait returns a failed job's exit and sends its stderr to stderr" {
  result_file failed abcd0002 '{"id":"abcd0002","exit":3,"stdout":"out","stderr":"boom"}'
  run --separate-stderr hps_job_wait abcd0002 2
  [ "$status" -eq 3 ]
  [ "$output" = "out" ]
  [ "${stderr:-}" = "boom" ]
}

@test "wait picks up a result that appears while it polls" {
  ( sleep 0.6; result_file 'done' abcd0003 '{"id":"abcd0003","exit":0,"stdout":"late","stderr":""}' ) 3>&- &
  run hps_job_wait abcd0003 5
  [ "$status" -eq 0 ]
  [ "$output" = "late" ]
}

@test "wait times out with 124 when there is no result" {
  hps_jobs_ensure_dirs
  start=$SECONDS
  run hps_job_wait abcd0004 1
  [ "$status" -eq 124 ]
  [ $((SECONDS - start)) -le 3 ]
}

@test "wait refuses an id that is not 8 hex digits" {
  run hps_job_wait '../etc' 1
  [ "$status" -eq 124 ]
}

@test "result prints the JSON of a finished job and fails for an unfinished one" {
  result_file 'done' abcd0005 '{"id":"abcd0005","exit":0,"stdout":"x","stderr":""}'
  run hps_job_result abcd0005
  [ "$status" -eq 0 ]
  [ "$(jq -r .stdout <<< "$output")" = "x" ]
  run hps_job_result abcd0006
  [ "$status" -eq 1 ]
}
