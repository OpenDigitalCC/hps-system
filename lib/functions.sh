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

# Optional timing - set HPS_PROFILE=1 to enable
[[ -n "${HPS_PROFILE:-}" ]] && { _HPS_START=$SECONDS; echo "[PROFILE] Starting functions.sh load"; }

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

[[ -n "${HPS_PROFILE:-}" ]] && echo "[PROFILE] Finding config: $((SECONDS - _HPS_START))s"

# Locate config file or registry
if ! HPS_CONFIG="$(find_hps_config)"; then
  echo "[HPS] ERROR: Could not locate hps.conf or system.db in any expected location:" >&2
  for loc in "${HPS_CONFIG_LOCATIONS[@]}"; do
    [[ -n "$loc" ]] && echo "  - $loc" >&2
  done
  return 1
fi

[[ -n "${HPS_PROFILE:-}" ]] && echo "[PROFILE] Config located: $((SECONDS - _HPS_START))s"

# Set HPS_CONFIG_BASE if not already set (derive from HPS_CONFIG)
if [[ -z "${HPS_CONFIG_BASE:-}" ]]; then
  if [[ "$HPS_CONFIG" == *"/system.db" ]]; then
    HPS_CONFIG_BASE="$(dirname "$(dirname "$HPS_CONFIG")")"  # Go up 2 levels from system.db
  else
    HPS_CONFIG_BASE="$(dirname "$HPS_CONFIG")"
  fi
fi

# Source hps.conf for system paths (HPS_LOG_DIR, HPS_PACKAGES_DIR, etc)
# This should be in the same location as HPS_CONFIG or system.db
if [[ -f "${HPS_CONFIG_BASE}/hps.conf" ]]; then
  source "${HPS_CONFIG_BASE}/hps.conf"
fi

# Load configuration based on type
if [[ -d "$HPS_CONFIG" ]]; then
  [[ -n "${HPS_PROFILE:-}" ]] && echo "[PROFILE] Loading registry from $HPS_CONFIG"
  
  # System registry - export variables from JSON
  if command -v jq >/dev/null 2>&1; then
    # Count files for profiling
    [[ -n "${HPS_PROFILE:-}" ]] && {
      local json_count=$(find "${HPS_CONFIG}" -name "*.json" -type f 2>/dev/null | wc -l)
      echo "[PROFILE] Found ${json_count} JSON files to process"
    }
    
    # Export each system registry key as environment variable
    for json_file in "${HPS_CONFIG}"/*.json; do
      [[ -f "$json_file" ]] || continue
      key=$(basename "$json_file" .json)
      value=$(jq -r . "$json_file" 2>/dev/null)
      [[ -n "$value" ]] && export "${key}=${value}"
    done
  else
    echo "[HPS] WARNING: jq not found, cannot read system registry" >&2
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

[[ -n "${HPS_PROFILE:-}" ]] && echo "[PROFILE] Registry/config loaded: $((SECONDS - _HPS_START))s"

# Set all defaults based on CONFIG location
export HPS_CONFIG
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

export FUNCDIR="${LIB_DIR}/functions.d"

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

[[ -n "${HPS_PROFILE:-}" ]] && echo "[PROFILE] Core functions loaded: $((SECONDS - _HPS_START))s"

#------------------------------------------------------------------------------
# Source function library fragments
#------------------------------------------------------------------------------

if [[ -d "$FUNCDIR" ]]; then
  [[ -n "${HPS_PROFILE:-}" ]] && echo "[PROFILE] Loading libraries from $FUNCDIR"
  
  # Check if we have debug function once
  has_debug_func=0
  declare -f hps_source_with_debug >/dev/null 2>&1 && has_debug_func=1
  
  # Source registry functions first as other functions depend on it
  if [[ -f "${FUNCDIR}/hps-registry.sh" ]]; then
    if [[ $has_debug_func -eq 1 ]]; then
      hps_source_with_debug "${FUNCDIR}/hps-registry.sh" "continue"
    else
      source "${FUNCDIR}/hps-registry.sh" || {
        echo "[HPS] ERROR: Failed to source registry functions" >&2
        return 1
      }
    fi
  fi
  
  [[ -n "${HPS_PROFILE:-}" ]] && echo "[PROFILE] Registry functions loaded: $((SECONDS - _HPS_START))s"
  
  # Count libraries for profiling
  [[ -n "${HPS_PROFILE:-}" ]] && {
    lib_count=$(find "${FUNCDIR}" -name "*.sh" -type f 2>/dev/null | wc -l)
    echo "[PROFILE] Found ${lib_count} library files to load"
  }
  
  # Source remaining function libraries
  for func_file in "$FUNCDIR"/*.sh; do
    [[ -e "$func_file" ]] || continue  # Skip if no matches
    [[ "$func_file" == *"hps-registry.sh" ]] && continue  # Already loaded
    
    [[ -n "${HPS_PROFILE:-}" ]] && {
      _lib_start=$SECONDS
      echo -n "[PROFILE]   Loading $(basename "$func_file")... "
    }
    
    # Source the file
    if [[ $has_debug_func -eq 1 ]]; then
      hps_source_with_debug "$func_file" "continue"
    else
      source "$func_file" || {
        echo "[HPS] ERROR: Failed to source: $func_file" >&2
        return 1
      }
    fi
    
    [[ -n "${HPS_PROFILE:-}" ]] && echo "$((SECONDS - _lib_start))s"
  done
else
  echo "[HPS] WARNING: Function directory not found: $FUNCDIR" >&2
fi

[[ -n "${HPS_PROFILE:-}" ]] && echo "[PROFILE] All libraries loaded: $((SECONDS - _HPS_START))s"

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

[[ -n "${HPS_PROFILE:-}" ]] && echo "[PROFILE] Total load time: $((SECONDS - _HPS_START))s"

# Success
return 0
