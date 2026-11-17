# shellcheck shell=bash
# adapter/alpine.sh - the Alpine part of the node bundle (plan step 4). Sourced by
# init; nothing runs when it is sourced. The same functions and variables as
# adapter/nixos.sh (see its header), for OpenRC and apk:
#
#   boot arguments  not here: the IPS issues the kernel line and the apkovl
#                   (lib/functions.d/alpine-boot-functions.sh)
#   pkg_add         apk add from the IPS repository (docs/BUNDLE.md "Alpine");
#                   upstream packages are checked by apk against Alpine's own keys,
#                   local ones (no Alpine signature) in a separate call with
#                   --allow-untrusted from the IPS's local/ repository
#   pkg_realise     the same, one package, upgraded when the IPS holds a newer one
#   svc_start       an OpenRC service in /etc/init.d (RAM), started; supervise-daemon
#                   for a service that restarts; the systemd settings that have an
#                   OpenRC meaning are translated, the others are named in the script
#                   as not applied
#   svc_reload, svc_restart_later, svc_mask, svc_env, fw_open
#
# What the OS does differently, in one place:
#   - no firewall on Alpine: fw_open says so and changes nothing
#   - no systemd: a small systemctl and udevadm for the scripts of the bundle (os_compat)
#   - the agent has no unit sandbox: it runs through setpriv with no capability, no
#     bounding set and no_new_privs, as the unprivileged user (svc_start)
#   - libvirt: Alpine's own has no AppArmor driver, so the compute role needs the local
#     package libvirt-apparmor (plan step 5) and refuses without it (aa_libvirt_check)
#
# Every command is logged with run (defined by init) before it executes.

# the kernel packages: installed without scripts (mkinitfs's trigger would build an
# 80 MiB initramfs into RAM), then depmod runs by itself
KERNEL_PKG_RE='^(linux-lts|linux-firmware-none|mkinitfs|zfs-lts)$'

# adapter_init <ips> <os version>
# shellcheck disable=SC2034  # these variables are read by init and role, which source this file
adapter_init() {
  ADAPTER_IPS="$1"
  ADAPTER_VERSION="$2"
  OPENRC_DIR="${HPS_OPENRC_DIR:-/etc/init.d}"
  PKG_PREFIX="${HPS_PKG_PREFIX:-/usr}"
  SUDO_GROUP=wheel
  PKG_BIN="$PKG_PREFIX/bin"
  PKG_SBIN="$PKG_PREFIX/sbin"
  PKG_ETC="${HPS_PKG_ETC:-/etc}"
  SYS_BIN="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  LIBVIRT_CONF_DIR=/etc/libvirt
  # the lines of the IPS's package list: a name, or local/<name>
  PKG_LINE_RE='^(local/)?[A-Za-z0-9][A-Za-z0-9._+-]*$'
  # where the scripts the node bundle runs find their systemctl and udevadm
  ADAPTER_PATH_EXTRA="$HPS_RUN_DIR/bin"
  # dbus: targetcli and libvirt expect it; configfs: targetcli (LIO) needs it mounted
  ENSURE_SERVICES="dbus"
  MOUNT_CONFIGFS=1
  return 0
}

#-------------------------------------------------------------------------------
# packages
#-------------------------------------------------------------------------------
# pkg_kind <line>: what a line of the package list is, for init (agent | nagios-check
# | nagios-plugins | other).
pkg_kind() {
  case "${1#local/}" in
    ctrl-exec-agent) echo agent ;;
    nagios-check) echo nagios-check ;;
    hps-nagios-plugins) echo nagios-plugins ;;
    *) echo other ;;
  esac
}

# pkg_stamp <line>: the installed version of a package, written into its service's script so
# that a new version is a changed script (SVC_CHANGED), as a new store path is on NixOS
pkg_stamp() { "${HPS_APK:-apk}" info -v "${1#local/}" 2> /dev/null | head -n 1 || true; }

# pkg_agent_dir <line>: the directory with bin/ctrl-exec-agent and bin/ctrl-exec-executor
pkg_agent_dir() { printf '%s\n' "$PKG_PREFIX"; }
# pkg_nagios_check <line>: the plugin file; pkg_nagios_plugins <line>: the directory of check_*
pkg_nagios_check() { printf '%s\n' "$PKG_PREFIX/bin/nagios-check"; }
pkg_nagios_plugins() { printf '%s\n' "$PKG_PREFIX/lib/hps-nagios-plugins"; }

# _apk_repos: /etc/apk/repositories names the IPS repository and nothing else. The
# stock initramfs wrote it from alpine_repo=; written again so that a node that
# lost it still installs from the IPS only.
_apk_repos() {
  local f="${HPS_ROOT}/etc/apk/repositories" base="http://${ADAPTER_IPS}/packages/alpine/${ADAPTER_VERSION}"
  mkdir -p "${f%/*}"
  printf '%s/main\n%s/community\n' "$base" "$base" | write_if_changed "$f" 0644
}

# _apk <args>: apk with the IPS's repositories; the index is read first (a diskless
# node keeps no cache)
_apk() {
  run "${HPS_APK:-apk}" "$@"
}

# pkg_add <line>...: install the packages. Kernel packages go first and without
# scripts; the running kernel's modules are indexed again afterwards (depmod). Local
# packages (local/<name>) come last, from the IPS's local repository, without Alpine's
# signature check, knowing so; everything else is checked by apk against Alpine's keys.
pkg_add() {
  local p
  local -a kernel=() normal=() local_=()
  for p in "$@"; do
    [[ "$p" =~ $PKG_LINE_RE ]] || { log "pkg_add: '$p' is not a package name"; return 1; }
    if [[ "$p" == local/* ]]; then local_+=("${p#local/}")
    elif [[ "$p" =~ $KERNEL_PKG_RE ]]; then kernel+=("$p")
    else normal+=("$p"); fi
  done
  ((${#kernel[@]} + ${#normal[@]} + ${#local_[@]} > 0)) || { log "pkg_add: nothing to install"; return 0; }
  _apk_repos || return 1
  _apk update --quiet || return 1
  if ((${#kernel[@]} > 0)); then
    _apk add --no-scripts --quiet "${kernel[@]}" || return 1
    local kr
    kr="$(uname -r)"
    if [[ -d "${HPS_LIB_MODULES:-/lib/modules}/$kr" ]]; then
      run depmod -a "$kr" || return 1
    else
      log "warning: the running kernel $kr has no module directory: the node booted a kernel the repository does not hold"
    fi
  fi
  if ((${#normal[@]} > 0)); then
    _apk add --quiet "${normal[@]}" || return 1
  fi
  if ((${#local_[@]} > 0)); then
    log "pkg_add: local (no Alpine signature) packages: ${local_[*]}"
    _apk add --quiet --allow-untrusted --repository "http://${ADAPTER_IPS}/packages/alpine/${ADAPTER_VERSION}/local" "${local_[@]}" || return 1
  fi
}

# pkg_realise <line>: one package, the version the IPS holds now (a new agent). Not in
# the node's "world" by constraint: apk add -u upgrades it, and what it needs.
pkg_realise() {
  local p="$1" name="${1#local/}"
  [[ "$p" =~ $PKG_LINE_RE ]] || { log "pkg_realise: '$p' is not a package name"; return 1; }
  _apk_repos || return 1
  _apk update --quiet || return 1
  if [[ "$p" == local/* ]]; then
    _apk add --quiet --upgrade --allow-untrusted --repository "http://${ADAPTER_IPS}/packages/alpine/${ADAPTER_VERSION}/local" "$name"
  else
    _apk add --quiet --upgrade "$name"
  fi
}

#-------------------------------------------------------------------------------
# users, sudo, hostname, the compatibility programs
#-------------------------------------------------------------------------------
# user_unlock <user>: a key login needs an account that is not locked; useradd leaves
# "!", sshd on Alpine refuses it ("account is locked"). "*" is no password and not locked.
user_unlock() {
  run usermod -p '*' "$1"
}

# sudo_grant <user>: sudo without a password for the sysadmin (stock sudo; doas is
# Alpine's lighter default, but sudo keeps `sudo -n` the same on every OS)
sudo_grant() {
  local d="${HPS_ROOT}/etc/sudoers.d"
  run install -d -m 0750 "$d"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$1" | write_if_changed "$d/hps-$1" 0440
}

# hostname_apply: the name is /etc/hostname (init wrote it) and the kernel's: Alpine's
# hostname service reads the file and nothing resets it, so there is nothing more to do
hostname_apply() { return 0; }

# os_compat: the two systemd programs the bundle's scripts call, as scripts on the PATH
# (init puts $HPS_RUN_DIR/bin first; the agent's script_path names it too).
# systemctl: start/stop/restart/reload/try-restart/cat/poweroff/reboot over OpenRC
# services; set-property and show (cgroup settings) are not available and say so.
# udevadm: settle = let mdev make the nodes (there is no udev).
os_compat() {
  local d="$HPS_RUN_DIR/bin"
  mkdir -p "$d"
  write_if_changed "$d/systemctl" 0755 << 'EOF'
#!/bin/sh
# systemctl for an OpenRC node (written by the HPS node bundle, adapter/alpine.sh).
# start/stop/restart/reload/try-restart/cat/poweroff/reboot over rc-service; set-property and
# show for machine.slice over cgroup v2 (the host reserve: host-reserve-apply, host-resources).
CG="${HPS_CGROUP_ROOT:-/sys/fs/cgroup}/machine"
verb=
units=
for a in "$@"; do
  case "$a" in
    -*) ;;
    *) if [ -z "$verb" ]; then verb="$a"; else units="$units ${a%.service}"; fi ;;
  esac
done
case "$verb" in
  start | stop | restart | reload)
    for u in $units; do rc-service "$u" "$verb" || exit 1; done ;;
  try-restart)
    for u in $units; do
      if rc-service "$u" status > /dev/null 2>&1; then rc-service "$u" restart || exit 1; fi
    done ;;
  cat)
    for u in $units; do [ -x "/etc/init.d/$u" ] || exit 1; done ;;
  daemon-reload) ;;
  poweroff) exec poweroff ;;
  reboot) exec reboot ;;
  set-property)
    set -- $units
    [ "$1" = machine.slice ] || { echo "systemctl set-property $1: not available on this OS (OpenRC): only machine.slice" >&2; exit 1; }
    shift
    [ -r "${CG%/*}/cgroup.controllers" ] || { echo "systemctl set-property: cgroup v2 is not mounted at ${CG%/*}" >&2; exit 1; }
    for c in cpuset cpu io memory; do echo "+$c" > "${CG%/*}/cgroup.subtree_control" 2> /dev/null; done
    mkdir -p "$CG" || exit 1
    for kv in "$@"; do
      k="${kv%%=*}"; v="${kv#*=}"
      case "$k" in
        AllowedCPUs) f=cpuset.cpus ;;
        CPUWeight) f=cpu.weight ;;
        IOWeight) f=io.weight; v="default $v" ;;
        MemoryMax)
          f=memory.max
          case "$v" in infinity) v=max ;; *M) v=$(( ${v%M} * 1048576 )) ;; *G) v=$(( ${v%G} * 1073741824 )) ;; esac ;;
        *) echo "systemctl set-property: $k is not available on this OS (OpenRC)" >&2; exit 1 ;;
      esac
      echo "$v" > "$CG/$f" || { echo "systemctl set-property: cannot write $v to $CG/$f" >&2; exit 1; }
    done ;;
  show)
    # systemctl show machine.slice -p AllowedCPUs -p CPUWeight -p IOWeight -p MemoryMax
    [ -d "$CG" ] || { echo "systemctl show: no machine cgroup at $CG" >&2; exit 1; }
    want=
    prev=
    for a in "$@"; do
      [ "$prev" = -p ] && want="$want $a"
      prev="$a"
    done
    for p in $want; do
      case "$p" in
        AllowedCPUs) echo "AllowedCPUs=$(cat "$CG/cpuset.cpus" 2> /dev/null)" ;;
        CPUWeight) echo "CPUWeight=$(cat "$CG/cpu.weight" 2> /dev/null)" ;;
        IOWeight) echo "IOWeight=$(sed 's/^default //' "$CG/io.weight" 2> /dev/null | head -n 1)" ;;
        MemoryMax) echo "MemoryMax=$(cat "$CG/memory.max" 2> /dev/null)" ;;
      esac
    done ;;
  *) echo "systemctl $verb: not available on this OS (OpenRC)" >&2; exit 1 ;;
esac
EOF
  write_if_changed "$d/udevadm" 0755 << 'EOF'
#!/bin/sh
# udevadm for an mdev node (written by the HPS node bundle, adapter/alpine.sh):
# settle and trigger rescan /sys for device nodes; nothing else is available.
case "$1" in
  settle | trigger) command -v mdev > /dev/null 2>&1 && mdev -s; sleep 1; exit 0 ;;
  *) echo "udevadm $1: not available on this OS (mdev)" >&2; exit 1 ;;
esac
EOF
  # node-journal asks for the journal of this boot with -n, -u, -p; this node has syslog
  write_if_changed "$d/journalctl" 0755 << 'EOF'
#!/bin/sh
# journalctl for a syslog node (written by the HPS node bundle, adapter/alpine.sh): what
# node-journal passes: -b --no-pager -o <format> -n N [-u UNIT] [-p PRIORITY]. The lines are
# busybox syslogd's (/var/log/messages), the newest N, for the unit's tag and the priorities
# up to PRIORITY.
n=200; unit=; prio=
while [ $# -gt 0 ]; do
  case "$1" in
    -n) n="$2"; shift ;;
    -u) unit="${2%.service}"; shift ;;
    -p) prio="$2"; shift ;;
    -o) shift ;;
  esac
  shift
done
log="${HPS_SYSLOG_FILE:-/var/log/messages}"
[ -r "$log" ] || { echo "journalctl: $log is not there (is syslog running?)" >&2; exit 1; }
levels=
if [ -n "$prio" ]; then
  case "$prio" in emerg) prio=0 ;; alert) prio=1 ;; crit) prio=2 ;; err) prio=3 ;; warning) prio=4 ;; notice) prio=5 ;; info) prio=6 ;; debug) prio=7 ;; esac
  i=0
  for name in emerg alert crit err warning notice info debug; do
    [ "$i" -le "$prio" ] && levels="$levels|$name"
    i=$((i + 1))
  done
  levels="${levels#|}"
fi
cat "$log" | {
  if [ -n "$unit" ]; then grep -E " $unit(\[[0-9]+\])?: "; else cat; fi
} | {
  if [ -n "$levels" ]; then grep -E " [a-z0-9]+\.($levels) "; else cat; fi
} | tail -n "$n"
EOF
  write_if_changed "$d/udhcpc-hps" 0755 << 'EOF'
#!/bin/sh
# udhcpc's script for a node that is already on the network (written by the HPS node
# bundle): udhcpc says "deconfig" when it starts, and the stock script would flush the
# address the node is using. The lease is renewed, never torn down first.
[ "$1" = deconfig ] && exit 0
exec /usr/share/udhcpc/default.script "$@"
EOF
}

# sshd_prepare: the host keys. The package makes none; its OpenRC script does at start, but
# init checks the configuration (sshd -t, which needs a key) before it starts the service.
sshd_prepare() {
  run ssh-keygen -A
}

# time_sync <ips>: the clock is kept in step with the IPS after boot, the source the NixOS
# nodes use (timesyncd, NTP=<ips>): busybox ntpd, which weighs nothing. lib/hps-time
# has stepped the clock once, from the IPS's HTTP date, before this.
time_sync() {
  mkdir -p "${HPS_ROOT}/etc/conf.d"
  printf 'NTPD_OPTS="-N -p %s"\n' "$1" | write_if_changed "${HPS_ROOT}/etc/conf.d/ntpd" 0644
  "${HPS_RC_SERVICE:-rc-service}" ntpd status > /dev/null 2>&1 && run "${HPS_RC_SERVICE:-rc-service}" ntpd restart || run "${HPS_RC_SERVICE:-rc-service}" ntpd start
}

# net_keep_lease: the stock initramfs got the address from DHCP and nothing renews it
# (the IPS's lease is an hour). udhcpc runs in the background on the interface that
# reaches the IPS, with a script that does not tear the address down when it starts.
net_keep_lease() {
  local dev pidf
  dev="$(ip route get "$ADAPTER_IPS" 2> /dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1)" || dev=""
  [[ -n "$dev" ]] || { log "net_keep_lease: no interface reaches $ADAPTER_IPS; no lease to keep"; return 0; }
  pidf="/run/hps-udhcpc.$dev.pid"
  if [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf")" 2> /dev/null; then return 0; fi
  run "${HPS_UDHCPC:-udhcpc}" -b -i "$dev" -p "$pidf" -s "$HPS_RUN_DIR/bin/udhcpc-hps" -t 5 || log "warning: udhcpc did not start on $dev: the lease will not be renewed"
}

# host_cgroups: cgroup v2 is mounted where the host reserve writes (systemd does it on NixOS)
host_cgroups() {
  [[ -r "${HPS_CGROUP_ROOT:-/sys/fs/cgroup}/cgroup.controllers" ]] && return 0
  svc_ensure cgroups
  [[ -r "${HPS_CGROUP_ROOT:-/sys/fs/cgroup}/cgroup.controllers" ]] || log "warning: cgroup v2 is not mounted: the host reserve cannot be applied (rc_cgroup_mode=unified is the OpenRC setting)"
  return 0
}

#-------------------------------------------------------------------------------
# services
#-------------------------------------------------------------------------------
_sq() { printf '%q' "$1"; }

# _arg_q <word>: a word of a command as the OpenRC script holds it: $NAME stays a
# variable (read from the service's environment file when it runs), the rest is quoted
_arg_q() {
  if [[ "$1" =~ ^\$[A-Za-z_][A-Za-z0-9_]*$ ]]; then printf '%s' "$1"; else printf '%q' "$1"; fi
}

# svc_start [--when-exists FILE] [--port N] [--opt Key=Value]... [--unit-opt Key=Value]...
#           <name> [VAR=value...] <command> [args...]
# Define the OpenRC service <name> in RAM and start it (a no-op when it runs). The
# options are those of adapter/nixos.sh (systemd's settings); the ones with an OpenRC
# meaning are applied: User, Group, ExecStartPre, ExecStop, Type=oneshot, Restart,
# WorkingDirectory, EnvironmentFile, LimitMEMLOCK, RuntimeDirectory(+Mode), After= (as
# "use"/"need"), and NoNewPrivileges with a user (setpriv, no capabilities). The others
# are written into the script as "not applied" (the unit sandbox: ProtectSystem,
# SystemCallFilter, ...: OpenRC has none).
# Sets SVC_CHANGED=1 when the script's text differs from what was there.
svc_start() {
  local when="" port=""
  local -a opt=() uopt=()
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --when-exists) when="$2"; shift 2 ;;
      --port) port="$2"; shift 2 ;;
      --opt) opt+=("$2"); shift 2 ;;
      --unit-opt) uopt+=("$2"); shift 2 ;;
      --stamp) STAMP="$2"; shift 2 ;;
      *) log "svc_start: unknown option $1"; return 2 ;;
    esac
  done
  local name="$1"
  shift
  local -a env=()
  while [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    env+=("$1")
    shift
  done
  local user="" group="" pre="" stop="" type=simple restart=on-failure wd="" envfile="" memlock="" rtdir="" rtmode=0755 nnp="" o
  local -a ignored=()
  for o in "${opt[@]}"; do
    case "$o" in
      User=*) user="${o#User=}" ;;
      Group=*) group="${o#Group=}" ;;
      ExecStartPre=*) pre="${o#ExecStartPre=}"; pre="${pre#+}" ;;
      ExecStop=*) stop="${o#ExecStop=}" ;;
      Type=*) type="${o#Type=}" ;;
      Restart=*) restart="${o#Restart=}" ;;
      WorkingDirectory=*) wd="${o#WorkingDirectory=}" ;;
      EnvironmentFile=*) envfile="${o#EnvironmentFile=}"; envfile="${envfile#-}" ;;
      LimitMEMLOCK=*) memlock="${o#LimitMEMLOCK=}" ;;
      RuntimeDirectory=*) rtdir="${o#RuntimeDirectory=}" ;;
      RuntimeDirectoryMode=*) rtmode="${o#RuntimeDirectoryMode=}" ;;
      NoNewPrivileges=true) nnp=1 ;;
      RemainAfterExit=* | KillMode=* | TimeoutStopSec=* | RestartSec=*) ;;
      *) ignored+=("$o") ;;
    esac
  done
  local need="" use="" u w
  for u in "${uopt[@]}"; do
    case "$u" in
      After=*)
        for w in ${u#After=}; do
          case "$w" in
            virtlogd.service) need="$need ${w%.service}" ;;
            *.service) use="$use ${w%.service}" ;;
          esac
        done ;;
    esac
  done
  [[ -z "$user" || -n "$group" ]] || group="$user"

  local file="$OPENRC_DIR/$name" i
  mkdir -p "$OPENRC_DIR"
  {
    printf '#!/sbin/openrc-run\n# HPS run-time service %s, written by the node bundle (adapter/alpine.sh); it is in RAM and nothing persists.\n' "$name"
    [[ -z "${STAMP:-}" ]] || printf '# stamp: %s\n' "$STAMP"
    for o in "${ignored[@]}"; do printf '# not applied (systemd only): %s\n' "$o"; done
    printf 'description="HPS %s"\n' "$name"
    for i in "${env[@]}"; do printf 'export %s=%q\n' "${i%%=*}" "${i#*=}"; done
    [[ -z "$envfile" ]] || printf 'set -a; [ -f %q ] && . %q; set +a\n' "$envfile" "$envfile"
    printf 'depend() {\n  use net%s\n' "$use"
    [[ -z "$need" ]] || printf '  need%s\n' "$need"
    printf '}\n'
    local -a words=("$@") qw=()
    local w
    for w in "${words[@]}"; do qw+=("$(_arg_q "$w")"); done
    if [[ "$type" == oneshot ]]; then
      printf 'start() {\n  ebegin "HPS %s"\n  %s\n  eend $?\n}\n' "$name" "${qw[*]}"
      if [[ -n "$stop" ]]; then
        printf 'stop() {\n  ebegin "HPS %s: stopping"\n  %s\n  eend $?\n}\n' "$name" "$stop"
      fi
    else
      if [[ -n "$user" && -n "$nnp" ]]; then
        # no unit sandbox here: the nearest thing is to start the agent as the user with
        # no capability, an empty bounding set and no_new_privs (setpriv, util-linux)
        printf 'command=%q\ncommand_args="--reuid=%s --regid=%s --clear-groups --inh-caps=-all --ambient-caps=-all --bounding-set=-all --no-new-privs -- %s"\n' \
          "$(command -v setpriv || echo /usr/bin/setpriv)" "$user" "$group" "${qw[*]}"
      else
        printf 'command=%s\n' "${qw[0]}"
        printf 'command_args="%s"\n' "${qw[*]:1}"
        [[ -z "$user" ]] || printf 'command_user=%q\n' "$user:$group"
      fi
      if [[ "$restart" == no ]]; then
        printf 'command_background=yes\npidfile=/run/%s.pid\n' "$name"
      else
        printf 'supervisor=supervise-daemon\nrespawn_delay=5\nrespawn_max=0\n'
      fi
      printf 'output_log=/var/log/hps-%s.log\nerror_log=/var/log/hps-%s.log\n' "$name" "$name"
      [[ -z "$wd" ]] || printf 'directory=%q\n' "$wd"
      [[ -z "$memlock" ]] || printf 'rc_ulimit="-l unlimited"\n'
      if [[ -n "$pre" || -n "$rtdir" || -n "$when" ]]; then
        printf 'start_pre() {\n'
        [[ -z "$when" ]] || printf '  [ -e %q ] || { ewarn "%s: %s is not there yet"; return 1; }\n' "$when" "$name" "$when"
        [[ -z "$rtdir" ]] || printf '  checkpath -d -m %s /run/%s\n' "$rtmode" "$rtdir"
        [[ -z "$pre" ]] || printf '  %s\n' "$pre"
        printf '}\n'
      fi
    fi
  } > "$file.new"
  chmod 0755 "$file.new"
  if cmp -s "$file.new" "$file" 2> /dev/null; then
    rm -f "$file.new"
  else
    # shellcheck disable=SC2034  # read by init
    [[ -e "$file" ]] && SVC_CHANGED=1
    mv -f "$file.new" "$file"
  fi
  STAMP=""
  [[ -z "$port" ]] || fw_open "$port"
  if [[ -n "$when" && ! -e "$when" ]]; then
    log "$name: $when is not there yet; not started"
    return 0
  fi
  run "${HPS_RC_SERVICE:-rc-service}" "$name" start
}

# svc_restart_later <name>...: restart these services a few seconds from now, detached
# from the caller (an action the agent is running: the agent must have answered first).
svc_restart_later() {
  local s cmd=""
  for s in "$@"; do cmd="$cmd ${HPS_RC_SERVICE:-rc-service} $s restart;"; done
  log "+ (sleep 5;$cmd) detached"
  setsid sh -c "sleep 5;$cmd" < /dev/null > /dev/null 2>&1 &
}

# svc_reload <name>: re-read the configuration of a service of the OS; start it when it
# is not running (sshd is installed by the package and not started by anything)
svc_reload() {
  if "${HPS_RC_SERVICE:-rc-service}" "$1" status > /dev/null 2>&1; then
    run "${HPS_RC_SERVICE:-rc-service}" "$1" reload
  else
    run "${HPS_RC_SERVICE:-rc-service}" "$1" start
  fi
}

# svc_ensure <name>: a service the OS ships is running (dbus, for libvirt and targetcli)
svc_ensure() {
  "${HPS_RC_SERVICE:-rc-service}" "$1" status > /dev/null 2>&1 || run "${HPS_RC_SERVICE:-rc-service}" "$1" start
}

# fw_open <port>...: Alpine runs no firewall; the ports are open
fw_open() {
  log "fw_open $*: no firewall on this OS, the port is open"
}

# svc_mask <unit>...: a unit of systemd; there is none here
svc_mask() { return 0; }

# svc_env <unit> <VAR=value>: a unit of systemd; there is none here
svc_env() { return 0; }

#-------------------------------------------------------------------------------
# role helpers (role calls these by name; nixos.sh has its own)
#-------------------------------------------------------------------------------
# log_forward: the node's log to the IPS's syslog (UDP 514, which its rsyslog takes as
# the TCP port): busybox syslogd with -R. Alpine has no journal, so lib/hps-log-journal
# has nothing to read; the IPS reads the same RFC 3164 lines.
log_forward() {
  mkdir -p "${HPS_ROOT}/etc/conf.d"
  printf 'SYSLOGD_OPTS="-t -R %s:514 -L"\n' "$ADAPTER_IPS" | write_if_changed "${HPS_ROOT}/etc/conf.d/syslog" 0644
  run "${HPS_RC_SERVICE:-rc-service}" syslog restart
}

# md_monitor: nothing starts mdadm's monitor by itself here (NixOS's udev does): the
# monitor is a service that reads /etc/mdadm.conf (PROGRAM, AUTO -all)
md_monitor() {
  svc_start --opt Restart=always mdmonitor "PATH=$(role_path)" "$(role_bin mdadm)" --monitor --scan --foreground
}

# zfs_hostid_set: the node's own ZFS hostid, from the kernel line (hps.zfs_hostid), as
# /etc/hostid, before the module loads: ZFS reads that file (musl's gethostid is 0)
zfs_hostid_set() {
  local id
  id="$(cmdline_value hps.zfs_hostid 2> /dev/null || true)"
  [[ "$id" =~ ^[0-9a-f]{8}$ ]] || { log "no hps.zfs_hostid on the kernel line: ZFS uses hostid 0"; return 0; }
  run zgenhostid -f "$id"
}

# AppArmor (role_apparmor). The profile texts are written for the nix layout
# (libvirtd as sbin/.libvirtd-wrapped, the parser in bin/); here everything is under
# /usr, so the markers all stand for $PKG_PREFIX and two sed expressions put the real
# paths in. Alpine's own libvirt is built without the AppArmor driver (no virt-aa-helper):
# the compute role needs the local package libvirt-apparmor, the AppArmor build, and says
# so when it is not what is installed. There is no fall back.
# shellcheck disable=SC2034  # read by role_aa_fill
aa_roots() { AA_PARSER="$PKG_PREFIX"; AA_LIBVIRT="$PKG_PREFIX"; AA_QEMU="$PKG_PREFIX"; }
aa_parser_path() { readlink -f "$(role_bin apparmor_parser)"; }
aa_libvirtd_path() { readlink -f "$(role_bin libvirtd)"; }
aa_sed_args() {
  printf '%s\n' -e "s|$AA_PARSER/bin/apparmor_parser|$(aa_parser_path)|g" -e "s|$AA_LIBVIRT/sbin/\\.libvirtd-wrapped|$(aa_libvirtd_path)|g"
}
aa_libvirt_check() {
  if [[ ! -x "$PKG_PREFIX/libexec/virt-aa-helper" ]]; then
    log "ERROR: this node's libvirt has no AppArmor driver (no $PKG_PREFIX/libexec/virt-aa-helper): Alpine's own libvirt is built without it."
    log "ERROR: the compute role needs the local package libvirt-apparmor (the AppArmor build of libvirt, plan step 5; hps-starter add-local alpine)."
    log "ERROR: libvirtd is NOT started: guests would run unconfined, and no node of HPS does."
    return 1
  fi
}

# iscsid_conf_source: the open-iscsi package's own iscsid.conf. Its file is the one the
# node uses, so the stock text is kept once beside it and the node's file is made from that.
iscsid_conf_source() {
  local f="${HPS_ROOT}/etc/iscsi/iscsid.conf"
  [[ -f "$f.hps-stock" ]] || cp "$f" "$f.hps-stock"
  printf '%s\n' "$f.hps-stock"
}
