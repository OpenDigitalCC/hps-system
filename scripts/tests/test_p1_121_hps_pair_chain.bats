#!/usr/bin/env bats
#
# CS-1.12: pairing-chain fixes from the third DL360 boot (hps-pair.sh).
#  - a hostname the registry did not really return (an error body) is never
#    set: it is validated, the first label only, else hps-<mac12>
#  - request-pairing runs in the background and the reqid is POSTed to the IPS
#    before approval (the old $(...) blocked until approval: a deadlock)
#  - a request-pairing that exits non-zero before a reqid is a failure

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-121.XXXXXX")"
  export TEST_DIR
  export SHIM_LOG="$TEST_DIR/shim.log"
  export HPS_CMDLINE="$TEST_DIR/cmdline"
  export HPS_AGENT_ETC="$TEST_DIR/etc/ctrl-exec-agent"
  export HPS_PAIR_TIMEOUT=6
  export HPS_PAIR_POLL=1
  # hps-pair's window: over at once (no retry waits; a 503 ends the run)
  export HPS_PAIR_BACKOFF=0 HPS_PAIR_GRACE=0 HPS_PAIR_WINDOW=0
  export HPS_UPTIME="$TEST_DIR/uptime"
  export TMPDIR="$TEST_DIR"
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PAIR="$ROOT/node-manager/nixos-26/boot/hps-pair.sh"
  export PATH="$TEST_DIR/bin:$PATH"
  mkdir -p "$TEST_DIR/bin" "$HPS_AGENT_ETC"
  echo "5.00 5.00" > "$HPS_UPTIME"
  echo "BOOT_IMAGE=bzImage hps.ips=10.99.1.1 hps.mac=aabbccddeeff hps.profile=audit" > "$HPS_CMDLINE"

  cat > "$TEST_DIR/bin/curl" <<'SHIM'
#!/usr/bin/env bash
echo "curl $*" >> "$SHIM_LOG"
case "$*" in
  *host_variable*)
    printf '%s' "${FAKE_HOSTNAME_BODY-held01}" ;;
  */api/api.sh*)
    o=/dev/null; p=""; nr=0
    for x in "$@"; do
      [[ "$p" == -o ]] && o="$x"
      [[ "$p" == -d && "$x" == *'"reqid":""'* ]] && nr=1
      p="$x"
    done
    if [[ $nr -eq 1 ]]; then printf '{"reason":"no_request"}' > "$o"; printf 503; exit 0; fi
    echo "ips: reqid POSTed" >> "$SHIM_LOG"
    c="${FAKE_API_CODE:-200}"
    [[ "$c" == 200 ]] && : > "$TEST_DIR/approved"   # the IPS approves once it has the reqid
    printf '{"success":true,"reason":"%s"}' "${FAKE_API_REASON:-paired}" > "$o"
    printf '%s' "$c" ;;
esac
exit 0
SHIM
  # Prints the reqid, then (like the real agent's child) waits for approval.
  # Approval exists only after the POST, so a reqid that is never POSTed
  # makes it time out (exit 2, no certificate).
  cat > "$TEST_DIR/bin/ctrl-exec-agent" <<'SHIM'
#!/usr/bin/env bash
echo "ctrl-exec-agent $*" >> "$SHIM_LOG"
[[ "${FAKE_PAIRING_RC:-0}" -ne 0 ]] && exit "$FAKE_PAIRING_RC"
[[ -n "${FAKE_NO_REQID:-}" ]] && exit 0
echo "ab12cd"
n=0
while [[ ! -e "$TEST_DIR/approved" && $n -lt 100 ]]; do sleep 0.1; n=$((n+1)); done
[[ -e "$TEST_DIR/approved" ]] || { echo "agent: never approved" >> "$SHIM_LOG"; exit 2; }
echo "agent: approved" >> "$SHIM_LOG"
echo cert > "$HPS_AGENT_ETC/agent.crt"
SHIM
  for s in hostnamectl hostname systemctl; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$SHIM_LOG"\nexit 0\n' "$s" > "$TEST_DIR/bin/$s"
  done
  chmod +x "$TEST_DIR"/bin/*
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "an error body from the registry is not set as the hostname: hps-<mac12> instead" {
  FAKE_HOSTNAME_BODY="Key 'HOSTNAME' not found" run bash "$PAIR"
  [ "$status" -eq 0 ]
  grep -qx 'hostnamectl set-hostname --transient hps-aabbccddeeff' "$SHIM_LOG"
  ! grep -q "Key 'HOSTNAME'" <(grep '^hostnamectl' "$SHIM_LOG")
}

@test "an empty registry answer falls back to hps-<mac12>" {
  FAKE_HOSTNAME_BODY="" run bash "$PAIR"
  [ "$status" -eq 0 ]
  grep -qx 'hostnamectl set-hostname --transient hps-aabbccddeeff' "$SHIM_LOG"
}

@test "an FQDN from the registry is cut to its first label" {
  FAKE_HOSTNAME_BODY="held01.lab.hps" run bash "$PAIR"
  [ "$status" -eq 0 ]
  grep -qx 'hostnamectl set-hostname --transient held01' "$SHIM_LOG"
}

@test "invalid labels are refused: leading hyphen, underscore, shell text, 64 chars" {
  for bad in "-held" "a_b" 'a;b' "$(printf 'a%.0s' $(seq 1 64))"; do
    : > "$SHIM_LOG"
    rm -f "$TEST_DIR/approved" "$HPS_AGENT_ETC/agent.crt"
    FAKE_HOSTNAME_BODY="$bad" run bash "$PAIR"
    [ "$status" -eq 0 ]
    grep -qx 'hostnamectl set-hostname --transient hps-aabbccddeeff' "$SHIM_LOG"
  done
}

@test "a 63-char label and a digit-first label are accepted" {
  label="$(printf 'a%.0s' $(seq 1 63))"
  FAKE_HOSTNAME_BODY="$label" run bash "$PAIR"
  [ "$status" -eq 0 ]
  grep -qx "hostnamectl set-hostname --transient $label" "$SHIM_LOG"
  : > "$SHIM_LOG"
  rm -f "$TEST_DIR/approved" "$HPS_AGENT_ETC/agent.crt"
  FAKE_HOSTNAME_BODY="7node" run bash "$PAIR"
  grep -qx 'hostnamectl set-hostname --transient 7node' "$SHIM_LOG"
}

@test "the reqid is POSTed to the IPS before the agent is approved (no deadlock)" {
  run bash "$PAIR"
  [ "$status" -eq 0 ]
  post="$(grep -n '^ips: reqid POSTed' "$SHIM_LOG" | head -1 | cut -d: -f1)"
  appr="$(grep -n '^agent: approved' "$SHIM_LOG" | head -1 | cut -d: -f1)"
  [ -n "$post" ]
  [ -n "$appr" ]
  [ "$post" -lt "$appr" ]
  grep -qx 'systemctl restart ctrl-exec-agent.service' "$SHIM_LOG"
}

@test "the POSTed body carries the reqid the agent printed" {
  run bash "$PAIR"
  [ "$status" -eq 0 ]
  grep -q '^curl .*-d {"action":"ctrl_exec_pair_request","mac":"aabbccddeeff","reqid":"ab12cd"}' "$SHIM_LOG"
}

@test "request-pairing exiting non-zero before a reqid is a failure, no reqid is POSTed" {
  FAKE_PAIRING_RC=3 run bash "$PAIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no reqid"* ]]
  ! grep -q '"reqid":"[0-9a-f]' "$SHIM_LOG"
}

@test "request-pairing exiting 0 without printing a reqid is a failure too" {
  FAKE_NO_REQID=1 run bash "$PAIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no reqid"* ]]
  ! grep -q '"reqid":"[0-9a-f]' "$SHIM_LOG"
}

@test "a pairing that is never approved times out and the agent process is stopped" {
  # the IPS refuses, so the shim is never approved
  export FAKE_API_CODE=403
  run bash "$PAIR"
  [ "$status" -eq 3 ]
  [[ "$output" == *"refused pairing"* ]]
  sleep 1
  ! pgrep -f "$TEST_DIR/bin/ctrl-exec-agent" > /dev/null
}

@test "the temp file for the reqid is removed" {
  run bash "$PAIR"
  [ "$status" -eq 0 ]
  ! ls "$TEST_DIR"/hps-pair-*.out
}
