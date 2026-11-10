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

    # Consoles. The kernel log goes to every console= device; the LAST one is
    # /dev/console (systemd status, the audit banner). The DL360 iLO Virtual
    # Serial Port is COM2 = ttyS1, so ttyS1 is last and is the primary; ttyS0
    # (COM1) and VGA still receive the kernel log. Gettys on both serial ports
    # are enabled below.
    boot.kernelParams = [ "console=tty0" "console=ttyS0,115200n8" "console=ttyS1,115200n8" ];
    systemd.services."serial-getty@ttyS0" = { enable = true; wantedBy = [ "getty.target" ]; };
    systemd.services."serial-getty@ttyS1" = { enable = true; wantedBy = [ "getty.target" ]; };
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
    # ---- networking: systemd-networkd, the boot NIC only ----------------------
    # No dhcpcd. hps-net (below) writes the .network files at boot from hps.mac=
    # on the kernel command line: DHCP on the NIC the node booted from, every
    # other interface unmanaged (a second NIC on a switch that carries another
    # LAN once took a lease and a foreign domain there). The lease gives no
    # hostname and no search domain (UseHostname/UseDomains=false): only HPS
    # names the node (hps-node-init / hps-pair, from the registry) and the
    # agent therefore registers under the short name. DNS servers still come
    # from the lease, written by systemd-resolved.
    networking.useDHCP = false;
    networking.useNetworkd = true;
    systemd.network.enable = true;
    networking.dhcpcd.enable = false;
    services.resolved.enable = true;
    # One configured NIC is enough for network-online.target.
    systemd.network.wait-online.anyInterface = true;

    environment.systemPackages = with pkgs; [
      bash curl jq iproute2 gawk gnutar findutils util-linux
      pciutils usbutils smartmontools numactl
      config.boot.zfs.package
    ];

    environment.etc."hps/profile".text = hpsProfile + "\n";
    environment.etc."hps/roles" = lib.mkIf (config.hps.roles != "") {
      text = config.hps.roles + "\n";
    };

    environment.etc."hps/hps-net" = {
      source = ../../node-manager/nixos-26/boot/hps-net.sh;
      mode = "0755";
    };

    # Before systemd-networkd starts, so the runtime .network files exist when
    # it reads them. MAC match: no interface name (and no udev settle) needed.
    systemd.services.hps-net = {
      description = "HPS: DHCP on the boot NIC only";
      wantedBy = [ "systemd-networkd.service" ];
      before = [ "systemd-networkd.service" ];
      unitConfig.DefaultDependencies = false;
      path = with pkgs; [ bash coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StandardOutput = "journal+console";
        StandardError = "journal+console";
        ExecStart = "${pkgs.bash}/bin/bash /etc/hps/hps-net";
      };
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
      # journald forwards what it receives on its sockets, never what it reads
      # from /dev/kmsg: without imklog no kernel line (oops, AppArmor denial,
      # link state) ever leaves the node. Lab 2026-11-10: zero kernel lines in
      # a day of forwarded logs while a guest start was being refused.
      extraConfig = ''
        module(load="imklog")
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

    # ---- time ------------------------------------------------------------------
    # A netboot node has no trustworthy RTC and ctrl-exec pairing is mTLS.
    # hps-time points timesyncd at the IPS (runtime drop-in under /run) and
    # steps a wrong clock once from the IPS HTTP Date header; the IPS runs
    # chrony. No NTP server is baked into the image.
    services.timesyncd.enable = true;
    services.timesyncd.servers = [ ];
    services.timesyncd.fallbackServers = [ ];

    environment.etc."hps/hps-time" = {
      source = ../../node-manager/nixos-26/boot/hps-time.sh;
      mode = "0755";
    };

    systemd.services.hps-time = {
      description = "HPS: set the clock and the time server from the IPS";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # Not Before=systemd-timesyncd: that unit is in sysinit.target and this one
      # is after network-online, so the pair would be an ordering cycle. The
      # script restarts timesyncd once the drop-in is written instead.
      before = [ "hps-audit.service" "hps-node-init.service" ];
      path = with pkgs; [ bash coreutils gawk iproute2 curl config.systemd.package ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StandardOutput = "journal+console";
        StandardError = "journal+console";
        ExecStart = "${pkgs.bash}/bin/bash /etc/hps/hps-time";
      };
    };

    # ---- power-off: the node honours the request, storage first ----------------
    # IPS-04. An ACPI power button press (iLO GracefulShutdown, an operator, a
    # BMC policy) is a poweroff: logind acts on it, and the `button` module makes
    # sure the event reaches logind on hardware that does not load it by itself.
    # (If a DL360 press shows no logind line in the journal, add services.acpid
    # with a poweroff handler; not added until the lab shows it is needed.)
    services.logind.settings.Login.HandlePowerKey = "poweroff";
    boot.kernelModules = [ "button" ];

    # Stops are the reverse of starts: a unit that is After= X stops BEFORE X.
    # This unit is after libvirt, the iSCSI initiator, the network, the resolver
    # and the log forwarder, so on any poweroff or reboot its ExecStop runs while
    # all of them are still up: guests stop, md mirrors stop, iSCSI targets and
    # sessions go, ZFS pools are exported, and only then the network and the
    # log forwarding stop. Every step is bounded by a timeout inside the script
    # and TimeoutStopSec bounds the whole unit; output goes to the journal (and
    # so to the IPS) and the console. After= on a unit this profile does not
    # have (libvirtd on a storage-only node) is harmless.
    environment.etc."hps/hps-shutdown-storage" = {
      source = ../../node-manager/nixos-26/boot/hps-shutdown-storage.sh;
      mode = "0755";
    };

    systemd.services.hps-shutdown-storage = {
      description = "HPS: stop guests and mirrors and export pools before power-off";
      wantedBy = [ "multi-user.target" ];
      after = [
        "libvirtd.service" "iscsid.service" "iscsid.socket" "ctrl-exec-agent.service"
        "network-online.target" "systemd-networkd.service" "systemd-resolved.service"
        "rsyslog.service" "local-fs.target"
      ];
      path = with pkgs; [ bash coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/true";
        ExecStop = "${pkgs.bash}/bin/bash /etc/hps/hps-shutdown-storage";
        TimeoutStopSec = 300;
        StandardOutput = "journal+console";
        StandardError = "journal+console";
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
