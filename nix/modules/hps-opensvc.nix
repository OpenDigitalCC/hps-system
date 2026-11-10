# hps-opensvc.nix - OpenSVC v3 (om3) on an HPS node profile (node-converged imports it): membership, health and
# local service management. Never placement (docs/OPENSVC.md, ADR 0001).
#
# Generic on purpose: a container-host profile imports this module unchanged (the
# node-base image, the bare ctrl-exec agent, does not carry it).
# It installs om (pkgs.om3, the overlay in flake.nix), the opensvc-daemon unit
# and the boot-time generator hps-osvc-config, which writes /etc/opensvc/
# cluster.conf and node.conf from the IPS. The image holds no cluster name, node
# list, address or secret; the cluster secret is delivered by the IPS over
# ctrl-exec (osvc-secret-set), so opensvc-daemon starts only once it is there.
#
# The node scripts that drive objects (osvc-status, osvc-object-*, osvc-freeze,
# osvc-thaw, osvc-secret-set) are allowlisted in hps-ctrl-exec.nix.
{ config, pkgs, ... }:

{
  environment.systemPackages = [ pkgs.om3 ];

  environment.etc."hps/hps-osvc-config" = {
    source = ../../node-manager/nixos-26/boot/hps-osvc-config.sh;
    mode = "0755";
  };

  # Config and state on the RAM root: nothing persists across a boot, and the
  # config is rewritten from the IPS each time the daemon starts.
  systemd.tmpfiles.rules = [
    "d /etc/opensvc 0700 root root -"
    "d /var/lib/opensvc 0700 root root -"
  ];

  # The listener (osvc_listener_port, default 1215) and the unicast heartbeat
  # (om3 default port 10000), both TCP. The rule is static: a cluster key other
  # than 1215 is not reachable until this list follows it (hps-osvc-config warns).
  networking.firewall.allowedTCPPorts = [ 1215 10000 ];

  systemd.services.opensvc-daemon = {
    description = "OpenSVC v3 daemon (membership, health, local service management)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "hps-node-init.service" ];
    wants = [ "network-online.target" ];
    # No cluster secret yet: stay down. osvc-secret-set restarts the unit once
    # it has stored the secret.
    unitConfig = {
      ConditionPathExists = "/run/hps/osvc-cluster-secret";
      StartLimitIntervalSec = 0;
    };
    path = with pkgs; [
      bash coreutils curl jq iproute2 gawk gnugrep gnused hostname util-linux
      config.systemd.package pkgs.om3
    ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = 15;
      # opensvc.env (OSVC_DAEMON_ARGS, the log level) is written by the generator.
      EnvironmentFile = "-/run/hps/opensvc.env";
      ExecStartPre = "${pkgs.bash}/bin/bash /etc/hps/hps-osvc-config";
      ExecStart = "${pkgs.om3}/bin/om daemon run $OSVC_DAEMON_ARGS";
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };
}
