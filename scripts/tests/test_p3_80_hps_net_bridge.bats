#!/usr/bin/env bats
#
# CS-3.12a: hps-net with hps.bridge=: the boot NIC is a bridge member and the
# DHCP client runs on the bridge; without it the files are today's.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-80.XXXXXX")"
  export HPS_CMDLINE="$TEST_DIR/cmdline"
  export HPS_NETWORK_DIR="$TEST_DIR/network"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  NET="$ROOT/node-manager/nixos-26/boot/hps-net.sh"
  D="$HPS_NETWORK_DIR"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "a bridge writes three units: the netdev, the member network and the DHCP network" {
  echo "hps.ips=10.99.1.1 hps.mac=AABBCCDDEEFF hps.bridge=br-prov" > "$HPS_CMDLINE"
  run bash "$NET"
  [ "$status" -eq 0 ]
  [ -f "$D/08-hps-boot-bridge.netdev" ]
  [ -f "$D/11-hps-boot-member.network" ]
  [ -f "$D/10-hps-boot.network" ]
  grep -qx 'Kind=bridge' "$D/08-hps-boot-bridge.netdev"
  grep -qx 'Name=br-prov' "$D/08-hps-boot-bridge.netdev"
}

@test "the bridge carries the boot NIC's MAC, so the IPS sees the same host" {
  echo "hps.mac=AABBCCDDEEFF hps.bridge=br-prov" > "$HPS_CMDLINE"
  run bash "$NET"
  grep -qx 'MACAddress=aa:bb:cc:dd:ee:ff' "$D/08-hps-boot-bridge.netdev"
}

@test "the boot NIC is enslaved: matched by MAC and type ether, never the bridge itself" {
  echo "hps.mac=aa:bb:cc:dd:ee:ff hps.bridge=br-prov" > "$HPS_CMDLINE"
  run bash "$NET"
  f="$D/11-hps-boot-member.network"
  grep -qx 'MACAddress=aa:bb:cc:dd:ee:ff' "$f"
  grep -qx 'Type=ether' "$f"
  grep -qx 'Name=!br-prov' "$f"
  grep -qx 'Bridge=br-prov' "$f"
  ! grep -q 'DHCP' "$f"
}

@test "the DHCP client moves to the bridge with the same lease options" {
  echo "hps.mac=aabbccddeeff hps.bridge=br-prov" > "$HPS_CMDLINE"
  run bash "$NET"
  f="$D/10-hps-boot.network"
  grep -qx 'Name=br-prov' "$f"
  ! grep -q 'MACAddress' "$f"
  grep -qx 'DHCP=ipv4' "$f"
  grep -qx 'UseHostname=false' "$f"
  grep -qx 'UseDomains=false' "$f"
  grep -qx 'SendHostname=false' "$f"
  grep -qx 'RequiredForOnline=yes' "$f"
}

@test "every other interface stays unmanaged" {
  echo "hps.mac=aabbccddeeff hps.bridge=br-prov" > "$HPS_CMDLINE"
  run bash "$NET"
  grep -qxF 'Name=*' "$D/99-hps-others.network"
  grep -qx 'Unmanaged=yes' "$D/99-hps-others.network"
}

@test "no bridge key: exactly today's two files, no netdev, no member" {
  echo "hps.mac=aabbccddeeff" > "$HPS_CMDLINE"
  run bash "$NET"
  [ "$status" -eq 0 ]
  [ "$(ls "$D" | paste -sd' ' -)" = "10-hps-boot.network 99-hps-others.network" ]
  grep -qx 'MACAddress=aa:bb:cc:dd:ee:ff' "$D/10-hps-boot.network"
}

@test "a malformed bridge name is ignored loudly and the node comes up as today" {
  echo "hps.mac=aabbccddeeff hps.bridge=eth0;rm" > "$HPS_CMDLINE"
  run bash "$NET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"*"hps.bridge"* ]]
  [ "$(ls "$D" | paste -sd' ' -)" = "10-hps-boot.network 99-hps-others.network" ]
}

@test "a bridge name without br- or longer than 12 after it is ignored" {
  echo "hps.mac=aabbccddeeff hps.bridge=prov" > "$HPS_CMDLINE"
  run bash "$NET"
  [ ! -e "$D/08-hps-boot-bridge.netdev" ]
  echo "hps.mac=aabbccddeeff hps.bridge=br-abcdefghijklm" > "$HPS_CMDLINE"
  run bash "$NET"
  [ ! -e "$D/08-hps-boot-bridge.netdev" ]
  echo "hps.mac=aabbccddeeff hps.bridge=br-abcdefghijkl" > "$HPS_CMDLINE"
  run bash "$NET"
  [ -e "$D/08-hps-boot-bridge.netdev" ]
}

@test "a bridge without a usable MAC is not built: the all-NIC fallback, no bridge units" {
  echo "hps.bridge=br-prov" > "$HPS_CMDLINE"
  run bash "$NET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"EVERY interface"* ]]
  [ ! -e "$D/08-hps-boot-bridge.netdev" ]
  [ ! -e "$D/11-hps-boot-member.network" ]
}

@test "a run without the key after a run with it removes the bridge units" {
  echo "hps.mac=aabbccddeeff hps.bridge=br-prov" > "$HPS_CMDLINE"
  run bash "$NET"
  echo "hps.mac=aabbccddeeff" > "$HPS_CMDLINE"
  run bash "$NET"
  [ ! -e "$D/08-hps-boot-bridge.netdev" ]
  [ ! -e "$D/11-hps-boot-member.network" ]
  grep -qx 'MACAddress=aa:bb:cc:dd:ee:ff' "$D/10-hps-boot.network"
}

@test "the unit ordering is unchanged: hps-net still runs before systemd-networkd" {
  grep -q 'before = \[ "systemd-networkd.service" \]' "$ROOT/nix/modules/hps-common.nix"
}
