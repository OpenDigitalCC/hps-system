#!/usr/bin/env bats
#
# Plan step 1: a host assigned HOST_PROFILE STARTER boots the stock starter
# that hps-starter put under <resources>/starter/nixos/<release>/, not a built
# pinned image (nixos-boot-functions.sh). Pinned boots stay as they were.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-263.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  load p1_50_helpers
  source "$ROOT/lib/functions.d/nixos-boot-functions.sh"
  p1_50_stubs
  ipxe_header() { printf '#!ipxe\n'; }
  printf '10.0.0.1' > "$TEST_DIR/cluster/network_dhcp_ip"
  MAC=52:54:00:aa:bb:01
  SDIR="$TEST_DIR/res/starter/nixos/26.05"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# starter_files [cmdline]: what hps-starter sync leaves for release 26.05
starter_files() {
  mkdir -p "$SDIR"
  printf 'kernel' > "$SDIR/bzImage"
  printf 'initrd' > "$SDIR/initrd"
  printf '{"schema":"hps-starter/1","cmdline":"%s"}\n' \
    "${1:-init=/nix/store/abc-nixos-system-nixos-kexec-26.05.1.abc/init initrd=initrd nohibernate root=fstab loglevel=4 lsm=landlock,yama,bpf}" > "$SDIR/manifest.json"
}

@test "starter boot lines: stock kernel and initramfs from the IPS, the stock arguments, a serial console" {
  starter_files
  run nixos_starter_boot_lines "$MAC" 26.05
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "kernel http://10.0.0.1/starter/nixos/26.05/bzImage init=/nix/store/abc-nixos-system-nixos-kexec-26.05.1.abc/init initrd=initrd nohibernate root=fstab loglevel=4 lsm=landlock,yama,bpf console=ttyS0,115200" ]
  [ "${lines[1]}" = "initrd http://10.0.0.1/starter/nixos/26.05/initrd" ]
  [ "${lines[2]}" = "boot" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "starter boot lines carry no hps.* argument: nothing of HPS runs on the starter" {
  starter_files
  run nixos_starter_boot_lines "$MAC" 26.05
  [ "$status" -eq 0 ]
  [[ "$output" != *"hps."* ]]
}

@test "a host with profile STARTER gets the starter script of its os_id release, pin or no pin" {
  starter_files
  p1_50_host "$MAC" HOST_PROFILE STARTER
  p1_50_host "$MAC" os_id x86_64:nixos:26.05
  run ipxe_boot_nixos "$MAC"
  [ "$status" -eq 0 ]
  [[ "$output" == "#!ipxe"* ]]
  [[ "$output" == *"imgfree"* ]]
  [[ "$output" == *"kernel http://10.0.0.1/starter/nixos/26.05/bzImage "* ]]
  [[ "$output" == *$'\nboot' ]]
  [[ "$output" != *"/nixos/"*"/node-"* ]]
}

@test "the starter boot ignores a leftover system_pin and opens no pairing window" {
  starter_files
  p1_50_host "$MAC" HOST_PROFILE STARTER
  p1_50_host "$MAC" os_id x86_64:nixos:26.05
  p1_50_host "$MAC" system_pin oldpin
  ce_pairing_window_open() { echo "window" >> "$CALL_LOG"; }
  run ipxe_boot_nixos "$MAC"
  [ "$status" -eq 0 ]
  [[ "$output" != *"oldpin"* ]]
  ! grep -q window "$CALL_LOG"
}

@test "a pinned CONVERGED host still boots its built image" {
  p1_50_manifest hostpin node-converged
  p1_50_host "$MAC" system_pin hostpin
  p1_50_host "$MAC" HOST_PROFILE CONVERGED
  p1_50_host "$MAC" os_id x86_64:nixos:26.05
  starter_files
  ce_pairing_window_open() { :; }
  run ipxe_boot_nixos "$MAC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kernel http://10.0.0.1/nixos/hostpin/node-converged/bzImage "* ]]
  [[ "$output" != *"/starter/"* ]]
}

@test "no starter synced: the host gets an error screen that says to run hps-starter" {
  p1_50_host "$MAC" HOST_PROFILE STARTER
  p1_50_host "$MAC" os_id x86_64:nixos:26.05
  run ipxe_boot_nixos "$MAC"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL: NixOS starter 26.05 unavailable: run hps-starter sync nixos"* ]]
  grep -q "hps-starter sync nixos" "$TEST_DIR/hps.log"
}

@test "a manifest without init= in its cmdline is not booted" {
  starter_files "quiet loglevel=4"
  run nixos_starter_boot_lines "$MAC" 26.05
  [ "$status" -eq 1 ]
  grep -q "no init=" "$TEST_DIR/hps.log"
}

@test "the release comes from os_id and is path-safe" {
  starter_files
  run nixos_starter_boot_lines "$MAC" "../26.05"
  [ "$status" -eq 1 ]
  run nixos_starter_boot_lines "$MAC" ""
  [ "$status" -eq 1 ]
}
