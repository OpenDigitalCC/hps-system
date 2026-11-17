# shellcheck shell=bash
# adapter/nixos.sh - the NixOS part of the node bundle. Sourced by init; nothing
# runs when it is sourced.
#
# The per-OS part of HPS is three things (STRATEGY.md): how to boot the OS, how
# to add a package, how to start a service. Everything else in the bundle is
# OS-neutral. For NixOS:
#
#   boot arguments  not here: the IPS issues the kernel line
#                   (lib/functions.d/nixos-boot-functions.sh, nixos_starter_boot_lines)
#   pkg_add         install store paths from the IPS's binary cache
#   pkg_realise     the same, one path, outside the profile (the agent)
#   svc_start       a run-time systemd unit, in RAM (/run/systemd/system)
#   svc_reload      reload a service the starter already has (sshd)
#   svc_restart_later  restart services from a timer, after the caller has answered
#   svc_mask        keep a unit the OS ships from ever starting (the md last-resort timers)
#   svc_env         give a service of the OS a setting of its environment (hostnamed's file)
#   fw_open         open a TCP port in the host firewall (the iSCSI portal, om3)
#
# and the small differences init and role ask the adapter about (adapter/alpine.sh has
# the same names): pkg_kind, pkg_agent_dir, pkg_nagios_check, pkg_nagios_plugins,
# pkg_stamp (what a package line is, and where it is), time_sync, net_keep_lease, host_cgroups,
# user_unlock, sudo_grant,
# hostname_apply, os_compat, log_forward, md_monitor, zfs_hostid_set, svc_ensure,
# iscsid_conf_source.
#
# What an adapter for another OS provides (Alpine: plan step 4, adapter/alpine.sh,
# chosen by init's "case $os"): the same function names, with the same arguments,
# and these variables, set by adapter_init:
#   PKG_BIN        directory where added packages' programs appear
#   PKG_SBIN       the same for programs a package installs under sbin (open-iscsi,
#                  libvirt)
#   PKG_ETC        the same for the files a package installs under etc (the AppArmor
#                  abstractions: etc/apparmor.d)
#   SYS_BIN        the starter's own program directories, colon separated
#   LIBVIRT_CONF_DIR  where the libvirt of this OS reads libvirtd.conf and qemu.conf
#   SUDO_GROUP     the group whose members have sudo
#   PKG_LINE_RE    the shape of a line of the IPS's package list
#   ADAPTER_PATH_EXTRA  a directory added to the agent's script_path (the compatibility
#                  programs of an OS without systemd), or empty
#   ENSURE_SERVICES, MOUNT_CONFIGFS  stock services a role needs started, and whether
#                  configfs must be mounted for targetcli (OpenRC): empty on NixOS
#
# Every command is logged with run (defined by init) before it executes.

NIX_PROFILE="${HPS_NIX_PROFILE:-/nix/var/nix/profiles/hps-extra}"
SYSTEMD_RUN_DIR="${HPS_SYSTEMD_DIR:-/run/systemd/system}"
# The signing key of the upstream binary cache: the packages keep upstream's
# signatures (STRATEGY.md), so the node trusts the stock key and nothing else.
NIX_CACHE_KEY=cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=

# adapter_init <ips> <os version>: set the variables above. PKG_PERL5LIB is
# read from the profile as it is now, so call it again after pkg_add.
# shellcheck disable=SC2034  # these variables are read by init, which sources this file
adapter_init() {
  ADAPTER_IPS="$1"
  ADAPTER_VERSION="$2"
  SUDO_GROUP=wheel
  PKG_BIN="$NIX_PROFILE/bin"
  PKG_SBIN="$NIX_PROFILE/sbin"
  PKG_ETC="$NIX_PROFILE/etc"
  SYS_BIN="/run/wrappers/bin:/run/current-system/sw/bin"
  LIBVIRT_CONF_DIR=/var/lib/libvirt
  PKG_LINE_RE='^/nix/store/'
  ADAPTER_PATH_EXTRA=""
  ENSURE_SERVICES=""
  MOUNT_CONFIGFS=""
  return 0
}

# pkg_kind <line>: what a line of the package list is, for init: agent | nagios-check |
# nagios-plugins | other. pkg_agent_dir, pkg_nagios_check, pkg_nagios_plugins: where that
# package is (a store path is where it is). pkg_stamp: what changes when its version does,
# for the service text (the path does that here: nothing).
pkg_kind() {
  if [[ "$1" =~ -ctrl-exec-agent-[0-9][0-9.]*$ ]]; then echo agent
  elif [[ "$1" =~ -nagios-check$ ]]; then echo nagios-check
  elif [[ "$1" =~ -hps-nagios-plugins$ ]]; then echo nagios-plugins
  else echo other; fi
}
pkg_agent_dir() { printf '%s\n' "$1"; }
pkg_nagios_check() { printf '%s\n' "$1"; }
pkg_nagios_plugins() { printf '%s\n' "$1"; }
pkg_stamp() { return 0; }

# _unsigned <store path>: true when the IPS repository's narinfo of the path has
# no signature: a local package (docs/BUNDLE.md "Local packages"). The upstream
# packages keep their upstream signatures and are checked against the stock key.
_unsigned() {
  local h="${1#/nix/store/}"
  h="${h:0:32}"
  ! curl -fs --max-time 20 "http://${ADAPTER_IPS}/packages/nixos/${ADAPTER_VERSION}/${h}.narinfo" | grep -q '^Sig:'
}

_nix_opts() {
  printf '%s\n' --option substituters "http://${ADAPTER_IPS}/packages/nixos/${ADAPTER_VERSION}" \
    --option trusted-public-keys "$NIX_CACHE_KEY" --option connect-timeout 5
}

# pkg_add <store path>...: make the packages available in the profile. The paths
# come from the IPS (cmd=node_packages); the closure is substituted from the IPS
# repository, the plain HTTP Nix binary cache hps-starter filled, and nothing
# else. A path the node already holds costs nothing. Upstream packages are
# installed with their signatures checked; a local package (no signature) in a
# second call without the check, after the signed ones, so that what it shares
# with them is already there.
pkg_add() {
  local -a signed=() unsigned=() opts=()
  local p
  mapfile -t opts < <(_nix_opts)
  for p in "$@"; do
    [[ "$p" =~ ^/nix/store/[0-9a-z]{32}-[A-Za-z0-9._+-]+$ ]] || { log "pkg_add: '$p' is not a store path"; return 1; }
    # already in the profile: nothing to install (a second run, a refresh)
    if [[ -e "$NIX_PROFILE/manifest.json" ]] && grep -qF -- "$p" "$NIX_PROFILE/manifest.json" 2> /dev/null; then
      continue
    fi
    if _unsigned "$p"; then unsigned+=("$p"); else signed+=("$p"); fi
  done
  if ((${#signed[@]} + ${#unsigned[@]} == 0)); then
    log "pkg_add: every package is installed already"
    return 0
  fi
  if ((${#signed[@]} > 0)); then
    run nix --extra-experimental-features nix-command profile install --profile "$NIX_PROFILE" "${opts[@]}" "${signed[@]}" || return 1
  fi
  if ((${#unsigned[@]} > 0)); then
    log "pkg_add: local (unsigned) packages: ${unsigned[*]}"
    run nix --extra-experimental-features nix-command profile install --profile "$NIX_PROFILE" "${opts[@]}" --option require-sigs false "${unsigned[@]}" || return 1
  fi
}

# pkg_realise <store path>: have one package's store path here, outside the
# profile, and print nothing. For a package the node runs by its path, so that
# a new version sits beside the old one and nothing is replaced under a running
# process (the agent and its executor). A local package is taken without the
# signature check, as pkg_add does.
pkg_realise() {
  local p="$1"
  local -a opts=()
  [[ "$p" =~ ^/nix/store/[0-9a-z]{32}-[A-Za-z0-9._+-]+$ ]] || { log "pkg_realise: '$p' is not a store path"; return 1; }
  [[ -e "$p" ]] && return 0
  mapfile -t opts < <(_nix_opts)
  if _unsigned "$p"; then opts+=(--option require-sigs false); fi
  run nix-store --realise "${opts[@]}" "$p" > /dev/null
}

# svc_start [--when-exists FILE] [--port N] [--opt Key=Value]... <name> [VAR=value...] <command> [args...]
# Define the unit <name>.service in RAM and start it (a no-op when it runs).
#   --when-exists FILE   the unit is skipped, not failed, until FILE exists (the
#                        agent has no certificate before it is paired)
#   --port N             open TCP port N in the host firewall (the NixOS
#                        firewall is on, and only ssh is open)
#   --opt Key=Value      one more line of the unit's [Service] section (the user
#                        and the confinement of the agent; ExecStartPre=+ ...); a
#                        key given again replaces the default (Type, Restart)
#   --unit-opt Key=Value one more line of the unit's [Unit] section (After=, Wants=,
#                        StartLimitIntervalSec=)
# Sets SVC_CHANGED=1 when the unit's text differs from what was there (a new
# version of the program): a running service then runs the old one until it is
# restarted (svc_restart_later).
svc_start() {
  local when="" port=""
  local -a opt=() uopt=()
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --stamp) shift 2 ;;    # for an OS whose unit text does not change with a package version
      --when-exists) when="$2"; shift 2 ;;
      --port) port="$2"; shift 2 ;;
      --opt) opt+=("$2"); shift 2 ;;
      --unit-opt) uopt+=("$2"); shift 2 ;;
      *) log "svc_start: unknown option $1"; return 2 ;;
    esac
  done
  local name="$1"
  shift
  local unit="${SYSTEMD_RUN_DIR}/${name}.service"
  local -a env=()
  while [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    env+=("$1")
    shift
  done
  mkdir -p "$SYSTEMD_RUN_DIR"
  {
    printf '[Unit]\nDescription=HPS %s (run-time unit, written by the node bundle)\nAfter=network.target\n' "$name"
    [[ -n "$when" ]] && printf 'ConditionPathExists=%s\n' "$when"
    local e
    for e in "${uopt[@]}"; do printf '%s\n' "$e"; done
    printf '\n[Service]\nType=simple\n'
    for e in "${env[@]}"; do
      printf 'Environment="%s"\n' "$e"
    done
    printf 'ExecStart=%s\nRestart=on-failure\nRestartSec=5\n' "$*"
    # 78: not paired yet; restarting cannot fix it
    printf 'RestartPreventExitStatus=78\n'
    for e in "${opt[@]}"; do printf '%s\n' "$e"; done
  } > "${unit}.new"
  if cmp -s "${unit}.new" "$unit" 2> /dev/null; then
    rm -f "${unit}.new"
  else
    # shellcheck disable=SC2034  # read by init
    [[ -e "$unit" ]] && SVC_CHANGED=1
    mv -f "${unit}.new" "$unit"
  fi
  [[ -z "$port" ]] || fw_open "$port"
  run systemctl daemon-reload
  run systemctl start "${name}.service"
}

# svc_restart_later <name>...: restart these services a few seconds from now, from
# a transient timer unit, not from the caller: the caller may be an action the
# agent is running, and the agent must have answered before it is restarted.
svc_restart_later() {
  run systemd-run --quiet --no-block --collect --on-active=5 --unit "hps-restart-$$" \
    systemctl try-restart "${@/%/.service}"
}

# svc_reload <name>: re-read the configuration of a service the OS already runs.
svc_reload() {
  run systemctl reload "${1}.service"
}

# fw_open <port>...: open TCP ports in the host firewall (the NixOS firewall is on,
# and only ssh is open). Idempotent; the rule lives as long as the boot.
fw_open() {
  local port
  for port in "$@"; do
    iptables -C nixos-fw -p tcp --dport "$port" -j nixos-fw-accept 2> /dev/null \
      || run iptables -I nixos-fw 1 -p tcp --dport "$port" -j nixos-fw-accept
  done
}

# svc_mask <unit>...: a unit the OS ships (name.timer, name@.service) is made to
# do nothing for this boot, by a run-time link to /dev/null.
svc_mask() {
  local u
  mkdir -p "$SYSTEMD_RUN_DIR"
  for u in "$@"; do
    [[ "$(readlink "$SYSTEMD_RUN_DIR/$u" 2> /dev/null)" == /dev/null ]] || run ln -sf /dev/null "$SYSTEMD_RUN_DIR/$u"
  done
  run systemctl daemon-reload
}

# AppArmor (role_apparmor): the directories the profile texts' markers stand for (a store
# path each), the parser, the libvirtd profile's name, extra sed expressions for the texts
# (none: the texts are written for this layout), and a check of libvirt (none: it is built
# with the driver).
aa_roots() {
  local p
  p="$(readlink -f "$(role_bin apparmor_parser)")"
  AA_PARSER="${p%/bin/*}"
  AA_LIBVIRT="$(readlink -f "$(role_bin libvirtd)")"
  AA_LIBVIRT="${AA_LIBVIRT%/sbin/*}"
  AA_QEMU="$(readlink -f "$(role_bin qemu-system-x86_64)")"
  AA_QEMU="${AA_QEMU%/bin/*}"
}
aa_parser_path() { printf '%s\n' "$AA_PARSER/bin/apparmor_parser"; }
aa_libvirtd_path() { printf '%s\n' "$AA_LIBVIRT/sbin/.libvirtd-wrapped"; }
aa_sed_args() { return 0; }
aa_libvirt_check() { return 0; }

# user_unlock, sudo_grant: nothing to do here (the wheel group has sudo; sshd takes the
# account as useradd made it)
user_unlock() { return 0; }
sudo_grant() { return 0; }

# hostname_apply <fqdn>: hostnamed reads the static name from the OS's own file unless
# told otherwise (NixOS: a link into the store); so it is told to read /etc/hostname
hostname_apply() {
  svc_env systemd-hostnamed "SYSTEMD_ETC_HOSTNAME=${HPS_ROOT}/etc/hostname"
  if [[ -n "${1:-}" ]]; then
    systemctl try-restart systemd-hostnamed.service 2> /dev/null || true
  fi
}

# os_compat: the programs the OS lacks, for the scripts: none (systemd is here)
os_compat() { return 0; }

# refresh_watch, zvol_links: systemd-run runs the refresh; udev makes the zvol links
refresh_watch() { return 0; }
zvol_links() { return 0; }

# sshd_prepare: sshd's host keys exist already
sshd_prepare() { return 0; }

# time_sync, net_keep_lease, host_cgroups: systemd's timesyncd, networkd and slices do these
time_sync() { return 0; }
net_keep_lease() { return 0; }
host_cgroups() { return 0; }

# log_forward: the journal's lines to the IPS (lib/hps-log-journal, jq and the shell)
log_forward() {
  role_need jq
  svc_start hps-log-journal "PATH=$(role_path)" "HPS_CMDLINE=$HPS_CMDLINE" \
    "$(command -v bash)" "$HPS_RUN_DIR/bundle/lib/hps-log-journal"
}

# md_monitor: the starter's own mdmonitor.service, which udev starts with the first array
md_monitor() { return 0; }

# zfs_hostid_set: the kernel line's spl.spl_hostid does it (nixos_starter_boot_lines)
zfs_hostid_set() { return 0; }

# svc_ensure <name>: a stock service is running (none is asked for here)
svc_ensure() {
  systemctl is-active --quiet "${1}.service" || run systemctl start "${1}.service"
}

# iscsid_conf_source: the open-iscsi package's own iscsid.conf, in its store path
iscsid_conf_source() {
  local iscsid pkg
  iscsid="$(role_bin iscsid)" || return 1
  pkg="$(readlink -f "$iscsid")"
  pkg="${pkg%/sbin/*}"
  pkg="${pkg%/bin/*}"
  printf '%s\n' "$pkg/etc/iscsi/iscsid.conf"
}

# svc_env <unit> <VAR=value>: the service <unit> (one the OS ships) gets this environment
# variable from now on, by a run-time drop-in that sorts after the OS's own (zz-), and is
# restarted if it runs. NixOS points systemd-hostnamed at /etc/static/hostname, a link into
# the store that no node can change: SYSTEMD_ETC_HOSTNAME=/etc/hostname makes it read the
# file the bundle writes.
svc_env() {
  local d="${SYSTEMD_RUN_DIR}/${1}.service.d"
  mkdir -p "$d"
  printf '[Service]\nEnvironment=%s\n' "$2" > "$d/zz-hps.conf"
  run systemctl daemon-reload
  systemctl try-restart "${1}.service" > /dev/null 2>&1 || true
}
