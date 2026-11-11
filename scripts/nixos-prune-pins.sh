#!/usr/bin/env bash
#===============================================================================
# nixos-prune-pins.sh [--dry-run | --apply] [--keep <n>]
# ------------------------------------------------------
# Remove superseded NixOS pin directories from ${HPS_RESOURCES}/nixos.
#
# Always kept: the pin named by the "latest" file, every host's system_pin and
# system_pin_previous, and the active cluster's nixos_default_pin. With
# --keep <n> the n newest other pins (by directory mtime) are kept as well.
# Everything else is listed; --apply removes it. The default is --dry-run,
# which changes nothing.
#
# Refuses (exit 1, nothing removed) when "latest" is missing, empty or names a
# pin that is not there. Only the artefact directories are removed: the
# builder's Nix store is a separate matter. Directories whose names are not
# valid pin names are left alone and reported, as is firmware/ (the shared
# firmware layers, which hps-pins prune manages).
#
# Environment: HPS_BASE (default /srv); HPS_SYSTEM_PATH overrides
# $HPS_BASE/hps-system. The pin directory is "resources" from hps_get_config.
#
# Exit: 0 done, 1 refused or failed, 2 bad usage.
#===============================================================================
set -euo pipefail

MODE=dry-run
KEEP=0
ROOT=""
declare -A REFERENCED=()
declare -A WHY=()

usage() {
  echo "usage: nixos-prune-pins.sh [--dry-run | --apply] [--keep <n>]" >&2
  return 0
}

parse_args() {
  local seen_mode=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) [[ -z "$seen_mode" || "$seen_mode" == dry-run ]] || { usage; exit 2; }
                 seen_mode=dry-run; MODE=dry-run; shift ;;
      --apply)   [[ -z "$seen_mode" || "$seen_mode" == apply ]] || { usage; exit 2; }
                 seen_mode=apply; MODE=apply; shift ;;
      --keep)    KEEP="${2:-}"
                 [[ "$KEEP" =~ ^[0-9]+$ ]] || { usage; exit 2; }
                 shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *)         usage; exit 2 ;;
    esac
  done
  return 0
}

load_hps() {
  local base="${HPS_BASE:-/srv}"
  local system_path="${HPS_SYSTEM_PATH:-${base}/hps-system}"
  export HPS_BASE="$base"
  if [[ ! -f "${system_path}/lib/functions.sh" ]]; then
    echo "nixos-prune-pins: function library not found: ${system_path}/lib/functions.sh" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "${system_path}/lib/functions.sh"
  return 0
}

refuse() {
  hps_log error "nixos-prune-pins: $*"
  echo "nixos-prune-pins: $*" >&2
  exit 1
}

# note_ref <pin> <why>: record a pin as referenced.
note_ref() {
  local pin="$1" why="$2"
  [[ -n "$pin" ]] || return 0
  REFERENCED["$pin"]=1
  WHY["$pin"]="${WHY[$pin]:+${WHY[$pin]}, }$why"
  return 0
}

collect_latest() {
  local pin=""
  [[ -r "${ROOT}/latest" ]] || refuse "no readable ${ROOT}/latest; refusing to prune"
  pin="$(tr -d '[:space:]' < "${ROOT}/latest")"
  [[ -n "$pin" ]] || refuse "${ROOT}/latest is empty; refusing to prune"
  [[ -d "${ROOT}/${pin}" ]] || refuse "latest names ${pin}, which is not under ${ROOT}; refusing to prune"
  note_ref "$pin" "latest"
  return 0
}

collect_cluster() {
  local cluster pin
  cluster="$(hps_get_config active_cluster 2>/dev/null)" || cluster=""
  [[ -n "$cluster" ]] || return 0
  pin="$(cluster_registry "$cluster" get nixos_default_pin 2>/dev/null)" || pin=""
  note_ref "$pin" "cluster nixos_default_pin"
  return 0
}

collect_hosts() {
  local mac pin
  while IFS= read -r mac; do
    [[ -n "$mac" ]] || continue
    pin="$(host_registry "$mac" get system_pin 2>/dev/null)" || pin=""
    note_ref "$pin" "system_pin of $mac"
    pin="$(host_registry "$mac" get system_pin_previous 2>/dev/null)" || pin=""
    note_ref "$pin" "system_pin_previous of $mac"
  done < <(list_cluster_hosts 2>/dev/null || true)
  return 0
}

# Pin directories, newest first, one name per line.
list_pins_newest_first() {
  find "$ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' | sort -rn | cut -d' ' -f2-
  return 0
}

keep_newest() {
  local pin kept=0
  (( KEEP > 0 )) || return 0
  while IFS= read -r pin; do
    [[ -n "${REFERENCED[$pin]:-}" ]] && continue
    [[ "$pin" =~ ^[a-z0-9][a-z0-9.-]+$ ]] || continue
    [[ "$pin" != firmware ]] || continue
    (( kept < KEEP )) || break
    note_ref "$pin" "among the ${KEEP} newest"
    kept=$((kept + 1))
  done < <(list_pins_newest_first)
  return 0
}

remove_pin() {
  local pin="$1"
  hps_log info "nixos-prune-pins: removing ${ROOT}/${pin}"
  rm -rf -- "${ROOT:?}/${pin:?}"
  echo "removed   ${pin}"
  return 0
}

report_and_act() {
  local pin removed=0 kept=0
  while IFS= read -r pin; do
    [[ -n "$pin" ]] || continue
    if ! [[ "$pin" =~ ^[a-z0-9][a-z0-9.-]+$ ]]; then
      echo "skipped   ${pin} (not a pin name)"
      continue
    fi
    if [[ "$pin" == firmware ]]; then
      echo "skipped   ${pin} (shared firmware layers; hps-pins prune removes the unused ones)"
      continue
    fi
    if [[ -n "${REFERENCED[$pin]:-}" ]]; then
      echo "keep      ${pin} (${WHY[$pin]})"
      kept=$((kept + 1))
      continue
    fi
    if [[ "$MODE" == apply ]]; then
      remove_pin "$pin"
    else
      echo "would remove ${pin}"
    fi
    removed=$((removed + 1))
  done < <(list_pins_newest_first)
  echo "${MODE}: ${removed} to remove or removed, ${kept} kept"
  return 0
}

main() {
  parse_args "$@"
  load_hps
  ROOT="$(hps_get_config resources)/nixos"
  [[ -d "$ROOT" ]] || refuse "pin directory ${ROOT} does not exist"
  collect_latest
  collect_cluster
  collect_hosts
  keep_newest
  report_and_act
  return 0
}

main "$@"
