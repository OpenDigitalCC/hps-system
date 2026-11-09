#!/usr/bin/env bash
#
# hps-time - get the node clock right before anything needs TLS.
#
# Runs as a oneshot (nix/modules/hps-common.nix) after network-online and
# before hps-audit and hps-node-init, on every HPS image.
# A netboot node has no RTC value worth trusting (the DL360 booted in 2001) and
# ctrl-exec pairing is mTLS, so a wrong clock stops pairing.
#
#  1. Finds the IPS: hps.ips= on the kernel command line, else the default
#     gateway.
#  2. Writes $HPS_TIMESYNCD_DIR/hps.conf ("[Time]", "NTP=<ips>",
#     empty "FallbackNTP=": the IPS is the only time source, no public pool) and restarts
#     systemd-timesyncd (it starts in sysinit, before the network, so it
#     cannot be ordered after this unit) so it syncs from the IPS chrony.
#  3. If the clock year is below HPS_MIN_YEAR, sets the clock once from the
#     Date: header of an HTTP response from the IPS, so TLS works before
#     timesyncd has converged.
#
# With no IPS found it logs and exits 0: time must never stop a boot.
#
# Overrides for tests: HPS_CMDLINE (file), HPS_TIMESYNCD_DIR, HPS_MIN_YEAR,
# HPS_TIME_GW_TRIES.

set -euo pipefail

: "${HPS_CMDLINE:=/proc/cmdline}"
: "${HPS_TIMESYNCD_DIR:=/run/systemd/timesyncd.conf.d}"
: "${HPS_MIN_YEAR:=2024}"
: "${HPS_TIME_GW_TRIES:=10}"

log() {
  printf '[hps-time] %s\n' "$*" >&2
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

gateway_ips() {
  local n=0 gw
  while [[ "$n" -lt "$HPS_TIME_GW_TRIES" ]]; do
    log "+ ip -4 route show default"
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

write_timesyncd_conf() {
  local ips="$1"
  local conf="$HPS_TIMESYNCD_DIR/hps.conf"
  log "+ mkdir -p $HPS_TIMESYNCD_DIR"
  mkdir -p "$HPS_TIMESYNCD_DIR"
  log "writing $conf (NTP=$ips)"
  printf '[Time]\nNTP=%s\nFallbackNTP=\n' "$ips" > "$conf"
}

restart_timesyncd() {
  log "+ systemctl try-restart systemd-timesyncd.service"
  systemctl try-restart systemd-timesyncd.service || log "timesyncd restart failed (continuing)"
}

# The Date: header value of an HTTP response from the IPS, or nothing.
ips_http_date() {
  local ips="$1"
  local url="http://${ips}/nixos/latest"
  log "+ curl -sI --max-time 10 $url"
  curl -sI --max-time 10 "$url" | awk -F': ' 'tolower($1) == "date" { sub(/\r$/, "", $2); print $2; exit }'
}

set_clock_from_ips() {
  local ips="$1"
  local year stamp
  log "+ date -u +%Y"
  year=$(date -u +%Y)
  if [[ "$year" -ge "$HPS_MIN_YEAR" ]]; then
    log "clock year $year is plausible; leaving it to timesyncd"
    return 0
  fi
  log "clock year $year is before $HPS_MIN_YEAR; taking the time from the IPS"
  stamp=$(ips_http_date "$ips" || true)
  if [[ -z "$stamp" ]]; then
    log "no Date: header from the IPS; clock left unchanged"
    return 0
  fi
  log "+ date -u -s $stamp"
  date -u -s "$stamp"
}

main() {
  local ips=""
  ips=$(cmdline_ips || true)
  if [[ -z "$ips" ]]; then
    log "hps.ips absent from the command line; trying the default gateway"
    ips=$(gateway_ips || true)
  fi
  if [[ -z "$ips" ]]; then
    log "no IPS address found; time left to the defaults"
    return 0
  fi
  log "IPS: $ips"
  write_timesyncd_conf "$ips"
  set_clock_from_ips "$ips" || log "setting the clock failed (continuing)"
  restart_timesyncd
  return 0
}

main "$@"
