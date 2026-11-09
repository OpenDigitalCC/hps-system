#!/usr/bin/env bash
#
# hps-node-init - boot-time identity and enrolment for a NixOS HPS node.
#
# Runs once per boot (nix/modules/hps-node.nix, oneshot after network-online
# and after the agent's first start attempt). Straight sequence, every command
# logged:
#   1. read hps.ips, hps.mac, hps.profile from the kernel command line
#      (fallbacks: default gateway; MAC of the default-route interface)
#   2. transient hostname from the registry (cmd=host_variable&name=HOSTNAME;
#      fallback hps-<mac without colons>)
#   3. fetch the node function bundle (cmd=get_remote_functions) to
#      /run/hps/functions.sh and run n_init_run from it (compat path; the
#      NixOS shims are CS-1.6 - a failure here is logged, not fatal)
#   4. pairing: run hps-pair (boot/hps-pair.sh; installed as /etc/hps/hps-pair,
#      shared with the audit image) with --no-hostname - step 2 has set it.
#
# Overrides for tests: HPS_CMDLINE (file), HPS_RUN_DIR, HPS_PAIR (the pairing
# script); HPS_AGENT_ETC, HPS_PAIR_TIMEOUT and HPS_PAIR_POLL pass through to it.

set -euo pipefail

: "${HPS_CMDLINE:=/proc/cmdline}"
: "${HPS_RUN_DIR:=/run/hps}"
: "${HPS_PAIR:=/etc/hps/hps-pair}"

log() {
  printf '[hps-node-init] %s\n' "$*" >&2
}

# run <command...>: log then execute; the caller decides what a failure means.
run() {
  log "+ $*"
  "$@"
}

cmdline_value() {
  local key="$1"
  local word
  for word in $(cat "$HPS_CMDLINE"); do
    if [[ "$word" == "$key="* ]]; then
      printf '%s\n' "${word#"$key"=}"
      return 0
    fi
  done
  return 1
}

default_route_json() {
  run ip -j route | jq -c '[.[] | select(.dst == "default")][0] // {}'
}

discover_ips() {
  if cmdline_value hps.ips; then
    return 0
  fi
  log "hps.ips absent from the command line; using the default gateway"
  default_route_json | jq -r '.gateway // empty'
}

discover_mac() {
  local dev
  if cmdline_value hps.mac; then
    return 0
  fi
  log "hps.mac absent from the command line; using the default-route interface"
  dev=$(default_route_json | jq -r '.dev // empty')
  if [[ -n "$dev" ]]; then
    run ip -j link show "$dev" | jq -r '.[0].address // empty'
  fi
}

# The CGI identifies the caller by its DHCP lease, so no MAC parameter.
fetch_hostname() {
  local ips="$1"
  run curl -fsS "http://${ips}/cgi-bin/boot_manager.sh?cmd=host_variable&name=HOSTNAME"
}

set_hostname() {
  local name="$1"
  if command -v hostnamectl > /dev/null 2>&1; then
    run hostnamectl set-hostname --transient "$name" && return 0
    log "hostnamectl failed; falling back to hostname(1)"
  fi
  run hostname "$name"
}

fetch_bundle() {
  local ips="$1"
  mkdir -p "$HPS_RUN_DIR"
  run curl -fsS "http://${ips}/cgi-bin/boot_manager.sh?cmd=get_remote_functions" \
    -o "$HPS_RUN_DIR/functions.sh"
}

# Compat path: source the bundle and run its init sequence in a subshell so a
# NixOS-incompatible function cannot take this script down with it.
run_bundle_init() {
  local rc
  log "+ (source $HPS_RUN_DIR/functions.sh; n_init_run)"
  set +e
  (
    set +u
    # shellcheck source=/dev/null
    source "$HPS_RUN_DIR/functions.sh"
    if type n_init_run > /dev/null 2>&1; then
      n_init_run
    else
      echo "n_init_run not provided by the bundle" >&2
      exit 1
    fi
  )
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    log "bundle init exited $rc (continuing to pairing)"
  fi
}

pair() {
  run bash "$HPS_PAIR" --no-hostname
}

main() {
  local ips mac profile name
  ips=$(discover_ips || true)
  mac=$(discover_mac || true)
  profile=$(cmdline_value hps.profile || true)
  log "ips=${ips:-<none>} mac=${mac:-<none>} profile=${profile:-<none>}"
  if [[ -z "$ips" ]]; then
    log "no IPS address: cannot continue"
    return 1
  fi

  name=$(fetch_hostname "$ips" || true)
  if [[ -z "$name" ]]; then
    name="hps-${mac//:/}"
    log "registry returned no HOSTNAME; using $name"
  fi
  set_hostname "$name"
  mkdir -p "$HPS_RUN_DIR"
  printf '%s\n' "${profile}" > "$HPS_RUN_DIR/profile"

  if fetch_bundle "$ips"; then
    run_bundle_init
  else
    log "bundle fetch failed (continuing to pairing)"
  fi

  pair
}

main "$@"
