#!/bin/bash
#===============================================================================
# HPS System - Bootstrap Library (Tier 1)
#===============================================================================
# This is the ONLY hard-loaded library before functions.sh.
# Purpose: Verify dependencies and create infrastructure needed by functions.sh
#
# Usage:
#   source hps-system.sh
#   hps_system_initialize || exit 1
#   # Now safe to load functions.sh
#
# Environment Variables:
#   HPS_BASE - Base installation path (default: /srv)
#
# Creates:
#   ${HPS_BASE}/hps.conf          - Configuration with 4 base paths
#   ${HPS_BASE}/hps-system/       - System files
#   ${HPS_BASE}/hps-config/       - Configuration
#   ${HPS_BASE}/hps-resources/    - Resources
#   ${HPS_BASE}/hps-log/          - Logs
#===============================================================================

# Disable patsub_replacement for consistent string substitution
shopt -u patsub_replacement 2>/dev/null || true

#===============================================================================
# Temporary bootstrap logger (replaced when functions-core-lib.sh loads)
#===============================================================================
hps_log() {
  local level="${1^^}"
  shift
  local ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${ts}] [${level}] [hps-bootstrap] $*" >&2
}

#===============================================================================
# hps_verify_dependencies
# -----------------------
# Verify required system binaries exist and export their paths.
#
# Behaviour:
#   - Checks each required binary using 'command -v'
#   - Exports BIN_* variables with full paths
#   - Logs missing dependencies
#   - Returns failure if any required binary missing
#
# Returns:
#   0 if all dependencies found
#   1 if any required dependency missing
#
# Example usage:
#   hps_verify_dependencies || exit 1
#   # Now use: $BIN_JQ, $BIN_CURL, etc.
#
#===============================================================================
hps_verify_dependencies() {
  local missing=0
  local deps_checked=0
  
  hps_log info "Verifying system dependencies"
  
  # Helper function to check and export binary
  check_binary() {
    local name="$1"
    local var_name="BIN_${name^^}"
    local path
    
    if path=$(command -v "$name" 2>/dev/null); then
      export "${var_name}=${path}"
      hps_log info "  ✓ ${name}: ${path}"
      ((deps_checked++))
      return 0
    else
      hps_log error "  ✗ ${name}: NOT FOUND"
      ((missing++))
      return 1
    fi
  }
  
  # Core system binaries (required for all operations)
  check_binary "bash"
  check_binary "jq"
  check_binary "cat"
  check_binary "mkdir"
  check_binary "tr"
  check_binary "grep"
  check_binary "sed"
  check_binary "awk"
  check_binary "find"
  check_binary "date"
  check_binary "hostname"
  check_binary "curl"
  check_binary "wget"
  check_binary "ip"
  
  # Service management
  check_binary "supervisord"
  check_binary "supervisorctl"
  
  # Additional binaries to be added during refactoring:
  # - nginx, dnsmasq, rsyslogd, logger
  # - ipxe (network boot)
  # - zfs, targetcli (storage)
  # - osvc, sozu (optional)
  
  if [[ $missing -eq 0 ]]; then
    hps_log info "✓ All dependencies verified ($deps_checked binaries)"
    return 0
  else
    hps_log error "✗ Missing $missing required dependencies"
    return 1
  fi
}

#===============================================================================
# hps_ensure_base_path
# --------------------
# Ensure HPS_BASE path exists and is writable.
#
# Behaviour:
#   - Uses HPS_BASE environment variable (default: /srv)
#   - Creates directory if it doesn't exist
#   - Verifies write permissions
#   - Exports HPS_BASE for use by other functions
#
# Returns:
#   0 on success
#   1 if directory cannot be created or is not writable
#
# Example usage:
#   hps_ensure_base_path || exit 1
#
#===============================================================================
hps_ensure_base_path() {
  # Use environment variable or default
  export HPS_BASE="${HPS_BASE:-/srv}"
  
  hps_log info "Ensuring base path: ${HPS_BASE}"
  
  # Create if doesn't exist
  if [[ ! -d "$HPS_BASE" ]]; then
    if mkdir -p "$HPS_BASE" 2>/dev/null; then
      hps_log info "  ✓ Created base directory: ${HPS_BASE}"
    else
      hps_log error "  ✗ Cannot create base directory: ${HPS_BASE}"
      return 1
    fi
  fi
  
  # Verify writable
  if [[ ! -w "$HPS_BASE" ]]; then
    hps_log error "  ✗ Base directory not writable: ${HPS_BASE}"
    return 1
  fi
  
  hps_log info "  ✓ Base path verified: ${HPS_BASE}"
  return 0
}

#===============================================================================
# hps_ensure_config
# -----------------
# Create hps.conf with 4 base paths.
#
# Behaviour:
#   - Creates ${HPS_BASE}/hps.conf if it doesn't exist
#   - Exports 4 base paths (absolute, resolved)
#   - Idempotent - skips if config already exists
#   - Adds documentation comments
#
# Returns:
#   0 on success or if already exists
#   1 if config cannot be created
#
# Example usage:
#   hps_ensure_config || exit 1
#
#===============================================================================
hps_ensure_config() {
  local hps_conf="${HPS_BASE}/hps.conf"
  
  # Skip if already exists
  if [[ -f "$hps_conf" ]]; then
    hps_log info "Configuration already exists: ${hps_conf}"
    return 0
  fi
  
  hps_log info "Creating HPS configuration: ${hps_conf}"
  
  # Define base paths (absolute, resolved from HPS_BASE)
  local system_base="${HPS_BASE}/hps-system"
  local config_base="${HPS_BASE}/hps-config"
  local resources="${HPS_BASE}/hps-resources"
  local log="${HPS_BASE}/hps-log"
  
  # Write configuration file
  cat > "$hps_conf" <<EOF
# HPS Configuration
# Generated: $(date -Iseconds)
# Base Path: ${HPS_BASE}
#
# This file defines the 4 foundation paths for HPS.
# All other paths are derived from these via hps_get_config().
#
# To relocate HPS installation:
#   1. Set HPS_BASE environment variable before starting
#   2. Re-run initialization to generate new hps.conf
#
# Example: HPS_BASE=/opt/hps /srv/hps-system/scripts/run-hps.sh

export HPS_SYSTEM_BASE="${system_base}"
export HPS_CONFIG_BASE="${config_base}"
export HPS_RESOURCES="${resources}"
export HPS_LOG="${log}"
EOF

  if [[ $? -eq 0 ]]; then
    hps_log info "  ✓ Created configuration: ${hps_conf}"
    return 0
  else
    hps_log error "  ✗ Failed to create configuration: ${hps_conf}"
    return 1
  fi
}

#===============================================================================
# hps_ensure_directories
# ----------------------
# Create base directory structure.
#
# Behaviour:
#   - Sources hps.conf to get base paths
#   - Creates 4 base directories
#   - Idempotent - safe to run multiple times
#
# Returns:
#   0 on success
#   1 if any directory cannot be created
#
# Example usage:
#   hps_ensure_directories || exit 1
#
#===============================================================================
hps_ensure_directories() {
  local hps_conf="${HPS_BASE}/hps.conf"
  
  # Source config to get paths
  if [[ ! -f "$hps_conf" ]]; then
    hps_log error "Configuration not found: ${hps_conf}"
    return 1
  fi
  
  source "$hps_conf"
  
  hps_log info "Creating base directories"
  
  # Create each base directory
  local dirs=(
    "$HPS_SYSTEM_BASE"
    "$HPS_CONFIG_BASE"
    "$HPS_RESOURCES"
    "$HPS_LOG"
  )
  
  local failed=0
  for dir in "${dirs[@]}"; do
    if [[ -d "$dir" ]]; then
      hps_log info "  ✓ Exists: ${dir}"
    elif mkdir -p "$dir" 2>/dev/null; then
      hps_log info "  ✓ Created: ${dir}"
    else
      hps_log error "  ✗ Failed to create: ${dir}"
      ((failed++))
    fi
  done
  
  if [[ $failed -eq 0 ]]; then
    hps_log info "  ✓ All base directories ready"
    return 0
  else
    hps_log error "  ✗ Failed to create $failed directories"
    return 1
  fi
}

#===============================================================================
# hps_ensure_system_registry
# --------------------------
# Initialize system registry database.
#
# Behaviour:
#   - Creates system.db directory if it doesn't exist
#   - Initializes registry structure
#   - Does NOT set ACTIVE_CLUSTER (that's done by cluster-configure)
#
# Returns:
#   0 on success
#   1 if registry cannot be initialized
#
# Example usage:
#   hps_ensure_system_registry || exit 1
#
#===============================================================================
hps_ensure_system_registry() {
  local hps_conf="${HPS_BASE}/hps.conf"
  
  # Source config to get paths
  if [[ ! -f "$hps_conf" ]]; then
    hps_log error "Configuration not found: ${hps_conf}"
    return 1
  fi
  
  source "$hps_conf"
  
  local registry_path="${HPS_CONFIG_BASE}/system.db"
  
  hps_log info "Initializing system registry: ${registry_path}"
  
  # Create registry directory and lock directory
  if mkdir -p "${registry_path}/.lock" 2>/dev/null; then
    hps_log info "  ✓ System registry initialized"
    return 0
  else
    hps_log error "  ✗ Failed to initialize system registry"
    return 1
  fi
}

#===============================================================================
# hps_system_initialize
# ---------------------
# Master initialization function - orchestrates all bootstrap steps.
#
# Behaviour:
#   - Verifies dependencies
#   - Ensures base path exists
#   - Creates hps.conf
#   - Creates directory structure
#   - Initializes system registry
#   - Returns success if already initialized
#
# Returns:
#   0 on success (or if already initialized)
#   1 if any step fails
#
# Example usage:
#   hps_system_initialize || exit 1
#   # Now safe to load functions.sh
#
#===============================================================================
hps_system_initialize() {
  hps_log info "Starting HPS system initialization"
  
  # Step 1: Verify dependencies
  if ! hps_verify_dependencies; then
    hps_log error "Dependency verification failed"
    return 1
  fi
  
  # Step 2: Ensure base path
  if ! hps_ensure_base_path; then
    hps_log error "Base path setup failed"
    return 1
  fi
  
  # Step 3: Create hps.conf
  if ! hps_ensure_config; then
    hps_log error "Configuration creation failed"
    return 1
  fi
  
  # Step 4: Create directories
  if ! hps_ensure_directories; then
    hps_log error "Directory creation failed"
    return 1
  fi
  
  # Step 5: Initialize system registry
  if ! hps_ensure_system_registry; then
    hps_log error "System registry initialization failed"
    return 1
  fi
  
  hps_log info "✓ HPS system initialization complete"
  return 0
}

#===============================================================================
# Bootstrap Complete
#===============================================================================
# At this point:
# - All dependencies verified
# - hps.conf exists with 4 base paths
# - Base directories created
# - System registry initialized
# - Ready to load functions.sh
#===============================================================================
