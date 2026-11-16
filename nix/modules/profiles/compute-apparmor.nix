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
# The profiles (node-manager/apparmor/: libvirtd, virt-aa-helper, the
# libvirt-qemu abstraction, TEMPLATE.qemu) are upstream libvirt v12.2.0's with the
# Debian paths replaced by store paths. The text is in those plain files, which
# the node bundle of a STARTER node carries as well; this file only fills in the
# store paths. NOT EVALUATED when the text was moved out of this file (no Nix on
# the host that did it). Disks are not in the abstraction: virt-aa-helper writes each
# guest's disks (the resolved /dev/mdN of its mirror) into
# /var/lib/apparmor.d/libvirt/<uuid>.files when the guest starts.
{ config, lib, pkgs, ... }:

let
  libvirt = config.virtualisation.libvirtd.package;
  qemu = config.virtualisation.libvirtd.qemu.package;
  aaParser = pkgs.apparmor-parser;

  # The profile texts are plain files, shared with the node bundle of a STARTER
  # node (node-manager/apparmor/, docs/BUNDLE.md "AppArmor"): one copy in the
  # tree. @@NAME@@ in a file stands for the store path of that package.
  aaText = file: builtins.replaceStrings
    [ "@@LIBVIRT@@" "@@QEMU@@" "@@APPARMOR_PARSER@@" ]
    [ "${libvirt}" "${qemu}" "${aaParser}" ]
    (builtins.readFile (../../../node-manager/apparmor + "/${file}"));

  # nixpkgs wraps the daemon: sbin/libvirtd is a makeWrapper bash script that
  # sets PATH and execs sbin/.libvirtd-wrapped (the ELF). The kernel attaches a
  # profile at exec by the path of the file exec'd, and libvirt's driver probe
  # resolves /proc/self/exe, which is the wrapped binary, so the profile is
  # named by that path. The wrapper script needs no profile: it runs unconfined
  # (as started by systemd) and its exec of the ELF attaches the profile. virt-aa-helper
  # in libexec is a plain ELF. (The name is in the text files, as
  # @@LIBVIRT@@/sbin/.libvirtd-wrapped.)

  # The upstream template, unchanged.
  templateQemu = aaText "TEMPLATE.qemu";

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
  abstractionLibvirtQemu = aaText "libvirt-qemu";

  # The daemon. Named by its store path: that is the name libvirt's probe looks
  # up. Lenient on purpose (upstream: "we want to first focus on confining the
  # guests"), except that it cannot run the parser or write the profile dir.
  libvirtdProfile = aaText "libvirtd";

  # The helper that writes a guest's profile and loads it through the parser.
  virtAaHelperProfile = aaText "virt-aa-helper";
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
