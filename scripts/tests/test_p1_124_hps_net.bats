#!/usr/bin/env bats
#
# CS-1.12: hps-net writes the networkd files for the boot NIC only.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-124.XXXXXX")"
  export HPS_CMDLINE="$TEST_DIR/cmdline"
  export HPS_NETWORK_DIR="$TEST_DIR/network"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  NET="$ROOT/node-manager/nixos-26/boot/hps-net.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "12-hex MAC (as the IPS writes it): boot NIC matched, DHCPv4 without hostname or domains" {
  echo "BOOT_IMAGE=bzImage hps.ips=10.99.1.1 hps.mac=AABBCCDDEEFF hps.profile=audit" > "$HPS_CMDLINE"
  run bash "$NET"
  [ "$status" -eq 0 ]
  f="$HPS_NETWORK_DIR/10-hps-boot.network"
  grep -qx '\[Match\]' "$f"
  grep -qx 'MACAddress=aa:bb:cc:dd:ee:ff' "$f"
  grep -qx 'DHCP=ipv4' "$f"
  grep -qx 'UseHostname=false' "$f"
  grep -qx 'UseDomains=false' "$f"
  grep -qx 'SendHostname=false' "$f"
  grep -qx 'RequiredForOnline=yes' "$f"
}

@test "colon MAC is accepted and normalised" {
  echo "hps.mac=aa:bb:cc:dd:ee:ff" > "$HPS_CMDLINE"
  run bash "$NET"
  [ "$status" -eq 0 ]
  grep -qx 'MACAddress=aa:bb:cc:dd:ee:ff' "$HPS_NETWORK_DIR/10-hps-boot.network"
}

@test "every other interface is unmanaged" {
  echo "hps.mac=aabbccddeeff" > "$HPS_CMDLINE"
  run bash "$NET"
  g="$HPS_NETWORK_DIR/99-hps-others.network"
  grep -qx 'Name=\*' "$g"
  grep -qx 'Unmanaged=yes' "$g"
  ! grep -q 'DHCP' "$g"
}

@test "the boot file sorts before the catch-all (networkd takes the first match)" {
  echo "hps.mac=aabbccddeeff" > "$HPS_CMDLINE"
  run bash "$NET"
  [ "$(ls "$HPS_NETWORK_DIR" | head -1)" = "10-hps-boot.network" ]
}

@test "no hps.mac: DHCP on every interface, a loud warning, no unmanaged file" {
  echo "hps.ips=10.99.1.1" > "$HPS_CMDLINE"
  run bash "$NET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"*"hps.mac"* ]]
  [[ "$output" == *"EVERY interface"* ]]
  grep -qx 'Name=\*' "$HPS_NETWORK_DIR/10-hps-boot.network"
  grep -qx 'DHCP=ipv4' "$HPS_NETWORK_DIR/10-hps-boot.network"
  grep -qx 'UseDomains=false' "$HPS_NETWORK_DIR/10-hps-boot.network"
  [ ! -e "$HPS_NETWORK_DIR/99-hps-others.network" ]
}

@test "a malformed MAC is treated as absent (never written into a Match)" {
  echo "hps.mac=zz:11;rm" > "$HPS_CMDLINE"
  run bash "$NET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  ! grep -q 'MACAddress' "$HPS_NETWORK_DIR/10-hps-boot.network"
}

@test "a fallback run after a MAC run removes the stale unmanaged file" {
  echo "hps.mac=aabbccddeeff" > "$HPS_CMDLINE"
  run bash "$NET"
  echo "console=ttyS0" > "$HPS_CMDLINE"
  run bash "$NET"
  [ ! -e "$HPS_NETWORK_DIR/99-hps-others.network" ]
}

@test "every command is logged" {
  echo "hps.mac=aabbccddeeff" > "$HPS_CMDLINE"
  run bash "$NET"
  [[ "$output" == *"+ mkdir -p $HPS_NETWORK_DIR"* ]]
  [[ "$output" == *"+ write $HPS_NETWORK_DIR/10-hps-boot.network"* ]]
  [[ "$output" == *"+ write $HPS_NETWORK_DIR/99-hps-others.network"* ]]
}
