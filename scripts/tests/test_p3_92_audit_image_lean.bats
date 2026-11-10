#!/usr/bin/env bats
#
# IPS-03: the audit image carries the full linux-firmware set and no other
# firmware package (owner ruling 2026-11-10: firmware stays whole for now), and
# it never pulls in a node role profile.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  AUDIT="$ROOT/nix/modules/hps-audit.nix"
}

@test "audit firmware is linux-firmware only (no sound, TV-tuner or Wi-Fi packages)" {
  grep -q 'hardware.firmware = \[ pkgs.linux-firmware \];' "$AUDIT"
  run grep -E '^[^#]*enableRedistributableFirmware *= *true' "$AUDIT"
  [ "$status" -eq 1 ]
  run grep -E '^[^#]*enableAllFirmware *= *true' "$AUDIT"
  [ "$status" -eq 1 ]
}

@test "the audit image imports no role profile (storage, compute, converged)" {
  run grep -E 'profiles/(storage|compute|converged)\.nix|\./(storage|compute|converged)\.nix' "$AUDIT"
  [ "$status" -eq 1 ]
}
