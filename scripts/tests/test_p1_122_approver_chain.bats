#!/usr/bin/env bats
#
# CS-1.12: ce_approve_pair_request
#  - calls `ctrl-exec-dispatcher approve <reqid>` with no --ip (0.14.1 refuses
#    the extra argument: "Too many arguments for subroutine mode_approve")
#  - compares the FIRST LABEL of the request hostname with the registry
#    HOSTNAME: the agent registers under an FQDN and a foreign domain (second
#    NIC on another LAN) or .lab.hps must not break the binding. The peer IP
#    binding is unchanged.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-122.XXXXXX")"
  export CTRL_EXEC_PAIRING_DIR="$TEST_DIR/pairing"
  mkdir -p "$CTRL_EXEC_PAIRING_DIR"
  export CTRL_EXEC_PAIR_WINDOW=300
  export CTRL_EXEC_PAIR_CLOSE_DELAY=0
  export CE_LOG="$TEST_DIR/ced.log"
  export CTRL_EXEC_DISPATCHER="$TEST_DIR/fake-ced"
  # behaves like 0.14.1: approve takes <reqid> only
  cat > "$CTRL_EXEC_DISPATCHER" <<SHIM
#!/usr/bin/env bash
echo "\$*" >> "$CE_LOG"
if [[ "\$1" == approve && \$# -gt 2 ]]; then
  echo "Too many arguments for subroutine 'main::mode_approve' (got \$#; expected at most 2)" >&2
  exit 255
fi
exit 0
SHIM
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
  host_registry "$MAC" set HOSTNAME "held01"
  host_registry "$MAC" set STATE HELD
  host_registry "$MAC" set last_boot_at "$(( $(date +%s) - 30 ))"
}

teardown() {
  rm -rf "$TEST_DIR"
}

request() {
  jq -n --arg h "$1" '{id:"abc123", hostname:$h, source_ip:"10.0.0.50"}' \
    > "$CTRL_EXEC_PAIRING_DIR/abc123.json"
}

@test "approve is called with the reqid alone" {
  request held01
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 0 ]
  grep -qx "approve abc123" "$CE_LOG"
}

@test "the approver source has no --ip on the approve call" {
  ! grep -n 'approve "\$reqid" --ip' "${BATS_TEST_DIRNAME}/../../lib/functions.d/ctrl-exec-functions.sh"
}

@test "a foreign-domain FQDN with the registry short name approves" {
  request held01.foreign.example
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 0 ]
}

@test "a .lab.hps FQDN approves" {
  request held01.lab.hps
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 0 ]
}

@test "a different first label is refused even with the same domain" {
  request other01.lab.hps
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 1 ]
  ! grep -q "^approve" "$CE_LOG" 2>/dev/null
}

@test "a registry FQDN compares by first label too" {
  host_registry "$MAC" set HOSTNAME "held01.lab.hps"
  request held01.foreign.example
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 0 ]
}

@test "the peer IP binding still refuses a wrong source address" {
  jq -n '{id:"abc123", hostname:"held01", source_ip:"10.0.0.99"}' > "$CTRL_EXEC_PAIRING_DIR/abc123.json"
  run ce_approve_pair_request "$MAC" abc123
  [ "$status" -eq 1 ]
  ! grep -q "^approve" "$CE_LOG" 2>/dev/null
}
