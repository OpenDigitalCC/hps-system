#!/usr/bin/env bash
#
# hps-node-init - boot-time identity and enrolment for a NixOS HPS node.
#
# Runs once per boot (nix/modules/hps-node.nix, oneshot after network-online
# and after the agent's first start attempt). Straight sequence, every command
# logged:
#   1. read hps.ips, hps.mac, hps.profile from the kernel command line
#      (fallbacks: default gateway; MAC of the default-route interface)
#   2. kernel hostname (static and transient) from the registry
#      (cmd=host_variable&name=HOSTNAME; fallback hps-<mac without colons>), as <name>.<hps.domain> when the
#      command line carries hps.domain (see hps-pair for why)
#      then net-bridge-ensure builds the bridges for the networks attached to
#      this host in the registry (non-fatal: a missing script or a failure is
#      logged and boot goes on)
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
: "${HPS_NET_BRIDGE_ENSURE:=/opt/ctrl-exec-scripts/net-bridge-ensure}"

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
  # -s without -S: a 404 (no name yet) is an expected answer, not an error line.
  run curl -fs "http://${ips}/cgi-bin/boot_manager.sh?cmd=host_variable&name=HOSTNAME"
}

# fqdn_of <name>: the node's one identity, <first label>.<hps.domain>
# (docs/NAMING.md). The label alone when the command line carries no domain.
# Fails, naming the reason, when the domain is malformed or the result is
# longer than 63 characters (the om3 node-name cap).
fqdn_of() {
  local label="${1%%.*}"
  local domain name
  label="${label,,}"
  domain=$(cmdline_value hps.domain || true)
  domain="${domain,,}"
  if [[ ! "$label" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    log "'$label' is not a usable host label"
    return 1
  fi
  if [[ -n "$domain" && ! "$domain" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
    log "hps.domain '$domain' is not a usable DNS domain"
    return 1
  fi
  name="$label"
  if [[ -n "$domain" ]]; then
    name="${label}.${domain}"
  fi
  if [[ ${#name} -gt 63 ]]; then
    log "$name is ${#name} characters; the limit is 63 (om3 node names): the cluster DNS domain is too long"
    return 1
  fi
  printf '%s\n' "$name"
}

# set_hostname <fqdn>: the transient kernel hostname only. /etc is read-only on
# a netbooted node, so a static write would fail on every boot. systemd-networkd takes no hostname from DHCP
# (UseHostname=false, hps-net), so nothing replaces it later.
set_hostname() {
  local name="$1"
  if command -v hostnamectl > /dev/null 2>&1; then
    run hostnamectl set-hostname --transient "$name" && return 0
    log "hostnamectl failed; falling back to hostname(1)"
  fi
  run hostname "$name"
}

# The allowlisted node script, run here once so the bridges exist before any
# workload; later runs go through ctrl-exec. Never stops the boot.
ensure_bridges() {
  if [[ ! -x "$HPS_NET_BRIDGE_ENSURE" ]]; then
    log "$HPS_NET_BRIDGE_ENSURE not present; no bridges built"
    return 0
  fi
  run "$HPS_NET_BRIDGE_ENSURE" || log "net-bridge-ensure exited $? (continuing)"
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
  name=$(fqdn_of "$name") || return 1
  set_hostname "$name"
  mkdir -p "$HPS_RUN_DIR"
  printf '%s\n' "${profile}" > "$HPS_RUN_DIR/profile"
  ensure_bridges

  if fetch_bundle "$ips"; then
    run_bundle_init
  else
    log "bundle fetch failed (continuing to pairing)"
  fi

  pair
}

main "$@"
