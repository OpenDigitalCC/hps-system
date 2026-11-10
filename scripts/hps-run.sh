#!/usr/bin/env bash
#===============================================================================
# hps-run.sh [--input] [--json] <mac-or-hostname> <script> [args...]
# ------------------------------------------------
# Run an allowlisted ctrl-exec script on a node, addressed the HPS way: by MAC
# (any format: aa:bb:.., aa-bb-.., aabb.., case-insensitive) or by registry
# HOSTNAME. Operations rely on ctrl-exec (owner ruling 2026-11-09); this is the
# short form of
#     ced run <agent> <script> -- args...
#
# The agent name is the host's FQDN, <registry HOSTNAME>.<network_dns_domain>
# (docs/NAMING.md; host_fqdn): the name hps-node-init gives the node's kernel
# hostname and hps-pair registers the agent under (request-pairing --name).
# There is one form and no fallback to another: the registered names are read
# from the dispatcher (list-agents) and the FQDN must be one of them. A re-pair
# replaces the old registration (approve --replace); names starting "stale-"
# are never matched.
#
# Output and exit status are the dispatcher's, passed through unchanged (see
# ce_run in lib/functions.d/ctrl-exec-functions.sh). The resolution line goes to
# stderr.
#
# --input: the script's stdin (an `input = raw` script, e.g. dataset-unlock) is
# sent as confidential run input. `ced run` has no input option on 0.14.4; the
# input goes through the dispatcher's API client instead:
#     $CTRL_EXEC_CLI run <agent> --script <script> --input - [--json] -- args...
# (default ctrl-exec-cli; it sends all of stdin as the one field "input" of
# POST /run, and an `input = raw` script reads exactly that on its stdin). It
# talks to the API named by CTRL_EXEC_API_SOCKET / CTRL_EXEC_API_URL. With
# --json the client's JSON result (per-host exit, stdout, stderr) is printed
# as is and its exit status is 0 unless the API call itself failed; without
# it the client prints text and exits 1 if the script failed. The input never
# appears in an argument or in this script's output.
#
# --json without --input: the same API client call without `--input -`
#     $CTRL_EXEC_CLI run <agent> --script <script> --json -- args...
# (stdin is /dev/null). Use it when the script's own exit status, stdout and
# stderr are needed: `ced run` and the client's text mode exit 1 whenever the
# script failed, whatever its real status was; the JSON reply carries it
# (results[0].exit) and hps-run.sh exits 0 unless the API call itself failed.
#
# Environment: HPS_BASE (default /srv); HPS_SYSTEM_PATH overrides
# $HPS_BASE/hps-system; CTRL_EXEC_DISPATCHER names the dispatcher CLI;
# CTRL_EXEC_CLI the API client used by --input (default: ctrl-exec-cli on PATH,
# else where the ctrl-exec-api-plugins .deb installs it); CTRL_EXEC_API_SOCKET
# the API's unix socket (default /run/ctrl-exec-api/api.sock, the IPS value;
# not set when CTRL_EXEC_API_URL is).
#
# Exit: dispatcher's status; 2 usage; 3 MAC or hostname not in the registry;
# 4 no registered agent under the host's FQDN; 1 function library missing or
# list-agents failed.
#===============================================================================
set -euo pipefail

usage() {
  echo "usage: hps-run.sh [--input] [--json] <mac-or-hostname> <script> [args...]" >&2
}

INPUT=0
JSON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --input) INPUT=1; shift ;;
    --json) JSON=1; shift ;;
    *) break ;;
  esac
done
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
  mac=$(get_host_mac_by_keyvalue HOSTNAME "$target" 2> /dev/null) || mac=$(get_host_mac_by_keyvalue HOSTNAME "${target%%.*}") || return 1
  mac="${mac%%$'\n'*}"
  [[ -n "$mac" ]] || return 1
  printf '%s\n' "$mac"
}

# agent_name <mac>: the host's FQDN (host_fqdn), else hps-<mac>.<domain> for a
# host that has no HOSTNAME yet (the name hps-node-init gives such a node).
agent_name() {
  local mac="$1"
  local name
  if name=$(host_fqdn "$mac" 2> /dev/null); then
    printf '%s\n' "$name"
    return 0
  fi
  fqdn_join "hps-${mac//:/}" "$(cluster_dns_domain)"
}

# registered_agents: first column of `list-agents` (the HOSTNAME column).
registered_agents() {
  "$CTRL_EXEC_DISPATCHER" list-agents | awk 'NR > 2 && $1 != "" && $1 !~ /^stale-/ { print $1 }'
}

MAC=$(resolve_mac "$TARGET") || {
  echo "hps-run: no host in the registry matches: $TARGET" >&2
  exit 3
}
AGENT=$(agent_name "$MAC") || {
  echo "hps-run: no usable FQDN for $TARGET (see the message above)" >&2
  exit 1
}
REGISTERED=$(registered_agents) || {
  echo "hps-run: cannot list the dispatcher's agents ($CTRL_EXEC_DISPATCHER list-agents failed)" >&2
  exit 1
}
if ! grep -qxF -- "$AGENT" <<< "$REGISTERED"; then
  echo "hps-run: no registered agent for ${TARGET}; expected the FQDN $AGENT" >&2
  exit 4
fi
echo "hps-run: ${TARGET} -> agent ${AGENT}, script ${SCRIPT}" >&2

# ce_run_input <agent> <script> [args...]: the script's stdin goes to ctrl-exec-cli.
ce_run_input() {
  local agent="$1" script="$2"
  shift 2
  local cli="${CTRL_EXEC_CLI:-}"
  if [[ -z "$cli" ]]; then
    if command -v ctrl-exec-cli > /dev/null 2>&1; then
      cli=ctrl-exec-cli
    else
      cli=/usr/share/ctrl-exec/plugins/ce-api-plugins/ctrl-exec-cli/ctrl-exec-cli
    fi
  fi
  # ctrl-exec-cli selects the transport by its own global options, not by
  # environment: --socket PATH (unix socket, api_socket) or --url. Without
  # --socket it talks TCP to 127.0.0.1 and the IPS auth hook denies it.
  local -a transport=()
  if [[ -n "${CTRL_EXEC_API_URL:-}" ]]; then
    transport=(--url "$CTRL_EXEC_API_URL")
  else
    transport=(--socket "${CTRL_EXEC_API_SOCKET:-/run/ctrl-exec-api/api.sock}")
  fi
  local cmd=("$cli" "${transport[@]}" run "$agent" --script "$script")
  if [[ $INPUT -eq 1 ]]; then
    cmd+=(--input -)
  fi
  if [[ $JSON -eq 1 ]]; then
    cmd+=(--json)
  fi
  if (( $# > 0 )); then
    cmd+=(-- "$@")
  fi
  if [[ $INPUT -eq 1 ]]; then
    "${cmd[@]}"
  else
    "${cmd[@]}" < /dev/null
  fi
}

rc=0
if [[ $INPUT -eq 1 || $JSON -eq 1 ]]; then
  ce_run_input "$AGENT" "$SCRIPT" "$@" || rc=$?
else
  ce_run "$AGENT" "$SCRIPT" "$@" || rc=$?
fi
exit "$rc"
