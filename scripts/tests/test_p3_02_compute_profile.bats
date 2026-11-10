#!/usr/bin/env bats
#
# CS-3.1: structural (grep) tests of the compute profile. nix is not installed
# on this host: these prove the source says what it must, not that it
# evaluates (`nix flake check` is the real test).

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  COMPUTE="$ROOT/nix/modules/profiles/compute.nix"
  CTRL="$ROOT/nix/modules/hps-ctrl-exec.nix"
}

@test "converged.nix imports storage.nix and compute.nix and keeps both roles" {
  grep -q '\./storage\.nix' "$ROOT/nix/modules/profiles/converged.nix"
  grep -q '\./compute\.nix' "$ROOT/nix/modules/profiles/converged.nix"
  grep -q 'hps.roles = "SCH,TCH"' "$ROOT/nix/modules/profiles/converged.nix"
}

@test "compute.nix carries the TCH role as a default and only that role" {
  grep -q 'hps.roles = lib.mkDefault "TCH";' "$COMPUTE"
  run ! grep -q '"SCH' "$COMPUTE"
}

@test "storage.nix does not import compute.nix and the base and audit images do not either" {
  run ! grep -q 'compute.nix' "$ROOT/nix/modules/profiles/storage.nix" "$ROOT/nix/modules/hps-node.nix" "$ROOT/nix/modules/hps-audit.nix" "$ROOT/nix/modules/hps-common.nix"
}

@test "libvirtd is on with the KVM-only QEMU and unprivileged guests" {
  grep -q 'virtualisation.libvirtd = {' "$COMPUTE"
  grep -q 'enable = true;' "$COMPUTE"
  grep -q 'package = pkgs.qemu_kvm;' "$COMPUTE"
  grep -q 'runAsRoot = false;' "$COMPUTE"
}

@test "KVM and VLAN/bridge kernel modules are loaded" {
  grep -q 'kvm-intel' "$COMPUTE"
  grep -q 'kvm-amd' "$COMPUTE"
  grep -q '"8021q"' "$COMPUTE"
  grep -q '"bridge"' "$COMPUTE"
}

@test "OVMF: the removed qemu.ovmf submodule is not set (26.05 asserts on it) and the module says why" {
  run ! grep -qE '^[^#]*ovmf\.(enable|package|packages)' "$COMPUTE"
  grep -q 'qemu.ovmf. submodule was removed' "$COMPUTE"
}

@test "confinement: seccomp sandbox, dropped capabilities, no format probing, DAC ownership" {
  grep -q 'seccomp_sandbox = 1' "$COMPUTE"
  grep -q 'clear_emulator_capabilities = 1' "$COMPUTE"
  grep -q 'allow_disk_format_probing = 0' "$COMPUTE"
  grep -q 'dynamic_ownership = 1' "$COMPUTE"
}

@test "confinement: the replaced verbatimConfig keeps the module's namespaces line" {
  grep -q '^        namespaces = \[\]$' "$COMPUTE"
}

@test "confinement: AppArmor is enabled and libvirt is told to use it (CS-3.4a)" {
  grep -q 'security.apparmor.enable = lib.mkDefault true;' "$COMPUTE"
  grep -q 'security_driver = "apparmor"' "$COMPUTE"
  grep -q 'imports = \[ ./compute-apparmor.nix \];' "$COMPUTE"
  test -f "$(dirname "$COMPUTE")/compute-apparmor.nix"
  grep -q 'security_default_confined = 1' "$COMPUTE"
  grep -q 'security_require_confined = 0' "$COMPUTE"
}

@test "open-iscsi is an initiator whose name comes from the runtime file, not the image" {
  grep -q 'services.openiscsi = {' "$COMPUTE"
  grep -q 'environment.etc."iscsi/initiatorname.iscsi".source' "$COMPUTE"
  grep -q 'lib.mkForce "/run/hps/initiatorname.iscsi"' "$COMPUTE"
  grep -q 'systemd.services.hps-iscsi-initiator' "$COMPUTE"
  grep -q 'after = \[ "hps-node-init.service" \]' "$COMPUTE"
  grep -q 'before = \[ "iscsid.service" \]' "$COMPUTE"
  grep -q 'node-manager/nixos-26/boot/hps-iscsi-name.sh' "$COMPUTE"
  [ -x "$ROOT/node-manager/nixos-26/boot/hps-iscsi-name.sh" ]
  run ! grep -E 'enableAutoLoginOut *= *true|discoverPortal *= *"' "$COMPUTE"
}

@test "mdadm: swraid on, no monitor mail, no udev auto-assembly, no degraded last-resort timer" {
  grep -q 'boot.swraid = {' "$COMPUTE"
  grep -q 'PROGRAM ${pkgs.coreutils}/bin/true' "$COMPUTE"
  run ! grep -E '^[^#]*MAILADDR' "$COMPUTE"
  grep -q 'AUTO -all' "$COMPUTE"
  grep -q '"mdadm-last-resort@.timer"' "$COMPUTE"
  grep -q 'suppressedSystemUnits' "$COMPUTE"
}

@test "the module holds no secret, pool name, disk id or address" {
  run ! grep -niE 'password|PRIVATE KEY|secret=|token=|BEGIN CERTIFICATE' "$COMPUTE"
  run ! grep -E '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$COMPUTE"
  run ! grep -E 'zpool|/dev/disk/by-id' "$COMPUTE"
}

@test "net-bridge-ensure and net-status are allowlisted, profile node, one source line each, under # CS-3.1 at the end" {
  local s
  for s in net-bridge-ensure net-status; do
    grep -q "^      $s.source = mkScript \"$s\" (scriptsDir + \"/$s\");\$" "$CTRL"
    grep -q "^      $s.options.profile = \"node\";\$" "$CTRL"
    [ -x "$ROOT/node-manager/nixos-26/scripts/$s" ]
  done
  # the CS-3.1 block is the last thing before the end of the scripts attrset
  run sed -n '/^      # CS-3.1$/,/^    };$/p' "$CTRL"
  [[ "${lines[1]}" == *'net-bridge-ensure.source'* ]]
  [[ "${lines[-1]}" == "    };" ]]
}

@test "hps-node-init calls net-bridge-ensure after the hostname step and treats a failure as non-fatal" {
  local f="$ROOT/node-manager/nixos-26/boot/hps-node-init.sh"
  grep -q 'ensure_bridges()' "$f"
  grep -q '|| log "net-bridge-ensure exited' "$f"
  # order inside main: set_hostname, then ensure_bridges, then the bundle
  run grep -nE '^  (set_hostname "\$name"|ensure_bridges|if fetch_bundle)' "$f"
  [[ "${lines[0]}" == *set_hostname* ]]
  [[ "${lines[1]}" == *ensure_bridges* ]]
  [[ "${lines[2]}" == *fetch_bundle* ]]
}

@test "boot_manager.sh already serves the read-only keys the node needs" {
  local f="$ROOT/http/cgi-bin/boot_manager.sh"
  grep -q '"\$cmd" == "host_variable"' "$f"
  grep -q '"\$cmd" == "cluster_variable"' "$f"
  grep -q 'cluster_registry "\$cluster" get "\$name"' "$f"
}

@test "docs/CONFINEMENT.md exists, names the mechanisms and the verification commands" {
  local f="$ROOT/docs/CONFINEMENT.md"
  [ -f "$f" ]
  grep -q 'seccomp_sandbox' "$f"
  grep -q 'runAsRoot = false' "$f"
  grep -qi 'apparmor' "$f"
  grep -q 'virsh -c qemu:///system dominfo' "$f"
  grep -q '/proc/\$PID/attr/current' "$f"
  grep -q 'ps -o pid,user,label' "$f"
  grep -q 'What is not enabled' "$f"
  # the settings the document names are the settings the module sets
  grep -q 'security_require_confined' "$f"
}

@test "no new file puts a hostname, real address or credential in the tracked tree" {
  local f
  for f in docs/CONFINEMENT.md nix/modules/profiles/compute.nix node-manager/nixos-26/scripts/net-bridge-ensure node-manager/nixos-26/scripts/net-status node-manager/nixos-26/boot/hps-iscsi-name.sh; do
    run ! grep -nE '(^|[^0-9])(192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]+\.[0-9]+' "$ROOT/$f"
  done
}
