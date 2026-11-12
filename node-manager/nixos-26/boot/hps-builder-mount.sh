#!/usr/bin/env bash
#
# hps-builder-mount - mount an image builder's persistent disk at boot.
#
# Runs as the oneshot hps-builder-mount.service on the builder image
# (nix/modules/profiles/builder.nix), before hps-builder-http.service. The
# disk is the one builder-disk-prepare made: an ext4 filesystem labelled
# hps-builder. This script NEVER formats anything; it only mounts it at
# /var/lib/hps-builder.
#
# No disk labelled hps-builder: logged, exit 0 (builder-disk-prepare <device>
# makes one). Two or more such disks: exit 1, nothing is mounted. A disk with
# the label but not ext4: exit 1. Already mounted: nothing to do.
#
# Overrides for tests: HPS_BUILDER_ROOT (prefix of the mount point),
# HPS_BUILDER_SETTLE (0 skips udevadm settle).

set -euo pipefail

: "${HPS_BUILDER_ROOT:=}"
: "${HPS_BUILDER_SETTLE:=1}"

LABEL=hps-builder
MNT="$HPS_BUILDER_ROOT/var/lib/hps-builder"

log() {
  printf '[hps-builder-mount] %s\n' "$*" >&2
}

# run <command...>: log then execute.
run() {
  printf '+ %s\n' "$*" >&2
  "$@"
}

main() {
  local devs=() dev type out
  if [[ "$HPS_BUILDER_SETTLE" == 1 ]]; then
    run udevadm settle --timeout=30 || log "udevadm settle did not finish; probing anyway"
  fi
  out=$(run blkid -o device -t "LABEL=$LABEL" || true)
  while IFS= read -r dev; do
    [[ -n "$dev" ]] && devs+=("$dev")
  done <<< "$out"
  if [[ ${#devs[@]} -eq 0 ]]; then
    log "no disk labelled $LABEL: nothing mounted (builder-disk-prepare <device> makes one)"
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
  if run findmnt -n -o SOURCE --mountpoint "$MNT" > /dev/null 2>&1; then
    log "$MNT is already mounted"
    return 0
  fi
  run mkdir -p -- "$MNT"
  run mount -t ext4 -o noatime -- "$dev" "$MNT"
  log "mounted $dev at $MNT"
}

main "$@"
