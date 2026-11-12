# profiles/container-host.nix - the container host (CNH) role: podman containers,
# om3 membership, the HPS node base; one profile for metal and for guests
# (CS-3.11, plans/cs311-container-host.md).
#
# UNEVALUATED: nix is not installed on the development host. Option names were
# written against the nixpkgs 26.05 module set (virtualisation/podman,
# virtualisation/containers) but this file has not been through
# `nix flake check`.
#
# What it carries:
#  - the HPS node base (hps-node.nix: ctrl-exec agent, pairing, node init,
#    monitor; hps-common.nix: hps-net, log forwarding, time, power-off)
#  - om3 (hps-opensvc.nix, unchanged): membership, health, local services
#  - podman with the netavark network backend, root (rootless later), overlay
#    storage in /var/lib/containers. The root is RAM: container storage
#    persists only on the CNH disk, made once by the node script
#    cnh-disk-prepare (an ext4 filesystem labelled hps-cnh, on a device that
#    carries no signature) and mounted at every boot by hps-cnh-mount below,
#    which never formats.
#  - hps-ips.service: the cluster IPS container, run when cnh-ips-run has
#    written /var/lib/hps-ips/ips.env (on the CNH disk) - docs/CONTAINER-HOST.md
#  - the CNH node scripts, allowlisted here and so ONLY on this image
#    (services.ctrl-exec-agent.scripts merges with hps-ctrl-exec.nix)
#
# What it leaves out on purpose: libvirt/QEMU (compute.nix), LIO and the pool
# tools (storage.nix), a ZFS pool of its own. ZFS userland and the kernel
# module still come with hps-common.nix (every image has them); trimming them
# from this image is a later size item.
#
# Nothing here holds a secret, an image name, a disk, an interface or an address.
{ config, lib, pkgs, ... }:

let
  scriptsDir = ../../../node-manager/nixos-26/scripts;
  # As hps-ctrl-exec.nix: each script its own derivation output, so the source
  # tree is in the system closure (a bare path loses its store context).
  mkScript = name: file: pkgs.writeTextFile {
    inherit name;
    executable = true;
    text = builtins.readFile file;
  };
in
{
  imports = [ ../hps-node.nix ../hps-opensvc.nix ];

  hps.roles = "CNH";

  # ---- podman ---------------------------------------------------------------
  virtualisation.podman = {
    enable = true;
    # No docker CLI alias and no docker socket: HPS calls podman by name.
    dockerCompat = false;
    dockerSocket.enable = false;
  };
  virtualisation.containers.containersConf.settings.network.network_backend = "netavark";

  # The cluster IPS's operator API (ctrl-exec API, TLS + bearer token,
  # CTRL_EXEC_OPERATOR_API_PORT), reached from outside on the CNH's own address
  # once cnh-ips-operator-init has set operator_api_listen. hps-ips-launch only
  # opens the IPS's provisioning interface.
  networking.firewall.allowedTCPPorts = [ 7445 ];
  virtualisation.containers.storage.settings.storage = {
    driver = "overlay";
    graphroot = "/var/lib/containers/storage";
    runroot = "/run/containers/storage";
  };

  # ---- the CNH disk ---------------------------------------------------------
  environment.etc."hps/hps-cnh-mount" = {
    source = ../../../node-manager/nixos-26/boot/hps-cnh-mount.sh;
    mode = "0755";
  };

  systemd.services.hps-cnh-mount = {
    description = "HPS: mount the container host disk (label hps-cnh) if present";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" "systemd-udevd.service" ];
    # Not before podman.socket: sockets start before basic.target, which this
    # unit (default dependencies) is after: an ordering cycle (lab
    # 2026-11-11). podman.service is what uses the storage.
    before = [ "hps-ips.service" "podman.service" ];
    path = with pkgs; [ bash coreutils util-linux config.systemd.package ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StandardOutput = "journal+console";
      StandardError = "journal+console";
      ExecStart = "${pkgs.bash}/bin/bash /etc/hps/hps-cnh-mount";
    };
  };

  # ---- the cluster IPS container ---------------------------------------------
  environment.etc."hps/hps-ips-launch" = {
    source = ../../../node-manager/nixos-26/boot/hps-ips-launch.sh;
    mode = "0755";
  };

  # Static unit, started only when cnh-ips-run has written ips.env on the CNH
  # disk: a unit file generated at run time would be lost with the RAM root on
  # every reboot, the settings on the disk are not. Restart=always keeps the
  # IPS up; cnh-ips-stop stops it and renames ips.env so it stays off.
  systemd.services.hps-ips = {
    description = "HPS: the cluster IPS container (podman), configured by cnh-ips-run";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "hps-cnh-mount.service" "firewall.service" ];
    wants = [ "network-online.target" ];
    requires = [ "hps-cnh-mount.service" ];
    unitConfig = {
      ConditionPathExists = "/var/lib/hps-ips/ips.env";
      StartLimitIntervalSec = 0;
    };
    path = with pkgs; [ bash coreutils iproute2 config.networking.firewall.package config.virtualisation.podman.package ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = 10;
      TimeoutStopSec = 60;
      ExecStart = "${pkgs.bash}/bin/bash /etc/hps/hps-ips-launch start";
      ExecStop = "${pkgs.bash}/bin/bash /etc/hps/hps-ips-launch stop";
      ExecStopPost = "${pkgs.bash}/bin/bash /etc/hps/hps-ips-launch stop-post";
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };

  # ---- CNH node scripts (CS-3.11), this image only ---------------------------
  services.ctrl-exec-agent.scripts = {
      cnh-disk-prepare.source = mkScript "cnh-disk-prepare" (scriptsDir + "/cnh-disk-prepare");
      cnh-disk-prepare.options.profile = "node";
      cnh-disk-grow.source = mkScript "cnh-disk-grow" (scriptsDir + "/cnh-disk-grow");
      cnh-disk-grow.options.profile = "node";
      cnh-image-load.source = mkScript "cnh-image-load" (scriptsDir + "/cnh-image-load");
      cnh-image-load.options.profile = "node";
      cnh-ips-bootstrap.source = mkScript "cnh-ips-bootstrap" (scriptsDir + "/cnh-ips-bootstrap");
      cnh-ips-bootstrap.options.profile = "node";
      cnh-ips-cleanup.source = mkScript "cnh-ips-cleanup" (scriptsDir + "/cnh-ips-cleanup");
      cnh-ips-cleanup.options.profile = "node";
      cnh-ips-cluster-bootstrap.source = mkScript "cnh-ips-cluster-bootstrap" (scriptsDir + "/cnh-ips-cluster-bootstrap");
      cnh-ips-cluster-bootstrap.options.profile = "node";
      cnh-ips-run.source = mkScript "cnh-ips-run" (scriptsDir + "/cnh-ips-run");
      cnh-ips-run.options.profile = "node";
      cnh-ips-stop.source = mkScript "cnh-ips-stop" (scriptsDir + "/cnh-ips-stop");
      cnh-ips-stop.options.profile = "node";
      # Prints the IPS's first operator credential: output=confidential, so the
      # dispatcher never stores its stdout and an async run is refused
      # (ctrl-exec >= 0.13.0, REFERENCE.md "Confidential output").
      cnh-ips-operator-init.source = mkScript "cnh-ips-operator-init" (scriptsDir + "/cnh-ips-operator-init");
      cnh-ips-operator-init.options.profile = "node";
      cnh-ips-operator-init.options.output = "confidential";
  };

  # What the CNH scripts call, on the agent's scriptPath (the system profile).
  environment.systemPackages = with pkgs; [
    e2fsprogs # mkfs.ext4 (cnh-disk-prepare), resize2fs (cnh-disk-grow)
    util-linux # blkid, findmnt, mount
    curl
    jq
    gnutar
    gzip
    iproute2
    config.networking.firewall.package # iptables (hps-ips-launch)
    config.virtualisation.podman.package
  ];
}
