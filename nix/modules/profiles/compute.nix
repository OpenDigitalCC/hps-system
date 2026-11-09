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
#  - open-iscsi as an INITIATOR only. The initiator name cannot be in the image:
#    one image serves every node. hps-iscsi-initiator writes it at boot from the
#    registry hostname (iqn.2026-11.hps:<hostname>) and /etc/iscsi/
#    initiatorname.iscsi points at that runtime file.
#  - mdadm, with the udev auto-assembly and the degraded "last resort" timer
#    OFF. HPS assembles every mirror explicitly (mirror-assemble) and a degraded
#    assembly needs an IPS declaration that the missing leg's owner is gone, so
#    the kernel/udev must never start a half mirror on its own. No monitor mail.
#  - bridges for the workload networks are NOT declared here: the layout lives in
#    the registry and net-bridge-ensure builds them at boot (hps-node-init).
#    Only the kernel modules are loaded here.
#
# Nothing here holds a secret, a pool name, a disk or an address.
{ config, lib, pkgs, ... }:

{
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
      '';
    };
    onBoot = "ignore";
    onShutdown = "shutdown";
  };

  # libvirt 12.x ships virt-secret-init-encryption.service, which encrypts the
  # secret-store key with systemd-creds (TPM2 or the host key). On a
  # netboot-to-RAM node with no TPM it fails ("host key located on temporary
  # file system") and libvirtd.service fails on the dependency (sch-001,
  # 2026-11-09). HPS does not use libvirt secrets (guest disks are plain
  # block devices; keys live in the IPS keysafe), so the unit is a no-op.
  systemd.services.virt-secret-init-encryption = {
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.mkForce "${pkgs.coreutils}/bin/true";
    };
  };

  boot.kernelModules = [ "kvm-intel" "kvm-amd" "vhost_net" "8021q" "bridge" ];

  # AppArmor in the kernel and the userspace parser. libvirt (built with the
  # AppArmor security driver in nixpkgs) probes for it at start; whether it
  # actually confines guests on this image is reported by docs/CONFINEMENT.md
  # section "Verify on the node". mkDefault: one line turns it off.
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

  # After hps-node-init: that unit sets the transient hostname from the registry.
  # iscsid must not start before the name exists (it is socket activated, so
  # the requires/after below make the first connection wait for the file).
  systemd.services.hps-iscsi-initiator = {
    description = "HPS: iSCSI initiator name from the registry hostname";
    wantedBy = [ "multi-user.target" ];
    after = [ "hps-node-init.service" ];
    before = [ "iscsid.service" ];
    path = with pkgs; [ bash coreutils hostname ];
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
    util-linux
  ];
}
