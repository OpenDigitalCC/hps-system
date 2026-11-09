# hps-ctrl-exec.nix - the ctrl-exec agent every HPS NixOS image carries (node
# images and the audit image), its script allowlist and the pairing script.
#
# Operations rely on ctrl-exec (owner ruling 2026-11-09): any node command
# worked out at the console becomes an allowlisted script under
# node-manager/nixos-26/scripts/ - one script per action, a straight sequence of
# standard commands with argument checks, every command logged as it runs, no
# runtime library sourcing - and is used through `ced run` from then on. Add a
# script by adding its file there and one `scripts.<name>.source` line below.
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
in
{
  imports = [ ctrl-exec.nixosModules.ctrl-exec-agent ];

  services.ctrl-exec-agent = {
    enable = true;
    openFirewall = true;
    scriptPath = "/run/wrappers/bin:/run/current-system/sw/bin";
    # The plugin's shebang is #!/usr/bin/env bash (CS-1.6); NixOS has no /bin/bash.
    scripts = {
      hps-node.source = ../../node-manager/plugins/hps-node/hps-node.sh;
      storage-pool-inspect.source = scriptsDir + "/storage-pool-inspect";
      storage-disks.source = scriptsDir + "/storage-disks";
      node-dmesg.source = scriptsDir + "/node-dmesg";
      node-facts.source = scriptsDir + "/node-facts";
    };
    # Mirrors node-manager/base/n_ctrl-exec.sh: executor off, so run_as is
    # recorded, not enforced (ADR 0003).
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
