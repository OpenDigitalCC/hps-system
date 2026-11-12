# hps-audit.nix - the onboarding audit image.
#
# Full driver set so an unknown node is seen whole (hpsa/smartpqi controllers,
# Broadcom/Intel NICs, firmware), then one oneshot that runs the read-only
# audit script and POSTs its JSON to the IPS (cmd=node_audit). After the IPS
# accepts the post the script reboots the node (IPS-14), and the IPS holds it at
# iPXE until a role is set; the cluster key held_reboot_after_audit=false keeps
# the node up instead (hps.audit_reboot=0 on the command line). Nothing here
# writes to a disk.
#
# The image also runs the ctrl-exec agent (hps-ctrl-exec.nix) and, once the
# audit report is posted, pairs it (hps-audit-pair -> hps-pair), so a HELD node
# can be inspected with `ced run` (the IPS approver accepts STATE=HELD). That
# inspection needs the node to stay up: with the reboot after the audit (the
# default) the window is short; set held_reboot_after_audit=false to inspect.
#
# Firmware is a layer of its own (owner go-ahead 2026-11-11): the full
# linux-firmware set (owner, 2026-11-10: keep it whole; audit image only) is
# NOT in this image's store. nix/pkgs/hps-firmware-layer.nix packs it as a
# second initrd (one file, /firmware.squashfs) that changes only with the
# firmware; nix/build.sh publishes it once under <resources>/nixos/firmware/
# and the IPS has iPXE load it after the image's initrd (boot.json
# extra_initrds). Below: mount it before udev starts and point the kernel's
# firmware loader at it (docs/IPXE.md, "Firmware layer").
{ config, lib, pkgs, ... }:

let
  firmwareLayer = pkgs.callPackage ../pkgs/hps-firmware-layer.nix { };
  # Where the firmware squashfs is mounted; the kernel's firmware_class.path.
  firmwareDir = "/run/hps-firmware";
in
{
  imports = [ ./hps-ctrl-exec.nix ];

  hardware.enableAllHardware = true;
  # No firmware in the image itself. enableAllHardware turns on
  # enableRedistributableFirmware, whose package list (linux-firmware plus
  # sound, TV-tuner and Wi-Fi firmware and wireless-regdb, IPS-03) would be
  # merged with any list given here, so both are forced.
  hardware.enableRedistributableFirmware = lib.mkForce false;
  hardware.firmware = lib.mkForce [ ];

  # The layer, for flake.nix (netbootArtefacts publishes it beside the image).
  system.build.hpsFirmwareLayer = firmwareLayer;

  # Stage 1 (systemd initrd): mount the layer's squashfs as soon as the loop
  # module is loaded and before udev triggers the coldplug, so a driver that
  # requests firmware while probing in the initrd already finds it. Under /run:
  # the initrd's /run (submounts included) is carried into the system, so the
  # same path serves stage 2. A boot without the layer (an old IPS serving one
  # initrd) skips the mount and comes up without firmware, as with no files.
  boot.initrd.systemd.mounts = [
    {
      what = "/firmware.squashfs";
      where = firmwareDir;
      type = "squashfs";
      options = lib.concatStringsSep "," (
        [ "loop" "ro" ]
        ++ lib.optional (config.boot.kernelPackages.kernel.kernelAtLeast "6.2") "threads=multi"
      );
      wantedBy = [ "sysinit.target" ];
      after = [ "systemd-modules-load.service" ];
      before = [ "sysinit.target" "systemd-udev-trigger.service" ];
      unitConfig = {
        DefaultDependencies = false;
        ConditionPathExists = "/firmware.squashfs";
        # Kept across the switch to the system (initrd-switch-root isolates).
        IgnoreOnIsolate = true;
      };
    }
  ];
  # firmware_class is built into the kernel: the parameter applies from the
  # first request (the initrd included).
  boot.kernelParams = [ "firmware_class.path=${firmwareDir}" ];
  # NixOS's activation (system.activationScripts.udevd) writes
  # ${config.hardware.firmware}/lib/firmware, here an empty tree, into the same
  # parameter; put the layer back right after it, when it is mounted.
  system.activationScripts.hpsFirmwarePath = {
    deps = [ "udevd" ];
    text = ''
      if [ -e /sys/module/firmware_class/parameters/path ] && [ -d ${firmwareDir} ]; then
        echo -n ${firmwareDir} > /sys/module/firmware_class/parameters/path
      fi
    '';
  };

  # Netboot needs none of these in stage 1 (root is RAM); listed so the audit
  # kernel has every storage/NIC driver module available at stage 2 as well.
  boot.initrd.availableKernelModules = [
    "hpsa" "smartpqi" "mpt3sas" "megaraid_sas" "ahci" "sd_mod" "sr_mod"
    "nvme" "usb_storage" "uas"
    "tg3" "bnx2" "bnx2x" "igb" "ixgbe" "i40e" "e1000e"
  ];

  # Local IPMI (KCS) interface, so the audit can read the BMC identity with
  # ipmitool (IPS-08). Without the hardware there is simply no /dev/ipmi0.
  boot.kernelModules = [ "ipmi_si" "ipmi_devintf" ];

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
      gnugrep gnused smartmontools ipmitool config.boot.zfs.package
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
      # hps-pair is idempotent and retries within the pairing window itself;
      # a failure it gives up on for now (exit 1) retries here, a refusal by
      # the IPS (exit 3) does not.
      Restart = "on-failure";
      RestartSec = 30;
      RestartPreventExitStatus = 3;
    };
  };
}
