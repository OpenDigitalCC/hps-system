# profiles/builder.nix - the image builder (role BLD): builds the HPS netboot
# artefact sets (nix/build.sh) on a cluster node instead of the development
# host, keeps its Nix store and its outputs on a local disk, and serves the
# outputs read-only for the IPS to pull (docs/BUILDER.md).
#
# What it carries:
#  - the HPS node base (hps-node.nix: ctrl-exec agent, pairing, node init,
#    monitor; hps-common.nix: hps-net, log forwarding, time, power-off); no
#    om3: a builder is no cluster member
#  - the builder disk: an ext4 filesystem labelled hps-builder, made once by
#    the node script builder-disk-prepare (on a device that carries no
#    signature) and mounted at every boot at /var/lib/hps-builder by
#    hps-builder-mount, which never formats
#  - the build store: a Nix store of its own on that disk
#    (/var/lib/hps-builder/root/nix, store URI local?root=...). The netboot
#    image's own store is a squashfs plus a RAM upper layer, registered anew
#    at every boot; nothing written there survives a reboot. The build runner
#    (hps-builder-run) copies the running system's closure into the disk
#    store, then runs nix/build.sh in a private mount namespace in which the
#    disk store is bind-mounted at /nix, so build.sh sees an ordinary /nix
#    and the store paths are the usual /nix/store ones (the binary cache
#    still applies). Nix runs there without the daemon, as root; the image's
#    nix-daemon stays on the RAM store and builds nothing.
#  - egress only through the proxy the IPS names on the kernel command line
#    (hps.proxy=, from the cluster key egress_proxy); nothing here names one
#  - hps-builder-http: darkhttpd serving /var/lib/hps-builder/out read-only on
#    port 8090 (GET only, no listing), from which the IPS pulls a pin with
#    hps-pin-fetch
#  - the builder node scripts, allowlisted here and so ONLY on this image
#
# Nothing here holds a secret, an image name, a disk, an interface or an address.
{ config, lib, pkgs, ... }:

let
  scriptsDir = ../../../node-manager/nixos-26/scripts;
  bootDir = ../../../node-manager/nixos-26/boot;
  # As hps-ctrl-exec.nix: each script its own derivation output, so the source
  # tree is in the system closure (a bare path loses its store context).
  mkScript = name: file: pkgs.writeTextFile {
    inherit name;
    executable = true;
    text = builtins.readFile file;
  };
  httpPort = 8090;
in
{
  imports = [ ../hps-node.nix ];

  hps.roles = "BLD";

  # ---- the builder disk -----------------------------------------------------
  environment.etc."hps/hps-builder-mount" = {
    source = bootDir + "/hps-builder-mount.sh";
    mode = "0755";
  };
  # The build runner, started by builder-build through systemd-run (a full
  # root transient unit: nix's sandbox needs namespaces and the build users,
  # which the executor's profile does not give a node script).
  environment.etc."hps/hps-builder-run" = {
    source = bootDir + "/hps-builder-run.sh";
    mode = "0755";
  };

  systemd.services.hps-builder-mount = {
    description = "HPS: mount the builder disk (label hps-builder) if present";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" "systemd-udevd.service" ];
    before = [ "hps-builder-http.service" ];
    path = with pkgs; [ bash coreutils util-linux config.systemd.package ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StandardOutput = "journal+console";
      StandardError = "journal+console";
      ExecStart = "${pkgs.bash}/bin/bash /etc/hps/hps-builder-mount";
    };
  };

  # ---- the outputs, read-only over HTTP ---------------------------------------
  # Only when the disk is mounted (builder-disk-prepare starts it after the
  # first mount). darkhttpd answers GET and HEAD only; no directory listing.
  systemd.services.hps-builder-http = {
    description = "HPS: serve the builder outputs read-only (darkhttpd)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "hps-builder-mount.service" ];
    wants = [ "network-online.target" ];
    unitConfig = {
      ConditionPathIsMountPoint = "/var/lib/hps-builder";
      RequiresMountsFor = "/var/lib/hps-builder";
    };
    serviceConfig = {
      Type = "simple";
      Restart = "on-failure";
      RestartSec = 10;
      DynamicUser = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      ReadOnlyPaths = [ "/var/lib/hps-builder/out" ];
      ExecStart = "${pkgs.darkhttpd}/bin/darkhttpd /var/lib/hps-builder/out --port ${toString httpPort} --no-listing --no-server-id";
    };
  };
  networking.firewall.allowedTCPPorts = [ httpPort ];

  # ---- builder node scripts, this image only ---------------------------------
  services.ctrl-exec-agent.scripts = {
      builder-disk-prepare.source = mkScript "builder-disk-prepare" (scriptsDir + "/builder-disk-prepare");
      builder-disk-prepare.options.profile = "node";
      builder-build.source = mkScript "builder-build" (scriptsDir + "/builder-build");
      builder-build.options.profile = "node";
      builder-status.source = mkScript "builder-status" (scriptsDir + "/builder-status");
      builder-status.options.profile = "node";
  };

  # What the scripts and the runner call, on the agent's scriptPath (the
  # system profile) and inside the build namespace (/run/current-system/sw).
  environment.systemPackages = with pkgs; [
    e2fsprogs # mkfs.ext4 (builder-disk-prepare)
    util-linux # blkid, findmnt, mount, unshare
    coreutils # dd (O_DIRECT reads), sha256sum, install
    curl
    jq
    gnutar
    gzip
    findutils
    gnused
    gnugrep
    darkhttpd
  ];
}
