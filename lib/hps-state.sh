#!/bin/bash
#===============================================================================
# HPS state ownership helpers
#===============================================================================
# One group owns the IPS state: the system group "hps" (created in the image;
# the web user www-data is a member). Every writer of state - root CLIs, the
# supervisor pre-start, the CGI as www-data - creates group-writable files
# (umask 002) and setgid directories of group hps, so any of them can write
# what another created.
#
# keysafe is the explicit exception: clusters/<cluster>/keysafe/ is root-only
# (0700). The CGI never reads keys. Nothing here chgrps or opens a path named
# keysafe.
#
# Sourced by hps-system.sh, hps-registry.sh and functions.sh; safe to source
# repeatedly.
#===============================================================================

HPS_STATE_GROUP="hps"
HPS_STATE_CHGRP_WARNED=0

_hps_state_log() {
  if declare -F hps_log >/dev/null 2>&1; then
    hps_log "$@"
  else
    echo "[hps-state] $*" >&2
  fi
}

# hps_state_umask: group-writable by default for everything created after.
hps_state_umask() {
  umask 002
}

# _hps_state_group_usable: true when running as root and group hps exists.
_hps_state_group_usable() {
  [[ "$(id -u)" -eq 0 ]] && getent group "$HPS_STATE_GROUP" >/dev/null 2>&1
}

# _hps_state_claim <dir>: setgid and (root only, best effort) group hps.
_hps_state_claim() {
  local dir=$1
  chmod g+rwxs "$dir" 2>/dev/null || true
  if [[ "$(id -u)" -ne 0 ]]; then
    return 0
  fi
  if ! getent group "$HPS_STATE_GROUP" >/dev/null 2>&1; then
    if [[ $HPS_STATE_CHGRP_WARNED -eq 0 ]]; then
      _hps_state_log warn "group ${HPS_STATE_GROUP} not found: state directories keep their default group"
      HPS_STATE_CHGRP_WARNED=1
    fi
    return 0
  fi
  if ! chgrp "$HPS_STATE_GROUP" "$dir" 2>/dev/null; then
    if [[ $HPS_STATE_CHGRP_WARNED -eq 0 ]]; then
      _hps_state_log warn "cannot chgrp ${HPS_STATE_GROUP} on ${dir} (continuing)"
      HPS_STATE_CHGRP_WARNED=1
    fi
  fi
  return 0
}

# hps_state_mkdir <dir>...: mkdir -p; every directory it creates gets g+s and
# group hps. Existing directories are left alone. Never fatal beyond mkdir.
hps_state_mkdir() {
  local dir p
  local -a made
  for dir in "$@"; do
    made=()
    p=$dir
    while [[ -n "$p" && "$p" != "/" && "$p" != "." && ! -d "$p" ]]; do
      made+=("$p")
      p=$(dirname "$p")
    done
    mkdir -p "$dir" || return 1
    for p in "${made[@]}"; do
      [[ -d "$p" ]] && _hps_state_claim "$p"
    done
  done
  return 0
}

# hps_state_fix_tree <dir>: make an existing tree group hps, group-writable,
# setgid on directories; prunes any path named keysafe. Idempotent. Sets
# HPS_STATE_FIX_COUNT to the number of paths visited. Refuses an empty value or /.
# shellcheck disable=SC2034  # HPS_STATE_FIX_COUNT is read by the caller
hps_state_fix_tree() {
  local top=${1:-}
  HPS_STATE_FIX_COUNT=0
  if [[ -z "$top" || "$top" == "/" ]]; then
    _hps_state_log error "hps_state_fix_tree: refusing to run against '${top}'"
    return 1
  fi
  if [[ ! -d "$top" ]]; then
    return 0
  fi
  if _hps_state_group_usable; then
    find "$top" -name keysafe -prune -o -exec chgrp "$HPS_STATE_GROUP" {} + 2>/dev/null || true
  elif [[ "$(id -u)" -eq 0 ]]; then
    _hps_state_log warn "group ${HPS_STATE_GROUP} not found: not changing group of ${top}"
  fi
  find "$top" -name keysafe -prune -o -exec chmod g+rwX {} + 2>/dev/null || true
  find "$top" -name keysafe -prune -o -type d -exec chmod g+s {} + 2>/dev/null || true
  HPS_STATE_FIX_COUNT=$(find "$top" -name keysafe -prune -o -print | wc -l)
  return 0
}
