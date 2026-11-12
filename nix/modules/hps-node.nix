# hps-node.nix - the node image (node-base): the ctrl-exec agent (hps-ctrl-exec.nix,
# shared with the audit image) plus the boot-time init that takes identity from
# the registry and then runs hps-pair to request pairing.
{ config, pkgs, ... }:

{
  imports = [ ./hps-ctrl-exec.nix ./hps-monitor.nix ];

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
      # hps-pair is idempotent and retries within the pairing window itself
      # (backoff 5, 10, 20, 40, 60 ... s; it reboots into netboot when the IPS
      # says the window has passed). A failure it gives up on for now (exit 1:
      # no IPS address, no answer) retries here; a refusal by the IPS (exit 3)
      # does not.
      Restart = "on-failure";
      RestartSec = 30;
      RestartPreventExitStatus = 3;
      StandardOutput = "journal+console";
      StandardError = "journal+console";
      ExecStart = "${pkgs.bash}/bin/bash /etc/hps/hps-node-init";
    };
  };

  # The host reserve (owner 2026-11-12: the host first, so it can run its RAID,
  # its ZFS and its guests): machine.slice gets the CPUs, weights and memory
  # left after the host's share, and a storage host caps the ZFS ARC. Before
  # hps-node-init, so it is in place before pairing and so before any guest
  # starts. The allowlisted script itself (copied to /opt/ctrl-exec-scripts by
  # the agent's activation) runs, so a `ced run host-reserve-apply` re-applies
  # exactly this. A failure is logged and does not hold up the boot.
  systemd.services.hps-host-reserve = {
    description = "HPS host reserve: CPU, memory and IO kept for the host (machine.slice, ZFS ARC cap)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "hps-time.service" ];
    wants = [ "network-online.target" ];
    before = [ "hps-node-init.service" ];
    path = with pkgs; [ bash coreutils curl gawk config.systemd.package ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StandardOutput = "journal+console";
      StandardError = "journal+console";
      ExecStart = "${pkgs.bash}/bin/bash /opt/ctrl-exec-scripts/host-reserve-apply";
    };
  };
}
