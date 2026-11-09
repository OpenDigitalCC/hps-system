# hps-common.nix - what every HPS NixOS image shares.
#
# Netboot into RAM (nixpkgs netboot module: tmpfs root, squashfs store in the
# initrd), serial + VGA console, the tools the node scripts call, ZFS userland,
# no sshd. Hostname and every per-node value arrive at runtime from the
# registry (hps-node-init), never from the image.
#
# ---- no-secrets rule --------------------------------------------------------
# No secret of any kind is placed in an HPS image: no password hash, no key, no
# certificate, no token. One image serves every node of a profile; identity is
# delivered by the IPS at boot (ctrl-exec pairing). Accounts have no password
# and no login is possible (users.allowNoPasswordLogin only silences the NixOS
# lock-out assertion; it grants nothing). scripts/tests/test_p1_43_no_secrets.bats
# greps this tree for the rule.
# -----------------------------------------------------------------------------
{ config, lib, pkgs, modulesPath, hpsProfile, ... }:

{
  imports = [ "${modulesPath}/installer/netboot/netboot.nix" ];

  options.hps.roles = lib.mkOption {
    type = lib.types.str;
    default = "";
    example = "SCH,TCH";
    description = "HPS roles this profile carries (comma list); recorded in /etc/hps/roles.";
  };

  config = {
    system.stateVersion = "26.05";
    nixpkgs.hostPlatform = "x86_64-linux";

    # Serial first (iLO virtual serial / ttyS0), VGA second.
    boot.kernelParams = [ "console=ttyS0,115200n8" "console=tty0" ];
    boot.supportedFilesystems = [ "zfs" ];
    # A normal boot imports the pool and never forces it (brief: pool safety);
    # also the 26.11 default.
    boot.zfs.forceImportRoot = false;
    boot.zfs.forceImportAll = false;
    # ZFS refuses to build without a hostId. A fixed image-wide id is accepted
    # for phase 1 (read-only listing; no import). Per-node ids are a phase-2
    # item (plans/phase-1.md §6).
    networking.hostId = "48505331";

    # Empty: the kernel/DHCP name applies until hps-node-init sets the
    # transient hostname from the registry.
    networking.hostName = "";
    networking.useDHCP = lib.mkDefault true;

    environment.systemPackages = with pkgs; [
      bash curl jq iproute2 gawk gnutar findutils util-linux
      pciutils usbutils smartmontools numactl
      config.boot.zfs.package
    ];

    environment.etc."hps/profile".text = hpsProfile + "\n";
    environment.etc."hps/roles" = lib.mkIf (config.hps.roles != "") {
      text = config.hps.roles + "\n";
    };

    # ---- logs leave the node from early boot ---------------------------------
    # Crash evidence must survive a RAM-only node: journald hands every message
    # to a local rsyslog, which forwards to the IPS (TCP 514; the IPS files it
    # under <log dir>/<node ip>/YYYY-MM-DD.log). The forward target is not in
    # the image: hps-log-target writes it at boot from hps.ips= on the kernel
    # command line. Every image carries this, the audit image included.
    services.journald.extraConfig = "ForwardToSyslog=yes";
    services.rsyslogd = {
      enable = true;
      # no local file sink: the root is tmpfs and the journal already holds it
      defaultConfig = "";
      extraConfig = ''
        include(file="/run/hps/rsyslog-target.conf" mode="optional")
      '';
    };

    environment.etc."hps/hps-log-target" = {
      source = ../../node-manager/nixos-26/boot/hps-log-target.sh;
      mode = "0755";
    };

    # Not ordered after network-online: with hps.ips= on the command line no
    # network is needed, and rsyslog (and the journal socket queue behind it)
    # must not wait for DHCP. Without hps.ips the script retries the default
    # gateway for up to 30 s itself.
    systemd.services.hps-log-target = {
      description = "HPS: point syslog forwarding at the IPS";
      wantedBy = [ "multi-user.target" ];
      before = [ "syslog.service" "rsyslog.service" ];
      path = with pkgs; [ bash coreutils gawk iproute2 ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.bash}/bin/bash /etc/hps/hps-log-target";
      };
    };

    services.openssh.enable = false;
    users.mutableUsers = false;
    users.allowNoPasswordLogin = true;

    documentation.enable = false;
    documentation.nixos.enable = false;
    nix.settings.experimental-features = [ "nix-command" "flakes" ];
  };
}
