#!/usr/bin/env bash
#
# hps-cnh-mount - mount a container host's persistent disk at boot.
#
# Runs as the oneshot hps-cnh-mount.service on the CNH image
# (nix/modules/profiles/container-host.nix), before hps-ips.service. The disk is
# the one cnh-disk-prepare made: an ext4 filesystem labelled hps-cnh. This
# script NEVER formats anything; it only mounts:
#
#   <disk>                 -> /var/lib/containers   (podman storage)
#   <disk>/hps-ips (bind)  -> /var/lib/hps-ips      (the IPS state)
#
# No disk labelled hps-cnh: logged, exit 0 (container storage stays in RAM
# until cnh-disk-prepare is run). Two or more such disks: exit 1, nothing is
# mounted (which one holds the state cannot be told). A disk with the label but
# not ext4: exit 1. Already mounted: nothing to do.
#
# Overrides for tests: HPS_CNH_ROOT (prefix of the two mount points),
# HPS_CNH_SETTLE (0 skips udevadm settle).

set -euo pipefail

: "${HPS_CNH_ROOT:=}"
: "${HPS_CNH_SETTLE:=1}"

LABEL=hps-cnh
CONTAINERS="$HPS_CNH_ROOT/var/lib/containers"
IPSDIR="$HPS_CNH_ROOT/var/lib/hps-ips"

log() {
  printf '[hps-cnh-mount] %s\n' "$*" >&2
}

# run <command...>: log then execute.
run() {
  printf '+ %s\n' "$*" >&2
  "$@"
}

is_mounted() {
  run findmnt -n -o SOURCE --mountpoint "$1" > /dev/null 2>&1
}

main() {
  local devs=() dev type out
  if [[ "$HPS_CNH_SETTLE" == 1 ]]; then
    run udevadm settle --timeout=30 || log "udevadm settle did not finish; probing anyway"
  fi
  out=$(run blkid -o device -t "LABEL=$LABEL" || true)
  while IFS= read -r dev; do
    [[ -n "$dev" ]] && devs+=("$dev")
  done <<< "$out"
  if [[ ${#devs[@]} -eq 0 ]]; then
    log "no disk labelled $LABEL: container storage stays in RAM (cnh-disk-prepare <device> makes one)"
    return 0
  fi
  if [[ ${#devs[@]} -gt 1 ]]; then
    log "${#devs[@]} disks are labelled $LABEL (${devs[*]}): not mounting any; remove the label from all but one"
    return 1
  fi
  dev=${devs[0]}
  type=$(run blkid -p -o value -s TYPE -- "$dev" || true)
  if [[ "$type" != ext4 ]]; then
    log "$dev is labelled $LABEL but its filesystem is '${type:-none}', not ext4: not mounting"
    return 1
  fi
  if is_mounted "$CONTAINERS"; then
    log "$CONTAINERS is already mounted"
  else
    run mkdir -p -- "$CONTAINERS"
    run mount -t ext4 -o noatime -- "$dev" "$CONTAINERS"
  fi
  run mkdir -p -- "$CONTAINERS/hps-ips"
  run chmod 0700 -- "$CONTAINERS/hps-ips"
  if is_mounted "$IPSDIR"; then
    log "$IPSDIR is already mounted"
  else
    run mkdir -p -- "$IPSDIR"
    run mount --bind -- "$CONTAINERS/hps-ips" "$IPSDIR"
  fi
  log "mounted $dev at $CONTAINERS and $IPSDIR"
}

main "$@"
