#!/usr/bin/env bash
#
# hps-log-target - tell the local rsyslog where the IPS is, before it starts.
#
# Runs as a oneshot ordered Before=syslog.service (nix/modules/hps-common.nix),
# on every HPS image. Reads hps.ips= from the kernel command line (fallback:
# the default gateway, retried briefly) and writes
# $HPS_RUN_DIR/rsyslog-target.conf, which rsyslog includes. With no IPS found
# it writes a comment-only file and exits 0: logging must never stop a boot.
#
# The IPS rsyslog listens on TCP and UDP 514 and files each source under
# <log dir>/<source ip>/YYYY-MM-DD.log. TCP is used so a dropped datagram does
# not lose the last lines before a crash; the action queues and retries while
# the IPS is unreachable.
#
# Overrides for tests: HPS_CMDLINE (file), HPS_RUN_DIR, HPS_LOG_GW_TRIES,
# HPS_LOG_PORT.

set -euo pipefail

: "${HPS_CMDLINE:=/proc/cmdline}"
: "${HPS_RUN_DIR:=/run/hps}"
: "${HPS_LOG_GW_TRIES:=30}"
: "${HPS_LOG_PORT:=514}"

log() {
  printf '[hps-log-target] %s\n' "$*" >&2
}

cmdline_ips() {
  local word
  # shellcheck disable=SC2013  # words of a one-line file
  for word in $(cat "$HPS_CMDLINE"); do
    case "$word" in
      hps.ips=*) printf '%s\n' "${word#hps.ips=}"; return 0 ;;
    esac
  done
  return 1
}

# hps.hostname= is the registry hostname the IPS put on the cmdline (assigned
# nodes only). rsyslog takes it as localHostname so the first forwarded line
# already carries the right name; hps-node-init sets the transient name later.
cmdline_hostname() {
  local word name
  # shellcheck disable=SC2013  # words of a one-line file
  for word in $(cat "$HPS_CMDLINE"); do
    case "$word" in
      hps.hostname=*)
        name="${word#hps.hostname=}"
        if [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$ ]]; then
          printf '%s\n' "$name"
          return 0
        fi
        log "ignoring malformed hps.hostname"
        return 1
        ;;
    esac
  done
  return 1
}

gateway_ips() {
  local n=0 gw
  while [[ "$n" -lt "$HPS_LOG_GW_TRIES" ]]; do
    gw=$(ip -4 route show default | awk '/^default/ {print $3; exit}')
    if [[ -n "$gw" ]]; then
      printf '%s\n' "$gw"
      return 0
    fi
    sleep 1
    n=$((n+1))
  done
  return 1
}

write_target() {
  local ips="$1" name="${2:-}" out="$HPS_RUN_DIR/rsyslog-target.conf"
  mkdir -p "$HPS_RUN_DIR"
  : > "$out"
  if [[ -n "$name" ]]; then
    log "syslog hostname ${name}"
    printf 'global(localHostname="%s")\n' "$name" >> "$out"
  fi
  if [[ -z "$ips" ]]; then
    log "no IPS address found; logs stay local"
    printf '# no IPS address found; logs stay local\n' >> "$out"
    return 0
  fi
  log "forwarding syslog to ${ips}:${HPS_LOG_PORT} (tcp)"
  printf '*.* action(type="omfwd" target="%s" port="%s" protocol="tcp" action.resumeRetryCount="-1" queue.type="LinkedList" queue.size="10000")\n' \
    "$ips" "$HPS_LOG_PORT" >> "$out"
}

main() {
  local ips=""
  ips=$(cmdline_ips || true)
  if [[ -z "$ips" ]]; then
    log "hps.ips absent from the command line; trying the default gateway"
    ips=$(gateway_ips || true)
  fi
  write_target "$ips" "$(cmdline_hostname || true)"
}

main "$@"
