#!/usr/bin/env bats
#
# CS-1.10: ce_approve_pair_request accepts STATE=HELD (a held node in the audit
# image pairs so it can be inspected). The window, last_boot_at, hostname and IP
# binding checks apply to it exactly as to a NETWORK_BOOT node.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-103.XXXXXX")"
  export CTRL_EXEC_PAIRING_DIR="$TEST_DIR/pairing"
  mkdir -p "$CTRL_EXEC_PAIRING_DIR"
  export CTRL_EXEC_PAIR_WINDOW=300
  export CTRL_EXEC_PAIR_CLOSE_DELAY=0
  export CE_LOG="$TEST_DIR/ced.log"
  export CTRL_EXEC_DISPATCHER="$TEST_DIR/fake-ced"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s"\nexit 0\n' "$CE_LOG" > "$CTRL_EXEC_DISPATCHER"
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
        printf '%s\n' "${line#*=}" ;;
      set) printf '%s|%s=%s\n' "$mac" "$key" "$value" >> "$REG_FILE" ;;
    esac
  }
  export -f hps_log host_registry
  export TEST_DIR
  source "${BATS_TEST_DIRNAME}/../../lib/functions.d/ctrl-exec-functions.sh"
  MAC="52:54:00:11:22:33"
  host_registry "$MAC" set IP "10.0.0.50"
  host_registry "$MAC" set HOSTNAME "node-50"
  jq -n '{id:"abc123", hostname:"node-50", ip:"10.0.0.50", source_ip:"10.0.0.50"}' \
    > "$CTRL_EXEC_PAIRING_DIR/abc123.json"
}

teardown() {
  rm -rf "$TEST_DIR"
}

held() {
  host_registry "$MAC" set STATE HELD
  host_registry "$MAC" set last_boot_at "$(( $(date +%s) - ${1:-30} ))"
}

@test "approves a HELD node inside the window and records ctrl_exec_paired" {
  held 30
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 0 ]
  grep -q "^approve abc123$" "$CE_LOG"
  [ -n "$(host_registry "$MAC" get ctrl_exec_paired)" ]
}

@test "a HELD node outside the window is refused" {
  held 301
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 1 ]
  ! grep -q "^approve" "$CE_LOG"
}

@test "a HELD node with no last_boot_at is refused" {
  host_registry "$MAC" set STATE HELD
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 1 ]
  grep -q "no usable last_boot_at" "$TEST_DIR/hps.log"
}

@test "a HELD node whose request comes from another IP is refused" {
  held 30
  jq -n '{id:"abc123", hostname:"node-50", source_ip:"10.0.0.99"}' > "$CTRL_EXEC_PAIRING_DIR/abc123.json"
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 1 ]
}

@test "a HELD node whose request hostname differs from the registry is refused" {
  held 30
  jq -n '{id:"abc123", hostname:"nixos", source_ip:"10.0.0.50"}' > "$CTRL_EXEC_PAIRING_DIR/abc123.json"
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 1 ]
}

@test "a HELD node already paired this cycle is refused" {
  held 30
  host_registry "$MAC" set ctrl_exec_paired 12345
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 1 ]
}

@test "other states stay refused (HELDX, held, INSTALLED, empty)" {
  for st in HELDX held INSTALLED UNKNOWN; do
    : > "$REG_FILE"
    host_registry "$MAC" set IP "10.0.0.50"
    host_registry "$MAC" set HOSTNAME "node-50"
    host_registry "$MAC" set STATE "$st"
    host_registry "$MAC" set last_boot_at "$(date +%s)"
    run ce_approve_pair_request "$MAC" abc123
    [ "$status" -eq 1 ]
  done
}

@test "ADR 0002 names HELD among the enrolment-eligible states" {
  grep -q 'HELD' "${BATS_TEST_DIRNAME}/../../docs/adr/0002-ctrl-exec-enrolment-trust.md"
}

@test "a HELD node with no allocated IP binds to the API caller address" {
  sed -i "/^${MAC}|IP=/d" "$REG_FILE"
  held
  run ce_approve_pair_request "$MAC" abc123 10.0.0.50
  [ "$status" -eq 0 ]
  grep -q 'approve abc123' "$CE_LOG"
}

@test "a HELD node with no allocated IP and a caller address that differs from the request is refused" {
  sed -i "/^${MAC}|IP=/d" "$REG_FILE"
  held
  run ce_approve_pair_request "$MAC" abc123 10.0.0.99
  [ "$status" -ne 0 ]
  ! grep -q 'approve abc123' "$CE_LOG"
}

@test "a HELD node with no allocated IP and no caller address is refused" {
  sed -i "/^${MAC}|IP=/d" "$REG_FILE"
  held
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -ne 0 ]
}
