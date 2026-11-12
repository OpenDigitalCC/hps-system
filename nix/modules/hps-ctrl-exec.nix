# hps-ctrl-exec.nix - the ctrl-exec agent every HPS NixOS image carries (node
# images and the audit image), its script allowlist and the pairing script.
#
# Operations rely on ctrl-exec (owner ruling 2026-11-09): any node command
# worked out at the console becomes an allowlisted script under
# node-manager/nixos-26/scripts/ - one script per action, a straight sequence of
# standard commands with argument checks, every command logged as it runs, no
# runtime library sourcing - and is used through `ced run` from then on. Add a
# script by adding its file there and one `scripts.<name>.source = mkScript ...`
# line below (every source must be a derivation output, never a bare path).
#
# The agent module copies each source out of the store to
# /opt/ctrl-exec-scripts/<name> (root-owned real file, as the agent's trust walk
# requires) and lists it in scripts.conf. Pairing is not declarative: the agent
# unit fails once (exit 78, not paired) and /etc/hps/hps-pair restarts it after
# the certificate arrives. hps-node-init (node images) and hps-audit-pair (audit
# image) both call hps-pair.
{ config, lib, pkgs, ctrl-exec, ... }:

let
  scriptsDir = ../../node-manager/nixos-26/scripts;
  # The agent module does `escapeShellArg (toString source)`, and toString drops
  # the store-path context: a bare path would leave the flake source tree out of
  # the system closure (and the netboot squashfs), so the install in the
  # activation script fails ("cannot stat .../hps-node.sh") and
  # /opt/ctrl-exec-scripts stays empty. writeTextFile makes each script its own
  # derivation output; the source tree is read at evaluation time.
  mkScript = name: file: pkgs.writeTextFile {
    inherit name;
    executable = true;
    text = builtins.readFile file;
  };
in
{
  imports = [ ctrl-exec.nixosModules.ctrl-exec-agent ];

  services.ctrl-exec-agent = {
    enable = true;
    openFirewall = true;
    scriptPath = "/run/wrappers/bin:/run/current-system/sw/bin";
    # The plugin's shebang is #!/usr/bin/env bash (CS-1.6); NixOS has no /bin/bash.
    # Every HPS script runs under profile "node" (see the profile below):
    # scriptType has no profile field, so the module's `options` attrset carries
    # profile=node onto each scripts.conf line (one options line per script).
    scripts = {
      hps-node.source = mkScript "hps-node" ../../node-manager/plugins/hps-node/hps-node.sh;
      hps-node.options.profile = "node";
      storage-pool-inspect.source = mkScript "storage-pool-inspect" (scriptsDir + "/storage-pool-inspect");
      storage-pool-inspect.options.profile = "node";
      storage-disks.source = mkScript "storage-disks" (scriptsDir + "/storage-disks");
      storage-disks.options.profile = "node";
      node-dmesg.source = mkScript "node-dmesg" (scriptsDir + "/node-dmesg");
      node-dmesg.options.profile = "node";
      node-journal.source = mkScript "node-journal" (scriptsDir + "/node-journal");
      node-journal.options.profile = "node";
      node-facts.source = mkScript "node-facts" (scriptsDir + "/node-facts");
      node-facts.options.profile = "node";
      storage-pool-import.source = mkScript "storage-pool-import" (scriptsDir + "/storage-pool-import");
      storage-pool-import.options.profile = "node";
      storage-pool-create.source = mkScript "storage-pool-create" (scriptsDir + "/storage-pool-create");
      storage-pool-create.options.profile = "node";
      storage-pool-create.options.input = "raw";
      storage-pool-destroy.source = mkScript "storage-pool-destroy" (scriptsDir + "/storage-pool-destroy");
      storage-pool-destroy.options.profile = "node";
      dataset-unlock.source = mkScript "dataset-unlock" (scriptsDir + "/dataset-unlock");
      dataset-unlock.options.profile = "node";
      dataset-unlock.options.input = "raw";
      storage-trim-check.source = mkScript "storage-trim-check" (scriptsDir + "/storage-trim-check");
      storage-trim-check.options.profile = "node";
      iscsi-export.source = mkScript "iscsi-export" (scriptsDir + "/iscsi-export");
      iscsi-export.options.profile = "node";
      iscsi-unexport.source = mkScript "iscsi-unexport" (scriptsDir + "/iscsi-unexport");
      iscsi-unexport.options.profile = "node";
      iscsi-status.source = mkScript "iscsi-status" (scriptsDir + "/iscsi-status");
      iscsi-status.options.profile = "node";
      storage-zvol-create.source = mkScript "storage-zvol-create" (scriptsDir + "/storage-zvol-create");
      storage-zvol-create.options.profile = "node";
      storage-zvol-destroy.source = mkScript "storage-zvol-destroy" (scriptsDir + "/storage-zvol-destroy");
      storage-zvol-destroy.options.profile = "node";
      storage-zvol-grow.source = mkScript "storage-zvol-grow" (scriptsDir + "/storage-zvol-grow");
      storage-zvol-grow.options.profile = "node";
      storage-zvol-list.source = mkScript "storage-zvol-list" (scriptsDir + "/storage-zvol-list");
      storage-zvol-list.options.profile = "node";
      storage-status.source = mkScript "storage-status" (scriptsDir + "/storage-status");
      storage-status.options.profile = "node";
      # CS-3.1
      net-bridge-ensure.source = mkScript "net-bridge-ensure" (scriptsDir + "/net-bridge-ensure");
      net-bridge-ensure.options.profile = "node";
      net-status.source = mkScript "net-status" (scriptsDir + "/net-status");
      net-status.options.profile = "node";
      net-capture.source = mkScript "net-capture" (scriptsDir + "/net-capture");
      net-capture.options.profile = "node";
      # CS-3.2: legs and md mirrors (mdadm and open-iscsi come with the compute profile, CS-3.1).
      leg-resolve.source = mkScript "leg-resolve" (scriptsDir + "/leg-resolve");
      leg-resolve.options.profile = "node";
      mirror-create.source = mkScript "mirror-create" (scriptsDir + "/mirror-create");
      mirror-create.options.profile = "node";
      mirror-assemble.source = mkScript "mirror-assemble" (scriptsDir + "/mirror-assemble");
      mirror-assemble.options.profile = "node";
      mirror-status.source = mkScript "mirror-status" (scriptsDir + "/mirror-status");
      mirror-status.options.profile = "node";
      mirror-rejoin.source = mkScript "mirror-rejoin" (scriptsDir + "/mirror-rejoin");
      mirror-rejoin.options.profile = "node";
      mirror-stop.source = mkScript "mirror-stop" (scriptsDir + "/mirror-stop");
      mirror-stop.options.profile = "node";
      mirror-detach-leg.source = mkScript "mirror-detach-leg" (scriptsDir + "/mirror-detach-leg");
      mirror-detach-leg.options.profile = "node";
      # CS-3.3: VM lifecycle, image fetch, confinement report (virsh and qemu-img come with the compute profile; curl must be on the system path).
      image-fetch.source = mkScript "image-fetch" (scriptsDir + "/image-fetch");
      image-fetch.options.profile = "node";
      vm-define.source = mkScript "vm-define" (scriptsDir + "/vm-define");
      vm-define.options.profile = "node";
      vm-image-write.source = mkScript "vm-image-write" (scriptsDir + "/vm-image-write");
      vm-image-write.options.profile = "node";
      # Scale test probes: the cloud-init NoCloud seed onto the freshly written boot disk (the seed arrives on stdin; partx, blkid and mount come with util-linux, jq with the common profile).
      vm-seed-write.source = mkScript "vm-seed-write" (scriptsDir + "/vm-seed-write");
      vm-seed-write.options.profile = "node";
      vm-seed-write.options.input = "raw";
      vm-start.source = mkScript "vm-start" (scriptsDir + "/vm-start");
      vm-start.options.profile = "node";
      vm-stop.source = mkScript "vm-stop" (scriptsDir + "/vm-stop");
      vm-stop.options.profile = "node";
      vm-disk-resize.source = mkScript "vm-disk-resize" (scriptsDir + "/vm-disk-resize");
      vm-disk-resize.options.profile = "node";
      vm-disk-hotplug.source = mkScript "vm-disk-hotplug" (scriptsDir + "/vm-disk-hotplug");
      vm-disk-hotplug.options.profile = "node";
      vm-status.source = mkScript "vm-status" (scriptsDir + "/vm-status");
      vm-status.options.profile = "node";
      vm-undefine.source = mkScript "vm-undefine" (scriptsDir + "/vm-undefine");
      vm-undefine.options.profile = "node";
      vm-console-log.source = mkScript "vm-console-log" (scriptsDir + "/vm-console-log");
      vm-console-log.options.profile = "node";
      vm-confinement-report.source = mkScript "vm-confinement-report" (scriptsDir + "/vm-confinement-report");
      vm-confinement-report.options.profile = "node";
      # CS-3.5: OpenSVC (om comes with hps-opensvc.nix; the secret arrives on stdin).
      osvc-status.source = mkScript "osvc-status" (scriptsDir + "/osvc-status");
      osvc-status.options.profile = "node";
      osvc-object-set.source = mkScript "osvc-object-set" (scriptsDir + "/osvc-object-set");
      osvc-object-set.options.profile = "node";
      osvc-object-start.source = mkScript "osvc-object-start" (scriptsDir + "/osvc-object-start");
      osvc-object-start.options.profile = "node";
      osvc-object-stop.source = mkScript "osvc-object-stop" (scriptsDir + "/osvc-object-stop");
      osvc-object-stop.options.profile = "node";
      osvc-object-delete.source = mkScript "osvc-object-delete" (scriptsDir + "/osvc-object-delete");
      osvc-object-delete.options.profile = "node";
      osvc-freeze.source = mkScript "osvc-freeze" (scriptsDir + "/osvc-freeze");
      osvc-freeze.options.profile = "node";
      osvc-thaw.source = mkScript "osvc-thaw" (scriptsDir + "/osvc-thaw");
      osvc-thaw.options.profile = "node";
      osvc-secret-set.source = mkScript "osvc-secret-set" (scriptsDir + "/osvc-secret-set");
      osvc-secret-set.options.profile = "node";
      osvc-secret-set.options.input = "raw";
      # IPS-12: read-only; prints the node CA file (mtime + base64) for the IPS keysafe.
      osvc-ca-export.source = mkScript "osvc-ca-export" (scriptsDir + "/osvc-ca-export");
      osvc-ca-export.options.profile = "node";
      # Lab test only (rig test 2); remove with the script once the rig results are recorded.
      osvc-rig-probe.source = mkScript "osvc-rig-probe" (scriptsDir + "/osvc-rig-probe");
      osvc-rig-probe.options.profile = "node";
      # IPS-04: clean power-off (systemctl poweroff, queued); the storage shutdown is hps-shutdown-storage.service.
      node-poweroff.source = mkScript "node-poweroff" (scriptsDir + "/node-poweroff");
      node-poweroff.options.profile = "node";
      # CS-3.12a: node-to-node iSCSI proof (open-iscsi comes with the compute profile).
      iscsi-login-test.source = mkScript "iscsi-login-test" (scriptsDir + "/iscsi-login-test");
      iscsi-login-test.options.profile = "node";
      # Scale test phase 2: a host address on a storage or transit VLAN (hps-node net-up).
      net-vlan-address.source = mkScript "net-vlan-address" (scriptsDir + "/net-vlan-address");
      net-vlan-address.options.profile = "node";
      # VXLAN workload networks over the transit VLAN (hps-node net-up, hps-workload).
      net-vxlan-ensure.source = mkScript "net-vxlan-ensure" (scriptsDir + "/net-vxlan-ensure");
      net-vxlan-ensure.options.profile = "node";
    };
    # The executor runs on NixOS nodes (ctrl-exec-executor.service, root, plus
    # executor_socket in agent.conf). Without it the agent runs scripts itself
    # as User=ctrl-exec-agent under PrivateDevices with no capabilities, and
    # node operations (zpool, mdadm, virsh, targetcli) fail for want of
    # /dev/zfs and /proc/self/mounts. With it the profile below is enforced:
    # run_as root. (ADR 0003 left the executor off for Alpine nodes; --async
    # runs are refused while it is on.)
    executor.enable = true;
    profiles.default = {
      run_as = "root";
      no_new_privileges = "yes";
    };
    # Profile "node": HPS node operations (zpool/zfs, dmesg, lsblk, smartctl,
    # hostnamectl, systemctl, later mdadm, virsh, targetcli, network changes).
    # The node scripts are the readable manual runbook and are meant to run as
    # full root, so a recovery by hand at the console and a `ced run` do the
    # same thing. The executor drops every capability a profile does not list,
    # even for run_as root: ZFS ioctls need CAP_SYS_ADMIN and dmesg needs
    # CAP_SYSLOG, so root with no caps saw "no pools available to import" and
    # "read kernel buffer failed". The list below is the set storage, compute
    # and network actions need in phases 1-3. The executor has no `all` value:
    # caps takes CAP_* names separated by commas or whitespace, at most 32, and
    # no inline comments on the value line.
    # `writable` is left out on purpose: setting it makes the whole filesystem
    # read-only except the listed paths, while omitting it leaves the
    # filesystem as it is (only /etc/ctrl-exec-agent and /var/lib/ctrl-exec-agent
    # are read-only to every profile). The scripts write /run/hps, /etc/zfs
    # (zpool.cache), /var/lib and /dev, so no path list could be both short and
    # complete. `default` above stays the restrictive baseline for any script
    # that names no profile; the allowlist and each script's argument checks are
    # the control, not the sandbox (docs/SECURITY.md).
    profiles.node = {
      run_as = "root";
      no_new_privileges = "yes";
      caps = lib.concatStringsSep "," [
        "CAP_SYS_ADMIN" "CAP_SYSLOG" "CAP_SYS_RAWIO"
        "CAP_DAC_OVERRIDE" "CAP_DAC_READ_SEARCH" "CAP_FOWNER" "CAP_CHOWN" "CAP_FSETID"
        "CAP_MKNOD" "CAP_SYS_MODULE"
        "CAP_NET_ADMIN" "CAP_NET_RAW" "CAP_NET_BIND_SERVICE"
        "CAP_KILL" "CAP_SETUID" "CAP_SETGID"
        "CAP_SYS_RESOURCE" "CAP_SYS_NICE" "CAP_IPC_LOCK" "CAP_SYS_BOOT"
        "CAP_SYS_PTRACE" "CAP_LINUX_IMMUTABLE"
      ];
    };
  };

  # No certificate, no start attempt: the unit is skipped (not failed) until
  # pairing has written agent.crt; /etc/hps/hps-pair restarts it after that.
  systemd.services.ctrl-exec-agent.unitConfig.ConditionPathExists = "/etc/ctrl-exec-agent/agent.crt";

  # Everything the scripts call must be on scriptPath (the system profile).
  environment.systemPackages = with pkgs; [
    coreutils gnugrep gawk procps util-linux iproute2 smartmontools
    config.systemd.package config.boot.zfs.package
  ];

  environment.etc."hps/hps-pair" = {
    source = ../../node-manager/nixos-26/boot/hps-pair.sh;
    mode = "0755";
  };
}
