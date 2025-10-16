#!/bin/bash
#===============================================================================
# functions.sh - HPS Core Function Library Loader
# ------------------------------------------------
# Locates and loads hps.conf, then sources all function libraries.
# Can be sourced from inside container (/srv/hps-system/...) or outside.
#===============================================================================

# Guard: prevent multiple sourcing
[[ -n "${_HPS_FUNCTIONS_LOADED:-}" ]] && return 0
_HPS_FUNCTIONS_LOADED=1

#------------------------------------------------------------------------------
# Locate and load hps.conf
#------------------------------------------------------------------------------

# Candidate locations in priority order
HPS_CONFIG_LOCATIONS=(
  "${HPS_CONFIG:-}"                   # Explicit override via environment
  "$PWD/hps-config/hps.conf"          # Relative to current directory
  "$PWD/../hps-config/hps.conf"       # One level up (dev setups)
  "/srv/hps-config/hps.conf"          # Inside-container default
)

# Find first existing config file
find_hps_config() {
  local candidate
  for candidate in "${HPS_CONFIG_LOCATIONS[@]}"; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# Locate config file
if ! HPS_CONFIG="$(find_hps_config)"; then
  echo "[HPS] ERROR: Could not locate hps.conf in any expected location:" >&2
  for loc in "${HPS_CONFIG_LOCATIONS[@]}"; do
    [[ -n "$loc" ]] && echo "  - $loc" >&2
  done
  return 1
fi

# Load configuration
if ! source "$HPS_CONFIG"; then
  echo "[HPS] ERROR: Failed to source config file: $HPS_CONFIG" >&2
  return 1
fi

export HPS_CONFIG

#------------------------------------------------------------------------------
# Determine library directory
#------------------------------------------------------------------------------

# Get the directory where this file resides
export LIB_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

if [[ ! -d "$LIB_DIR" ]]; then
  echo "[HPS] ERROR: Library directory not found: $LIB_DIR" >&2
  return 1
fi

#------------------------------------------------------------------------------
# Source core functions first
#------------------------------------------------------------------------------

if [[ -f "${LIB_DIR}/functions-core-lib.sh" ]]; then
  if ! source "${LIB_DIR}/functions-core-lib.sh"; then
    echo "[HPS] ERROR: Failed to source core function library" >&2
    return 1
  fi
else
  echo "[HPS] ERROR: Core function library not found: ${LIB_DIR}/functions-core-lib.sh" >&2
  return 1
fi

#------------------------------------------------------------------------------
# Source function library fragments
#------------------------------------------------------------------------------

FUNCDIR="${LIB_DIR}/functions.d"

if [[ -d "$FUNCDIR" ]]; then
  for func_file in "$FUNCDIR"/*.sh; do
    [[ -e "$func_file" ]] || continue  # Skip if no matches
    
    # Use hps_source_with_debug if available, otherwise simple source
    if declare -f hps_source_with_debug >/dev/null 2>&1; then
      hps_source_with_debug "$func_file" "continue"
    else
      source "$func_file" || {
        echo "[HPS] ERROR: Failed to source: $func_file" >&2
        return 1
      }
    fi
  done
else
  echo "[HPS] WARNING: Function directory not found: $FUNCDIR" >&2
fi

#------------------------------------------------------------------------------
# Initialize dynamic paths and cluster configuration
#------------------------------------------------------------------------------

# Export dynamic cluster paths if function is available and cluster dir exists
if declare -f export_dynamic_paths >/dev/null 2>&1; then
  if [[ -d "${HPS_CLUSTER_CONFIG_BASE_DIR:-/srv/hps-config/clusters}" ]]; then
    export_dynamic_paths >/dev/null 2>&1 || true
  fi
fi

# Load active cluster configuration
if declare -f get_active_cluster_file >/dev/null 2>&1; then
  if declare -f hps_safe_eval >/dev/null 2>&1; then
    if ! hps_safe_eval "$(get_active_cluster_file)" "cluster configuration"; then
      echo "[HPS] ERROR: Failed to load cluster configuration" >&2
      return 1
    fi
  else
    # Fallback if hps_safe_eval not available yet
    eval "$(get_active_cluster_file)" || {
      echo "[HPS] ERROR: Failed to load cluster configuration" >&2
      return 1
    }
  fi
fi

hps_log info "[HPS] Function library initialisation complete" >&2
