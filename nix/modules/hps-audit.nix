# hps-audit.nix - the onboarding audit image.
#
# Full driver set so an unknown node is seen whole (hpsa/smartpqi controllers,
# Broadcom/Intel NICs, firmware), then one oneshot that runs the read-only
# audit script and POSTs its JSON to the IPS (cmd=node_audit). The system then
# idles at a console banner. Nothing here writes to a disk.
#
# The image also runs the ctrl-exec agent (hps-ctrl-exec.nix) and, once the
# audit report is posted, pairs it (hps-audit-pair -> hps-pair), so a HELD node
# can be inspected with `ced run` (the IPS approver accepts STATE=HELD).
{ config, pkgs, ... }:

{
  imports = [ ./hps-ctrl-exec.nix ];

  hardware.enableAllHardware = true;
  # The full linux-firmware set (owner, 2026-11-10: keep it whole for now,
  # revisit later), and nothing else: enableRedistributableFirmware also adds
  # sound (sof, alsa), TV-tuner (libreelec-dvb) and Wi-Fi firmware packages
  # (IPS-03 measurement: ~57 MiB of the audit closure, none of it for a server).
  hardware.firmware = [ pkgs.linux-firmware ];

  # Netboot needs none of these in stage 1 (root is RAM); listed so the audit
  # kernel has every storage/NIC driver module available at stage 2 as well.
  boot.initrd.availableKernelModules = [
    "hpsa" "smartpqi" "mpt3sas" "megaraid_sas" "ahci" "sd_mod" "sr_mod"
    "nvme" "usb_storage" "uas"
    "tg3" "bnx2" "bnx2x" "igb" "ixgbe" "i40e" "e1000e"
  ];

  # Lab debugging aid: a root console on a held node. The audit image holds no
  # secrets and has no role, so the console exposes nothing; node images never
  # get this (no autologin anywhere outside this file).
  services.getty.autologinUser = "root";

  environment.etc."hps/hps-audit" = {
    source = ../../node-manager/nixos-26/audit/hps-audit.sh;
    mode = "0755";
  };

  systemd.services.hps-audit = {
    description = "HPS hardware audit (read-only) and report to the IPS";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = with pkgs; [
      bash coreutils util-linux pciutils numactl iproute2 jq curl gawk
      gnugrep gnused smartmontools config.boot.zfs.package
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StandardOutput = "journal+console";
      StandardError = "journal+console";
      ExecStart = "${pkgs.bash}/bin/bash /etc/hps/hps-audit";
    };
  };

  # After the audit POST: request ctrl-exec pairing. hps-pair exits 0 at once if
  # the agent already has its certificate. Its failure (no pairing window open,
  # IPS declined) leaves the audit and the banner untouched.
  systemd.services.hps-audit-pair = {
    description = "HPS audit image: ctrl-exec pairing, so a held node can be inspected";
    wantedBy = [ "multi-user.target" ];
    after = [ "hps-audit.service" "network-online.target" "ctrl-exec-agent.service" ];
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
      ExecStart = "${pkgs.bash}/bin/bash /etc/hps/hps-pair";
      # hps-pair is idempotent: a transient failure retries.
      Restart = "on-failure";
      RestartSec = 30;
    };
  };
}
