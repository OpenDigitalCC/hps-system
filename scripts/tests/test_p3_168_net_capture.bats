#!/usr/bin/env bats
#
# net-capture (scale test isolation): read-only, bounded frame summary on a
# bridge, bridge port or VLAN interface. ip, tcpdump and timeout are shims.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="$ROOT/node-manager/nixos-26/scripts/net-capture"
  T="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-168.XXXXXX")"
  mkdir -p "$T/bin"
  export SHIM_LOG="$T/calls.log"
  cat > "$T/bin/ip" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"dev br-fab"*) echo '9: br-fab: <BROADCAST> mtu 9000 qdisc noqueue bridge forward_delay 1500 vlan_filtering 1' ;;
  *"dev vnet3"*) echo '12: vnet3: <BROADCAST> mtu 9000 master br-fab bridge_slave state forwarding' ;;
  *"dev eno49"*) echo '2: eno49: <BROADCAST> mtu 1500 qdisc mq master br-prov' ;;
  *) exit 1 ;;
esac
SH
  cat > "$T/bin/tcpdump" <<'SH'
#!/usr/bin/env bash
printf 'tcpdump %s\n' "$*" >> "$SHIM_LOG"
[[ -n "${FAKE_FRAMES:-}" ]] && printf '%s\n' "$FAKE_FRAMES"
exit 0
SH
  cat > "$T/bin/timeout" <<'SH'
#!/usr/bin/env bash
printf 'timeout %s\n' "$1" >> "$SHIM_LOG"
shift
"$@"
SH
  chmod +x "$T/bin/ip" "$T/bin/tcpdump" "$T/bin/timeout"
  export PATH="$T/bin:$PATH"
}

teardown() {
  rm -rf "$T"
}

@test "a tap port: bounded tcpdump with link headers and the DHCP filter by default; a count line" {
  FAKE_FRAMES='52:54:00:00:00:01 > ff:ff:ff:ff:ff:ff, ethertype IPv4, length 342: 0.0.0.0.68 > 255.255.255.255.67: BOOTP/DHCP, Request' run -0 bash "$SCRIPT" vnet3 10
  grep -q '^timeout 10$' "$SHIM_LOG"
  grep -q '^tcpdump -i vnet3 -e -nn -l -c 200 udp port 67 or udp port 68' "$SHIM_LOG"
  [[ "$output" == *"BOOTP/DHCP, Request"* ]]
  [[ "$output" == *"CAPTURE vnet3 seconds=10 frames=1"* ]]
}

@test "nothing seen is frames=0" {
  run -0 bash "$SCRIPT" br-fab 5 all
  [[ "$output" == *"CAPTURE br-fab seconds=5 frames=0"* ]]
  grep -q '^tcpdump -i br-fab -e -nn -l -c 200 *$' "$SHIM_LOG"
}

@test "a physical NIC, an unknown interface and bad arguments are refused" {
  run -3 bash "$SCRIPT" eno49 5
  run -3 bash "$SCRIPT" nosuch0 5
  run -2 bash "$SCRIPT" vnet3 0
  run -2 bash "$SCRIPT" vnet3 121
  run -2 bash "$SCRIPT" vnet3 5 udp
  run -2 bash "$SCRIPT" 'vnet3;id' 5
  run -2 bash "$SCRIPT" vnet3
  [ ! -s "$SHIM_LOG" ] || ! grep -q tcpdump "$SHIM_LOG"
}

@test "allowlisted once under profile node; tcpdump is in the compute profile" {
  [ "$(grep -c 'net-capture.source = mkScript "net-capture"' "$ROOT/nix/modules/hps-ctrl-exec.nix")" -eq 1 ]
  grep -q 'net-capture.options.profile = "node";' "$ROOT/nix/modules/hps-ctrl-exec.nix"
  grep -qE '^\s+tcpdump # net-capture' "$ROOT/nix/modules/profiles/compute.nix"
}
