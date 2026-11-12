#!/usr/bin/env bats
#
# Pairing resilience, node side (incident 2026-11-12): hps-pair acts on the
# IPS's answer. 503 retry with backoff within the window, 410 reboot into
# netboot, 403 stop (exit 3, which the units do not restart); every attempt is
# logged with the reason the IPS gave. The IPS answers come from a script
# (one line per POST: "<code> <reason> <window_left>").

bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-210.XXXXXX")"
  export TEST_DIR
  export SHIM_LOG="$TEST_DIR/shim.log"
  export HPS_CMDLINE="$TEST_DIR/cmdline"
  export HPS_AGENT_ETC="$TEST_DIR/etc/ctrl-exec-agent"
  export HPS_PAIR_TIMEOUT=4
  export HPS_PAIR_POLL=1
  export HPS_PAIR_BACKOFF="0 0 0"
  export HPS_PAIR_GRACE=0
  export HPS_UPTIME="$TEST_DIR/uptime"
  export ANSWERS="$TEST_DIR/answers"
  export TMPDIR="$TEST_DIR"
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PAIR="$ROOT/node-manager/nixos-26/boot/hps-pair.sh"
  export PATH="$TEST_DIR/bin:$PATH"
  mkdir -p "$TEST_DIR/bin" "$HPS_AGENT_ETC"
  echo "5.00 5.00" > "$HPS_UPTIME"
  echo "BOOT_IMAGE=bzImage hps.ips=10.99.1.1 hps.mac=aa:bb:cc:dd:ee:ff" > "$HPS_CMDLINE"

  # curl: the API answers from $ANSWERS, one line per POST (the last repeats).
  cat > "$TEST_DIR/bin/curl" <<'SHIM'
#!/usr/bin/env bash
echo "curl $*" >> "$SHIM_LOG"
case "$*" in
  *host_variable*) printf 'node01'; exit 0 ;;
esac
o=/dev/null; p=""
for x in "$@"; do [[ "$p" == -o ]] && o="$x"; p="$x"; done
n=$(cat "$TEST_DIR/posts" 2> /dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$TEST_DIR/posts"
line=$(sed -n "${n}p" "$ANSWERS")
[[ -n "$line" ]] || line=$(tail -n1 "$ANSWERS")
read -r code reason left <<< "$line"
[[ "$code" == 200 ]] && : > "$TEST_DIR/approved"
jq -n -c --arg r "$reason" --arg l "${left:-0}" '{reason: $r, details: "test", window_left: ($l | tonumber)}' > "$o"
printf '%s' "$code"
SHIM
  # agent: prints a reqid (a new one per request), waits for approval.
  cat > "$TEST_DIR/bin/ctrl-exec-agent" <<'SHIM'
#!/usr/bin/env bash
echo "ctrl-exec-agent $*" >> "$SHIM_LOG"
[[ "$1" == request-pairing && "${2:-}" == --help ]] && exit 0
k=$(cat "$TEST_DIR/reqs" 2> /dev/null || echo 0)
k=$((k + 1))
echo "$k" > "$TEST_DIR/reqs"
echo "abc${k}"
n=0
while [[ ! -e "$TEST_DIR/approved" && $n -lt 100 ]]; do sleep 0.1; n=$((n+1)); done
[[ -e "$TEST_DIR/approved" ]] || exit 2
echo cert > "$HPS_AGENT_ETC/agent.crt"
SHIM
  for s in hostnamectl hostname systemctl; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$SHIM_LOG"\nexit 0\n' "$s" > "$TEST_DIR/bin/$s"
  done
  chmod +x "$TEST_DIR"/bin/*
}

teardown() {
  pkill -f "$TEST_DIR/bin/ctrl-exec-agent" 2> /dev/null || true
  rm -rf "$TEST_DIR"
}

@test "1: 503 pending twice, then 200: retries with the same reqid and pairs" {
  printf '503 pending 200\n503 pending 190\n200 paired 180\n' > "$ANSWERS"
  run bash "$PAIR" --no-hostname
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_DIR/posts")" -eq 3 ]
  [ "$(grep -c '"reqid":"abc1"' "$SHIM_LOG")" -eq 3 ]
  [[ "$output" == *"attempt 1: reqid abc1: IPS answered 503 pending (test); 200s left in the window"* ]]
  [[ "$output" == *"attempt 3: reqid abc1: IPS answered 200 paired"* ]]
  grep -qx 'systemctl restart ctrl-exec-agent.service' "$SHIM_LOG"
}

@test "2: 410 outside_window: reboots into netboot (exit 0) and stops the request" {
  printf '410 outside_window 0\n' > "$ANSWERS"
  run bash "$PAIR" --no-hostname
  [ "$status" -eq 0 ]
  grep -qx 'systemctl reboot' "$SHIM_LOG"
  [[ "$output" == *"IPS answered 410 outside_window"* ]]
  [[ "$output" == *"rebooting into netboot"* ]]
  ! grep -q 'systemctl restart' "$SHIM_LOG"
}

@test "3: 403 refused: stops with exit 3, no reboot, no further attempt" {
  printf '403 reboots_exhausted 0\n' > "$ANSWERS"
  run bash "$PAIR" --no-hostname
  [ "$status" -eq 3 ]
  [ "$(cat "$TEST_DIR/posts")" -eq 1 ]
  [[ "$output" == *"refused pairing (reboots_exhausted)"* ]]
  ! grep -q '^systemctl' "$SHIM_LOG"
}

@test "4: 503 unknown_request: a new request-pairing, then its reqid is reported" {
  printf '503 unknown_request 200\n200 paired 190\n' > "$ANSWERS"
  run bash "$PAIR" --no-hostname
  [ "$status" -eq 0 ]
  grep -q '"reqid":"abc1"' "$SHIM_LOG"
  grep -q '"reqid":"abc2"' "$SHIM_LOG"
  [[ "$output" == *"requesting pairing again"* ]]
}

@test "5: no answer from the IPS counts as not yet; past the window and the grace it fails (1)" {
  printf '000 none 0\n' > "$ANSWERS"
  export HPS_PAIR_WINDOW=0
  run bash "$PAIR" --no-hostname
  [ "$status" -eq 1 ]
  [[ "$output" == *"no usable answer from the IPS (HTTP 000)"* ]]
  [[ "$output" == *"past the pairing window with no decision"* ]]
}

@test "6: the backoff is 5, 10, 20, 40, 60, 60 s by default, bounded by the window left" {
  unset HPS_PAIR_BACKOFF
  source <(sed -n '/^backoff_for()/,/^}/p' "$PAIR")
  HPS_PAIR_BACKOFF="5 10 20 40 60"
  [ "$(backoff_for 1) $(backoff_for 2) $(backoff_for 3) $(backoff_for 4) $(backoff_for 5) $(backoff_for 6) $(backoff_for 9)" = "5 10 20 40 60 60 60" ]
  grep -q ': "${HPS_PAIR_BACKOFF:=5 10 20 40 60}"' "$PAIR"
  # window_left 3 cuts a 60 s backoff to 4 s (the next ask lands just after it)
  printf '503 pending 3\n200 paired 0\n' > "$ANSWERS"
  HPS_PAIR_BACKOFF=60 run bash "$PAIR" --no-hostname
  [ "$status" -eq 0 ]
  [[ "$output" == *"attempt 1: next attempt in 4s"* ]]
}

@test "7: every attempt is logged with the code and the reason" {
  printf '503 pending 100\n503 no_request 90\n200 paired 80\n' > "$ANSWERS"
  run bash "$PAIR" --no-hostname
  [ "$status" -eq 0 ]
  [ "$(grep -c 'attempt [0-9]*: reqid .*IPS answered' <<< "$output")" -eq 3 ]
}

@test "8: the units do not restart on a refusal (exit 3); the pairing timeouts are aligned" {
  grep -q 'RestartPreventExitStatus = 3;' "$ROOT/nix/modules/hps-node.nix"
  grep -q 'RestartPreventExitStatus = 3;' "$ROOT/nix/modules/hps-audit.nix"
  node=$(sed -n 's/^: "${HPS_PAIR_TIMEOUT:=\([0-9]*\)}"$/\1/p' "$PAIR")
  ips=$(sed -n 's/^: "${CTRL_EXEC_PAIR_REQUEST_TIMEOUT:=\([0-9]*\)}"$/\1/p' "$ROOT/lib/functions.d/ctrl-exec-functions.sh")
  [ -n "$node" ]
  [ "$ips" -ge "$node" ]
}
