# hps-audit.nix - the onboarding audit image.
#
# Full driver set so an unknown node is seen whole (hpsa/smartpqi controllers,
# Broadcom/Intel NICs, firmware), then one oneshot that runs the read-only
# audit script and POSTs its JSON to the IPS (cmd=node_audit). The system then
# idles at a console banner. Nothing here writes to a disk.
{ config, pkgs, ... }:

{
  hardware.enableAllHardware = true;
  hardware.enableRedistributableFirmware = true;

  # Netboot needs none of these in stage 1 (root is RAM); listed so the audit
  # kernel has every storage/NIC driver module available at stage 2 as well.
  boot.initrd.availableKernelModules = [
    "hpsa" "smartpqi" "mpt3sas" "megaraid_sas" "ahci" "sd_mod" "sr_mod"
    "nvme" "usb_storage" "uas"
    "tg3" "bnx2" "bnx2x" "igb" "ixgbe" "i40e" "e1000e"
  ];

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
}
