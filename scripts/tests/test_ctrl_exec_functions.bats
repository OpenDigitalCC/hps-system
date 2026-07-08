#!/usr/bin/env bats
#
# Tests for the registry-bound ctrl-exec pairing approver
# (lib/functions.d/ctrl-exec-functions.sh, ce_approve_pair_request).
#
# The approver is the enrolment trust decision (ADR 0002). These tests
# exercise every binding check with the dispatcher, host registry and
# pairing directory all mocked, so they need no ctrl-exec and no network.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/ce-approve.XXXXXX")"
  export CTRL_EXEC_PAIRING_DIR="$TEST_DIR/pairing"
  mkdir -p "$CTRL_EXEC_PAIRING_DIR"

  # Record dispatcher invocations instead of running the real binary.
  export CE_APPROVE_LOG="$TEST_DIR/approve.log"
  export CTRL_EXEC_DISPATCHER="$TEST_DIR/fake-ced"
  cat > "$CTRL_EXEC_DISPATCHER" <<EOF
#!/bin/bash
echo "\$@" >> "$CE_APPROVE_LOG"
exit \${FAKE_CED_RC:-0}
EOF
  chmod +x "$CTRL_EXEC_DISPATCHER"

  # jq is a hard dependency of the approver; skip cleanly if absent.
  command -v jq >/dev/null || skip "jq not available"

  # Minimal stubs for the HPS functions the approver calls. host_registry is
  # a get/set store backed by an associative array persisted to a file so the
  # subshells the approver spawns see a consistent view.
  export REG_FILE="$TEST_DIR/registry"
  : > "$REG_FILE"

  hps_log() { :; }
  export -f hps_log

  # host_registry <mac> get|set <key> [value]
  host_registry() {
    local mac="$1" cmd="$2" key="$3" value="${4:-}"
    case "$cmd" in
      get)
        local line
        line=$(grep -F "${mac}|${key}=" "$REG_FILE" | tail -n1) || true
        [[ -n "$line" ]] || return 1
        printf '%s\n' "${line#*=}"
        ;;
      set)
        printf '%s|%s=%s\n' "$mac" "$key" "$value" >> "$REG_FILE"
        ;;
    esac
  }
  export -f host_registry

  # Load the code under test.
  source "${BATS_TEST_DIRNAME}/../../lib/functions.d/ctrl-exec-functions.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Helper: seed a host registry entry.
seed_host() {
  local mac="$1" state="$2" ip="$3" hostname="${4:-}"
  host_registry "$mac" set STATE "$state"
  host_registry "$mac" set IP "$ip"
  [[ -n "$hostname" ]] && host_registry "$mac" set HOSTNAME "$hostname"
  return 0
}

# Helper: write a pending pairing request file.
seed_request() {
  local reqid="$1" hostname="$2" source_ip="$3"
  jq -n --arg id "$reqid" --arg h "$hostname" --arg ip "$source_ip" \
    '{id:$id, hostname:$h, ip:$ip, source_ip:$ip, code:"123456"}' \
    > "${CTRL_EXEC_PAIRING_DIR}/${reqid}.json"
}

@test "approves when state, IP and hostname all bind" {
  seed_host "52:54:00:11:22:33" INSTALLING "10.99.1.50" "tch-050"
  seed_request "abc123" "tch-050" "10.99.1.50"

  run ce_approve_pair_request "52:54:00:11:22:33" "abc123"
  [ "$status" -eq 0 ]
  grep -q "approve abc123 --ip 10.99.1.50" "$CE_APPROVE_LOG"
  # Records the pairing timestamp.
  run host_registry "52:54:00:11:22:33" get ctrl_exec_paired
  [ "$status" -eq 0 ]
}

@test "denies when host state is not enrolment-eligible" {
  seed_host "52:54:00:11:22:33" INSTALLED "10.99.1.50" "tch-050"
  seed_request "abc123" "tch-050" "10.99.1.50"

  run ce_approve_pair_request "52:54:00:11:22:33" "abc123"
  [ "$status" -eq 1 ]
  [ ! -f "$CE_APPROVE_LOG" ]
}

@test "denies unknown MAC" {
  seed_request "abc123" "tch-050" "10.99.1.50"
  run ce_approve_pair_request "52:54:00:99:99:99" "abc123"
  [ "$status" -eq 1 ]
}

@test "denies when request source IP does not match allocation" {
  seed_host "52:54:00:11:22:33" INSTALLING "10.99.1.50" "tch-050"
  seed_request "abc123" "tch-050" "10.99.1.99"

  run ce_approve_pair_request "52:54:00:11:22:33" "abc123"
  [ "$status" -eq 1 ]
  [ ! -f "$CE_APPROVE_LOG" ]
}

@test "denies when request hostname does not match a recorded hostname" {
  seed_host "52:54:00:11:22:33" INSTALLING "10.99.1.50" "tch-050"
  seed_request "abc123" "evil-host" "10.99.1.50"

  run ce_approve_pair_request "52:54:00:11:22:33" "abc123"
  [ "$status" -eq 1 ]
}

@test "denies a second approval in the same cycle" {
  seed_host "52:54:00:11:22:33" INSTALLING "10.99.1.50" "tch-050"
  seed_request "abc123" "tch-050" "10.99.1.50"
  run ce_approve_pair_request "52:54:00:11:22:33" "abc123"
  [ "$status" -eq 0 ]

  seed_request "def456" "tch-050" "10.99.1.50"
  run ce_approve_pair_request "52:54:00:11:22:33" "def456"
  [ "$status" -eq 1 ]
}

@test "denies a malformed reqid without touching the dispatcher" {
  seed_host "52:54:00:11:22:33" INSTALLING "10.99.1.50" "tch-050"
  run ce_approve_pair_request "52:54:00:11:22:33" "../../etc/passwd"
  [ "$status" -eq 1 ]
  [ ! -f "$CE_APPROVE_LOG" ]
}

@test "denies when the pairing request is absent" {
  seed_host "52:54:00:11:22:33" INSTALLING "10.99.1.50" "tch-050"
  run ce_approve_pair_request "52:54:00:11:22:33" "notthere"
  [ "$status" -eq 1 ]
  [ ! -f "$CE_APPROVE_LOG" ]
}

@test "does not record pairing when the dispatcher approve fails" {
  seed_host "52:54:00:11:22:33" INSTALLING "10.99.1.50" "tch-050"
  seed_request "abc123" "tch-050" "10.99.1.50"
  export FAKE_CED_RC=1

  run ce_approve_pair_request "52:54:00:11:22:33" "abc123"
  [ "$status" -eq 1 ]
  run host_registry "52:54:00:11:22:33" get ctrl_exec_paired
  [ "$status" -ne 0 ]
}
