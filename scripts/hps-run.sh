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
# its FQDN (Net::Domain::hostfqdn). hps-pair (node-manager/nixos-26/boot) makes
# the node's hostname <registry HOSTNAME, fallback hps-<mac without delimiters>>
# followed by .<network_dns_domain>, and ce_approve_pair_request compares first
# labels with the registry. With ctrl-exec 0.14.3 hps-pair passes the agent
# --name <name>.<domain>, so the first candidate below is what registers; the
# others serve nodes paired by older images. A re-pair replaces the old
# registration (approve --replace); names starting "stale-" are never matched.
# The registered names are read from the dispatcher
# (list-agents) and the first of these that exists is used:
#     <name>.<network_dns_domain>   (only when the cluster has a domain)
#     <name>
#     <name>..                      (ctrl-exec 0.14.x, node without a domain)
#
# Output and exit status are the dispatcher's, passed through unchanged (see
# ce_run in lib/functions.d/ctrl-exec-functions.sh). The resolution line goes to
# stderr.
#
# Environment: HPS_BASE (default /srv); HPS_SYSTEM_PATH overrides
# $HPS_BASE/hps-system; CTRL_EXEC_DISPATCHER names the dispatcher CLI.
#
# Exit: dispatcher's status; 2 usage; 3 MAC or hostname not in the registry;
# 4 no registered agent under any candidate name; 1 function library missing or
# list-agents failed.
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

# base_name <mac>: the registry HOSTNAME (first label), else hps-<mac>.
base_name() {
  local mac="$1"
  local name
  name=$(host_registry "$mac" get HOSTNAME 2> /dev/null) || name=""
  name="${name%%.*}"
  if [[ -z "$name" ]]; then
    name="hps-${mac//:/}"
  fi
  printf '%s\n' "$name"
}

# cluster_domain: the cluster's network_dns_domain, empty when unset.
cluster_domain() {
  local cluster domain
  cluster=$(hps_get_config active_cluster 2> /dev/null) || cluster=""
  [[ -n "$cluster" ]] || return 0
  domain=$(cluster_registry "$cluster" get network_dns_domain 2> /dev/null) || domain=""
  if [[ "$domain" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
    printf '%s\n' "$domain"
  fi
}

# registered_agents: first column of `list-agents` (the HOSTNAME column).
registered_agents() {
  "$CTRL_EXEC_DISPATCHER" list-agents | awk 'NR > 2 && $1 != "" && $1 !~ /^stale-/ { print $1 }'
}

# candidates <base> <domain>: names to try, in order: <base>.<domain> (when the
# cluster has a domain; what a node with a DNS domain registers as), <base>,
# <base>.. (ctrl-exec 0.14.x registers a node without a domain that way).
candidates() {
  local base="$1"
  local domain="$2"
  if [[ -n "$domain" ]]; then
    printf '%s\n' "${base}.${domain}"
  fi
  printf '%s\n' "$base" "${base}.."
}

# pick_agent <candidates, one per line> <registered, one per line>: the first
# candidate that is registered.
pick_agent() {
  local cand
  while IFS= read -r cand; do
    [[ "$cand" == stale-* ]] && continue
    if grep -qxF -- "$cand" <<< "$2"; then
      printf '%s\n' "$cand"
      return 0
    fi
  done <<< "$1"
  return 1
}

MAC=$(resolve_mac "$TARGET") || {
  echo "hps-run: no host in the registry matches: $TARGET" >&2
  exit 3
}
BASE=$(base_name "$MAC")
DOMAIN=$(cluster_domain)
CANDS=$(candidates "$BASE" "$DOMAIN")
REGISTERED=$(registered_agents) || {
  echo "hps-run: cannot list the dispatcher's agents ($CTRL_EXEC_DISPATCHER list-agents failed)" >&2
  exit 1
}
AGENT=$(pick_agent "$CANDS" "$REGISTERED") || {
  echo "hps-run: no registered agent for ${TARGET}; tried: $(tr '\n' ' ' <<< "$CANDS")" >&2
  exit 4
}
echo "hps-run: ${TARGET} -> agent ${AGENT}, script ${SCRIPT}" >&2

rc=0
ce_run "$AGENT" "$SCRIPT" "$@" || rc=$?
exit "$rc"
