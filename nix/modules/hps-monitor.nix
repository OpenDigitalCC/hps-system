# hps-monitor.nix - resource monitoring on every node image (node-base,
# node-converged; not the audit image). See docs/MONITORING.md.
#
# The ctrl-exec nagios-check agent script (from the pinned ctrl-exec-plugins
# input) is allowlisted as the node script `nagios-check`. The IPS decides what
# is checked and when (it sends check names: `hps-monitor`); the node decides
# how, in /etc/nagios-checks/checks.conf, generated below. The script reads no
# input, so the allowlist entry has no `input` option (arguments are the check
# names, passed through as for every other script with arguments).
#
# Nothing here is secret; the checks only read the system (profile node).
{ config, lib, pkgs, ctrl-exec-plugins, ... }:

let
  pluginSrc = "${ctrl-exec-plugins}/ce-agent-plugins/nagios-check";

  # nagios-check.pl starts with #!/usr/bin/perl, which NixOS does not have.
  nagiosCheck = pkgs.runCommand "nagios-check" { nativeBuildInputs = [ pkgs.perl ]; } ''
    install -m 0755 ${pluginSrc}/nagios-check.pl "$out"
    patchShebangs "$out"
  '';

  # One directory of real files (nagios-check refuses a plugin that resolves
  # outside the directory it was found in): the standard plugins HPS uses, copied
  # out of monitoring-plugins wherever that package keeps them (the build fails
  # when one is missing), plus check_mem from the input and check_zpool.
  plugins = pkgs.runCommand "hps-nagios-plugins" { nativeBuildInputs = [ pkgs.bash ]; } ''
    mkdir -p "$out"
    for p in check_disk check_load check_procs; do
      f=$(find ${pkgs.monitoring-plugins} \( -type f -o -type l \) -name "$p" | head -n 1)
      test -n "$f" || { echo "$p not found in monitoring-plugins" >&2; exit 1; }
      cp -L "$f" "$out/$p"
    done
    install -m 0755 ${pluginSrc}/plugins/check_mem "$out/check_mem"
    install -m 0755 ${../../node-manager/nixos-26/plugins/check_zpool} "$out/check_zpool"
    patchShebangs "$out/check_mem" "$out/check_zpool"
    ${usagePlugins}
  '';

  # The usage checks (docs/MONITORING.md): HPS's own bash plugins. Each has a
  # "# @HPS_PATH@" line that becomes a PATH of the tools it needs (coreutils,
  # awk), because nagios-check passes on whatever PATH the agent has; zpool and
  # virsh are substituted as absolute store paths where they are used. The role
  # plugins are installed only where the role is, so the closure of a node does
  # not carry libvirt or ZFS for them.
  pluginSrcDir = ../../node-manager/nixos-26/plugins;
  toolPath = lib.makeBinPath [ pkgs.coreutils pkgs.gawk pkgs.jq ];
  usagePlugin = name: extra: ''
    install -m 0755 ${pluginSrcDir + "/${name}"} "$out/${name}"
    patchShebangs "$out/${name}"
    substituteInPlace "$out/${name}" --replace-fail '# @HPS_PATH@' 'export PATH=${toolPath}:"$PATH"' ${extra}
  '';
  usagePlugins = lib.concatStrings (
    [
      (usagePlugin "check_cpu" "")
      (usagePlugin "check_net" "")
      (usagePlugin "check_diskio" "")
      (usagePlugin "check_fs" "")
      (usagePlugin "check_swap_use" "")
    ]
    ++ lib.optional isStorage (usagePlugin "check_zpool_io"
      "--replace-fail 'HPS_ZPOOL:-zpool}' 'HPS_ZPOOL:-${config.boot.zfs.package}/bin/zpool}'")
    ++ lib.optional isCompute (usagePlugin "check_vms"
      "--replace-fail 'HPS_VIRSH:-virsh}' 'HPS_VIRSH:-${config.virtualisation.libvirtd.package}/bin/virsh}'")
    ++ lib.optional hasOsvc (usagePlugin "check_osvc_hb"
      "--replace-fail 'HPS_OM:-om}' 'HPS_OM:-${pkgs.om3}/bin/om}'")
  );

  isStorage = lib.hasInfix "SCH" config.hps.roles;
  isCompute = lib.hasInfix "TCH" config.hps.roles;
  # om3 runs here (hps-opensvc.nix sets this): the osvc_hb check
  hasOsvc = config.hps.monitor.osvc;
  isCnh = lib.hasInfix "CNH" config.hps.roles;
  isBuilder = lib.hasInfix "BLD" config.hps.roles;

  # Persistent filesystems (docs/MONITORING.md): WARNING at diskWarn percent
  # used, CRITICAL at diskCrit, space and inodes. These are the node's own
  # grades; hps-monitor on the IPS grades the same figures again with the
  # cluster keys monitor_disk_warn_pct and monitor_disk_crit_pct, so a
  # threshold change needs no new image. Each role disk has its own check,
  # disk_<mount slug>; disk_other is every other persistent local filesystem
  # (not RAM, pseudo, network or ZFS: pool capacity is zpool_cap's).
  diskWarn = "80";
  diskCrit = "90";
  diskThresholds = "-w ${diskWarn} -c ${diskCrit}";
  roleMounts =
    lib.optionals isCnh [ "/var/lib/containers" "/var/lib/hps-ips" ]
    ++ lib.optional isBuilder "/var/lib/hps-builder";
  mountSlug = m: lib.replaceStrings [ "/" "-" ] [ "_" "_" ] (lib.removePrefix "/" m);
  diskLines =
    map (m: "disk_${mountSlug m} = check_fs -p ${m} ${diskThresholds}") roleMounts
    ++ [ ("disk_other = check_fs -a" + lib.concatMapStrings (m: " -x ${m}") roleMounts + " ${diskThresholds}") ];

  # The set. Thresholds are the plugin's example. On a netbooted node "/" is a
  # tmpfs, so disk_root is RAM that files written to / use up; the persistent
  # filesystems are diskLines (check_fs) and, on a storage node, zpool_cap.
  checksConf = lib.concatStringsSep "\n" ([
    "# Generated by hps-monitor.nix; the IPS (hps-monitor) names the checks, this file says how."
    "plugin_dir = ${plugins}"
    "timeout = 10"
    "budget = 50"
    "disk_root = check_disk -w 20% -c 10% -p /"
    "load = check_load -r -w 1.5,1.2,1 -c 3,2.5,2"
    "mem = check_mem -w 10 -c 5"
    # swap space and swap traffic; a node with no swap (the usual RAM-booted
    # node) is OK "no swap configured", swap_total=0
    "swap = check_swap_use -w 50 -c 80"
    # -k: user-space processes only; a 48-thread host has hundreds of kernel
    # threads (lab DL360: 747 processes in all, WARNING at the old 400)
    "procs = check_procs -k -w 1000 -c 2000"
    # usage, not alarms: trend and baseline data (one 1 s sample each, see
    # docs/MONITORING.md); OK whenever they can read their source
    "cpu = check_cpu"
    "net = check_net"
    "diskio = check_diskio"
  ]
  ++ diskLines
  ++ lib.optional hasOsvc "osvc_hb = check_osvc_hb"
  ++ lib.optionals isStorage [
    # check_disk with no path finds no disk on a RAM-booted node ("No disks
    # were found", UNKNOWN on the lab DL360); pool health is check_zpool's,
    # pool capacity check_zpool -m cap's
    "zpool = check_zpool"
    "zpool_io = check_zpool_io"
    # how full each pool is (zpool list capacity), health aside
    "zpool_cap = check_zpool -m cap ${diskThresholds}"
  ]
  ++ lib.optional isCompute "vms = check_vms") + "\n";
in
{
  options.hps.monitor.osvc = lib.mkOption {
    type = lib.types.bool;
    default = false;
    internal = true;
    description = "om3 runs on this node (set by hps-opensvc.nix): the osvc_hb check is offered.";
  };

  config = {
    services.ctrl-exec-agent.scripts.nagios-check = {
      source = nagiosCheck;
      options.profile = "node";
    };

    environment.etc."nagios-checks/checks.conf" = {
      text = checksConf;
      mode = "0644";
    };
  };
}
