# hps-ctrl-exec.nix - the ctrl-exec agent every HPS NixOS image carries (node
# images and the audit image), its script allowlist and the pairing script.
#
# Operations rely on ctrl-exec (owner ruling 2026-11-09): any node command
# worked out at the console becomes an allowlisted script under
# node-manager/nixos-26/scripts/ - one script per action, a straight sequence of
# standard commands with argument checks, every command logged as it runs, no
# runtime library sourcing - and is used through `ced run` from then on. Add a
# script by adding its file there and one `scripts.<name>.source = mkScript ...`
# line below (every source must be a derivation output, never a bare path).
#
# The agent module copies each source out of the store to
# /opt/ctrl-exec-scripts/<name> (root-owned real file, as the agent's trust walk
# requires) and lists it in scripts.conf. Pairing is not declarative: the agent
# unit fails once (exit 78, not paired) and /etc/hps/hps-pair restarts it after
# the certificate arrives. hps-node-init (node images) and hps-audit-pair (audit
# image) both call hps-pair.
{ config, pkgs, ctrl-exec, ... }:

let
  scriptsDir = ../../node-manager/nixos-26/scripts;
  # The agent module does `escapeShellArg (toString source)`, and toString drops
  # the store-path context: a bare path would leave the flake source tree out of
  # the system closure (and the netboot squashfs), so the install in the
  # activation script fails ("cannot stat .../hps-node.sh") and
  # /opt/ctrl-exec-scripts stays empty. writeTextFile makes each script its own
  # derivation output; the source tree is read at evaluation time.
  mkScript = name: file: pkgs.writeTextFile {
    inherit name;
    executable = true;
    text = builtins.readFile file;
  };
in
{
  imports = [ ctrl-exec.nixosModules.ctrl-exec-agent ];

  services.ctrl-exec-agent = {
    enable = true;
    openFirewall = true;
    scriptPath = "/run/wrappers/bin:/run/current-system/sw/bin";
    # The plugin's shebang is #!/usr/bin/env bash (CS-1.6); NixOS has no /bin/bash.
    scripts = {
      hps-node.source = mkScript "hps-node" ../../node-manager/plugins/hps-node/hps-node.sh;
      storage-pool-inspect.source = mkScript "storage-pool-inspect" (scriptsDir + "/storage-pool-inspect");
      storage-disks.source = mkScript "storage-disks" (scriptsDir + "/storage-disks");
      node-dmesg.source = mkScript "node-dmesg" (scriptsDir + "/node-dmesg");
      node-facts.source = mkScript "node-facts" (scriptsDir + "/node-facts");
    };
    # The executor runs on NixOS nodes (ctrl-exec-executor.service, root, plus
    # executor_socket in agent.conf). Without it the agent runs scripts itself
    # as User=ctrl-exec-agent under PrivateDevices with no capabilities, and
    # node operations (zpool, mdadm, virsh, targetcli) fail for want of
    # /dev/zfs and /proc/self/mounts. With it the profile below is enforced:
    # run_as root. (ADR 0003 left the executor off for Alpine nodes; --async
    # runs are refused while it is on.)
    executor.enable = true;
    profiles.default = {
      run_as = "root";
      no_new_privileges = "yes";
    };
  };

  # Everything the scripts call must be on scriptPath (the system profile).
  environment.systemPackages = with pkgs; [
    coreutils gnugrep gawk procps util-linux iproute2 smartmontools
    config.systemd.package config.boot.zfs.package
  ];

  environment.etc."hps/hps-pair" = {
    source = ../../node-manager/nixos-26/boot/hps-pair.sh;
    mode = "0755";
  };
}
