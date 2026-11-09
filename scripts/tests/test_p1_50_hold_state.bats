#!/usr/bin/env bats
#
# CS-1.5 item 1: an unknown MAC is registered HELD and gets the audit boot
# script, never a menu; HELD hosts keep getting the audit; other states are
# unchanged; RESCUE still overrides.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-50.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  load p1_50_helpers
  source "$ROOT/lib/functions.d/ipxe-menu-functions.sh"
  source "$ROOT/lib/functions.d/host-functions.sh"
  source "$ROOT/lib/functions.d/nixos-boot-functions.sh"
  source "$ROOT/lib/functions.d/os-function-helpers.sh"
  p1_50_stubs
  ipxe_configure_main_menu() { echo "MENU-SHOWN"; }
  ipxe_boot_installer() { echo "installer"; }
  ipxe_network_boot() { echo "network-boot"; }
  p1_50_manifest pin1 audit
  printf 'pin1' > "$TEST_DIR/cluster/nixos_default_pin"
  printf '10.0.0.1' > "$TEST_DIR/cluster/network_dhcp_ip"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "unknown MAC is registered HELD, not UNCONFIGURED" {
  run ipxe_init_handler "52:54:00:aa:bb:01"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_DIR/hosts/525400aabb01/STATE")" = "HELD" ]
  [ "$(cat "$TEST_DIR/hosts/525400aabb01/arch")" = "x86_64" ]
}

@test "unknown MAC gets the audit iPXE script and no menu" {
  run ipxe_init_handler "52:54:00:aa:bb:01"
  [ "$status" -eq 0 ]
  [[ "$output" == *"#!ipxe"* ]]
  [[ "$output" == *"kernel http://10.0.0.1/nixos/pin1/audit/bzImage "* ]]
  [[ "$output" == *"hps.profile=audit"* ]]
  [[ "$output" == *$'\nboot'* ]]
  [[ "$output" != *"MENU-SHOWN"* ]]
  [[ "$output" != *"menu "* ]]
}

@test "known HELD host never gets a menu" {
  p1_50_host 52:54:00:aa:bb:02 STATE HELD
  run ipxe_init_handler "52:54:00:aa:bb:02"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/audit/bzImage"* ]]
  [[ "$output" != *"MENU-SHOWN"* ]]
}

@test "HELD with no audit manifest fails clearly, no menu" {
  rm -rf "$TEST_DIR/res/nixos/pin1"
  p1_50_host 52:54:00:aa:bb:02 STATE HELD
  run ipxe_init_handler "52:54:00:aa:bb:02"
  [[ "$output" == *"FAIL:"* ]]
  [[ "$output" == *"audit/boot.json"* ]]
  [[ "$output" != *"MENU-SHOWN"* ]]
}

@test "UNCONFIGURED still shows the configure menu" {
  p1_50_host 52:54:00:aa:bb:03 STATE UNCONFIGURED
  run ipxe_init_handler "52:54:00:aa:bb:03"
  [[ "$output" == *"MENU-SHOWN"* ]]
}

@test "CONFIGURED still starts the installer, NETWORK_BOOT still net boots" {
  p1_50_host 52:54:00:aa:bb:04 STATE CONFIGURED
  run ipxe_init_handler "52:54:00:aa:bb:04"
  [[ "$output" == *"installer"* ]]
  p1_50_host 52:54:00:aa:bb:05 STATE NETWORK_BOOT
  run ipxe_init_handler "52:54:00:aa:bb:05"
  [[ "$output" == *"network-boot"* ]]
}

@test "RESCUE=true overrides HELD" {
  p1_50_host 52:54:00:aa:bb:06 STATE HELD
  p1_50_host 52:54:00:aa:bb:06 RESCUE true
  run ipxe_init_handler "52:54:00:aa:bb:06"
  [[ "$output" == *"network-boot"* ]]
  [[ "$output" != *"/audit/bzImage"* ]]
}

@test "host_initialise_config defaults to UNCONFIGURED without a state argument" {
  run host_initialise_config 52:54:00:aa:bb:07 x86_64
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_DIR/hosts/525400aabb07/STATE")" = "UNCONFIGURED" ]
}

@test "ipxe_network_boot reaches ipxe_boot_nixos for os name nixos" {
  [ "$(get_os_name x86_64:nixos:26.05)" = "nixos" ]
  source "$ROOT/lib/functions.d/ipxe-menu-functions.sh"
  ipxe_boot_nixos() { echo "nixos-boot $1"; }
  os_registry() { return 0; }
  p1_50_host 52:54:00:aa:bb:08 os_id x86_64:nixos:26.05
  run ipxe_network_boot 52:54:00:aa:bb:08
  [ "$output" = "nixos-boot 52:54:00:aa:bb:08" ]
}
