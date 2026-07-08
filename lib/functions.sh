#!/bin/bash
#===============================================================================
# HPS Functions - Main Library Loader (Tier 2)
#===============================================================================
# This file loads the base HPS configuration and sources all function libraries.
#
# Prerequisites:
#   - hps-system.sh must be loaded first (creates hps.conf)
#   - hps.conf must exist with 4 base paths
#
# Bootstrap process:
#   1. Locate and load hps.conf
#   2. Set LIB_DIR from loaded config
#   3. Source core function libraries
#   4. Source all function libraries from functions.d/
#
# Usage:
#   source /srv/hps-system/lib/functions.sh
#   # Now all HPS functions available
#===============================================================================

# Disable patsub_replacement to ensure consistent string substitution
shopt -u patsub_replacement 2>/dev/null || true

#===============================================================================
# locate_hps_conf
# ---------------
# Locate hps.conf file.
#
# Search order:
#   1. $HPS_CONF environment variable
#   2. ${HPS_BASE}/hps.conf (if HPS_BASE set)
#   3. /srv/hps.conf (default location)
#   4. $PWD/hps.conf (current directory)
#
# Returns:
#   0 on success (path printed to stdout)
#   1 if not found
#
# Example usage:
#   conf=$(locate_hps_conf) || exit 1
#
#===============================================================================
locate_hps_conf() {
  local candidates=(
    "${HPS_CONF:-}"
    "${HPS_BASE:-}/hps.conf"
    "/srv/hps.conf"
    "$PWD/hps.conf"
  )
  
  for conf in "${candidates[@]}"; do
    if [[ -n "$conf" ]] && [[ -f "$conf" ]]; then
      echo "$conf"
      return 0
    fi
  done
  
  return 1
}

#===============================================================================
# load_hps_conf
# -------------
# Load hps.conf configuration file.
#
# Behaviour:
#   - Locates hps.conf using locate_hps_conf
#   - Sources the file to load configuration variables
#   - Sets LIB_DIR based on loaded HPS_SYSTEM_BASE
#   - Fails hard if hps.conf not found (should be created by hps-system.sh)
#
# Expected variables in hps.conf:
#   HPS_SYSTEM_BASE   - Base path for HPS system files
#   HPS_CONFIG_BASE   - Base path for HPS configuration
#   HPS_RESOURCES     - Base path for HPS resources
#   HPS_LOG           - Base path for HPS logs
#
# Sets:
#   LIB_DIR           - Derived as ${HPS_SYSTEM_BASE}/lib
#
# Returns:
#   0 on success
#   1 if hps.conf not found or cannot be sourced
#
# Example usage:
#   load_hps_conf || return 1
#
#===============================================================================
load_hps_conf() {
  local conf
  conf=$(locate_hps_conf) || {
    echo "[HPS] ERROR: Could not locate hps.conf" >&2
    echo "[HPS] Expected hps-system.sh to create it during initialization" >&2
    echo "[HPS] Checked: \$HPS_CONF, \${HPS_BASE}/hps.conf, /srv/hps.conf, \$PWD/hps.conf" >&2
    return 1
  }
  
  # Source the configuration file
  source "$conf" || {
    echo "[HPS] ERROR: Failed to source hps.conf: $conf" >&2
    return 1
  }
  
  # Set LIB_DIR based on loaded config
  LIB_DIR="${HPS_SYSTEM_BASE}/lib"
  
  if [[ ! -d "$LIB_DIR" ]]; then
    echo "[HPS] ERROR: Library directory not found: $LIB_DIR" >&2
    return 1
  fi
  
  return 0
}

#===============================================================================
# Bootstrap: Load Configuration
#===============================================================================
load_hps_conf || return 1

#===============================================================================
# Source Core Function Library
#===============================================================================
# Load core functions first - these are required by other libraries
if [[ -f "${LIB_DIR}/functions-core-lib.sh" ]]; then
  source "${LIB_DIR}/functions-core-lib.sh" || {
    echo "[HPS] ERROR: Failed to source core function library" >&2
    return 1
  }
else
  echo "[HPS] ERROR: Core function library not found: ${LIB_DIR}/functions-core-lib.sh" >&2
  return 1
fi

#===============================================================================
# Source Registry Functions
#===============================================================================
# Load registry functions - other libraries depend on it
if [[ -f "${LIB_DIR}/hps-registry.sh" ]]; then
  source "${LIB_DIR}/hps-registry.sh" || {
    echo "[HPS] ERROR: Failed to source registry functions" >&2
    return 1
  }
else
  echo "[HPS] ERROR: Registry function library not found: ${LIB_DIR}/hps-registry.sh" >&2
  return 1
fi

#===============================================================================
# Source Function Libraries
#===============================================================================
# Source all function libraries from LIB_DIR/functions.d/

if [[ ! -d "${LIB_DIR}/functions.d" ]]; then
  echo "[HPS] ERROR: Functions directory not found: ${LIB_DIR}/functions.d" >&2
  return 1
fi

# Load all function libraries
for func_lib in "${LIB_DIR}/functions.d"/*.sh; do
  [[ -f "$func_lib" ]] || continue
  
  source "$func_lib" || {
    echo "[HPS] ERROR: Failed to source function library: $func_lib" >&2
    return 1
  }
done

#===============================================================================
# Initialization Complete
#===============================================================================
# At this point:
# - hps.conf loaded with 4 base paths
# - All core functions available (hps_log, hps_get_config)
# - Registry functions available (system_registry, host_registry, etc.)
# - All domain-specific functions loaded from functions.d/
#===============================================================================
