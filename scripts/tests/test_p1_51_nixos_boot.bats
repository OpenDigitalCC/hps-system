#!/usr/bin/env bats
#
# CS-1.5 item 2: manifest-driven NixOS netboot lines and pin resolution.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-51.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  load p1_50_helpers
  source "$ROOT/lib/functions.d/nixos-boot-functions.sh"
  p1_50_stubs
  ipxe_header() { printf '#!ipxe\n'; }
  printf '10.0.0.1' > "$TEST_DIR/cluster/network_dhcp_ip"
  MAC=52:54:00:aa:bb:01
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "manifest path is resources/nixos/pin/profile/boot.json" {
  run nixos_manifest_path node-base pin9
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_DIR/res/nixos/pin9/node-base/boot.json" ]
}

@test "manifest path rejects a profile or pin that is not a path-safe word" {
  run nixos_manifest_path "../x" pin9
  [ "$status" -eq 1 ]
  run nixos_manifest_path node-base "a/b"
  [ "$status" -eq 1 ]
}

@test "boot lines use the host system_pin" {
  p1_50_manifest hostpin node-base
  p1_50_manifest clusterpin node-base
  printf 'clusterpin' > "$TEST_DIR/cluster/nixos_default_pin"
  p1_50_host "$MAC" system_pin hostpin
  run nixos_boot_lines "$MAC" node-base
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "kernel http://10.0.0.1/nixos/hostpin/node-base/bzImage console=ttyS0 loglevel=4 init=/nix/store/abc-system/init hps.ips=10.0.0.1 hps.mac=$MAC hps.profile=node-base hps.pin=hostpin" ]
  [ "${lines[1]}" = "initrd http://10.0.0.1/nixos/hostpin/node-base/initrd" ]
  [ "${lines[2]}" = "boot" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "boot lines fall back to the cluster nixos_default_pin" {
  p1_50_manifest clusterpin audit
  printf 'clusterpin' > "$TEST_DIR/cluster/nixos_default_pin"
  run nixos_boot_lines "$MAC" audit
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "kernel http://10.0.0.1/nixos/clusterpin/audit/bzImage "* ]]
  [[ "${lines[0]}" == *"hps.pin=clusterpin" ]]
}

@test "boot lines fall back to the builder's latest file" {
  p1_50_manifest latestpin audit
  printf 'latestpin\n' > "$TEST_DIR/res/nixos/latest"
  run nixos_boot_lines "$MAC" audit
  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == "initrd http://10.0.0.1/nixos/latestpin/audit/initrd" ]]
}

@test "an init= already in the manifest cmdline is not repeated" {
  p1_50_manifest p1 audit "quiet init=/nix/store/abc-system/init"
  run nixos_boot_lines "$MAC" audit p1
  [ "$status" -eq 0 ]
  [ "$(grep -o 'init=' <<< "${lines[0]}" | wc -l)" -eq 1 ]
}

@test "no pin anywhere fails" {
  run nixos_boot_lines "$MAC" audit
  [ "$status" -eq 1 ]
  grep -q "no NixOS pin" "$TEST_DIR/hps.log"
}

@test "missing manifest fails and names the path" {
  printf 'gone' > "$TEST_DIR/cluster/nixos_default_pin"
  run nixos_boot_lines "$MAC" audit
  [ "$status" -eq 1 ]
  grep -q "$TEST_DIR/res/nixos/gone/audit/boot.json" "$TEST_DIR/hps.log"
  run nixos_emit_boot "$MAC" audit
  [[ "$output" == *"FAIL:"*"$TEST_DIR/res/nixos/gone/audit/boot.json"* ]]
}

@test "manifest without init fails" {
  p1_50_manifest p1 audit
  printf '{"cmdline":"x"}\n' > "$TEST_DIR/res/nixos/p1/audit/boot.json"
  run nixos_boot_lines "$MAC" audit p1
  [ "$status" -eq 1 ]
}

@test "image profile mapping" {
  [ "$(nixos_image_profile CONVERGED)" = "node-converged" ]
  [ "$(nixos_image_profile DEFAULT)" = "node-base" ]
  run nixos_image_profile WHATEVER
  [ "$status" -eq 1 ]
}

@test "ipxe_boot_nixos maps HOST_PROFILE to the image profile" {
  p1_50_manifest hostpin node-converged
  p1_50_host "$MAC" system_pin hostpin
  p1_50_host "$MAC" HOST_PROFILE CONVERGED
  run ipxe_boot_nixos "$MAC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kernel http://10.0.0.1/nixos/hostpin/node-converged/bzImage "* ]]
  [[ "$output" == *$'\nboot' ]]
}

@test "ipxe_boot_nixos with an unknown host profile fails clearly" {
  p1_50_host "$MAC" HOST_PROFILE ODD
  run ipxe_boot_nixos "$MAC"
  [[ "$output" == *"FAIL: No NixOS image profile for host profile 'ODD'"* ]]
}

@test "ipxe_boot_audit boots the audit profile" {
  p1_50_manifest p1 audit
  printf 'p1' > "$TEST_DIR/cluster/nixos_default_pin"
  run ipxe_boot_audit "$MAC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/nixos/p1/audit/bzImage "* ]]
}

@test "an assigned host's registry HOSTNAME rides on the command line; a held host has none" {
  p1_50_manifest hostpin node-base
  p1_50_host "$MAC" system_pin hostpin
  run nixos_boot_lines "$MAC" node-base
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" != *"hps.hostname="* ]]
  p1_50_host "$MAC" HOSTNAME sch-1
  run nixos_boot_lines "$MAC" node-base
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *" hps.pin=hostpin hps.hostname=sch-1" ]]
}
