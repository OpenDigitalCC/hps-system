# profiles/compute.nix - the compute (TCH) role: libvirt + QEMU/KVM guests whose
# disks are md RAID1 mirrors (phase 3).
#
# UNEVALUATED: nix is not installed on the development host. Option names were
# checked against the nixpkgs 26.05 sources (nixos/modules/virtualisation/
# libvirtd.nix, tasks/swraid.nix, services/networking/iscsi/initiator.nix) but
# this file has not been through `nix flake check`.
#
# What it adds, and what it leaves out on purpose:
#  - libvirtd with the nixpkgs QEMU (KVM host CPU only: qemu_kvm). OVMF needs no
#    option in 26.05: the `qemu.ovmf` submodule was removed and every firmware
#    description shipped with QEMU is linked into /run/libvirt/nix-ovmf by
#    libvirtd-config (an assertion fires if `qemu.ovmf.*` is set).
#  - guest confinement: see docs/CONFINEMENT.md, which states exactly what is on.
#    The AppArmor profiles (libvirtd, virt-aa-helper, the guest abstraction and
#    template) are in compute-apparmor.nix.
#  - open-iscsi as an INITIATOR only. The initiator name cannot be in the image:
#    one image serves every node. hps-iscsi-initiator writes it at boot from the
#    node FQDN and cluster (iqn.2026-11.hps.<cluster>:<fqdn>) and /etc/iscsi/
#    initiatorname.iscsi points at that runtime file.
#  - mdadm, with the udev auto-assembly and the degraded "last resort" timer
#    OFF. HPS assembles every mirror explicitly (mirror-assemble) and a degraded
#    assembly needs an explicit --peer-gone (the missing leg's owner is gone), so
#    the kernel/udev must never start a half mirror on its own. No monitor mail.
#  - bridges for the workload networks are NOT declared here: the layout lives in
#    the registry and net-bridge-ensure builds them at boot (hps-node-init).
#    Only the kernel modules are loaded here.
#
# Nothing here holds a secret, a pool name, a disk or an address.
{ config, lib, pkgs, ... }:

{
  imports = [ ./compute-apparmor.nix ];

  hps.roles = lib.mkDefault "TCH";

  # ---- libvirt / QEMU / KVM -------------------------------------------------
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm;
      # QEMU runs as the unprivileged qemu-libvirtd user (libvirtd itself stays
      # root and relabels each guest's disks to that user for the guest's life).
      runAsRoot = false;
      # Replaces the module default (`namespaces = []`); keep that line when
      # editing. Every setting is explained in docs/CONFINEMENT.md.
      verbatimConfig = ''
        namespaces = []
        seccomp_sandbox = 1
        clear_emulator_capabilities = 1
        dynamic_ownership = 1
        allow_disk_format_probing = 0
        security_default_confined = 1
        security_require_confined = 0
        set_process_name = 1
        security_driver = "apparmor"
      '';
    };
    onBoot = "ignore";
    onShutdown = "shutdown";
  };

  # libvirt 12.x encrypts its secret-store key with systemd-creds:
  # virt-secret-init-encryption.service creates the key (TPM2 or the host
  # key) and libvirtd.service / virtsecretd.service load it with
  # LoadCredentialEncrypted=. On a netboot-to-RAM node with no TPM the
  # creation fails ("host key located on temporary file system") and
  # libvirtd fails first on the dependency, then at CREDENTIALS when the
  # file is missing (sch-001, pins 43e235c and 64fee81, 2026-11-09). HPS
  # uses no libvirt secrets (guest disks are plain block devices, keys live
  # in the IPS keysafe), so the key is 32 random bytes written in the clear
  # and handed to the daemons as a plain credential; it lives only in RAM.
  # The units come from the libvirt package, so these are drop-ins and the
  # empty first entry resets the package's setting.
  systemd.services.virt-secret-init-encryption = {
    overrideStrategy = "asDropin";
    serviceConfig = {
      RemainAfterExit = true;
      ExecStart = [
        ""
        (pkgs.writeShellScript "hps-virt-secret-key" ''
          set -eu
          umask 0077
          mkdir -p /var/lib/libvirt/secrets
          head -c 32 /dev/random > /var/lib/libvirt/secrets/secrets-encryption-key
        '')
      ];
    };
  };
  systemd.services.libvirtd.serviceConfig = {
    LoadCredentialEncrypted = [ "" ];
    LoadCredential = [ "secrets-encryption-key:/var/lib/libvirt/secrets/secrets-encryption-key" ];
  };
  systemd.services.virtsecretd = {
    overrideStrategy = "asDropin";
    serviceConfig = {
      LoadCredentialEncrypted = [ "" ];
      LoadCredential = [ "secrets-encryption-key:/var/lib/libvirt/secrets/secrets-encryption-key" ];
    };
  };

  # kvm-intel and kvm-amd are not listed: on any one CPU one of them always
  # fails ("Failed to insert module 'kvm_amd'", "CPU 0 isn't AMD or Hygon").
  # hps-kvm below loads the module of the CPU vendor.
  boot.kernelModules = [ "vhost_net" "8021q" "bridge" ];

  # The vendor check is read from /proc/cpuinfo, not left to udev's cpu modalias,
  # so the module is there before libvirtd starts whatever udev's timing. No VT
  # (or a CPU of neither family) leaves KVM off, as before.
  systemd.services.hps-kvm = {
    description = "HPS: load the KVM module for this CPU vendor";
    wantedBy = [ "multi-user.target" ];
    before = [ "libvirtd.service" ];
    path = with pkgs; [ kmod gnugrep ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if grep -q '^vendor_id[[:space:]]*:[[:space:]]*GenuineIntel' /proc/cpuinfo; then
        modprobe kvm-intel
      elif grep -qE '^vendor_id[[:space:]]*:[[:space:]]*(AuthenticAMD|HygonGenuine)' /proc/cpuinfo; then
        modprobe kvm-amd
      else
        echo "hps-kvm: CPU vendor is neither Intel nor AMD/Hygon; no KVM module loaded"
      fi
    '';
  };

  # AppArmor in the kernel and the userspace parser. The libvirt profiles that
  # make the per-guest layer work are in compute-apparmor.nix; qemu.conf above
  # sets security_driver = "apparmor" so libvirtd fails to start rather than fall
  # back to the DAC driver alone. mkDefault: one line turns the module off.
  security.apparmor.enable = lib.mkDefault true;

  # ---- open-iscsi initiator -------------------------------------------------
  services.openiscsi = {
    enable = true;
    # Placeholder so the option is defined; never used: initiatorname.iscsi is
    # replaced by the runtime file below.
    name = lib.mkDefault "iqn.2026-11.hps:unset";
  };

  environment.etc."iscsi/initiatorname.iscsi".source =
    lib.mkForce "/run/hps/initiatorname.iscsi";

  environment.etc."hps/hps-iscsi-name" = {
    source = ../../../node-manager/nixos-26/boot/hps-iscsi-name.sh;
    mode = "0755";
  };

  # After hps-node-init: that unit sets the kernel hostname (the FQDN) from the registry.
  # iscsid must not start before the name exists (it is socket activated, so
  # the requires/after below make the first connection wait for the file).
  systemd.services.hps-iscsi-initiator = {
    description = "HPS: iSCSI initiator name from the node FQDN";
    wantedBy = [ "multi-user.target" ];
    after = [ "hps-node-init.service" ];
    before = [ "iscsid.service" ];
    path = with pkgs; [ bash coreutils hostname curl jq iproute2 ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 15;
      StandardOutput = "journal+console";
      StandardError = "journal+console";
      ExecStart = "${pkgs.bash}/bin/bash /etc/hps/hps-iscsi-name";
    };
  };

  systemd.services.iscsid = {
    requires = [ "hps-iscsi-initiator.service" ];
    after = [ "hps-iscsi-initiator.service" ];
  };

  # open-iscsi ships iscsi-init.service ("One time configuration for
  # iscsi.service"): a oneshot that runs iscsi-gen-initiatorname when
  # /etc/iscsi/initiatorname.iscsi does not exist. Here that path is a symlink
  # into /run/hps that hps-iscsi-initiator creates later in the boot; run early,
  # the condition passed on the dangling link and the generator failed (sch-001,
  # every boot, 2026-11-09). It was masked for that, but iscsid's socket
  # activation requires it: with it masked iscsid never started ("iscsid.socket:
  # Failed to queue service startup job: Unit iscsi-init.service is masked",
  # nested node 2026-11-10, no iSCSI login possible). Ordered after the name
  # instead: the file then exists and the unit skips itself on its condition.
  systemd.services.iscsi-init = {
    requires = [ "hps-iscsi-initiator.service" ];
    after = [ "hps-iscsi-initiator.service" ];
  };

  # ---- mdadm ----------------------------------------------------------------
  boot.swraid = {
    enable = true;
    # PROGRAM (a no-op) satisfies the module's "MAILADDR or PROGRAM" check, so
    # the monitor never mails and never crashes. AUTO -all: no incremental
    # (udev) assembly of any metadata type; explicit `mdadm --assemble` with
    # named devices, which is what HPS runs, is not affected by AUTO.
    mdadmConf = ''
      PROGRAM ${pkgs.coreutils}/bin/true
      AUTO -all
    '';
  };

  # The degraded-start timer would force a half mirror active after a delay.
  systemd.suppressedSystemUnits = [
    "mdadm-last-resort@.timer"
    "mdadm-last-resort@.service"
  ];

  environment.systemPackages = with pkgs; [
    mdadm
    openiscsi
    qemu_kvm
    curl # image-fetch (CS-3.3)
    jq
    iproute2
    tcpdump # net-capture: read-only frame summary on a bridge port (scale test isolation)
    util-linux
  ];
}
