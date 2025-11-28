#!/bin/bash
#===============================================================================
# functions.sh - HPS Core Function Library Loader
# ------------------------------------------------
# Locates and loads hps.conf (or system registry), then sources all function 
# libraries. Can be sourced from inside container (/srv/hps-system/...) or outside.
#===============================================================================

# Guard: prevent multiple sourcing
[[ -n "${_HPS_FUNCTIONS_LOADED:-}" ]] && return 0
_HPS_FUNCTIONS_LOADED=1

#------------------------------------------------------------------------------
# Locate and load hps.conf (or system registry)
#------------------------------------------------------------------------------

# Candidate locations in priority order
HPS_CONFIG_LOCATIONS=(
  "${HPS_CONFIG:-}"                   # Explicit override via environment
  "/srv/hps-config/system.db"         # System registry (new format)
  "$PWD/hps-config/hps.conf"          # Relative to current directory
  "$PWD/../hps-config/hps.conf"       # One level up (dev setups)
  "/srv/hps-config/hps.conf"          # Legacy config file
  "/srv/hps-system/hps.conf"          # Legacy inside-container default
)

# Find first existing config file or registry
find_hps_config() {
  local candidate
  for candidate in "${HPS_CONFIG_LOCATIONS[@]}"; do
    if [[ -n "$candidate" ]] && [[ -e "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# Locate config file or registry
if ! HPS_CONFIG="$(find_hps_config)"; then
  echo "[HPS] ERROR: Could not locate hps.conf or system.db in any expected location:" >&2
  for loc in "${HPS_CONFIG_LOCATIONS[@]}"; do
    [[ -n "$loc" ]] && echo "  - $loc" >&2
  done
  return 1
fi

# Source hps.conf for system paths (HPS_LOG_DIR, HPS_PACKAGES_DIR, etc)
if [[ -f "${HPS_CONFIG_BASE}/hps.conf" ]]; then
  source "${HPS_CONFIG_BASE}/hps.conf"
elif [[ -f /srv/hps-config/hps.conf ]]; then
  source /srv/hps-config/hps.conf
fi


# Load configuration based on type
if [[ -d "$HPS_CONFIG" ]]; then
  # System registry - export variables from JSON
  if [[ -f "${HPS_CONFIG}/../lib/functions.d/hps-registry.sh" ]]; then
    # Need basic jq functionality to read registry
    if command -v jq >/dev/null 2>&1; then
      # Export each system registry key as environment variable
      for json_file in "${HPS_CONFIG}"/*.json; do
        [[ -f "$json_file" ]] || continue
        local key=$(basename "$json_file" .json)
        local value=$(jq -r . "$json_file" 2>/dev/null)
        [[ -n "$value" ]] && export "${key}=${value}"
      done
    else
      echo "[HPS] WARNING: jq not found, cannot read system registry" >&2
    fi
  fi
elif [[ -f "$HPS_CONFIG" ]]; then
  # Legacy hps.conf file
  if ! source "$HPS_CONFIG"; then
    echo "[HPS] ERROR: Failed to source config file: $HPS_CONFIG" >&2
    return 1
  fi
else
  echo "[HPS] ERROR: Config location exists but is neither file nor directory: $HPS_CONFIG" >&2
  return 1
fi

export HPS_CONFIG

# Set defaults if not already set
export HPS_SYSTEM_BASE="${HPS_SYSTEM_BASE:-/srv/hps-system}"
export HPS_CONFIG_BASE="${HPS_CONFIG_BASE:-/srv/hps-config}"
export HPS_CLUSTER_CONFIG_BASE_DIR="${HPS_CLUSTER_CONFIG_BASE_DIR:-${HPS_CONFIG_BASE}/clusters}"
export HPS_CLUSTERS="${HPS_CLUSTERS:-${HPS_CLUSTER_CONFIG_BASE_DIR}}"

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
  # Source registry functions first as other functions depend on it
  if [[ -f "${FUNCDIR}/hps-registry.sh" ]]; then
    if declare -f hps_source_with_debug >/dev/null 2>&1; then
      hps_source_with_debug "${FUNCDIR}/hps-registry.sh" "continue"
    else
      source "${FUNCDIR}/hps-registry.sh" || {
        echo "[HPS] ERROR: Failed to source registry functions" >&2
        return 1
      }
    fi
  fi
  
  # Source remaining function libraries
  for func_file in "$FUNCDIR"/*.sh; do
    [[ -e "$func_file" ]] || continue  # Skip if no matches
    [[ "$func_file" == *"hps-registry.sh" ]] && continue  # Already loaded
    
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
  if [[ -d "${HPS_CLUSTER_CONFIG_BASE_DIR}" ]]; then
    export_dynamic_paths >/dev/null 2>&1 || true
  fi
fi

# Load active cluster configuration variables into environment
if declare -f load_cluster_config >/dev/null 2>&1; then
  load_cluster_config >/dev/null 2>&1 || {
    echo "[HPS] WARNING: Failed to load cluster configuration" >&2
  }
elif declare -f get_active_cluster_file >/dev/null 2>&1; then
  # Legacy: Try to eval cluster config (for backward compatibility)
  # This will work with the updated get_active_cluster_file that outputs bash format
  if cluster_config_data="$(get_active_cluster_file 2>/dev/null)"; then
    if [[ -n "$cluster_config_data" ]]; then
      if declare -f hps_safe_eval >/dev/null 2>&1; then
        hps_safe_eval "$cluster_config_data" "cluster configuration" || {
          echo "[HPS] WARNING: Failed to eval cluster configuration" >&2
        }
      else
        # Fallback eval (less safe)
        eval "$cluster_config_data" 2>/dev/null || {
          echo "[HPS] WARNING: Failed to eval cluster configuration" >&2
        }
      fi
    fi
  fi
fi

# Success
return 0
