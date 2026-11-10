#!/usr/bin/env bats
#
# CS-3.12a: nixos_boot_lines puts the host key boot_bridge on the kernel
# command line as hps.bridge=<name>, and only when it is a valid name.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-83.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  load p1_50_helpers
  source "$ROOT/lib/functions.d/nixos-boot-functions.sh"
  p1_50_stubs
  printf '10.0.0.1' > "$TEST_DIR/cluster/network_dhcp_ip"
  MAC=52:54:00:aa:bb:01
  mkdir -p "$TEST_DIR/res/nixos/hostpin/node-base"
  printf '{"cmdline":"console=ttyS0","init":"/nix/store/abc-system/init"}\n' > "$TEST_DIR/res/nixos/hostpin/node-base/boot.json"
  p1_50_host "$MAC" system_pin hostpin
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "no boot_bridge key: no hps.bridge on the command line" {
  run nixos_boot_lines "$MAC" node-base
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" != *"hps.bridge="* ]]
}

@test "boot_bridge set: hps.bridge=<name> is on the kernel line" {
  p1_50_host "$MAC" boot_bridge br-prov
  run nixos_boot_lines "$MAC" node-base
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *" hps.pin=hostpin hps.bridge=br-prov" ]]
}

@test "a malformed boot_bridge never reaches the command line" {
  p1_50_host "$MAC" boot_bridge 'br-prov;reboot'
  run nixos_boot_lines "$MAC" node-base
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" != *"hps.bridge="* ]]
  p1_50_host "$MAC" boot_bridge 'eth0'
  run nixos_boot_lines "$MAC" node-base
  [[ "${lines[0]}" != *"hps.bridge="* ]]
}
