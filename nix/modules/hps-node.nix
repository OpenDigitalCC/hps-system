# hps-node.nix - the node image (node-base): ctrl-exec agent plus the boot-time
# init that takes identity from the registry and requests pairing.
#
# The agent module copies the hps-node plugin out of the store to
# /opt/ctrl-exec-scripts/hps-node (root-owned real file, as the agent's trust
# walk requires) and lists it as the single allowlisted script. Pairing is not
# declarative: the agent unit fails once (exit 78, not paired) and
# hps-node-init restarts it after the certificate arrives.
{ config, pkgs, ctrl-exec, ... }:

{
  imports = [ ctrl-exec.nixosModules.ctrl-exec-agent ];

  services.ctrl-exec-agent = {
    enable = true;
    openFirewall = true;
    scriptPath = "/run/wrappers/bin:/run/current-system/sw/bin";
    # The plugin's shebang is fixed to #!/usr/bin/env bash by CS-1.6; until
    # then the copied file does not run on NixOS (no /bin/bash).
    scripts.hps-node.source = ../../node-manager/plugins/hps-node/hps-node.sh;
    # Mirrors node-manager/base/n_ctrl-exec.sh: executor off, so run_as is
    # recorded, not enforced (ADR 0003).
    profiles.default = {
      run_as = "root";
      no_new_privileges = "yes";
    };
  };

  environment.etc."hps/hps-node-init" = {
    source = ../../node-manager/nixos-26/boot/hps-node-init.sh;
    mode = "0755";
  };

  systemd.services.hps-node-init = {
    description = "HPS node init: hostname from the registry, node bundle, ctrl-exec pairing";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "ctrl-exec-agent.service" ];
    wants = [ "network-online.target" ];
    path = with pkgs; [
      bash coreutils curl jq iproute2 gawk gnugrep gnused hostname
      config.systemd.package config.services.ctrl-exec-agent.package
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StandardOutput = "journal+console";
      StandardError = "journal+console";
      ExecStart = "${pkgs.bash}/bin/bash /etc/hps/hps-node-init";
    };
  };
}
