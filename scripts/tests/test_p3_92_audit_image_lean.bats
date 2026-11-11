#!/usr/bin/env bats
#
# IPS-03: the audit image carries the full linux-firmware set and no other
# firmware package (owner ruling 2026-11-10: firmware stays whole for now), and
# it never pulls in a node role profile. Since the firmware layer (2026-11-11)
# that set travels as a separate initrd (nix/pkgs/hps-firmware-layer.nix), not
# in the image's store: test_p3_197.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  AUDIT="$ROOT/nix/modules/hps-audit.nix"
}

@test "audit firmware is linux-firmware only (no sound, TV-tuner or Wi-Fi packages)" {
  # the image's own list is forced empty (enableAllHardware would merge the
  # redistributable set into any list given); the layer is linux-firmware only
  grep -q 'hardware.firmware = lib.mkForce \[ \];' "$AUDIT"
  grep -q 'hardware.enableRedistributableFirmware = lib.mkForce false;' "$AUDIT"
  grep -q 'compressFirmwareZstd linux-firmware' "$ROOT/nix/pkgs/hps-firmware-layer.nix"
  run grep -E 'sof-firmware|alsa-firmware|libreelec|wireless-regdb|ipw2200|rtl8192su' "$ROOT/nix/pkgs/hps-firmware-layer.nix"
  [ "$status" -eq 1 ]
  run grep -E '^[^#]*enableRedistributableFirmware *= *true' "$AUDIT"
  [ "$status" -eq 1 ]
  run grep -E '^[^#]*enableAllFirmware *= *true' "$AUDIT"
  [ "$status" -eq 1 ]
}

@test "the audit image imports no role profile (storage, compute, converged)" {
  run grep -E 'profiles/(storage|compute|converged)\.nix|\./(storage|compute|converged)\.nix' "$AUDIT"
  [ "$status" -eq 1 ]
}
