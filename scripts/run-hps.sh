#!/bin/bash
#===============================================================================
# run-hps.sh - HPS System Entry Point
#===============================================================================
# Main entry point for HPS system startup.
# Called by entrypoint.sh in Docker or directly by sysadmin.
#
# Behaviour:
#   1. Initialize HPS system (create hps.conf, directories, registry)
#   2. Load all function libraries
#   3. Validate configuration (pre-start checks)
#   4. Check if cluster configured
#   5. Prepare services if cluster configured
#   6. Start supervisord
#
# Environment Variables:
#   HPS_BASE - Base installation path (default: /srv)
#              Set this to relocate HPS installation
#
# Usage:
#   /srv/hps-system/scripts/run-hps.sh
#   HPS_BASE=/opt/hps /opt/hps/hps-system/scripts/run-hps.sh
#
#===============================================================================

set -euo pipefail

#===============================================================================
# Configuration
#===============================================================================
# Base path - customizable via environment
export HPS_BASE="${HPS_BASE:-/srv}"

# Derive system path from base
SYSTEM_PATH="${HPS_BASE}/hps-system"

# Set container hostname to 'ips' if not already set
if [[ "$(hostname)" != "ips" ]]; then
  if hostname ips 2>/dev/null; then
    echo "ips" > /etc/hostname 2>/dev/null || true
  fi
fi

#===============================================================================
# Step 1: Bootstrap System (Tier 1)
#===============================================================================
# Load bootstrap library (provides simple hps_log)
if [[ ! -f "${SYSTEM_PATH}/lib/hps-system.sh" ]]; then
  echo "[RUN-HPS] ERROR: Bootstrap library not found: ${SYSTEM_PATH}/lib/hps-system.sh" >&2
  echo "[RUN-HPS] Ensure hps-system is installed at: ${SYSTEM_PATH}" >&2
  exit 1
fi

source "${SYSTEM_PATH}/lib/hps-system.sh" || {
  echo "[RUN-HPS] ERROR: Failed to source bootstrap library" >&2
  exit 1
}

# Verify critical functions loaded
if ! declare -f hps_log >/dev/null 2>&1; then
  echo "[RUN-HPS] FATAL: hps_log function not defined after sourcing hps-system.sh" >&2
  echo "[RUN-HPS] Check ${SYSTEM_PATH}/lib/hps-system.sh for syntax errors" >&2
  exit 1
fi

if ! declare -f hps_system_initialize >/dev/null 2>&1; then
  echo "[RUN-HPS] FATAL: hps_system_initialize function not defined after sourcing hps-system.sh" >&2
  echo "[RUN-HPS] Check ${SYSTEM_PATH}/lib/hps-system.sh for syntax errors" >&2
  exit 1
fi

# Now hps_log available (bootstrap version)
hps_log info "Starting HPS system bootstrap"
hps_log info "Base path: ${HPS_BASE}"

# Initialize system (create hps.conf, directories, registry)
hps_system_initialize || {
  hps_log error "System initialization failed"
  exit 1
}

hps_log info "✓ System bootstrap complete"

#===============================================================================
# Step 2: Load Function Libraries (Tier 2)
#===============================================================================
hps_log info "Loading function libraries"

if [[ ! -f "${SYSTEM_PATH}/lib/functions.sh" ]]; then
  hps_log error "Function library loader not found: ${SYSTEM_PATH}/lib/functions.sh"
  exit 1
fi

source "${SYSTEM_PATH}/lib/functions.sh" || {
  hps_log error "Failed to load function libraries"
  exit 1
}

# Verify critical functions loaded
if ! declare -f hps_get_config >/dev/null 2>&1; then
  echo "[RUN-HPS] ERROR: hps_get_config function not defined after sourcing functions.sh" >&2
  exit 1
fi

if ! declare -f system_registry >/dev/null 2>&1; then
  echo "[RUN-HPS] ERROR: system_registry function not defined after sourcing functions.sh" >&2
  exit 1
fi

# Log completion using full hps_log (now upgraded from bootstrap version)
echo "✓ Function libraries loaded - logging upgraded to full version"

#===============================================================================
# Step 3: Validate Configuration (Pre-Start Checks)
#===============================================================================
hps_log info "Running pre-start validation"

PRE_START_CHECKS="${SYSTEM_PATH}/scripts/pre-start-checks.sh"

if [[ ! -f "$PRE_START_CHECKS" ]]; then
  hps_log warn "Pre-start checks script not found: ${PRE_START_CHECKS}"
  hps_log warn "Continuing without validation"
else
  if bash "$PRE_START_CHECKS"; then
    hps_log info "✓ Pre-start validation passed"
  else
    validation_exit=$?
    if [[ $validation_exit -eq 1 ]]; then
      hps_log error "Pre-start validation failed with critical errors"
      hps_log error "Cannot start services - fix configuration and restart"
      exit 1
    else
      hps_log warn "Pre-start validation completed with warnings"
      hps_log warn "Continuing startup despite warnings"
    fi
  fi
fi

#===============================================================================
# Step 4: Check Cluster Configuration
#===============================================================================
hps_log info "Checking cluster configuration"

if system_registry exists ACTIVE_CLUSTER 2>/dev/null; then
  ACTIVE_CLUSTER=$(system_registry get ACTIVE_CLUSTER 2>/dev/null)
  
  if [[ -n "$ACTIVE_CLUSTER" ]]; then
    hps_log info "Active cluster found: ${ACTIVE_CLUSTER}"
    
    # Verify cluster directory exists
    cluster_dir=$(hps_get_config cluster_base 2>/dev/null)
    if [[ -d "$cluster_dir" ]]; then
      hps_log info "Cluster directory verified: ${cluster_dir}"
      CLUSTER_CONFIGURED=true
    else
      hps_log warn "Cluster '${ACTIVE_CLUSTER}' set but directory missing: ${cluster_dir}"
      CLUSTER_CONFIGURED=false
    fi
  else
    hps_log info "No active cluster configured"
    CLUSTER_CONFIGURED=false
  fi
else
  hps_log info "No active cluster configured"
  CLUSTER_CONFIGURED=false
fi

#===============================================================================
# Step 4b: Bring up the ctrl-exec dispatcher (CA + install), cluster-independent
#===============================================================================
if declare -f ce_dispatcher_bring_up >/dev/null 2>&1; then
  hps_log info "Bringing up ctrl-exec dispatcher"
  ce_dispatcher_bring_up || hps_log warn "ctrl-exec dispatcher bring-up failed; remote execution unavailable until resolved"
fi

#===============================================================================
# Step 5: Prepare Services (if cluster configured)
#===============================================================================
if [[ "${CLUSTER_CONFIGURED}" == "true" ]]; then
  hps_log info "Preparing services for cluster: ${ACTIVE_CLUSTER}"
  
  # Check if supervisor preparation function exists
  if declare -f _supervisor_pre_start >/dev/null 2>&1; then
    _supervisor_pre_start || {
      hps_log error "Service preparation failed"
      exit 1
    }
    hps_log info "✓ Services prepared"
  else
    hps_log warn "Function _supervisor_pre_start not found - skipping service preparation"
  fi
else
  hps_log info "No cluster configured - services will not be started"
  hps_log info "To configure a cluster, run:"
  hps_log info "  ${SYSTEM_PATH}/cli/cluster-configure.sh"
fi

#===============================================================================
# Step 6: Start Supervisord
#===============================================================================
hps_log info "Starting supervisord"


# Get supervisor configuration path
SUPERVISORD_CONF=$(hps_get_config supervisord_conf 2>/dev/null) || {
  hps_log error "Cannot determine supervisord configuration path"
  exit 1
}

# Verify supervisord binary available
if ! command -v supervisord >/dev/null 2>&1; then
  hps_log error "supervisord binary not found"
  exit 1
fi

hps_log info "Handing control to supervisord"
hps_log info "Configuration: ${SUPERVISORD_CONF}"

# Execute supervisord (replaces current process)
exec supervisord -c "${SUPERVISORD_CONF}"
