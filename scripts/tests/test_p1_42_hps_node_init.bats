#!/usr/bin/env bats
#
# node-manager/nixos-26/boot/hps-node-init.sh with shims for curl, ip,
# hostnamectl, hostname, systemctl and ctrl-exec-agent. Proves: hostname from
# the registry (fallback hps-<mac>), the bundle fetch + n_init_run compat
# call, and the pairing request + report in the n_api_call shape. Pairing
# itself lives in boot/hps-pair.sh (shared with the audit image); hps-node-init
# runs it with --no-hostname, so these tests drive both scripts together.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-42.XXXXXX")"
  export TEST_DIR
  export SHIM_LOG="$TEST_DIR/shim.log"
  export HPS_CMDLINE="$TEST_DIR/cmdline"
  export HPS_RUN_DIR="$TEST_DIR/run/hps"
  export HPS_AGENT_ETC="$TEST_DIR/etc/ctrl-exec-agent"
  export HPS_PAIR_TIMEOUT=4
  export HPS_PAIR_POLL=1
  export FAKE_BUNDLE="$TEST_DIR/bundle.sh"
  export BUNDLE_LOG="$TEST_DIR/bundle.log"
  INIT="${BATS_TEST_DIRNAME}/../../node-manager/nixos-26/boot/hps-node-init.sh"
  export HPS_PAIR="${BATS_TEST_DIRNAME}/../../node-manager/nixos-26/boot/hps-pair.sh"
  export PATH="$TEST_DIR/bin:$PATH"
  mkdir -p "$TEST_DIR/bin" "$HPS_AGENT_ETC"

  echo "BOOT_IMAGE=bzImage initrd=initrd hps.ips=10.99.1.1 hps.mac=aa:bb:cc:dd:ee:ff hps.profile=converged" > "$HPS_CMDLINE"
  cat > "$FAKE_BUNDLE" <<'EOF'
# fake node function bundle
n_init_run() { echo "n_init_run ran" >> "$BUNDLE_LOG"; return "${FAKE_INIT_RC:-0}"; }
EOF

  # curl: host_variable -> hostname, get_remote_functions -> bundle, api.sh -> ok
  cat > "$TEST_DIR/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$SHIM_LOG"
out=""
prev=""
for a in "$@"; do
  [[ "$prev" == "-o" ]] && out="$a"
  [[ "$prev" == "-d" ]] && echo "body $a" >> "$SHIM_LOG"
  prev="$a"
done
case "$*" in
  *host_variable*)
    [[ "${FAKE_HOSTNAME_RC:-0}" -ne 0 ]] && exit "$FAKE_HOSTNAME_RC"
    printf 'node01' ;;
  *get_remote_functions*)
    [[ "${FAKE_BUNDLE_RC:-0}" -ne 0 ]] && exit "$FAKE_BUNDLE_RC"
    cat "$FAKE_BUNDLE" > "$out" ;;
  */api/api.sh*)
    [[ "${FAKE_API_RC:-0}" -ne 0 ]] && exit "$FAKE_API_RC"
    echo '{"success":true,"data":{"paired":true}}' ;;
esac
exit 0
EOF
  cat > "$TEST_DIR/bin/ctrl-exec-agent" <<'EOF'
#!/bin/bash
echo "ctrl-exec-agent $*" >> "$SHIM_LOG"
case "$1" in
  request-pairing)
    echo "${FAKE_REQID:-deadbeef}"
    if [[ -z "${FAKE_NO_CERT:-}" ]]; then
      ( sleep 1; echo cert > "$HPS_AGENT_ETC/agent.crt" ) &
    fi ;;
esac
EOF
  cat > "$TEST_DIR/bin/ip" <<'EOF'
#!/bin/bash
echo "ip $*" >> "$SHIM_LOG"
route='[{"dst":"default","gateway":"10.99.1.254","dev":"eno1"}]'
[[ -n "${FAKE_ROUTE:-}" ]] && route="$FAKE_ROUTE"
case "$*" in
  *route*) echo "$route" ;;
  *link*) echo '[{"ifname":"eno1","address":"11:22:33:44:55:66"}]' ;;
esac
EOF
  for s in hostnamectl hostname systemctl; do
    printf '#!/bin/bash\necho "%s $*" >> "$SHIM_LOG"\nexit "${FAKE_%s_RC:-0}"\n' "$s" "$(echo "$s" | tr a-z A-Z)" > "$TEST_DIR/bin/$s"
  done
  chmod +x "$TEST_DIR"/bin/*
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "sets the transient hostname from the registry HOSTNAME" {
  run bash "$INIT"
  [ "$status" -eq 0 ]
  grep -q 'curl .*boot_manager.sh?cmd=host_variable&name=HOSTNAME' "$SHIM_LOG"
  grep -qx 'hostnamectl set-hostname node01' "$SHIM_LOG"
}

@test "falls back to hps-<mac> when the registry has no HOSTNAME" {
  FAKE_HOSTNAME_RC=22 run bash "$INIT"
  [ "$status" -eq 0 ]
  grep -qx 'hostnamectl set-hostname hps-aabbccddeeff' "$SHIM_LOG"
}

@test "falls back to hostname(1) when hostnamectl fails" {
  FAKE_HOSTNAMECTL_RC=1 run bash "$INIT"
  [ "$status" -eq 0 ]
  grep -qx 'hostname node01' "$SHIM_LOG"
}

@test "fetches the bundle to /run/hps/functions.sh, runs n_init_run and records the profile" {
  run bash "$INIT"
  [ "$status" -eq 0 ]
  grep -q 'curl .*cmd=get_remote_functions -o '"$HPS_RUN_DIR"'/functions.sh' "$SHIM_LOG"
  cmp "$HPS_RUN_DIR/functions.sh" "$FAKE_BUNDLE"
  grep -qx 'n_init_run ran' "$BUNDLE_LOG"
  [ "$(cat "$HPS_RUN_DIR/profile")" = "converged" ]
}

@test "a failing bundle init or bundle fetch is logged and pairing still happens" {
  FAKE_INIT_RC=3 run bash "$INIT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bundle init exited 3"* ]]
  grep -q '^ctrl-exec-agent request-pairing' "$SHIM_LOG"

  : > "$SHIM_LOG"
  rm -f "$HPS_AGENT_ETC/agent.crt"
  FAKE_BUNDLE_RC=22 run bash "$INIT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bundle fetch failed"* ]]
  grep -q '^ctrl-exec-agent request-pairing' "$SHIM_LOG"
}

@test "requests pairing from the IPS and reports the reqid in the n_api_call shape" {
  FAKE_REQID="ab12cd" run bash "$INIT"
  [ "$status" -eq 0 ]
  grep -qx 'ctrl-exec-agent request-pairing --background --timeout 4 --dispatcher 10.99.1.1' "$SHIM_LOG"
  grep -q '^curl .*-X POST .*-H X-HPS-MAC: aa:bb:cc:dd:ee:ff .*http://10.99.1.1/api/api.sh$' "$SHIM_LOG"
  body="$(grep '^body ' "$SHIM_LOG" | sed 's/^body //')"
  echo "$body" | jq -e '.action == "ctrl_exec_pair_request" and .mac == "aa:bb:cc:dd:ee:ff" and .reqid == "ab12cd"'
  grep -qx 'systemctl restart ctrl-exec-agent.service' "$SHIM_LOG"
  [[ "$output" == *"paired (certificate received)"* ]]
}

@test "strips non-hex characters from the reqid before reporting" {
  FAKE_REQID=$'ab12cd\n; rm -rf /' run bash "$INIT"
  [ "$status" -eq 0 ]
  body="$(grep '^body ' "$SHIM_LOG" | sed 's/^body //')"
  echo "$body" | jq -e '.reqid == "ab12cd"'
  ! grep -q 'rm -rf' "$SHIM_LOG"
}

@test "fails when no certificate arrives within the timeout" {
  FAKE_NO_CERT=1 run bash "$INIT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"pairing timed out"* ]]
  ! grep -q '^systemctl restart' "$SHIM_LOG"
}

@test "fails when the IPS declines the pairing report" {
  FAKE_API_RC=22 run bash "$INIT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"declined"* ]]
}

@test "skips pairing when a certificate is already present" {
  echo existing > "$HPS_AGENT_ETC/agent.crt"
  run bash "$INIT"
  [ "$status" -eq 0 ]
  ! grep -q '^ctrl-exec-agent' "$SHIM_LOG"
  ! grep -q 'api/api.sh' "$SHIM_LOG"
}

@test "falls back to the default gateway and route interface MAC when hps.ips/hps.mac are absent" {
  echo "console=ttyS0 hps.profile=converged" > "$HPS_CMDLINE"
  run bash "$INIT"
  [ "$status" -eq 0 ]
  grep -q 'http://10.99.1.254/cgi-bin/boot_manager.sh?cmd=host_variable' "$SHIM_LOG"
  grep -q 'X-HPS-MAC: 11:22:33:44:55:66' "$SHIM_LOG"
}

@test "fails early when no IPS address can be found" {
  echo "console=ttyS0" > "$HPS_CMDLINE"
  FAKE_ROUTE='[]' run bash "$INIT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no IPS address"* ]]
  ! grep -q '^curl' "$SHIM_LOG"
}

@test "logs every command as it runs" {
  run bash "$INIT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ curl -fsS http://10.99.1.1/cgi-bin/boot_manager.sh?cmd=host_variable&name=HOSTNAME"* ]]
  [[ "$output" == *"+ hostnamectl set-hostname node01"* ]]
  [[ "$output" == *"+ ctrl-exec-agent request-pairing"* ]]
  [[ "$output" == *"+ systemctl restart ctrl-exec-agent.service"* ]]
}

@test "hps-node-init hands pairing to hps-pair --no-hostname and does not repeat the hostname step" {
  run bash "$INIT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ bash $HPS_PAIR --no-hostname"* ]]
  [ "$(grep -c '^hostnamectl' "$SHIM_LOG")" -eq 1 ]
}
