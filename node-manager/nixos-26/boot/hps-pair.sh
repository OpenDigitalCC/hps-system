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
#      (first label only, validated as an RFC 1123 label; fallback
#      hps-<mac without colons>), followed by ".<hps.domain>" when the kernel
#      command line carries hps.domain. The agent registers under it and the
#      IPS approver binds the request to the registry hostname (first label).
#      Why a dotted hostname: the agent registers as Net::Domain::hostfqdn().
#      With a bare host and no domain that is "host.." (trailing dots). With
#      a dotted hostname Net::Domain does not append a domain; it searches
#      for a name that gethostbyname() resolves, trying the dotted name
#      itself. nss-myhostname (in NixOS's default hosts: line) resolves the
#      machine's own hostname, so the result is exactly <name>.<domain>.
#      /etc/hosts is store-managed on NixOS and is left alone; a check after
#      setting the name logs a warning if getent cannot resolve it.
#   4. start ctrl-exec-agent request-pairing --background in the background
#      with its stdout in a temp file (a pipe would stay open until approval:
#      the agent forks and the child keeps stdout), poll the file for the
#      reqid, POST it to the IPS API (action ctrl_exec_pair_request, header
#      X-HPS-MAC) at once - the IPS approves only after that - then wait for
#      the certificate and for the request-pairing process to end, and
#      restart the agent
#      With ctrl-exec 0.14.3 or later the agent is told the name to register
#      under (request-pairing --name <the transient hostname>), so the
#      registration is exactly <label>.<hps.domain> whatever hostfqdn() would
#      make of a DHCP-supplied domain. Support is detected from the agent's own
#      usage text (a feature probe: it needs no version parsing and holds for
#      a backport or a build whose version string is unusual); an older agent
#      gets the call without --name and registers as before.
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

# valid_hostname <text>: print the first label when it is a valid host label
# (letters, digits, hyphen; 1-63 chars; not starting with a hyphen), else fail.
# The registry answer is untrusted text (an error body once became the name).
valid_hostname() {
  local label="${1%%.*}"
  if [[ "$label" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]]; then
    printf '%s\n' "$label"
    return 0
  fi
  [[ -n "$1" ]] && log "ignoring invalid hostname from the registry"
  return 1
}

# fqdn_of <label>: <label>.<hps.domain> when the command line has a valid
# domain, else the label alone.
fqdn_of() {
  local label="$1"
  local domain
  domain=$(cmdline_value hps.domain || true)
  if [[ "$domain" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
    printf '%s.%s\n' "$label" "$domain"
    return 0
  fi
  [[ -n "$domain" ]] && log "ignoring invalid hps.domain on the command line"
  printf '%s\n' "$label"
}

# check_self_resolves <name>: the agent's hostfqdn() needs gethostbyname() to
# resolve the node's own name; warn (never fail) when it does not.
check_self_resolves() {
  local name="$1"
  [[ "$name" == *.* ]] || return 0
  if ! getent hosts "$name" > /dev/null 2>&1; then
    log "warning: $name does not resolve locally; the agent may register under another name"
  fi
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
  name=$(valid_hostname "$name" || true)
  if [[ -z "$name" ]]; then
    name="hps-${mac//:/}"
    log "registry returned no usable HOSTNAME; using $name"
  fi
  name=$(fqdn_of "$name")
  set_hostname "$name"
  check_self_resolves "$name"
  REGISTER_NAME="$name"
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

# first_reqid_line <file>: print the hex reqid when the first line of the file
# is complete and hex; fail otherwise.
first_reqid_line() {
  local line
  [[ -s "$1" ]] || return 1
  IFS= read -r line < "$1" || return 1
  line="${line//[$'\r\t ']/}"
  [[ "$line" =~ ^[a-f0-9]+$ ]] || return 1
  printf '%s\n' "$line"
}

# await_reqid <pid> <file>: poll until the reqid line appears. Fails when the
# process ends without one (non-zero exit, or no output) or on timeout.
await_reqid() {
  local pid="$1"
  local file="$2"
  local waited=0
  local reqid
  while [[ $waited -lt $HPS_PAIR_TIMEOUT ]]; do
    if reqid=$(first_reqid_line "$file"); then
      printf '%s\n' "$reqid"
      return 0
    fi
    if ! kill -0 "$pid" 2> /dev/null; then
      # exited: one last look, since it may have printed just before exiting
      if reqid=$(first_reqid_line "$file"); then
        printf '%s\n' "$reqid"
        return 0
      fi
      return 1
    fi
    sleep "$HPS_PAIR_POLL"
    waited=$((waited + HPS_PAIR_POLL))
  done
  return 1
}

# agent_supports_name: true when ctrl-exec-agent request-pairing knows --name
# (0.14.3+). An unknown option makes the agent print its usage and exit; the
# text is captured first (grep -q on a pipe could SIGPIPE the producer under
# pipefail).
agent_supports_name() {
  local help
  help=$(ctrl-exec-agent request-pairing --help 2>&1 || true)
  [[ "$help" == *--name* ]]
}

pair() {
  local ips="$1"
  local mac="$2"
  local name="${3:-}"
  local reqid pid out rc=0
  local -a name_args=()
  if [[ -n "$name" ]]; then
    if agent_supports_name; then
      name_args=(--name "$name")
      log "agent supports --name: registering as $name"
    else
      log "agent has no request-pairing --name (before ctrl-exec 0.14.3): registering under its own FQDN"
    fi
  fi
  out="${TMPDIR:-/tmp}/hps-pair-$$.out"
  : > "$out"
  log "+ ctrl-exec-agent request-pairing --background --timeout $HPS_PAIR_TIMEOUT --dispatcher $ips ${name_args[*]} (background, stdout in $out)"
  ctrl-exec-agent request-pairing --background \
    --timeout "$HPS_PAIR_TIMEOUT" --dispatcher "$ips" "${name_args[@]}" > "$out" &
  pid=$!
  if ! reqid=$(await_reqid "$pid" "$out"); then
    if kill -0 "$pid" 2> /dev/null; then
      log "no reqid within ${HPS_PAIR_TIMEOUT}s; stopping request-pairing"
      kill "$pid" 2> /dev/null || true
    fi
    wait "$pid" 2> /dev/null || rc=$?
    log "request-pairing gave no reqid (exit ${rc})"
    rm -f "$out"
    return 1
  fi
  log "pairing reqid $reqid"
  # Report at once: the IPS approves only after it has the reqid.
  if ! report_pair_request "$ips" "$mac" "$reqid" > /dev/null; then
    log "the IPS declined the pairing request"
    kill "$pid" 2> /dev/null || true
    rm -f "$out"
    return 1
  fi
  if ! wait_for_cert; then
    log "pairing timed out after ${HPS_PAIR_TIMEOUT}s"
    kill "$pid" 2> /dev/null || true
    rm -f "$out"
    return 1
  fi
  wait "$pid" || log "request-pairing exited ${?} (certificate present; continuing)"
  rm -f "$out"
  log "paired (certificate received)"
  run systemctl restart ctrl-exec-agent.service || log "agent restart failed (continuing)"
  return 0
}

# The name just set as the transient hostname (empty with --no-hostname).
REGISTER_NAME=""

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
  pair "$ips" "$mac" "$REGISTER_NAME"
}

main "$@"
