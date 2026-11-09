#!/usr/bin/env bats
#
# CS-1.12: structural (grep) tests of the Nix modules. nix is not installed on
# this host: these prove the source says what it must, not that it evaluates.
#  - dhcpcd is gone; systemd-networkd is on; hps-net runs before networkd
#  - every ctrl-exec agent script source is a derivation output (writeTextFile)
#    so it lands in the system closure
#  - the pairing units retry on failure

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  COMMON="$ROOT/nix/modules/hps-common.nix"
  CTRL="$ROOT/nix/modules/hps-ctrl-exec.nix"
}

@test "dhcpcd is gone from the node image modules and scripts" {
  ! grep -rn 'dhcpcd' "$ROOT/nix/modules" | grep -v 'networking.dhcpcd.enable = false' | grep -v '^[^:]*:[0-9]*: *#'
  ! grep -rln 'dhcpcd' "$ROOT/node-manager/nixos-26" "$ROOT/nix/build.sh"
}

@test "networkd is on, DHCP is not global" {
  grep -q 'networking.useDHCP = false;' "$COMMON"
  grep -q 'networking.useNetworkd = true;' "$COMMON"
  grep -q 'systemd.network.enable = true;' "$COMMON"
  grep -q 'systemd.network.wait-online.anyInterface = true;' "$COMMON"
  ! grep -q 'useDHCP = lib.mkDefault true' "$COMMON"
}

@test "hps-net is a oneshot before systemd-networkd and ships from the boot dir" {
  grep -q 'systemd.services.hps-net = {' "$COMMON"
  grep -q 'before = \[ "systemd-networkd.service" \]' "$COMMON"
  grep -q 'wantedBy = \[ "systemd-networkd.service" \]' "$COMMON"
  grep -q 'node-manager/nixos-26/boot/hps-net.sh' "$COMMON"
  grep -q 'ExecStart = "${pkgs.bash}/bin/bash /etc/hps/hps-net"' "$COMMON"
  [ -x "$ROOT/node-manager/nixos-26/boot/hps-net.sh" ]
}

@test "the units that need the network stay ordered on network-online.target" {
  grep -q 'after = \[ "network-online.target" \]' "$COMMON"
  grep -q '"network-online.target" "ctrl-exec-agent.service"' "$ROOT/nix/modules/hps-node.nix"
  grep -q '"network-online.target" "ctrl-exec-agent.service"' "$ROOT/nix/modules/hps-audit.nix"
  grep -q 'after = \[ "network-online.target" \]' "$ROOT/nix/modules/hps-audit.nix"
}

@test "every scripts.*.source in hps-ctrl-exec.nix goes through mkScript (writeTextFile)" {
  grep -q 'mkScript = name: file: pkgs.writeTextFile {' "$CTRL"
  grep -q 'executable = true;' "$CTRL"
  grep -q 'builtins.readFile file' "$CTRL"
  total=$(grep -c '\.source = ' <(sed -n '/scripts = {/,/^    };/p' "$CTRL"))
  viamk=$(grep -c '\.source = mkScript "' <(sed -n '/scripts = {/,/^    };/p' "$CTRL"))
  [ "$total" -ge 5 ]
  [ "$total" -eq "$viamk" ]
}

@test "no scripts source is a bare path" {
  ! grep -E '^\s+[a-z-]+\.source = (\.\./|scriptsDir|\./)' "$CTRL"
}

@test "hps-node-init and hps-audit-pair retry on failure" {
  grep -q 'Restart = "on-failure";' "$ROOT/nix/modules/hps-node.nix"
  grep -q 'RestartSec = 30;' "$ROOT/nix/modules/hps-node.nix"
  grep -q 'Restart = "on-failure";' "$ROOT/nix/modules/hps-audit.nix"
  grep -q 'RestartSec = 30;' "$ROOT/nix/modules/hps-audit.nix"
}

@test "hps-pair restarts the agent as the next step after the certificate arrives" {
  # wait_for_cert success -> (wait for the pairing process) -> systemctl restart
  awk '/wait_for_cert; then/,/restart ctrl-exec-agent/' "$ROOT/node-manager/nixos-26/boot/hps-pair.sh" > "$BATS_TEST_TMPDIR/seg"
  grep -q 'systemctl restart ctrl-exec-agent.service' "$BATS_TEST_TMPDIR/seg"
  [ "$(grep -c 'run ' "$BATS_TEST_TMPDIR/seg")" -eq 1 ]
}

@test "the ctrl-exec executor is enabled and the default profile runs as root" {
  grep -q 'executor.enable = true;' "$CTRL"
  grep -q 'run_as = "root";' "$CTRL"
  grep -q 'no_new_privileges = "yes";' "$CTRL"
  ! grep -q 'executor off, so run_as' "$CTRL"
}
