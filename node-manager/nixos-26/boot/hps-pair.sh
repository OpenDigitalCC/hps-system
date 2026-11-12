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
#   3. unless --no-hostname: make the kernel hostname the registry HOSTNAME
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
#      restart the agent. The IPS's HTTP code decides what comes next (see
#      pair below): 503 retry with backoff 5, 10, 20, 40, 60, 60 ... s within
#      the pairing window, 410 reboot into netboot (a new boot script, a new
#      window; the IPS allows three), 403 stop. Every attempt is logged with
#      the reason the IPS gave.
#      With ctrl-exec 0.14.3 or later the agent is told the name to register
#      under (request-pairing --name <the transient hostname>), so the
#      registration is exactly <label>.<hps.domain> whatever hostfqdn() would
#      make of a DHCP-supplied domain. Support is detected from the agent's own
#      usage text (a feature probe: it needs no version parsing and holds for
#      a backport or a build whose version string is unusual); an older agent
#      gets the call without --name and registers as before.
#
# Usage: hps-pair [--no-hostname]
# Exit: 0 paired, already paired, or rebooting for a new window; 1 pairing
# failed for now (the unit retries); 2 usage; 3 the IPS refused (the units
# do not restart on 3: RestartPreventExitStatus).
#
# Overrides for tests: HPS_CMDLINE (file), HPS_AGENT_ETC, HPS_PAIR_TIMEOUT
# (seconds), HPS_PAIR_POLL (seconds), HPS_PAIR_WINDOW, HPS_PAIR_BACKOFF,
# HPS_PAIR_GRACE, HPS_PAIR_REPORT_TIMEOUT, HPS_UPTIME (file).

set -euo pipefail

: "${HPS_CMDLINE:=/proc/cmdline}"
: "${HPS_AGENT_ETC:=/etc/ctrl-exec-agent}"
# The pairing request timeout: request-pairing --timeout, the time the
# dispatcher holds the request. The IPS waits as long for its pairing jobs
# (CTRL_EXEC_PAIR_REQUEST_TIMEOUT, lib/functions.d/ctrl-exec-functions.sh):
# keep the two equal.
: "${HPS_PAIR_TIMEOUT:=300}"
: "${HPS_PAIR_POLL:=2}"
# The IPS's pairing window (CTRL_EXEC_PAIR_WINDOW): seconds from the boot
# script within which the IPS approves. Used until the IPS gives window_left.
: "${HPS_PAIR_WINDOW:=300}"
# Waits between attempts, seconds; the last one repeats.
: "${HPS_PAIR_BACKOFF:=5 10 20 40 60}"
# How long past the window to go on asking an IPS that does not answer.
: "${HPS_PAIR_GRACE:=60}"
# curl --max-time of one report: the IPS may wait HPS_PAIR_TIMEOUT for its jobs.
: "${HPS_PAIR_REPORT_TIMEOUT:=$((HPS_PAIR_TIMEOUT + 30))}"
: "${HPS_UPTIME:=/proc/uptime}"

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
  # -s without -S: a 404 (no name yet) is an expected answer, not an error line.
  run curl -fs "http://${ips}/cgi-bin/boot_manager.sh?cmd=host_variable&name=HOSTNAME"
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

# fqdn_of <label>: <label>.<hps.domain> (docs/NAMING.md), the label alone when
# the command line has no domain. A malformed domain, or an FQDN over 63
# characters (the om3 node-name cap), fails.
fqdn_of() {
  local label="${1,,}"
  local domain name
  domain=$(cmdline_value hps.domain || true)
  domain="${domain,,}"
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
  name=$(fqdn_of "$name") || return 1
  set_hostname "$name"
  check_self_resolves "$name"
  REGISTER_NAME="$name"
}

# report_pair_request <ips> <mac> <reqid or empty>: POST the reqid (same
# request shape as node-manager/base/n_api_client.sh n_api_call; an empty reqid
# asks only whether to keep trying). Sets REPLY_CODE (the HTTP status, 000
# when there was no answer), REPLY_REASON, REPLY_DETAILS and REPLY_LEFT (the
# window_left the IPS gave, empty when none). Always returns 0.
report_pair_request() {
  local ips="$1"
  local mac="$2"
  local reqid="$3"
  local body reply code
  body=$(jq -n -c --arg mac "$mac" --arg reqid "$reqid" \
    '{action: "ctrl_exec_pair_request", mac: $mac, reqid: $reqid}')
  reply="${TMPDIR:-/tmp}/hps-pair-$$.reply"
  : > "$reply"
  code=$(run curl -sS --max-time "$HPS_PAIR_REPORT_TIMEOUT" -o "$reply" -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' -H "X-HPS-MAC: ${mac}" \
    -d "$body" "http://${ips}/api/api.sh") || code=000
  [[ "$code" =~ ^[0-9]{3}$ ]] || code=000
  REPLY_CODE="$code"
  REPLY_REASON=$(jq -r '.reason // empty' "$reply" 2> /dev/null || true)
  REPLY_DETAILS=$(jq -r '.details // empty' "$reply" 2> /dev/null || true)
  REPLY_LEFT=$(jq -r '.window_left // empty' "$reply" 2> /dev/null || true)
  [[ "$REPLY_LEFT" =~ ^[0-9]+$ ]] || REPLY_LEFT=""
  rm -f "$reply"
  return 0
}

# wait_for_cert: poll for agent.crt, at most HPS_PAIR_TIMEOUT seconds.
wait_for_cert() {
  local waited=0
  while [[ $waited -lt $HPS_PAIR_TIMEOUT ]]; do
    if [[ -s "$HPS_AGENT_ETC/agent.crt" ]]; then
      return 0
    fi
    sleep "$HPS_PAIR_POLL"
    waited=$((waited + HPS_PAIR_POLL))
  done
  [[ -s "$HPS_AGENT_ETC/agent.crt" ]]
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

# await_reqid <pid> <file> [seconds]: poll until the reqid line appears. Fails
# when the process ends without one (non-zero exit, or no output) or on
# timeout (default HPS_PAIR_TIMEOUT).
await_reqid() {
  local pid="$1"
  local file="$2"
  local limit="${3:-$HPS_PAIR_TIMEOUT}"
  local waited=0
  local reqid
  while [[ $waited -lt $limit ]]; do
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

# The running request-pairing: its pid, stdout file and reqid.
REQ_PID=""
REQ_OUT=""
REQID=""
NAME_ARGS=()

# stop_request: end the running request-pairing (if any) and forget its reqid.
stop_request() {
  if [[ -n "$REQ_PID" ]] && kill -0 "$REQ_PID" 2> /dev/null; then
    kill "$REQ_PID" 2> /dev/null || true
  fi
  if [[ -n "$REQ_PID" ]]; then
    wait "$REQ_PID" 2> /dev/null || true
  fi
  [[ -n "$REQ_OUT" ]] && rm -f "$REQ_OUT"
  REQ_PID=""
  REQ_OUT=""
  REQID=""
}

# start_request <ips> <seconds>: start ctrl-exec-agent request-pairing in the
# background and wait (at most <seconds>) for its reqid. Sets REQID; fails
# (REQID empty, the process stopped) when none came.
start_request() {
  local ips="$1"
  local limit="$2"
  local rc=0
  REQ_OUT="${TMPDIR:-/tmp}/hps-pair-$$.out"
  : > "$REQ_OUT"
  log "+ ctrl-exec-agent request-pairing --background --timeout $HPS_PAIR_TIMEOUT --dispatcher $ips ${NAME_ARGS[*]} (background, stdout in $REQ_OUT)"
  ctrl-exec-agent request-pairing --background \
    --timeout "$HPS_PAIR_TIMEOUT" --dispatcher "$ips" "${NAME_ARGS[@]}" > "$REQ_OUT" &
  REQ_PID=$!
  if REQID=$(await_reqid "$REQ_PID" "$REQ_OUT" "$limit"); then
    log "pairing reqid $REQID"
    return 0
  fi
  REQID=""
  if kill -0 "$REQ_PID" 2> /dev/null; then
    log "no reqid within ${limit}s; stopping request-pairing"
    kill "$REQ_PID" 2> /dev/null || true
  fi
  wait "$REQ_PID" 2> /dev/null || rc=$?
  log "request-pairing gave no reqid (exit ${rc})"
  rm -f "$REQ_OUT"
  REQ_PID=""
  REQ_OUT=""
  return 1
}

# backoff_for <attempt>: the attempt's wait from HPS_PAIR_BACKOFF (5 10 20 40
# 60 by default); the last value repeats.
backoff_for() {
  local n="$1"
  local -a steps
  read -r -a steps <<< "$HPS_PAIR_BACKOFF"
  if (( n > ${#steps[@]} )); then
    n=${#steps[@]}
  fi
  printf '%s\n' "${steps[n - 1]}"
}

# window_end_from_boot: the epoch the node's pairing window ends, counted from
# its own boot (HPS_UPTIME, /proc/uptime) until the IPS says otherwise. The boot
# script was issued shortly before the kernel started, so this errs late; the
# IPS's window_left in its first answer replaces it.
window_end_from_boot() {
  local up now
  up=$(cut -d' ' -f1 "$HPS_UPTIME" 2> /dev/null || echo 0)
  up="${up%%.*}"
  [[ "$up" =~ ^[0-9]+$ ]] || up=0
  now=$(date +%s)
  printf '%s\n' "$((now - up + HPS_PAIR_WINDOW))"
}

# finish_paired: the IPS approved; wait for the certificate, restart the agent.
finish_paired() {
  if ! wait_for_cert; then
    log "pairing timed out after ${HPS_PAIR_TIMEOUT}s: approved, but no certificate arrived"
    stop_request
    return 1
  fi
  if [[ -n "$REQ_PID" ]]; then
    wait "$REQ_PID" || log "request-pairing exited ${?} (certificate present; continuing)"
  fi
  [[ -n "$REQ_OUT" ]] && rm -f "$REQ_OUT"
  REQ_PID=""
  log "paired (certificate received)"
  run systemctl restart ctrl-exec-agent.service || log "agent restart failed (continuing)"
  return 0
}

# pair <ips> <mac> [<name>]: request pairing and report the reqid to the IPS
# until it decides, every attempt logged with the reason the IPS gave:
#   200  approved: wait for the certificate, restart the agent (0)
#   503  not yet: wait 5, 10, 20, 40, 60, 60 ... s (HPS_PAIR_BACKOFF), bounded by
#        the time left in the pairing window, and ask again; reason
#        unknown_request (or no reqid): a new request-pairing first
#   410  the window has passed: reboot into netboot, which renews the window
#        (the IPS counts these reboots and gives up after three) (0)
#   403  refused: stop (3; the unit does not restart)
# No answer at all (000, another code) counts as not yet; once the window is
# HPS_PAIR_GRACE seconds past without a decision it fails (1; the unit retries).
pair() {
  local ips="$1"
  local mac="$2"
  local name="${3:-}"
  local attempt=0 window_end now left wait_s
  NAME_ARGS=()
  if [[ -n "$name" ]]; then
    if agent_supports_name; then
      NAME_ARGS=(--name "$name")
      log "agent supports --name: registering as $name"
    else
      log "agent has no request-pairing --name (before ctrl-exec 0.14.3): registering under its own FQDN"
    fi
  fi
  window_end=$(window_end_from_boot)
  while true; do
    attempt=$((attempt + 1))
    now=$(date +%s)
    left=$((window_end - now))
    if [[ -s "$HPS_AGENT_ETC/agent.crt" ]]; then
      log "attempt ${attempt}: the certificate is already here (approved earlier)"
      finish_paired
      return $?
    fi
    if [[ -z "$REQID" ]]; then
      # Wait for the reqid at most the window left, but never less than 30 s
      # (the node's own estimate of its window may be early); the IPS decides.
      wait_s=$(( left > 30 ? left : 30 ))
      start_request "$ips" "$(( wait_s < HPS_PAIR_TIMEOUT ? wait_s : HPS_PAIR_TIMEOUT ))" || true
    fi
    report_pair_request "$ips" "$mac" "$REQID"
    if [[ -n "$REPLY_LEFT" ]]; then
      window_end=$(( $(date +%s) + REPLY_LEFT ))
    fi
    log "attempt ${attempt}: reqid ${REQID:-<none>}: IPS answered ${REPLY_CODE} ${REPLY_REASON:-<no reason>}${REPLY_DETAILS:+ (${REPLY_DETAILS})}; ${REPLY_LEFT:-?}s left in the window"
    case "$REPLY_CODE" in
      200)
        if [[ -z "$REQID" ]]; then
          log "the IPS approved without a reqid: not expected; asking again"
        else
          finish_paired
          return $?
        fi
        ;;
      410)
        log "error: the pairing window has passed; rebooting into netboot for a new one"
        stop_request
        run systemctl reboot || { log "systemctl reboot failed"; return 1; }
        return 0
        ;;
      403)
        log "error: the IPS refused pairing (${REPLY_REASON:-refused}); not retrying. ${REPLY_DETAILS}"
        stop_request
        return 3
        ;;
      503)
        if [[ "$REPLY_REASON" == unknown_request && -n "$REQID" ]]; then
          log "the dispatcher does not hold reqid ${REQID}; requesting pairing again"
          stop_request
        fi
        ;;
      *)
        log "no usable answer from the IPS (HTTP ${REPLY_CODE}); counted as not yet"
        ;;
    esac
    now=$(date +%s)
    left=$((window_end - now))
    if (( left < -HPS_PAIR_GRACE )); then
      if [[ -s "$HPS_AGENT_ETC/agent.crt" ]]; then
        log "the certificate arrived (approved without an answer reaching this node)"
        finish_paired
        return $?
      fi
      log "error: ${HPS_PAIR_GRACE}s past the pairing window with no decision from the IPS; giving up for now"
      stop_request
      return 1
    fi
    wait_s=$(backoff_for "$attempt")
    # Bounded by the window: the next ask lands just after it ends at the
    # latest, when the IPS answers 410 (reboot) or 403.
    if (( left >= 0 && wait_s > left + 1 )); then
      wait_s=$((left + 1))
    fi
    log "attempt ${attempt}: next attempt in ${wait_s}s"
    sleep "$wait_s"
  done
}

# The name the agent registers under: the FQDN just set as the hostname, or,
# with --no-hostname (hps-node-init set it), the kernel hostname as it is now.
REGISTER_NAME=""

# use_current_hostname: with --no-hostname, register under the kernel hostname,
# which hps-node-init made the FQDN. A name with no dot (no cluster domain) is
# used as it is; an empty answer leaves the agent to choose its own name.
use_current_hostname() {
  local name
  name=$(hostname 2> /dev/null || true)
  name="${name,,}"
  if [[ "$name" =~ ^[a-z0-9][a-z0-9.-]*$ && "$name" != localhost ]]; then
    REGISTER_NAME="$name"
    log "registering under the kernel hostname $name"
  else
    log "no usable kernel hostname ('$name'); the agent registers under its own name"
  fi
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
  else
    use_current_hostname
  fi
  pair "$ips" "$mac" "$REGISTER_NAME"
}

main "$@"
