#!/usr/bin/env bats
#
# Pairing resilience, IPS side (incident 2026-11-12):
#  - ce_approve_pair_request says why: 3 not yet (pending, unknown_request,
#    no_request), 4 outside the window (reboot; pair_reboots counts, three at
#    most, then pair_failed_at and a refusal), 1 refused; a pairing clears both
#  - the pairing window is not closed while another host is within its own
#    window and unpaired
#  - api.sh answers 503 / 410 / 403 with the reason in the body

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-211.XXXXXX")"
  export TEST_DIR ROOT
  id() { if [[ "${1:-}" == -u ]]; then echo "${FAKE_UID:-0}"; else command id "$@"; fi; }
  export -f id
  export CTRL_EXEC_PAIRING_DIR="$TEST_DIR/pairing"
  mkdir -p "$CTRL_EXEC_PAIRING_DIR" "$TEST_DIR/reg"
  export CTRL_EXEC_PAIR_WINDOW=300
  export CTRL_EXEC_PAIR_CLOSE_DELAY=0
  export CE_LOG="$TEST_DIR/ced.log"
  export CTRL_EXEC_DISPATCHER="$TEST_DIR/fake-ced"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s"\nexit 0\n' "$CE_LOG" > "$CTRL_EXEC_DISPATCHER"
  chmod +x "$CTRL_EXEC_DISPATCHER"
  hps_log() { echo "$*" >> "$TEST_DIR/hps.log"; }
  # registry: one file per host and key
  host_registry() {
    local f="$TEST_DIR/reg/$1/$3"
    case "$2" in
      get) [[ -f "$f" ]] && cat "$f" ;;
      set) mkdir -p "$TEST_DIR/reg/$1"; printf '%s\n' "$4" > "$f" ;;
      delete) rm -f "$f" ;;
    esac
  }
  list_cluster_hosts() { ls "$TEST_DIR/reg"; }
  host_fqdn() { printf '%s.lab.hps\n' "$(host_registry "$1" get HOSTNAME)"; }
  export -f hps_log host_registry list_cluster_hosts host_fqdn
  source "$ROOT/lib/functions.d/ctrl-exec-functions.sh"
  MAC=525400000001
}

teardown() {
  rm -rf "$TEST_DIR"
}

# host <mac> <booted seconds ago> [ip] [name]
host() {
  host_registry "$1" set STATE NETWORK_BOOT
  host_registry "$1" set IP "${3:-10.0.0.50}"
  host_registry "$1" set HOSTNAME "${4:-node-50}"
  host_registry "$1" set last_boot_at "$(( $(date +%s) - $2 ))"
}

request() {
  jq -n --arg ip "${2:-10.0.0.50}" --arg h "${3:-node-50.lab.hps}" '{id:"abc123", hostname:$h, source_ip:$ip}' \
    > "$CTRL_EXEC_PAIRING_DIR/${1:-abc123}.json"
}

@test "1: approved: rc 0, reason paired, pair_reboots and pair_failed_at cleared" {
  host "$MAC" 30
  host_registry "$MAC" set pair_reboots 2
  host_registry "$MAC" set pair_failed_at 1794321826
  request
  ce_approve_pair_request "$MAC" abc123
  [ "$CE_PAIR_REASON" = paired ]
  [ ! -f "$TEST_DIR/reg/$MAC/pair_reboots" ]
  [ ! -f "$TEST_DIR/reg/$MAC/pair_failed_at" ]
}

@test "2: outside the window: rc 4 (reboot) three times, counted; then 1 reboots_exhausted with pair_failed_at" {
  host "$MAC" 400
  request
  local i rc
  for i in 1 2 3; do
    rc=0
    ce_approve_pair_request "$MAC" abc123 || rc=$?
    [ "$rc" -eq 4 ]
    [ "$CE_PAIR_REASON" = outside_window ]
    [ "$(host_registry "$MAC" get pair_reboots)" -eq "$i" ]
  done
  rc=0
  ce_approve_pair_request "$MAC" abc123 || rc=$?
  [ "$rc" -eq 1 ]
  [ "$CE_PAIR_REASON" = reboots_exhausted ]
  [[ "$(host_registry "$MAC" get pair_failed_at)" =~ ^[0-9]+$ ]]
  ! grep -q '^approve' "$CE_LOG"
}

@test "3: no reqid inside the window: rc 3 no_request with the window left" {
  host "$MAC" 100
  rc=0
  ce_approve_pair_request "$MAC" "" || rc=$?
  [ "$rc" -eq 3 ]
  [ "$CE_PAIR_REASON" = no_request ]
  (( CE_PAIR_WINDOW_LEFT > 190 && CE_PAIR_WINDOW_LEFT <= 200 ))
}

@test "4: a reqid the dispatcher does not hold: rc 3 unknown_request" {
  host "$MAC" 30
  rc=0
  ce_approve_pair_request "$MAC" abc999 || rc=$?
  [ "$rc" -eq 3 ]
  [ "$CE_PAIR_REASON" = unknown_request ]
}

@test "5: job runner path: a pairing-list or pairing-approve that does not finish in time is rc 3 pending" {
  host "$MAC" 30
  export FAKE_UID=33
  _ce_job() { echo "$*" >> "$TEST_DIR/jobs.log"; return 124; }
  rc=0
  ce_approve_pair_request "$MAC" abc123 || rc=$?
  [ "$rc" -eq 3 ]
  [ "$CE_PAIR_REASON" = pending ]
  # the wait is the request timeout (one deadline for the whole approval)
  read -r wait kind < "$TEST_DIR/jobs.log"
  [ "$kind" = pairing-list ]
  (( wait >= CTRL_EXEC_PAIR_REQUEST_TIMEOUT - 2 && wait <= CTRL_EXEC_PAIR_REQUEST_TIMEOUT ))

  request
  _ce_job() { echo "$*" >> "$TEST_DIR/jobs.log"; [[ "$2" == pairing-list ]] && return 1; return 124; }
  rc=0
  ce_approve_pair_request "$MAC" abc123 || rc=$?
  [ "$rc" -eq 3 ]
  [ "$CE_PAIR_REASON" = pending ]
  grep -q 'pairing-approve abc123 --replace' "$TEST_DIR/jobs.log"
  [ ! -f "$TEST_DIR/reg/$MAC/ctrl_exec_paired_at" ]
}

@test "6: refusals are rc 1 reason refused (wrong address, bad state)" {
  host "$MAC" 30
  request abc123 10.0.0.99
  rc=0
  ce_approve_pair_request "$MAC" abc123 || rc=$?
  [ "$rc" -eq 1 ]
  [ "$CE_PAIR_REASON" = refused ]
  host_registry "$MAC" set STATE INSTALLED
  rc=0
  ce_approve_pair_request "$MAC" abc123 || rc=$?
  [ "$rc" -eq 1 ]
}

@test "7: three hosts: the window stays open until the last is paired, then closes" {
  host 525400000001 20 10.0.0.51 n1
  host 525400000002 10 10.0.0.52 n2
  host 525400000003 5 10.0.0.53 n3
  request a1 10.0.0.51 n1.lab.hps
  ce_approve_pair_request 525400000001 a1
  ! grep -q '^pairing-mode stop' "$CE_LOG"
  grep -q 'pairing window kept open: 2 host(s)' "$TEST_DIR/hps.log"
  request a2 10.0.0.52 n2.lab.hps
  ce_approve_pair_request 525400000002 a2
  ! grep -q '^pairing-mode stop' "$CE_LOG"
  request a3 10.0.0.53 n3.lab.hps
  ce_approve_pair_request 525400000003 a3
  grep -q '^pairing-mode stop' "$CE_LOG"
}

@test "8: a host whose own window has expired does not hold the window open" {
  host 525400000001 20 10.0.0.51 n1
  host 525400000002 400 10.0.0.52 n2
  request a1 10.0.0.51 n1.lab.hps
  ce_approve_pair_request 525400000001 a1
  grep -q '^pairing-mode stop' "$CE_LOG"
}

@test "9: a late host's refusal does not close the window under a host still waiting" {
  host 525400000001 400 10.0.0.51 n1
  host 525400000002 10 10.0.0.52 n2
  rc=0
  ce_approve_pair_request 525400000001 a1 || rc=$?
  [ "$rc" -eq 4 ]
  ! grep -q '^pairing-mode stop' "$CE_LOG"
}

# --- api.sh: the HTTP code and the reason
api_rig() {
  mkdir -p "$TEST_DIR/tree/http/api" "$TEST_DIR/tree/lib"
  cp "$ROOT/http/api/api.sh" "$TEST_DIR/tree/http/api/api.sh"
  cat > "$TEST_DIR/tree/lib/functions.sh" <<EOT
hps_log() { echo "\$*" >> "$TEST_DIR/api.log"; }
hps_origin_tag() { echo aa:bb:cc:dd:ee:01; }
host_config_exists() { return 0; }
cgi_resolve_caller_mac() { echo "\$1"; }
host_registry() { return 1; }
hps_get_config() { return 1; }
hps_job_submit() { return 1; }
ce_approve_pair_request() {
  CE_PAIR_REASON="\$FAKE_REASON"; CE_PAIR_DETAIL="why"; CE_PAIR_WINDOW_LEFT=42; CE_PAIR_LAST_BOOT_AT=1794321826
  return "\$FAKE_RC"
}
EOT
}

call_api() {
  local body="{\"action\":\"ctrl_exec_pair_request\",\"reqid\":\"${1-}\"}"
  REQUEST_METHOD=POST CONTENT_TYPE=application/json CONTENT_LENGTH="${#body}" \
    REMOTE_ADDR=10.0.0.9 bash "$TEST_DIR/tree/http/api/api.sh" <<< "$body"
}

@test "10: api.sh answers 503, 410 and 403 with reason, details and window_left" {
  api_rig
  FAKE_RC=3 FAKE_REASON=pending run call_api ab12
  [[ "$output" == *"Status: 503"* ]]
  body=$(sed '1,/^\r\{0,1\}$/d' <<< "$output")
  jq -e '.reason == "pending" and .details == "why" and .window_left == 42 and .last_boot_at == 1794321826' <<< "$body"
  FAKE_RC=4 FAKE_REASON=outside_window run call_api ab12
  [[ "$output" == *"Status: 410 Gone"* ]]
  FAKE_RC=1 FAKE_REASON=reboots_exhausted run call_api ab12
  [[ "$output" == *"Status: 403"* ]]
  [[ "$output" == *'"reason": "reboots_exhausted"'* ]]
}

@test "11: api.sh passes an empty reqid to the approver (a node asking whether to go on)" {
  api_rig
  FAKE_RC=3 FAKE_REASON=no_request run call_api ""
  [[ "$output" == *"Status: 503"* ]]
  [[ "$output" != *"Missing reqid"* ]]
}
