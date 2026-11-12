#!/usr/bin/env bats
#
# CS-1.6 item 4: the pairing approver accepts a RAM-booted node (NETWORK_BOOT),
# enforces ADR 0002 check 3 (arrival within CTRL_EXEC_PAIR_WINDOW of the last
# boot-script issue; a missing last_boot_at refuses), reads the request through
# the dispatcher CLI first, and closes the dispatcher pairing window.

setup() {
  # CS-2.4: these tests drive the root path (dispatcher called directly); as a
  # non-root user the library goes through the job queue, tested in test_p2_61.
  id() { if [[ "${1:-}" == -u ]]; then echo 0; else command id "$@"; fi; }
  export -f id
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-61.XXXXXX")"
  export CTRL_EXEC_PAIRING_DIR="$TEST_DIR/pairing"
  mkdir -p "$CTRL_EXEC_PAIRING_DIR"
  export CTRL_EXEC_PAIR_WINDOW=300
  export CTRL_EXEC_PAIR_CLOSE_DELAY=0

  export CE_LOG="$TEST_DIR/ced.log"
  export CTRL_EXEC_DISPATCHER="$TEST_DIR/fake-ced"
  cat > "$CTRL_EXEC_DISPATCHER" <<EOT
#!/usr/bin/env bash
echo "\$*" >> "$CE_LOG"
if [[ "\$1" == list-requests && -n "\${FAKE_LIST_ROW:-}" ]]; then
  echo "ID  HOSTNAME  SOURCE IP  REVERSE DNS  CODE"
  echo "-------------------------------------------"
  echo "\$FAKE_LIST_ROW"
fi
exit \${FAKE_CED_RC:-0}
EOT
  chmod +x "$CTRL_EXEC_DISPATCHER"

  export REG_FILE="$TEST_DIR/registry"
  : > "$REG_FILE"
  hps_log() { echo "$*" >> "$TEST_DIR/hps.log"; }
  host_registry() {
    local mac="$1" cmd="$2" key="$3" value="${4:-}" line
    case "$cmd" in
      get)
        line=$(grep -F "${mac}|${key}=" "$REG_FILE" | tail -n1) || true
        [[ -n "$line" ]] || return 1
        printf '%s\n' "${line#*=}"
        ;;
      set) printf '%s|%s=%s\n' "$mac" "$key" "$value" >> "$REG_FILE" ;;
    esac
  }
  export -f hps_log host_registry
  # host_fqdn (host-functions.sh) stubbed: registry HOSTNAME (first label) + .lab.hps
  host_fqdn() {
    local h
    h=$(host_registry "$1" get HOSTNAME) || return 1
    printf '%s.lab.hps\n' "${h%%.*}"
  }
  export -f host_fqdn
  export TEST_DIR

  source "${BATS_TEST_DIRNAME}/../../lib/functions.d/ctrl-exec-functions.sh"
  MAC="52:54:00:11:22:33"
}

teardown() {
  rm -rf "$TEST_DIR"
}

seed() {
  local state="$1" booted_ago="${2-}"
  host_registry "$MAC" set STATE "$state"
  host_registry "$MAC" set IP "10.0.0.50"
  host_registry "$MAC" set HOSTNAME "node-50"
  if [[ -n "$booted_ago" ]]; then
    host_registry "$MAC" set last_boot_at "$(( $(date +%s) - booted_ago ))"
  fi
}

seed_request() {
  jq -n '{id:"abc123", hostname:"node-50.lab.hps", ip:"10.0.0.50", source_ip:"10.0.0.50"}' \
    > "$CTRL_EXEC_PAIRING_DIR/abc123.json"
}

@test "approves a NETWORK_BOOT node inside the window and closes the pairing window" {
  seed NETWORK_BOOT 60
  seed_request
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 0 ]
  grep -q "^approve abc123$" "$CE_LOG"
  grep -q "^pairing-mode stop" "$CE_LOG"
}

@test "a request that arrives after the window is told to reboot (4), not approved" {
  seed NETWORK_BOOT 301
  seed_request
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 4 ]
  ! grep -q "^approve" "$CE_LOG"
  grep -q "window is 300s" "$TEST_DIR/hps.log"
}

@test "accepts a request at the edge of the window" {
  seed NETWORK_BOOT 299
  seed_request
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 0 ]
}

@test "refuses when last_boot_at is missing and says why" {
  seed NETWORK_BOOT
  seed_request
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 1 ]
  ! grep -q "^approve" "$CE_LOG"
  grep -q "no usable last_boot_at" "$TEST_DIR/hps.log"
}

@test "refuses a non-numeric last_boot_at" {
  seed NETWORK_BOOT
  host_registry "$MAC" set last_boot_at "yesterday"
  seed_request
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 1 ]
}

@test "refuses a future last_boot_at" {
  seed NETWORK_BOOT
  host_registry "$MAC" set last_boot_at "$(( $(date +%s) + 600 ))"
  seed_request
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 1 ]
}

@test "still refuses states that are not enrolment-eligible" {
  seed INSTALLED 10
  seed_request
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 1 ]
}

@test "reads the request from the dispatcher list-requests table first" {
  seed NETWORK_BOOT 10
  # No queue file: only the CLI knows the request.
  export FAKE_LIST_ROW="abc123  node-50.lab.hps  10.0.0.50  -  482917 (v2)"
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 0 ]
  grep -q "^list-requests" "$CE_LOG"
}

@test "CLI row with a different source IP is refused" {
  seed NETWORK_BOOT 10
  export FAKE_LIST_ROW="abc123  node-50  10.0.0.99  -  482917 (v2)"
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 1 ]
}

@test "ce_pairing_window_open and close call the dispatcher pairing-mode verbs" {
  run ce_pairing_window_open 120
  [ "$status" -eq 0 ]
  run ce_pairing_window_close
  [ "$status" -eq 0 ]
  grep -q "^pairing-mode start --timeout 120" "$CE_LOG"
  grep -q "^pairing-mode stop" "$CE_LOG"
}

@test "a close delay detaches the close instead of blocking the approval" {
  export CTRL_EXEC_PAIR_CLOSE_DELAY=2
  seed NETWORK_BOOT 10
  seed_request
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 0 ]
  ! grep -q "^pairing-mode stop" "$CE_LOG"
}
