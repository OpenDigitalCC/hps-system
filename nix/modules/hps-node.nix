# hps-node.nix - the node image (node-base): the ctrl-exec agent (hps-ctrl-exec.nix,
# shared with the audit image) plus the boot-time init that takes identity from
# the registry and then runs hps-pair to request pairing.
{ config, pkgs, ... }:

{
  imports = [ ./hps-ctrl-exec.nix ];

  environment.etc."hps/hps-node-init" = {
    source = ../../node-manager/nixos-26/boot/hps-node-init.sh;
    mode = "0755";
  };

  systemd.services.hps-node-init = {
    description = "HPS node init: hostname from the registry, node bundle, ctrl-exec pairing (hps-pair)";
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
