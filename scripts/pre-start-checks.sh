#!/bin/bash
#===============================================================================
# pre-start-checks.sh
# -------------------
# Validate HPS configuration completeness before starting services.
#
# Usage:
#   /srv/hps-system/scripts/pre-start-checks.sh
#   # Or called from run-hps.sh in subshell
#
# Returns:
#   0 if all checks pass (or only warnings)
#   1 if critical errors found
#
#===============================================================================

#set -euo pipefail

# Track issues
ERRORS=0
WARNINGS=0

#===============================================================================
# Bootstrap
#===============================================================================
# Determine HPS_BASE
export HPS_BASE="${HPS_BASE:-/srv}"
SYSTEM_PATH="${HPS_BASE}/hps-system"

# Load function libraries
if [[ -f "${SYSTEM_PATH}/lib/functions.sh" ]]; then
  source "${SYSTEM_PATH}/lib/functions.sh" || {
    echo "[PRE-CHECK] ERROR: Failed to load function libraries" >&2
    exit 1
  }
else
  echo "[PRE-CHECK] ERROR: Function library not found: ${SYSTEM_PATH}/lib/functions.sh" >&2
  exit 1
fi

#===============================================================================
# Start Validation
#===============================================================================
hps_log info "=== HPS Configuration Validation ==="

#===============================================================================
# 1. Validate hps.conf base paths
#===============================================================================
hps_log info "1. Checking hps.conf base paths"

check_path() {
  local key="$1"
  local path
  path=$(hps_get_config "$key" 2>/dev/null)
  
  if [[ -z "$path" ]]; then
    hps_log error "  ✗ $key: NOT SET"
    ((ERRORS++))
  elif [[ ! -d "$path" ]]; then
    hps_log warn "  ⚠ $key: $path (directory does not exist)"
    ((WARNINGS++))
  else
    hps_log info "  ✓ $key: $path"
  fi
}

check_path "system_base"
check_path "config_base"
check_path "resources"
check_path "log"

#===============================================================================
# 2. Validate system registry
#===============================================================================
hps_log info "2. Checking system registry"

check_registry_key() {
  local key="$1"
  local required="$2"
  local value
  value=$(system_registry get "$key" 2>/dev/null) || value=""
  
  if [[ -z "$value" ]]; then
    if [[ "$required" == "required" ]]; then
      hps_log error "  ✗ $key: NOT SET (required)"
      ((ERRORS++))
    else
      hps_log warn "  ⚠ $key: NOT SET (optional)"
      ((WARNINGS++))
    fi
  else
    hps_log info "  ✓ $key: $value"
  fi
}

check_registry_key "ACTIVE_CLUSTER" "optional"

#===============================================================================
# 3. Validate active cluster (if configured)
#===============================================================================
hps_log info "3. Checking active cluster configuration"

# Use hps_get_config which uses system_registry internally
ACTIVE_CLUSTER=$(hps_get_config active_cluster 2>/dev/null) || ACTIVE_CLUSTER=""

if [[ -z "$ACTIVE_CLUSTER" ]]; then
  hps_log info "  ⚠ No active cluster configured (expected on first boot)"
  hps_log info "  → Run cluster-configure.sh to set up a cluster"
  # This is NOT an error - just info
else
  hps_log info "  ✓ Active cluster: $ACTIVE_CLUSTER"
  
  # Check if cluster directory exists
  cluster_base=$(hps_get_config cluster_base 2>/dev/null)
  if [[ -d "$cluster_base" ]]; then
    hps_log info "  ✓ Cluster directory exists: $cluster_base"
  else
    hps_log error "  ✗ Cluster directory not found: $cluster_base"
    ((ERRORS++))
  fi
fi

#===============================================================================
# 4. Validate cluster registry (if active cluster set)
#===============================================================================
if [[ -n "$ACTIVE_CLUSTER" ]]; then
  hps_log info "4. Checking cluster registry keys"
  
  check_cluster_key() {
    local key="$1"
    local required="$2"
    local value
    value=$(cluster_registry get "$key" 2>/dev/null) || value=""
    
    if [[ -z "$value" ]]; then
      if [[ "$required" == "required" ]]; then
        hps_log error "  ✗ $key: NOT SET (required)"
        ((ERRORS++))
      else
        hps_log warn "  ⚠ $key: NOT SET (optional)"
        ((WARNINGS++))
      fi
    else
      hps_log info "  ✓ $key: $value"
    fi
  }
  
  # Required cluster keys
  check_cluster_key "CLUSTER_NAME" "required"
  check_cluster_key "network_dhcp_ip" "required"
  check_cluster_key "network_cidr" "required"
  
  # Optional cluster keys
  check_cluster_key "dns_domain" "optional"
  check_cluster_key "network_dhcp_iface" "optional"
  check_cluster_key "network_dhcp_rangesize" "optional"
else
  hps_log info "4. Skipping cluster registry checks (no cluster configured)"
fi

#===============================================================================
# 5. Validate hps_get_config derived paths
#===============================================================================
hps_log info "5. Checking hps_get_config derived paths"

check_derived_path() {
  local key="$1"
  local path
  path=$(hps_get_config "$key" 2>/dev/null)
  
  if [[ $? -ne 0 ]] || [[ -z "$path" ]]; then
    hps_log error "  ✗ $key: FAILED to retrieve"
    ((ERRORS++))
  else
    hps_log info "  ✓ $key: $path"
  fi
}

# Always available paths
check_derived_path "system_registry"
check_derived_path "os_registry"
check_derived_path "tftp"
check_derived_path "system_log"
check_derived_path "supervisord_conf"
check_derived_path "supervisord_dir"

# Cluster-specific paths (only if cluster configured)
if [[ -n "$ACTIVE_CLUSTER" ]]; then
  check_derived_path "cluster_base"
  check_derived_path "cluster_hosts"
  check_derived_path "cluster_services"
  check_derived_path "cluster_registry"
  check_derived_path "cluster_log"
fi

#===============================================================================
# 6. Summary
#===============================================================================
hps_log info "=== Validation Summary ==="
hps_log info "Errors:   $ERRORS"
hps_log info "Warnings: $WARNINGS"

if [[ $ERRORS -eq 0 ]] && [[ $WARNINGS -eq 0 ]]; then
  hps_log info "✓ All checks passed!"
  exit 0
elif [[ $ERRORS -eq 0 ]]; then
  hps_log warn "⚠ Validation passed with warnings"
  exit 0
else
  hps_log error "✗ Validation failed with $ERRORS errors"
  exit 1
fi
