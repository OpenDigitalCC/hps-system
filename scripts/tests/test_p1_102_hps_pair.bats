#!/usr/bin/env bats
#
# CS-1.10: node-manager/nixos-26/boot/hps-pair.sh, the pairing step shared by
# the node image (called from hps-node-init) and the audit image (oneshot
# hps-audit-pair). Proves: exit 0 at once when agent.crt exists, the request /
# report / wait / restart sequence, the hostname step (and --no-hostname), the
# failure modes, and that both units call it (Nix source grep).

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-102.XXXXXX")"
  export TEST_DIR
  export SHIM_LOG="$TEST_DIR/shim.log"
  export HPS_CMDLINE="$TEST_DIR/cmdline"
  export HPS_AGENT_ETC="$TEST_DIR/etc/ctrl-exec-agent"
  export HPS_PAIR_TIMEOUT=4
  export HPS_PAIR_POLL=1
  # hps-pair's window: over at once (no retry waits; a 503 ends the run)
  export HPS_PAIR_BACKOFF=0 HPS_PAIR_GRACE=0 HPS_PAIR_WINDOW=0
  export HPS_UPTIME="$TEST_DIR/uptime"
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PAIR="$ROOT/node-manager/nixos-26/boot/hps-pair.sh"
  export PATH="$TEST_DIR/bin:$PATH"
  mkdir -p "$TEST_DIR/bin" "$HPS_AGENT_ETC"
  echo "5.00 5.00" > "$HPS_UPTIME"
  echo "BOOT_IMAGE=bzImage hps.ips=10.99.1.1 hps.mac=aa:bb:cc:dd:ee:ff hps.profile=audit" > "$HPS_CMDLINE"

  cat > "$TEST_DIR/bin/curl" <<'SHIM'
#!/usr/bin/env bash
echo "curl $*" >> "$SHIM_LOG"
prev=""
for a in "$@"; do
  [[ "$prev" == "-d" ]] && echo "body $a" >> "$SHIM_LOG"
  prev="$a"
done
case "$*" in
  *host_variable*)
    [[ "${FAKE_HOSTNAME_RC:-0}" -ne 0 ]] && exit "$FAKE_HOSTNAME_RC"
    printf 'held01' ;;
  */api/api.sh*)
    o=/dev/null; p=""; nr=0
    for x in "$@"; do
      [[ "$p" == -o ]] && o="$x"
      [[ "$p" == -d && "$x" == *'"reqid":""'* ]] && nr=1
      p="$x"
    done
    if [[ $nr -eq 1 ]]; then printf '{"reason":"no_request"}' > "$o"; printf 503; exit 0; fi
    c="${FAKE_API_CODE:-200}"
    [[ "$c" == 200 ]] && : > "$TEST_DIR/approved"   # the IPS approves once it has the reqid
    printf '{"success":true,"reason":"%s"}' "${FAKE_API_REASON:-paired}" > "$o"
    printf '%s' "$c" ;;
esac
exit 0
SHIM
  cat > "$TEST_DIR/bin/ctrl-exec-agent" <<'SHIM'
#!/usr/bin/env bash
echo "ctrl-exec-agent $*" >> "$SHIM_LOG"
case "$1" in
  request-pairing)
    [[ "${FAKE_PAIRING_RC:-0}" -ne 0 ]] && exit "$FAKE_PAIRING_RC"
    echo "${FAKE_REQID:-deadbeef}"
    # like the real agent: stay running until the IPS approves (CS-1.12)
    n=0
    while [[ ! -e "$TEST_DIR/approved" && $n -lt 80 ]]; do sleep 0.1; n=$((n+1)); done
    [[ -e "$TEST_DIR/approved" ]] || exit 2
    echo "agent approved" >> "$SHIM_LOG"
    [[ -z "${FAKE_NO_CERT:-}" ]] && echo cert > "$HPS_AGENT_ETC/agent.crt"
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

@test "exits 0 at once when agent.crt exists: no request, no report, no restart" {
  echo existing > "$HPS_AGENT_ETC/agent.crt"
  run bash "$PAIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already present"* ]]
  [ ! -s "$SHIM_LOG" ]
}

@test "is idempotent: a second run after a successful pairing does nothing more" {
  run bash "$PAIR"
  [ "$status" -eq 0 ]
  : > "$SHIM_LOG"
  run bash "$PAIR"
  [ "$status" -eq 0 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "sets the registry hostname, requests pairing, reports the reqid, waits, restarts the agent" {
  FAKE_REQID=ab12cd run bash "$PAIR"
  [ "$status" -eq 0 ]
  grep -qx 'hostnamectl set-hostname --transient held01' "$SHIM_LOG"
  grep -qx 'ctrl-exec-agent request-pairing --background --timeout 4 --dispatcher 10.99.1.1' "$SHIM_LOG"
  grep -q '^curl .*-X POST .*-H X-HPS-MAC: aa:bb:cc:dd:ee:ff .*http://10.99.1.1/api/api.sh$' "$SHIM_LOG"
  body="$(grep '^body ' "$SHIM_LOG" | sed 's/^body //')"
  echo "$body" | jq -e '.action == "ctrl_exec_pair_request" and .mac == "aa:bb:cc:dd:ee:ff" and .reqid == "ab12cd"'
  grep -qx 'systemctl restart ctrl-exec-agent.service' "$SHIM_LOG"
  # the hostname is set before pairing is requested
  [ "$(grep -n '^hostnamectl' "$SHIM_LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n '^ctrl-exec-agent' "$SHIM_LOG" | head -1 | cut -d: -f1)" ]
}

@test "falls back to hps-<mac> when the registry has no HOSTNAME" {
  FAKE_HOSTNAME_RC=22 run bash "$PAIR"
  [ "$status" -eq 0 ]
  grep -qx 'hostnamectl set-hostname --transient hps-aabbccddeeff' "$SHIM_LOG"
}

@test "--no-hostname leaves the hostname alone and does not ask the registry for it" {
  run bash "$PAIR" --no-hostname
  [ "$status" -eq 0 ]
  ! grep -q '^hostnamectl' "$SHIM_LOG"
  ! grep -q 'host_variable' "$SHIM_LOG"
  grep -q '^ctrl-exec-agent request-pairing' "$SHIM_LOG"
}

@test "an unknown argument is a usage error (2)" {
  run bash "$PAIR" --bogus
  [ "$status" -eq 2 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "falls back to the default gateway and route-interface MAC" {
  echo "console=ttyS0" > "$HPS_CMDLINE"
  printf '#!/usr/bin/env bash\ncase "$*" in\n  *route*) echo %s ;;\n  *link*) echo %s ;;\nesac\n' \
    "'[{\"dst\":\"default\",\"gateway\":\"10.99.1.254\",\"dev\":\"eno1\"}]'" \
    "'[{\"address\":\"11:22:33:44:55:66\"}]'" > "$TEST_DIR/bin/ip"
  chmod +x "$TEST_DIR/bin/ip"
  run bash "$PAIR"
  [ "$status" -eq 0 ]
  grep -q 'http://10.99.1.254/api/api.sh' "$SHIM_LOG"
  grep -q 'X-HPS-MAC: 11:22:33:44:55:66' "$SHIM_LOG"
}

@test "no IPS address: fails (1) before any request" {
  echo "console=ttyS0" > "$HPS_CMDLINE"
  printf '#!/usr/bin/env bash\necho "[]"\n' > "$TEST_DIR/bin/ip"
  chmod +x "$TEST_DIR/bin/ip"
  run bash "$PAIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no IPS address"* ]]
  ! grep -q '^ctrl-exec-agent' "$SHIM_LOG"
}

@test "fails (1) when request-pairing fails: no reqid is reported, the IPS is only asked whether to go on" {
  FAKE_PAIRING_RC=1 run bash "$PAIR"
  [ "$status" -eq 1 ]
  ! grep -q '"reqid":"[0-9a-f]' "$SHIM_LOG"
  grep -q '"reqid":""' "$SHIM_LOG"
}

@test "stops (3) when the IPS refuses the report (403)" {
  FAKE_API_CODE=403 FAKE_API_REASON=refused run bash "$PAIR"
  [ "$status" -eq 3 ]
  [[ "$output" == *"refused pairing"* ]]
  ! grep -q '^systemctl' "$SHIM_LOG"
}

@test "fails (1) when no certificate arrives within the timeout" {
  FAKE_NO_CERT=1 run bash "$PAIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"pairing timed out"* ]]
  ! grep -q '^systemctl' "$SHIM_LOG"
}

@test "logs every command as it runs" {
  run bash "$PAIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ ctrl-exec-agent request-pairing"* ]]
  [[ "$output" == *"+ systemctl restart ctrl-exec-agent.service"* ]]
}

@test "hps-node-init calls hps-pair and carries no pairing code of its own" {
  grep -q 'bash "\$HPS_PAIR" --no-hostname' "$ROOT/node-manager/nixos-26/boot/hps-node-init.sh"
  ! grep -q 'request-pairing' "$ROOT/node-manager/nixos-26/boot/hps-node-init.sh"
}

@test "the audit image runs hps-audit-pair after hps-audit; the node image gets hps-pair via hps-node-init" {
  grep -q 'systemd.services.hps-audit-pair' "$ROOT/nix/modules/hps-audit.nix"
  grep -q 'after = \[ "hps-audit.service"' "$ROOT/nix/modules/hps-audit.nix"
  grep -q 'ExecStart = "${pkgs.bash}/bin/bash /etc/hps/hps-pair"' "$ROOT/nix/modules/hps-audit.nix"
  grep -q 'environment.etc."hps/hps-pair"' "$ROOT/nix/modules/hps-ctrl-exec.nix"
  grep -q 'node-manager/nixos-26/boot/hps-pair.sh' "$ROOT/nix/modules/hps-ctrl-exec.nix"
  grep -q 'imports = \[ ./hps-ctrl-exec.nix ./hps-monitor.nix \]' "$ROOT/nix/modules/hps-node.nix"
  grep -q 'imports = \[ ./hps-ctrl-exec.nix \]' "$ROOT/nix/modules/hps-audit.nix"
  # the agent config lives only in the shared module
  ! grep -q 'services.ctrl-exec-agent = {' "$ROOT/nix/modules/hps-node.nix"
}

@test "the shared module allowlists hps-node and the four node scripts, each file present" {
  for s in storage-pool-inspect storage-disks node-dmesg node-facts; do
    grep -q "$s.source = mkScript \"$s\" (scriptsDir + \"/$s\")" "$ROOT/nix/modules/hps-ctrl-exec.nix"
    [ -x "$ROOT/node-manager/nixos-26/scripts/$s" ]
  done
  grep -q 'hps-node.source = mkScript "hps-node" ../../node-manager/plugins/hps-node/hps-node.sh' "$ROOT/nix/modules/hps-ctrl-exec.nix"
  grep -q 'scriptPath' "$ROOT/nix/modules/hps-ctrl-exec.nix"
  grep -q 'openFirewall = true' "$ROOT/nix/modules/hps-ctrl-exec.nix"
}
