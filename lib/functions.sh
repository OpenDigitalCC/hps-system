#!/bin/bash
# functions.sh - Common functions for HPS

# Candidate locations in order of priority (customize as needed)
HPS_CONFIG_LOCATIONS=(
  "${HPS_CONFIG:-}"                   # Explicit override
  "$PWD/hps-config/hps.conf"          # Relative to current dir
  "$PWD/../hps-config/hps.conf"       # One up, in dev setups
  "/srv/hps-config/hps.conf"          # Inside-container default
)


find_hps_config() {
  local found=""
  for candidate in "${HPS_CONFIG_LOCATIONS[@]}"; do
    [[ -n "$candidate" && -f "$candidate" ]] && found="$candidate"
  done
  if [[ -n "$found" ]]; then
    echo "$found"
    return 0
  else
    return 1
  fi
}

# Try to find config file
if HPS_CONFIG="$(find_hps_config)"; then
  export HPS_CONFIG
else
  echo "[✗] Could not locate hps.conf in any expected location" >&2
  return 1
fi


# Load config
source "$HPS_CONFIG"
#echo "[debug $(realpath "${BASH_SOURCE[0]}")] Loaded hps.conf from: $HPS_CONFIG"

# Extract the directory part
HPS_CONFIG_DIR="$(dirname "$HPS_CONFIG")"

# Adjust all *_DIR paths based on where HPS_CONFIG was actually found
while IFS='=' read -r k v; do
  [[ "$k" =~ ^#.*$ || -z "$k" || ! "$k" =~ _DIR$ ]] && continue
  varname="${k//[[:space:]]/}"  # Strip whitespace
  raw="${v%\"}"; raw="${raw#\"}"  # Strip quotes
  relpath=$(realpath -m "$HPS_CONFIG_DIR/$raw")
  export "$varname=$relpath"
done < "$HPS_CONFIG"

# Re-export for debug
#for var in $(grep -E '^export [A-Z0-9_]+_DIR=' "$HPS_CONFIG" | awk '{print $2}' | cut -d= -f1); do
#  echo "[debug $(realpath "${BASH_SOURCE[0]}")] $var = ${!var}"
#done

# Validate that all *_DIR variables point to existing directories
#or var in $(grep -E '^export [A-Z0-9_]+_DIR=' "$HPS_CONFIG" | awk '{print $2}' | cut -d= -f1); do
# val="${!var:-}"
# if [[ -z "$val" ]]; then
#   echo "[x] $var is not set in environment after sourcing $HPS_CONFIG" >&2
#   return 1
# elif [[ ! -d "$val" ]]; then
#   echo "[x] $var points to a non-existent directory: $val" >&2
#   return 1
# else
#echo "[OK] $var: $val"
# fi
#one


# Guard: avoid sourcing hps.conf again if already sourced and initialized
if [[ -z "${__HPS_CONF_LOADED:-}" ]]; then
  if [[ -n "${HPS_CONF_FILE:-}" && -f "$HPS_CONF_FILE" ]]; then
    source "$HPS_CONF_FILE"
  elif [[ -f "/srv/hps-config/hps.conf" ]]; then
    HPS_CONF_FILE="/srv/hps-config/hps.conf"
    source "$HPS_CONF_FILE"
  else
    echo "[x] Could not locate hps.conf" >&2
    return 1
  fi
  export __HPS_CONF_LOADED=1
fi


#echo "[debug ${BASH_SOURCE[0]}] Loaded hps.conf from: $HPS_CONF_FILE" >&2
#echo "[debug ${BASH_SOURCE[0]}] HPS_DISTROS_DIR = $HPS_DISTROS_DIR" >&2

# Get the directory where this file resides
export LIB_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"


# Optional: main guard to avoid multiple sourcing
[[ -n "${_HPS_FUNCTIONS_LOADED:-}" ]] && return
_HPS_FUNCTIONS_LOADED=1

# Directory for function fragments
FUNCDIR="${LIB_DIR}/functions.d"

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



# Load up cluster variables
eval $(get_active_cluster_file)



