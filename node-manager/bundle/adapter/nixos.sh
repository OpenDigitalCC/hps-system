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
#   svc_start       a run-time systemd unit, in RAM (/run/systemd/system)
#   svc_reload      reload a service the starter already has (sshd)
#
# What an adapter for another OS provides (Alpine: plan step 4, adapter/alpine.sh,
# chosen by init's "case $os"): the same function names, with the same arguments,
# and these variables, set by adapter_init:
#   PKG_BIN        directory where added packages' programs appear
#   PKG_PERL5LIB   directories of the Perl modules added packages carry
#   SUDO_GROUP     the group whose members have sudo
#
# Every command is logged with run (defined by init) before it executes.

NIX_PROFILE="${HPS_NIX_PROFILE:-/nix/var/nix/profiles/hps-extra}"
SYSTEMD_RUN_DIR="${HPS_SYSTEMD_DIR:-/run/systemd/system}"
# The signing key of the upstream binary cache: the packages keep upstream's
# signatures (STRATEGY.md), so the node trusts the stock key and nothing else.
NIX_CACHE_KEY=cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=

# adapter_init <ips> <os version>: set the variables above. PKG_PERL5LIB is
# read from the profile as it is now, so call it again after pkg_add.
# shellcheck disable=SC2034  # SUDO_GROUP, PKG_BIN and PKG_PERL5LIB are read by init, which sources this file
adapter_init() {
  ADAPTER_IPS="$1"
  ADAPTER_VERSION="$2"
  SUDO_GROUP=wheel
  PKG_BIN="$NIX_PROFILE/bin"
  PKG_PERL5LIB=""
  local d
  for d in "$NIX_PROFILE"/lib/perl5/site_perl/*/ ; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    PKG_PERL5LIB="${PKG_PERL5LIB:+$PKG_PERL5LIB:}$d"
    [[ -d "$d/x86_64-linux-thread-multi" ]] && PKG_PERL5LIB="$PKG_PERL5LIB:$d/x86_64-linux-thread-multi"
  done
  return 0
}

# pkg_add <store path>...: make the packages available. The paths come from the
# IPS (cmd=node_packages); the closure is substituted from the IPS repository,
# the plain HTTP Nix binary cache hps-starter filled, and nothing else. A path
# the node already holds (it is in the starter) costs nothing.
pkg_add() {
  local -a todo=()
  local p
  for p in "$@"; do
    [[ "$p" =~ ^/nix/store/[0-9a-z]{32}-[A-Za-z0-9._+-]+$ ]] || { log "pkg_add: '$p' is not a store path"; return 1; }
    # already in the profile: nothing to install (a second run, a refresh)
    if [[ -e "$NIX_PROFILE/manifest.json" ]] && grep -qF -- "$p" "$NIX_PROFILE/manifest.json" 2> /dev/null; then
      continue
    fi
    todo+=("$p")
  done
  if ((${#todo[@]} == 0)); then
    log "pkg_add: every package is installed already"
    return 0
  fi
  run nix --extra-experimental-features nix-command profile install \
    --profile "$NIX_PROFILE" \
    --option substituters "http://${ADAPTER_IPS}/packages/nixos/${ADAPTER_VERSION}" \
    --option trusted-public-keys "$NIX_CACHE_KEY" \
    --option connect-timeout 5 \
    "${todo[@]}"
}

# svc_start [--when-exists FILE] [--port N] <name> [VAR=value...] <command> [args...]
# Define the unit <name>.service in RAM and start it (a no-op when it runs).
#   --when-exists FILE   the unit is skipped, not failed, until FILE exists (the
#                        agent has no certificate before it is paired)
#   --port N             open TCP port N in the host firewall (the NixOS
#                        firewall is on, and only ssh is open)
svc_start() {
  local when="" port=""
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --when-exists) when="$2"; shift 2 ;;
      --port) port="$2"; shift 2 ;;
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
    printf '\n[Service]\nType=simple\n'
    local e
    for e in "${env[@]}"; do
      printf 'Environment="%s"\n' "$e"
    done
    printf 'ExecStart=%s\nRestart=on-failure\nRestartSec=5\n' "$*"
    # 78: not paired yet; restarting cannot fix it
    printf 'RestartPreventExitStatus=78\n'
  } > "${unit}.new"
  mv -f "${unit}.new" "$unit"
  if [[ -n "$port" ]]; then
    iptables -C nixos-fw -p tcp --dport "$port" -j nixos-fw-accept 2> /dev/null \
      || run iptables -I nixos-fw 1 -p tcp --dport "$port" -j nixos-fw-accept
  fi
  run systemctl daemon-reload
  run systemctl start "${name}.service"
}

# svc_reload <name>: re-read the configuration of a service the OS already runs.
svc_reload() {
  run systemctl reload "${1}.service"
}
