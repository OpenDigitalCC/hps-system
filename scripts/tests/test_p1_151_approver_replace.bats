#!/usr/bin/env bats
#
# CS-1.16: ce_approve_pair_request calls `approve <reqid> --replace` when the
# dispatcher's usage lists it (ctrl-exec 0.14.3+), plain `approve` otherwise;
# logs the replaced registration; refuses the same cases as before.

setup() {
  # CS-2.4: these tests drive the root path (dispatcher called directly); as a
  # non-root user the library goes through the job queue, tested in test_p2_61.
  id() { if [[ "${1:-}" == -u ]]; then echo 0; else command id "$@"; fi; }
  export -f id
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-151.XXXXXX")"
  export TEST_DIR
  export CTRL_EXEC_PAIRING_DIR="$TEST_DIR/pairing"
  mkdir -p "$CTRL_EXEC_PAIRING_DIR"
  export CTRL_EXEC_PAIR_WINDOW=300
  export CTRL_EXEC_PAIR_CLOSE_DELAY=0
  export CE_LOG="$TEST_DIR/ced.log"
  export CTRL_EXEC_DISPATCHER="$TEST_DIR/fake-ced"
  cat > "$CTRL_EXEC_DISPATCHER" <<'EOT'
#!/usr/bin/env bash
echo "$*" >> "$CE_LOG"
case "$1" in
  --help)
    echo "Usage: ctrl-exec-dispatcher <mode>"
    echo "  approve <reqid> [--lookup-by ip|hostname]"
    [[ -n "${FAKE_REPLACE:-}" ]] && echo "                             [--replace] also unpairs another agent"
    exit 1 ;;
  approve)
    echo "Approved ${2}"
    if [[ " $* " == *" --replace "* && -n "${FAKE_REPLACED_LINE:-}" ]]; then
      echo "$FAKE_REPLACED_LINE"
    fi
    exit "${FAKE_APPROVE_RC:-0}" ;;
esac
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
        printf '%s\n' "${line#*=}" ;;
      set) printf '%s|%s=%s\n' "$mac" "$key" "$value" >> "$REG_FILE" ;;
    esac
  }
  export -f hps_log host_registry
  source "${BATS_TEST_DIRNAME}/../../lib/functions.d/ctrl-exec-functions.sh"
  MAC="52:54:00:11:22:33"
  host_registry "$MAC" set IP "10.0.0.50"
  host_registry "$MAC" set HOSTNAME "node-50"
  host_registry "$MAC" set STATE NETWORK_BOOT
  host_registry "$MAC" set last_boot_at "$(( $(date +%s) - 30 ))"
  jq -n '{id:"abc123", hostname:"node-50.lab.example", source_ip:"10.0.0.50"}' \
    > "$CTRL_EXEC_PAIRING_DIR/abc123.json"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "uses approve --replace when the dispatcher supports it" {
  FAKE_REPLACE=1 run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 0 ]
  grep -qx 'approve abc123 --replace' "$CE_LOG"
  ! grep -qx 'approve abc123' "$CE_LOG"
  [ -n "$(host_registry "$MAC" get ctrl_exec_paired)" ]
}

@test "uses plain approve when the dispatcher has no --replace, and logs it" {
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 0 ]
  grep -qx 'approve abc123' "$CE_LOG"
  ! grep -q -- 'approve .*--replace' "$CE_LOG"
  grep -q 'no approve --replace' "$TEST_DIR/hps.log"
}

@test "an unpair REPLACED_BY line in the approve output is logged" {
  FAKE_REPLACE=1 FAKE_REPLACED_LINE='unpair AGENT=old-50 EXPIRY=2027-01-01 REPLACED_BY=node-50.lab.example' \
    run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 0 ]
  grep -q 'replaced registration: unpair AGENT=old-50 .*REPLACED_BY=node-50.lab.example' "$TEST_DIR/hps.log"
}

@test "no replaced line is logged when nothing was replaced" {
  FAKE_REPLACE=1 run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 0 ]
  ! grep -q 'replaced registration' "$TEST_DIR/hps.log"
}

@test "a failing approve is still a refusal (1) and records nothing" {
  FAKE_REPLACE=1 FAKE_APPROVE_RC=1 run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 1 ]
  run host_registry "$MAC" get ctrl_exec_paired
  [ "$status" -ne 0 ]
}

@test "refusals are unchanged: foreign IP, other hostname, bad reqid, bad state, stale window, repeat" {
  export FAKE_REPLACE=1
  jq -n '{id:"abc123", hostname:"node-50", source_ip:"10.0.0.99"}' > "$CTRL_EXEC_PAIRING_DIR/abc123.json"
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 1 ]
  jq -n '{id:"abc123", hostname:"nixos", source_ip:"10.0.0.50"}' > "$CTRL_EXEC_PAIRING_DIR/abc123.json"
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 1 ]
  jq -n '{id:"abc123", hostname:"node-50", source_ip:"10.0.0.50"}' > "$CTRL_EXEC_PAIRING_DIR/abc123.json"
  run ce_approve_pair_request "$MAC" 'abc;123'
  [ "$status" -eq 1 ]
  host_registry "$MAC" set STATE INSTALLED
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 1 ]
  host_registry "$MAC" set STATE NETWORK_BOOT
  host_registry "$MAC" set last_boot_at "$(( $(date +%s) - 400 ))"
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 1 ]
  host_registry "$MAC" set last_boot_at "$(date +%s)"
  host_registry "$MAC" set ctrl_exec_paired 1
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 1 ]
  ! grep -q '^approve' "$CE_LOG"
}
