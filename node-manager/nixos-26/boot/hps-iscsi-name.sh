#!/usr/bin/env bash
#
# hps-iscsi-name - write the iSCSI initiator name for this boot.
#
# Runs as a oneshot (nix/modules/profiles/compute.nix) after hps-node-init has
# set the transient hostname from the registry, and before iscsid starts.
# /etc/iscsi/initiatorname.iscsi is a symlink to $HPS_RUN_DIR/initiatorname.iscsi
# (the image holds no per-node value).
#
#   name = iqn.2026-11.hps:<short hostname>
#
# The short hostname (first label) is lowercased; anything outside [a-z0-9.-]
# is refused rather than rewritten, so two nodes cannot collapse to one name.
#
# Overrides for tests: HPS_RUN_DIR, HPS_HOSTNAME (instead of hostname(1)).

set -euo pipefail

: "${HPS_RUN_DIR:=/run/hps}"

log() {
  printf '[hps-iscsi-name] %s\n' "$*" >&2
}

current_hostname() {
  if [[ -v HPS_HOSTNAME ]]; then
    printf '%s\n' "$HPS_HOSTNAME"
    return 0
  fi
  log "+ hostname"
  hostname
}

main() {
  local full short name target
  full=$(current_hostname)
  short="${full%%.*}"
  short="${short,,}"
  if [[ -z "$short" || "$short" == "localhost" || "$short" == "(none)" ]]; then
    log "no registry hostname yet ('${full}'): not writing an initiator name"
    exit 1
  fi
  if [[ ! "$short" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
    log "hostname '${short}' is not usable in an IQN"
    exit 1
  fi
  name="iqn.2026-11.hps:${short}"
  target="$HPS_RUN_DIR/initiatorname.iscsi"
  log "+ mkdir -p $HPS_RUN_DIR"
  mkdir -p "$HPS_RUN_DIR"
  log "+ write $target (InitiatorName=${name})"
  printf 'InitiatorName=%s\n' "$name" > "$target.tmp"
  mv -f "$target.tmp" "$target"
}

main "$@"
