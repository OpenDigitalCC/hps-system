#!/usr/bin/env bats
#
# CS-1.16: hps-pair passes request-pairing --name <transient hostname> when the
# installed agent's usage text lists --name (ctrl-exec 0.14.3+), and omits it
# for an older agent.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-150.XXXXXX")"
  export TEST_DIR
  export SHIM_LOG="$TEST_DIR/shim.log"
  export HPS_CMDLINE="$TEST_DIR/cmdline"
  export HPS_AGENT_ETC="$TEST_DIR/etc/ctrl-exec-agent"
  export HPS_PAIR_TIMEOUT=4
  export HPS_PAIR_POLL=1
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PAIR="$ROOT/node-manager/nixos-26/boot/hps-pair.sh"
  export PATH="$TEST_DIR/bin:$PATH"
  mkdir -p "$TEST_DIR/bin" "$HPS_AGENT_ETC"
  echo "BOOT_IMAGE=bzImage hps.ips=10.99.1.1 hps.mac=aa:bb:cc:dd:ee:ff hps.profile=audit" > "$HPS_CMDLINE"

  cat > "$TEST_DIR/bin/curl" <<'SHIM'
#!/usr/bin/env bash
echo "curl $*" >> "$SHIM_LOG"
case "$*" in
  *host_variable*) printf 'held01' ;;
  */api/api.sh*)
    : > "$TEST_DIR/approved"
    echo '{"success":true}' ;;
esac
exit 0
SHIM
  cat > "$TEST_DIR/bin/ctrl-exec-agent" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  request-pairing)
    if [[ "$*" == *--help* ]]; then
      # an unknown option: the agent prints its usage and fails
      echo "probe: $*" >> "$SHIM_LOG"
      echo "Usage: ctrl-exec-agent request-pairing --dispatcher <host> [--rekey]"
      [[ -n "${FAKE_AGENT_NAME:-}" ]] && echo "  --name <name>   the name to register under"
      exit 1
    fi
    echo "ctrl-exec-agent $*" >> "$SHIM_LOG"
    echo "deadbeef"
    n=0
    while [[ ! -e "$TEST_DIR/approved" && $n -lt 80 ]]; do sleep 0.1; n=$((n+1)); done
    [[ -e "$TEST_DIR/approved" ]] || exit 2
    echo cert > "$HPS_AGENT_ETC/agent.crt"
    exit 0 ;;
esac
SHIM
  for s in hostnamectl hostname systemctl; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$SHIM_LOG"\nexit 0\n' "$s" > "$TEST_DIR/bin/$s"
  done
  chmod +x "$TEST_DIR"/bin/*
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "passes --name with the exact transient hostname when the agent supports it" {
  FAKE_AGENT_NAME=1 run bash "$PAIR"
  [ "$status" -eq 0 ]
  grep -qx 'ctrl-exec-agent request-pairing --background --timeout 4 --dispatcher 10.99.1.1 --name held01' "$SHIM_LOG"
  [[ "$output" == *"agent supports --name"* ]]
}

@test "--name carries <label>.<hps.domain> when the command line has a domain" {
  echo "hps.ips=10.99.1.1 hps.mac=aa:bb:cc:dd:ee:ff hps.domain=lab.example" > "$HPS_CMDLINE"
  FAKE_AGENT_NAME=1 run bash "$PAIR"
  [ "$status" -eq 0 ]
  grep -qx 'hostnamectl set-hostname held01.lab.example' "$SHIM_LOG"
  grep -qx 'ctrl-exec-agent request-pairing --background --timeout 4 --dispatcher 10.99.1.1 --name held01.lab.example' "$SHIM_LOG"
}

@test "omits --name for an agent whose usage does not list it, and says so" {
  run bash "$PAIR"
  [ "$status" -eq 0 ]
  grep -qx 'ctrl-exec-agent request-pairing --background --timeout 4 --dispatcher 10.99.1.1' "$SHIM_LOG"
  [[ "$output" == *"no request-pairing --name"* ]]
}

@test "--no-hostname passes no --name (no name was chosen) and does not probe" {
  FAKE_AGENT_NAME=1 run bash "$PAIR" --no-hostname
  [ "$status" -eq 0 ]
  grep -qx 'ctrl-exec-agent request-pairing --background --timeout 4 --dispatcher 10.99.1.1' "$SHIM_LOG"
  ! grep -q '^probe' "$SHIM_LOG"
}
