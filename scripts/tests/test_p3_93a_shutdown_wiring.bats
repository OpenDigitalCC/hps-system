#!/usr/bin/env bats
#
# IPS-04: structural (grep) tests of the power-off wiring. nix is not installed
# on this host: these prove the source says what it must, not that it
# evaluates (`nix flake check` is the real test).

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  COMMON="$ROOT/nix/modules/hps-common.nix"
  CTRL="$ROOT/nix/modules/hps-ctrl-exec.nix"
}

@test "logind turns the ACPI power key into a poweroff, in the common module (all profiles)" {
  grep -q 'services.logind.settings.Login.HandlePowerKey = "poweroff";' "$COMMON"
}

@test "the button module is loaded so the event reaches logind" {
  grep -q 'boot.kernelModules = \[ "button" \];' "$COMMON"
}

@test "the shutdown script is installed at /etc/hps and run as the unit's ExecStop" {
  grep -q 'environment.etc."hps/hps-shutdown-storage"' "$COMMON"
  grep -q 'hps-shutdown-storage.sh' "$COMMON"
  grep -q 'ExecStop = "${pkgs.bash}/bin/bash /etc/hps/hps-shutdown-storage";' "$COMMON"
  grep -q 'systemd.services.hps-shutdown-storage = {' "$COMMON"
}

@test "the unit is a RemainAfterExit oneshot wanted by multi-user.target with a bounded stop" {
  grep -q 'Type = "oneshot";' "$COMMON"
  grep -q 'wantedBy = \[ "multi-user.target" \];' "$COMMON"
  grep -q 'TimeoutStopSec = 300;' "$COMMON"
}

@test "ordering: After= libvirt, iSCSI, network and log forwarder, so the stop runs before them" {
  block="$(sed -n '/systemd.services.hps-shutdown-storage = {/,/^    };/p' "$COMMON")"
  for u in libvirtd.service iscsid.service network-online.target systemd-networkd.service rsyslog.service; do
    [[ "$block" == *"\"$u\""* ]]
  done
  [[ "$block" == *"after = ["* ]]
}

@test "every step is logged to the journal and console (forwarded to the IPS)" {
  block="$(sed -n '/systemd.services.hps-shutdown-storage = {/,/^    };/p' "$COMMON")"
  [[ "$block" == *'StandardOutput = "journal+console";'* ]]
  [[ "$block" == *'StandardError = "journal+console";'* ]]
}

@test "node-poweroff is allowlisted under profile node" {
  grep -q 'node-poweroff.source = mkScript "node-poweroff" (scriptsDir + "/node-poweroff");' "$CTRL"
  grep -q 'node-poweroff.options.profile = "node";' "$CTRL"
}

@test "the shipped scripts exist, are executable and use the env shebang" {
  for f in node-manager/nixos-26/scripts/node-poweroff node-manager/nixos-26/boot/hps-shutdown-storage.sh; do
    [ -x "$ROOT/$f" ]
    [ "$(head -1 "$ROOT/$f")" = "#!/usr/bin/env bash" ]
    grep -q '^set -euo pipefail' "$ROOT/$f"
  done
}

@test "the shutdown script's order is guests, mirrors, targets, sessions, pools" {
  s="$ROOT/node-manager/nixos-26/boot/hps-shutdown-storage.sh"
  g=$(grep -n '^  stop_guests$' "$s" | cut -d: -f1)
  m=$(grep -n '^  stop_mirrors$' "$s" | cut -d: -f1)
  t=$(grep -n '^  unexport_targets$' "$s" | cut -d: -f1)
  i=$(grep -n '^  logout_sessions$' "$s" | cut -d: -f1)
  p=$(grep -n '^  export_pools$' "$s" | cut -d: -f1)
  [ "$g" -lt "$m" ]
  [ "$m" -lt "$t" ]
  [ "$t" -lt "$i" ]
  [ "$i" -lt "$p" ]
}
