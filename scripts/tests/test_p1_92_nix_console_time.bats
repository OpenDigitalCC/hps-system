#!/usr/bin/env bats
#
# CS-1.9: the Nix modules carry the console, time and dhcpcd settings. Nix is
# not evaluated here (no nix on the host); these are grep checks of the source
# and of the ordering that matters.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  COMMON="$ROOT/nix/modules/hps-common.nix"
}

@test "the iLO virtual serial port ttyS1 is the last console and has a getty" {
  grep -q 'boot.kernelParams = \[ "console=tty0" "console=ttyS0,115200n8" "console=ttyS1,115200n8" \]' "$COMMON"
  grep -q 'serial-getty@ttyS1' "$COMMON"
  grep -q 'serial-getty@ttyS0' "$COMMON"
}

@test "timesyncd is enabled with no baked-in or fallback servers" {
  grep -q 'services.timesyncd.enable = true' "$COMMON"
  grep -q 'services.timesyncd.servers = \[ \]' "$COMMON"
  grep -q 'services.timesyncd.fallbackServers = \[ \]' "$COMMON"
}

@test "hps-time runs after network-online and before audit and node-init, not before timesyncd" {
  grep -q 'after = \[ "network-online.target" \]' "$COMMON"
  grep -q 'before = \[ "hps-audit.service" "hps-node-init.service" \]' "$COMMON"
  if grep -q 'before = .*systemd-timesyncd' "$COMMON"; then return 1; fi
  grep -q 'node-manager/nixos-26/boot/hps-time.sh' "$COMMON"
}

@test "dhcpcd does not set the hostname" {
  grep -q 'networking.dhcpcd.extraConfig = "nohook hostname"' "$COMMON"
}
