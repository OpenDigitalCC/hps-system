#!/usr/bin/env bash
#
# hps-md-event - the mdadm monitor's PROGRAM on compute (TCH) nodes.
#
# NOT a ctrl-exec script: mdadm --monitor (mdmonitor.service) runs it for every
# md event as
#   hps-md-event <event> <md device> [<component device>]
# and mdadm already logs every event itself. This adds ONE structured syslog
# line (tag hps-issue) for the events that open or close a mirror-leg issue;
# the IPS issue watcher parses exactly this format:
#
#   Fail | FailSpare | DegradedArray:
#     HPS-ISSUE open kind=mirror-leg host=<host> mirror=<name> component=<dev> event=<Event> [leg=<iqn>@<portal>]
#   RebuildFinished | RecoveryFinished | SpareActive, and the array is clean
#   (/sys/block/<mdX>/md/degraded is 0):
#     HPS-ISSUE resolve kind=mirror-leg host=<host> mirror=<name> event=<Event>
#   anything else: no line.
#
# <host> is the short hostname. <name> is the mirror's name: the /dev/md/<name>
# link that points at the device, else the Name of mdadm --detail (without the
# "host:" prefix), else the device's own name. <dev> is the component mdadm
# names, "-" when it names none (DegradedArray). leg= is added when the
# component is the disk of an iSCSI session (iscsiadm -m session -P3), and left
# out otherwise. Nothing secret is ever in the line.
#
# Always exits 0: an event hook must never disturb the monitor.
# Test hooks: HPS_DEV (default /dev), HPS_SYS (default /sys), HPS_HOSTNAME_FILE
# (default /proc/sys/kernel/hostname).

# No -e: a lookup that fails (no /dev/md link, no iSCSI session) leaves a field
# out; the line is still written and the exit is still 0.
set -uo pipefail

: "${HPS_DEV:=/dev}"
: "${HPS_SYS:=/sys}"
: "${HPS_HOSTNAME_FILE:=/proc/sys/kernel/hostname}"

EVENT=${1:-}
MD=${2:-}
COMPONENT=${3:-}

log() {
  printf '[hps-md-event] %s\n' "$*" >&2
}

short_host() {
  local h=""
  read -r h < "$HPS_HOSTNAME_FILE" 2> /dev/null || true
  h=${h%%.*}
  printf '%s\n' "${h:-unknown}"
}

# devpath <path>: a /dev path under HPS_DEV (the same path when HPS_DEV is /dev).
devpath() {
  case "$1" in
    /dev/*) printf '%s/%s\n' "$HPS_DEV" "${1#/dev/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# md_kernel_name: mdX of the md device ("md127").
md_kernel_name() {
  local real
  real=$(readlink -f -- "$(devpath "$MD")" 2> /dev/null || printf '%s' "$MD")
  printf '%s\n' "${real##*/}"
}

# mirror_name: the /dev/md/<name> link of the device, else mdadm's Name.
mirror_name() {
  local link kname name=""
  case "$MD" in
    */md/*)
      printf '%s\n' "${MD##*/}"
      return 0
      ;;
  esac
  kname=$(md_kernel_name)
  for link in "$HPS_DEV/md"/*; do
    [[ -L "$link" ]] || continue
    if [[ "$(readlink -f -- "$link")" == */"$kname" ]]; then
      printf '%s\n' "${link##*/}"
      return 0
    fi
  done
  printf '+ mdadm --detail %s\n' "$MD" >&2
  name=$(mdadm --detail "$MD" 2> /dev/null | sed -n -E '/^[[:space:]]*Name[[:space:]]*:/{s/^[^:]*:[[:space:]]*//;s/[[:space:]].*$//;p;q}')
  name=${name##*:}
  printf '%s\n' "${name:-$kname}"
}

# array_clean: /sys/block/<mdX>/md/degraded reads 0.
array_clean() {
  local d=""
  read -r d < "$HPS_SYS/block/$(md_kernel_name)/md/degraded" 2> /dev/null || return 1
  [[ "$d" == 0 ]]
}

# leg_of_component: <iqn>@<portal> of the iSCSI session whose attached disk is
# the component; nothing when there is none.
leg_of_component() {
  local disk line target="" portal=""
  disk=$(readlink -f -- "$(devpath "$COMPONENT")" 2> /dev/null || printf '%s' "$COMPONENT")
  disk=${disk##*/}
  [[ -n "$disk" ]] || return 0
  printf '+ iscsiadm -m session -P3\n' >&2
  while IFS= read -r line; do
    if [[ "$line" =~ ^Target:\ ([^ ]+) ]]; then
      target=${BASH_REMATCH[1]}
      portal=""
    elif [[ "$line" =~ Current\ Portal:\ ([^ ,]+) ]]; then
      portal=${BASH_REMATCH[1]}
    elif [[ "$line" =~ Attached\ scsi\ disk\ ([^ [:space:]]+) ]]; then
      if [[ "${BASH_REMATCH[1]}" == "$disk" && -n "$target" && -n "$portal" ]]; then
        printf '%s@%s\n' "$target" "$portal"
        return 0
      fi
    fi
  done < <(iscsiadm -m session -P3 2> /dev/null)
  return 0
}

emit() {
  log "$*"
  logger -t hps-issue -- "$*" || log "logger failed"
}

main() {
  local host name line leg
  case "$EVENT" in
    Fail | FailSpare | DegradedArray)
      host=$(short_host)
      name=$(mirror_name)
      line="HPS-ISSUE open kind=mirror-leg host=$host mirror=$name component=${COMPONENT:--} event=$EVENT"
      if [[ -n "$COMPONENT" ]]; then
        leg=$(leg_of_component)
        if [[ -n "$leg" ]]; then
          line="$line leg=$leg"
        fi
      fi
      emit "$line"
      ;;
    RebuildFinished | RecoveryFinished | SpareActive)
      if array_clean; then
        host=$(short_host)
        name=$(mirror_name)
        emit "HPS-ISSUE resolve kind=mirror-leg host=$host mirror=$name event=$EVENT"
      fi
      ;;
    *) ;;
  esac
  return 0
}

main
exit 0
