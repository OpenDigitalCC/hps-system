# profiles/compute-apparmor.nix - the AppArmor layer of the compute role (CS-3.4a).
#
# Imported from compute.nix. UNEVALUATED on a node: the profile texts are parsed
# by checks.<system>.apparmor-profiles in flake.nix (apparmor_parser -Q), which
# reads them out of the evaluated node-converged configuration, so the check and
# the node see the same text. Whether libvirt then accepts and applies them is
# the lab step (docs/CONFINEMENT.md, "AppArmor layer").
#
# Why this file exists. libvirt in nixpkgs has the AppArmor security driver but
# the package ships no profiles, and its compile-time paths are not NixOS paths:
#  - the template and the per-guest profiles live in /var/lib/apparmor.d/libvirt
#    (APPARMOR_DIR, from --sysconfdir=/var/lib);
#  - virt-aa-helper runs the parser as the absolute path /sbin/apparmor_parser;
#  - the driver is only usable if the daemon itself is confined: libvirt looks
#    for "<its store path> (enforce)" (or "libvirtd (enforce)") in
#    /sys/kernel/security/apparmor/profiles, then needs TEMPLATE.qemu.
# The profiles below are upstream libvirt v12.2.0's (libvirtd, virt-aa-helper,
# the libvirt-qemu abstraction, TEMPLATE.qemu) with the Debian paths replaced by
# store paths. Disks are not in the abstraction: virt-aa-helper writes each
# guest's disks (the resolved /dev/mdN of its mirror) into
# /var/lib/apparmor.d/libvirt/<uuid>.files when the guest starts.
{ config, lib, pkgs, ... }:

let
  libvirt = config.virtualisation.libvirtd.package;
  qemu = config.virtualisation.libvirtd.qemu.package;
  aaParser = pkgs.apparmor-parser;

  # The upstream template, unchanged.
  templateQemu = ''
    #
    # This profile is for the domain whose UUID matches this file.
    #

    #include <tunables/global>

    profile LIBVIRT_TEMPLATE flags=(attach_disconnected) {
      #include <abstractions/libvirt-qemu>
    }
  '';

  # The parser resolves `#include <libvirt/<uuid>.files>` in a generated profile
  # through the Include lines of /etc/apparmor/parser.conf, which NixOS builds
  # from security.apparmor.packages. APPARMOR_DIR is /var/lib/apparmor.d, so a
  # package whose etc/apparmor.d points there adds it to the search path.
  varLibIncludes = pkgs.runCommand "hps-apparmor-var-lib" { } ''
    mkdir -p $out/etc
    ln -s /var/lib/apparmor.d $out/etc/apparmor.d
  '';

  # What a guest's QEMU may do, before virt-aa-helper adds its disks, sockets,
  # log and pid. Nothing under /nix/store is writable or executable except the
  # QEMU binaries. Upstream's Debian paths, sound, USB, spice, swtpm, passt,
  # ceph, GSS, save/restore helpers and PPC lines are left out: this role uses
  # none of them. virt-aa-helper adds what a particular guest definition needs.
  abstractionLibvirtQemu = ''
    #include <abstractions/base>
    #include <abstractions/consoles>
    #include <abstractions/nameservice>

    # QEMU runs as qemu-libvirtd with cleared capabilities (docs/CONFINEMENT.md);
    # these are the ceiling, not a grant of anything it does not already lack.
    capability setgid,
    capability setuid,
    capability ipc_lock,
    deny capability kill,

    network inet stream,
    network inet6 stream,

    ptrace (readby, tracedby) peer=${libvirt}/sbin/libvirtd,
    signal (receive) peer=${libvirt}/sbin/libvirtd,
    unix (send, receive) type=stream addr=none peer=(label=${libvirt}/sbin/libvirtd),

    /dev/kvm rw,
    /dev/vhost-net rw,
    /dev/net/tun rw,
    /dev/ptmx rw,
    @{PROC}/*/status r,
    # QEMU reads the cmdline of the process that signals it to terminate.
    @{PROC}/@{pid}/cmdline r,
    owner @{PROC}/@{pid}/task/@{tid}/comm rw,
    @{PROC}/sys/kernel/cap_last_cap r,
    @{PROC}/sys/vm/max_map_count r,
    @{PROC}/sys/vm/overcommit_memory r,
    owner @{PROC}/*/auxv r,
    /etc/libnl{,-3}/classid r,

    # Hugepage-backed guests.
    /dev/hugepages/libvirt/qemu/ r,
    owner /dev/hugepages/libvirt/qemu/** rw,

    # Shared libraries, QEMU modules and firmware are in the store: read and map
    # only. No write, and no execute (the binaries are listed below).
    /nix/store/** mr,

    # libvirtd links the firmware it found in QEMU's descriptions here.
    /run/libvirt/nix-ovmf/ r,
    /run/libvirt/nix-ovmf/* r,

    # UEFI variable stores.
    owner /var/lib/libvirt/qemu/nvram/*_VARS.fd rwk,
    owner /var/lib/libvirt/qemu/nvram/*_VARS.ms.fd rwk,

    # The QEMU binaries.
    ${qemu}/bin/qemu-system-x86_64 rmix,
    ${qemu}/bin/qemu-kvm rmix,

    /{,var/}tmp/ r,
    owner /{,var/}tmp/**/ r,

    # Host resource information QEMU gathers.
    /sys/devices/**/block/*/queue/max_segments r,
    /sys/devices/system/cpu/ r,
    /sys/devices/system/node/ r,
    /sys/devices/system/node/node[0-9]*/meminfo r,
    /sys/devices/system/node/*/cpumap r,
    /sys/module/vhost/parameters/max_mem_regions r,

    deny /dev/shm/lttng-ust-wait-* r,
    deny /run/shm/lttng-ust-wait-* r,

    include if exists <abstractions/libvirt-qemu.d>
  '';

  # The daemon. Named by its store path: that is the name libvirt's probe looks
  # up. Lenient on purpose (upstream: "we want to first focus on confining the
  # guests"), except that it cannot run the parser or write the profile dir.
  libvirtdProfile = ''
    #include <tunables/global>

    @{hextet}=[0-9a-f][0-9a-f][0-9a-f][0-9a-f]
    @{UUID}=@{hextet}@{hextet}-@{hextet}-@{hextet}-@{hextet}-@{hextet}@{hextet}@{hextet}
    @{LIBVIRT}="libvirt"

    ${libvirt}/sbin/libvirtd flags=(attach_disconnected) {
      #include <abstractions/base>
      #include <abstractions/dbus>

      capability kill,
      capability net_admin,
      capability net_raw,
      capability setgid,
      capability sys_admin,
      capability sys_module,
      capability sys_ptrace,
      capability sys_pacct,
      capability sys_nice,
      capability sys_chroot,
      capability setuid,
      capability dac_override,
      capability dac_read_search,
      capability fowner,
      capability chown,
      capability setpcap,
      capability mknod,
      capability fsetid,
      capability audit_write,
      capability ipc_lock,
      capability sys_rawio,
      capability bpf,
      capability perfmon,
      capability sys_resource,

      mount options=(rw,rslave)  -> /,
      mount options=(rw, nosuid) -> /{var/,}run/libvirt/qemu/*.dev/,
      umount /{var/,}run/libvirt/qemu/*.dev/,
      umount /dev/,
      mount options=(rw, move) /dev/ -> /{,var/}run/libvirt/qemu/*.dev/,
      mount options=(rw, move) /dev/** -> /{,var/}run/libvirt/qemu/*{,/},
      mount options=(rw, move) /{,var/}run/libvirt/qemu/*.dev/ -> /dev/,
      mount options=(rw, move) /{,var/}run/libvirt/qemu/*{,/} -> /dev/**,
      umount /{,var/}run/libvirt/qemu/*{,/},

      network inet stream,
      network inet dgram,
      network inet6 stream,
      network inet6 dgram,
      network netlink raw,
      network packet dgram,
      network packet raw,

      unix (send, receive) type=stream addr=none peer=(label=unconfined addr=none),

      ptrace (read,trace) peer=unconfined,
      ptrace (read,trace) peer=@{profile_name},
      ptrace (read,trace) peer=dnsmasq,
      ptrace (read,trace) peer=libvirt-*,

      signal (send) peer=dnsmasq,
      signal (read, send) peer=libvirt-*,
      signal (send) set=("kill", "term") peer=unconfined,

      # qemu-bridge-helper child profile (below).
      unix (send, receive) type=stream addr=none peer=(label=${libvirt}/sbin/libvirtd//qemu_bridge_helper),
      signal (send) set=("term") peer=${libvirt}/sbin/libvirtd//qemu_bridge_helper,

      unix (send, receive) type=stream addr=none peer=(label=libvirt-@{UUID}),
      unix (send, receive) type=stream addr=none peer=(label=unconfined),
      signal (read, send) peer=unconfined,

      / r,
      /** rwmkl,

      # Programs the daemon starts (qemu-img, ip, dnsmasq, iptables, ...). The
      # store is the NixOS equivalent of /usr/bin and /usr/sbin.
      /nix/store/*/bin/* PUx,
      /nix/store/*/sbin/* PUx,
      /run/current-system/sw/bin/* PUx,
      ${libvirt}/sbin/virtlogd pix,
      ${libvirt}/libexec/* PUxr,
      ${libvirt}/libexec/libvirt_parthelper ix,
      ${libvirt}/libexec/libvirt_iohelper ix,
      ${libvirt}/libexec/virt-aa-helper PUx,
      /var/lib/libvirt/virtd* ixr,
      /var/lib/libvirt/hooks/** rmix,

      # Force the use of virt-aa-helper: no parser, no profile writes. The
      # parser is reached through /sbin and through its store path (the kernel
      # mediates the resolved path).
      audit deny /sbin/apparmor_parser rwxl,
      audit deny ${aaParser}/bin/apparmor_parser rwxl,
      audit deny /var/lib/apparmor.d/libvirt/** wxl,
      audit deny /sys/kernel/security/apparmor/features rwxl,
      audit deny /sys/kernel/security/apparmor/matching rwxl,
      audit deny /sys/kernel/security/apparmor/.* rwxl,
      /sys/kernel/security/apparmor/profiles r,

      # Allow changing to the per-guest profiles.
      change_profile -> @{LIBVIRT}-@{UUID},

      ${qemu}/libexec/qemu-bridge-helper Cx -> qemu_bridge_helper,
      /run/wrappers/wrappers.*/qemu-bridge-helper Cx -> qemu_bridge_helper,
      profile qemu_bridge_helper {
        #include <abstractions/base>

        capability setuid,
        capability setgid,
        capability setpcap,
        capability net_admin,

        network inet stream,

        unix (send, receive) type=stream addr=none peer=(label=${libvirt}/sbin/libvirtd),
        signal (receive) set=("term") peer=${libvirt}/sbin/libvirtd,

        /dev/net/tun rw,
        /etc/qemu/** r,
        /nix/store/** mr,
        owner @{PROC}/*/status r,

        ${qemu}/libexec/qemu-bridge-helper rmix,
        /run/wrappers/wrappers.*/qemu-bridge-helper rmix,
      }

      include if exists <local/usr.sbin.libvirtd>
    }
  '';

  # The helper that writes a guest's profile and loads it through the parser.
  virtAaHelperProfile = ''
    #include <tunables/global>

    @{hextet}=[0-9a-f][0-9a-f][0-9a-f][0-9a-f]
    @{UUID}=@{hextet}@{hextet}-@{hextet}-@{hextet}-@{hextet}-@{hextet}@{hextet}@{hextet}

    ${libvirt}/libexec/virt-aa-helper {
      #include <abstractions/base>
      #include <abstractions/openssl>

      capability dac_override,
      capability dac_read_search,

      # Disks on a network filesystem.
      network inet,
      network inet6,

      deny @{PROC}/[0-9]*/mounts r,
      @{PROC}/[0-9]*/net/psched r,
      owner @{PROC}/[0-9]*/status r,
      @{PROC}/filesystems r,
      @{PROC}/@{pid}/fd/ r,

      /etc/libnl{,-3}/classid r,
      /dev/dri/{,*} r,

      /sys/devices/ r,
      /sys/devices/** r,
      /sys/bus/usb/devices/ r,

      # Block devices are valid guest disks (the helper only needs their
      # resolved path); it must not open them to probe a format.
      deny /dev/sd* r,
      deny /dev/vd* r,
      deny /dev/dm-* r,
      deny /dev/md[0-9]* r,
      deny /dev/md/* r,
      deny /dev/drbd[0-9]* r,
      deny /dev/dasd* r,
      deny /dev/nvme* r,
      deny /dev/zd[0-9]* r,
      deny /dev/mapper/ r,
      deny /dev/mapper/* r,

      # The helper's own libraries and the parser's includes are in the store.
      /nix/store/** mr,
      ${libvirt}/libexec/virt-aa-helper mr,
      /sbin/apparmor_parser Ux,
      ${aaParser}/bin/apparmor_parser Ux,

      /etc/apparmor.d/** r,
      /var/lib/apparmor.d/libvirt/ r,
      /var/lib/apparmor.d/libvirt/* r,
      /var/lib/apparmor.d/libvirt/libvirt-@{UUID}* rw,

      audit deny @{HOME}/.* mrwkl,
      audit deny @{HOME}/.*/ rw,
      audit deny @{HOME}/.*/** mrwkl,
      audit deny @{HOME}/bin/ rw,
      audit deny @{HOME}/bin/** mrwkl,
      @{HOME}/ r,
      @{HOME}/** r,
      /var/lib/libvirt/images/ r,
      /var/lib/libvirt/images/** r,
      /{media,mnt,opt,srv}/** r,
      /{,var/}run/libvirt/**/[sv]d[a-z] r,

      /**.img r,
      /**.raw r,
      /**.qcow{,2} r,
      /**.qed r,
      /**.vmdk r,
      /**.vhd r,
      /**.[iI][sS][oO] r,
      /**/disk{,.*} r,

      include if exists <local/usr.lib.libvirt.virt-aa-helper>
    }
  '';
in
{
  security.apparmor.packages = [ pkgs.apparmor-profiles varLibIncludes ];

  security.apparmor.includes = {
    "abstractions/libvirt-qemu" = abstractionLibvirtQemu;
    # Not loaded by apparmor.service (it loads policies only). libvirt reads it
    # from /var/lib/apparmor.d/libvirt/TEMPLATE.qemu (tmpfiles link below).
    "libvirt/TEMPLATE.qemu" = templateQemu;
  };

  security.apparmor.policies = {
    libvirtd = {
      state = "enforce";
      profile = libvirtdProfile;
    };
    virt-aa-helper = {
      state = "enforce";
      profile = virtAaHelperProfile;
    };
  };

  # Compile-time paths of the nixpkgs libvirt: see the header.
  systemd.tmpfiles.rules = [
    "d /var/lib/apparmor.d 0755 root root -"
    "d /var/lib/apparmor.d/libvirt 0755 root root -"
    "L+ /var/lib/apparmor.d/libvirt/TEMPLATE.qemu - - - - ${config.security.apparmor.includes."libvirt/TEMPLATE.qemu"}"
    "d /sbin 0755 root root -"
    "L+ /sbin/apparmor_parser - - - - ${aaParser}/bin/apparmor_parser"
  ];

  # The parser must have loaded the profiles before libvirtd starts (the daemon
  # must itself be confined for the driver to load), and a parser failure is a
  # libvirtd failure, not a silent fall back to the DAC driver.
  systemd.services.libvirtd = {
    after = [ "apparmor.service" ];
    requires = [ "apparmor.service" ];
  };
}
