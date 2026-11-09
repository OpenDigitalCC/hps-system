#!/usr/bin/env bash
#
# hps-pair - ctrl-exec pairing for a NixOS HPS node (node image and audit
# image alike).
#
# Called by hps-node-init (node images) and by the hps-audit-pair oneshot (audit
# image, after the audit report). Straight sequence, every command logged:
#   1. exit 0 at once if the agent certificate exists (idempotent)
#   2. read hps.ips and hps.mac from the kernel command line (fallbacks: default
#      gateway; MAC of the default-route interface)
#   3. unless --no-hostname: make the transient hostname the registry HOSTNAME
#      (fallback hps-<mac without colons>); the agent registers under it and the
#      IPS approver binds the request to the registry hostname
#   4. ctrl-exec-agent request-pairing --background, report the reqid to the IPS
#      API (action ctrl_exec_pair_request, header X-HPS-MAC), wait for the
#      certificate, restart the agent
#
# Usage: hps-pair [--no-hostname]
# Exit: 0 paired or already paired, 1 pairing failed, 2 usage.
#
# Overrides for tests: HPS_CMDLINE (file), HPS_AGENT_ETC, HPS_PAIR_TIMEOUT
# (seconds), HPS_PAIR_POLL (seconds).

set -euo pipefail

: "${HPS_CMDLINE:=/proc/cmdline}"
: "${HPS_AGENT_ETC:=/etc/ctrl-exec-agent}"
: "${HPS_PAIR_TIMEOUT:=300}"
: "${HPS_PAIR_POLL:=2}"

log() {
  printf '[hps-pair] %s\n' "$*" >&2
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

ensure_hostname() {
  local ips="$1"
  local mac="$2"
  local name
  name=$(fetch_hostname "$ips" || true)
  if [[ -z "$name" ]]; then
    name="hps-${mac//:/}"
    log "registry returned no HOSTNAME; using $name"
  fi
  set_hostname "$name"
}

# Same request shape as node-manager/base/n_api_client.sh n_api_call.
report_pair_request() {
  local ips="$1"
  local mac="$2"
  local reqid="$3"
  local body
  body=$(jq -n -c --arg mac "$mac" --arg reqid "$reqid" \
    '{action: "ctrl_exec_pair_request", mac: $mac, reqid: $reqid}')
  run curl -fsS -X POST -H 'Content-Type: application/json' -H "X-HPS-MAC: ${mac}" \
    -d "$body" "http://${ips}/api/api.sh"
}

wait_for_cert() {
  local waited=0
  while [[ $waited -lt $HPS_PAIR_TIMEOUT ]]; do
    if [[ -s "$HPS_AGENT_ETC/agent.crt" ]]; then
      return 0
    fi
    sleep "$HPS_PAIR_POLL"
    waited=$((waited + HPS_PAIR_POLL))
  done
  return 1
}

pair() {
  local ips="$1"
  local mac="$2"
  local reqid
  reqid=$(run ctrl-exec-agent request-pairing --background \
    --timeout "$HPS_PAIR_TIMEOUT" --dispatcher "$ips") || {
    log "request-pairing failed"
    return 1
  }
  # The reqid is the first output line; keep its hex only.
  reqid="${reqid%%$'\n'*}"
  reqid=$(printf '%s' "$reqid" | tr -dc 'a-f0-9')
  if [[ -z "$reqid" ]]; then
    log "no reqid returned from request-pairing"
    return 1
  fi
  log "pairing reqid $reqid"
  if ! report_pair_request "$ips" "$mac" "$reqid" > /dev/null; then
    log "the IPS declined the pairing request"
    return 1
  fi
  if ! wait_for_cert; then
    log "pairing timed out after ${HPS_PAIR_TIMEOUT}s"
    return 1
  fi
  log "paired (certificate received)"
  run systemctl restart ctrl-exec-agent.service || log "agent restart failed (continuing)"
  return 0
}

main() {
  local ips mac set_name=1
  case "${1:-}" in
    "") ;;
    --no-hostname) set_name=0 ;;
    *) echo "Usage: hps-pair [--no-hostname]" >&2; exit 2 ;;
  esac

  if [[ -s "$HPS_AGENT_ETC/agent.crt" ]]; then
    log "certificate already present; skipping pairing"
    return 0
  fi

  ips=$(discover_ips || true)
  mac=$(discover_mac || true)
  log "ips=${ips:-<none>} mac=${mac:-<none>}"
  if [[ -z "$ips" ]]; then
    log "no IPS address: cannot pair"
    return 1
  fi

  if [[ $set_name -eq 1 ]]; then
    ensure_hostname "$ips" "$mac"
  fi
  pair "$ips" "$mac"
}

main "$@"
