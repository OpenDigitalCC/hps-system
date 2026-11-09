#!/usr/bin/env bash
#===============================================================================
# hps-run.sh <mac-or-hostname> <script> [args...]
# ------------------------------------------------
# Run an allowlisted ctrl-exec script on a node, addressed the HPS way: by MAC
# (any format: aa:bb:.., aa-bb-.., aabb.., case-insensitive) or by registry
# HOSTNAME. Operations rely on ctrl-exec (owner ruling 2026-11-09); this is the
# short form of
#     ced run <agent> <script> -- args...
#
# The agent name is what the node's ctrl-exec agent registered under at pairing:
# its hostname. hps-pair (node-manager/nixos-26/boot) makes that the registry
# HOSTNAME (fallback hps-<mac without delimiters>) before it requests pairing,
# and ce_approve_pair_request refuses a request whose hostname differs from the
# registry. So the name is the registry HOSTNAME, or the same fallback when the
# registry has none.
#
# Output and exit status are the dispatcher's, passed through unchanged (see
# ce_run in lib/functions.d/ctrl-exec-functions.sh). The resolution line goes to
# stderr.
#
# Environment: HPS_BASE (default /srv); HPS_SYSTEM_PATH overrides
# $HPS_BASE/hps-system; CTRL_EXEC_DISPATCHER names the dispatcher CLI.
#
# Exit: dispatcher's status; 2 usage; 3 MAC or hostname not in the registry;
# 1 function library missing.
#===============================================================================
set -euo pipefail

usage() {
  echo "usage: hps-run.sh <mac-or-hostname> <script> [args...]" >&2
}

if [[ $# -lt 2 || -z "$1" || -z "$2" ]]; then
  usage
  exit 2
fi

TARGET="$1"
SCRIPT="$2"
shift 2

if [[ ! "$SCRIPT" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "hps-run: script name must match [A-Za-z0-9_-]+: $SCRIPT" >&2
  exit 2
fi

HPS_BASE="${HPS_BASE:-/srv}"
SYSTEM_PATH="${HPS_SYSTEM_PATH:-${HPS_BASE}/hps-system}"
export HPS_BASE

if [[ ! -f "${SYSTEM_PATH}/lib/functions.sh" ]]; then
  echo "hps-run: function library not found: ${SYSTEM_PATH}/lib/functions.sh" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${SYSTEM_PATH}/lib/functions.sh"

# target_is_mac <string>: 12 hex digits once the delimiters are removed.
target_is_mac() {
  local stripped="${1//[:.-]/}"
  [[ "$stripped" =~ ^[0-9a-fA-F]{12}$ ]]
}

# resolve_mac <target>: print the 12-hex MAC of a registered host.
resolve_mac() {
  local target="$1"
  local mac
  if target_is_mac "$target"; then
    mac=$(normalise_mac "$target") || return 1
    host_registry "$mac" exists || return 1
    printf '%s\n' "$mac"
    return 0
  fi
  mac=$(get_host_mac_by_keyvalue HOSTNAME "$target") || return 1
  mac="${mac%%$'\n'*}"
  [[ -n "$mac" ]] || return 1
  printf '%s\n' "$mac"
}

# agent_name <mac>: the registry HOSTNAME, else hps-<mac>.
agent_name() {
  local mac="$1"
  local name
  name=$(host_registry "$mac" get HOSTNAME 2> /dev/null) || name=""
  if [[ -z "$name" ]]; then
    name="hps-${mac//:/}"
  fi
  printf '%s\n' "$name"
}

MAC=$(resolve_mac "$TARGET") || {
  echo "hps-run: no host in the registry matches: $TARGET" >&2
  exit 3
}
AGENT=$(agent_name "$MAC")
echo "hps-run: ${TARGET} -> agent ${AGENT}, script ${SCRIPT}" >&2

rc=0
ce_run "$AGENT" "$SCRIPT" "$@" || rc=$?
exit "$rc"
