#!/bin/bash
set -euo pipefail

HPS_CONFIG=/srv/hps-config/hps.conf
source $HPS_CONFIG

# Get the directory where this file resides
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

# Optional: main guard to avoid multiple sourcing
[[ -n "${_HPS_FUNCTIONS_LOADED:-}" ]] && return
_HPS_FUNCTIONS_LOADED=1

# Directory for function fragments
FUNCDIR="${SCRIPT_DIR}/functions.d"

__guard_source() {
    local src="${BASH_SOURCE[1]}"
    local _guard_var="_GUARD_$(basename "$src" | sed 's/[^a-zA-Z0-9_]/_/g')"
    [[ -n "${!_guard_var:-}" ]] && return 1
    declare "$_guard_var=1"
    return 0
}


## Load function fragments

if [[ -d "$FUNCDIR" ]]; then
  for f in "$FUNCDIR"/*.sh; do
    [[ -e "$f" ]] || continue  # Skip if no matches
    # Avoid double-sourcing: each file can guard itself, or rely on this
    source "$f"
  done
else
  echo "[WARN] Function directory not found: $FUNCDIR" >&2
fi


# Automatically export dynamic paths only if cluster base dir exists
if declare -f export_dynamic_paths >/dev/null; then
  if [[ -d "${HPS_CLUSTER_CONFIG_BASE_DIR:-/srv/hps-config/clusters}" ]]; then
    export_dynamic_paths >/dev/null 2>&1 || true
  fi
fi

